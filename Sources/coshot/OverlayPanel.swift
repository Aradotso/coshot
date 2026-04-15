import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    static let hardcodedTriggerKeys: [Character] = ["5", "6", "7", "8", "9", "0"]

    private var panel: KeyablePanel?
    private let state = OverlayState()
    private var streamTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var configPollTask: Task<Void, Never>?
    private var hasPromptedScreenRecordingThisSession = false
    private var hasPromptedAccessibilityThisSession = false

    // MARK: - Public API

    /// Called when the user clicks the Dock icon or the menu bar "Configure…"
    /// item. Activates coshot normally (user intent is explicit), skips
    /// capture, and opens the overlay in config mode for editing prompts.
    func showConfig() {
        show(capture: false)
    }

    /// Fire a prompt without opening the overlay. This is the ⌥Space
    /// listen-mode path: AppDelegate intercepts the key via CGEventTap
    /// and calls here. We run capture → LLM → paste entirely in the
    /// background; the user's cursor is still in their target app so
    /// CGEventPost ⌘V lands there.
    func fireListenedPrompt(_ key: Character) {
        Log.fire.info("fireListenedPrompt key=\(String(key), privacy: .public)")

        let prompts = Self.promptsWithHardcodedKeys(PromptLibrary.load().prompts)
        guard let keyIndex = Self.hardcodedTriggerKeys.firstIndex(of: key),
              keyIndex < prompts.count else {
            Log.fire.error("no hardcoded prompt mapped to key=\(String(key), privacy: .public)")
            return
        }
        let prompt = prompts[keyIndex]
        Log.fire.info("matched prompt name=\(prompt.name, privacy: .public) template_len=\(prompt.template.count, privacy: .public)")

        streamTask?.cancel()
        state.output = ""
        state.isStreaming = true

        let t0 = Date()

        streamTask = Task { @MainActor [weak self] in
            guard let self = self else {
                Log.fire.error("self nil in stream task")
                return
            }
            do {
                Log.fire.info("t+\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms → calling Capture.captureAndOCR")
                let ocr = try await Capture.captureAndOCR()
                Log.fire.info("t+\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms ← OCR returned \(ocr.count, privacy: .public) chars")
                guard !ocr.isEmpty else {
                    Log.fire.error("OCR returned empty, aborting")
                    self.state.isStreaming = false
                    return
                }

                Log.fire.info("t+\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms → CerebrasClient.stream model=\(prompt.model ?? "llama3.1-8b", privacy: .public)")
                try await CerebrasClient().stream(
                    model: prompt.model ?? "llama3.1-8b",
                    system: prompt.template,
                    user: ocr,
                    onDelta: { [weak self] delta in
                        Task { @MainActor in self?.state.output += delta }
                    }
                )
                Log.fire.info("t+\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms ← stream done output_len=\(self.state.output.count, privacy: .public)")

                guard !Task.isCancelled else {
                    Log.fire.info("task cancelled before paste")
                    return
                }
                self.state.isStreaming = false
                Log.fire.info("t+\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms → Paster.paste \(self.state.output.count, privacy: .public) chars")
                Paster.paste(self.state.output)
                Log.fire.info("t+\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms ✓ fire complete")
            } catch {
                self.state.isStreaming = false
                Log.fire.error("ERROR: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Show / hide

    private func show(capture: Bool) {
        if panel == nil { buildPanel() }

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let s = panel!.frame.size
            panel!.setFrameOrigin(NSPoint(
                x: f.midX - s.width / 2,
                y: f.midY - s.height / 2 + 80
            ))
        }

        // Refresh state each show so disk edits are picked up.
        state.prompts = Self.promptsWithHardcodedKeys(PromptLibrary.load().prompts)
        state.output = ""
        state.ocrText = nil
        state.lastKey = ""
        state.editingPromptIndex = nil
        state.isStreaming = false
        state.isConfigMode = !capture
        state.status = capture ? "Capturing…" : "Configure"

        if capture {
            panel!.orderFrontRegardless()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel!.makeKeyAndOrderFront(nil)
            startConfigPolling()
            requestMissingPermissions()
        }

        if capture {
            Task { @MainActor in
                do {
                    let text = try await Capture.captureAndOCR()
                    self.state.ocrText = text
                    self.state.status = text.isEmpty
                        ? "No text detected on screen"
                        : "Press any configured prompt key"
                } catch {
                    let msg = error.localizedDescription.lowercased()
                    let tccFailure = msg.contains("declined")
                        || msg.contains("tcc")
                        || !PermissionGate.hasScreenRecording
                    if tccFailure {
                        self.state.status = "Screen Recording denied — enable it in System Settings"
                        PermissionGate.reactToScreenRecordingDenied()
                    } else {
                        self.state.status = "Capture failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func hide() {
        streamTask?.cancel()
        configPollTask?.cancel()
        configPollTask = nil
        state.capturingShortcutForPromptIndex = nil
        panel?.orderOut(nil)
    }

    // MARK: - Config mode: live permission status

    private func refreshPermissionStatus() {
        state.hasScreenRecording = PermissionGate.hasScreenRecording
        state.hasAccessibility   = PermissionGate.hasAccessibility
        state.hasApiKey          = PermissionGate.hasApiKey
    }

    private func startConfigPolling() {
        configPollTask?.cancel()
        refreshPermissionStatus()
        configPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self = self else { return }
                self.refreshPermissionStatus()
            }
        }
    }

    private func requestMissingPermissions() {
        if !PermissionGate.hasScreenRecording {
            if !hasPromptedScreenRecordingThisSession {
                hasPromptedScreenRecordingThisSession = true
                _ = CGRequestScreenCaptureAccess()
                Task.detached {
                    _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
            }
        }
        if !PermissionGate.hasAccessibility {
            if !hasPromptedAccessibilityThisSession {
                hasPromptedAccessibilityThisSession = true
                _ = AXIsProcessTrustedWithOptions([
                    "AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue
                ] as CFDictionary)
            }
        }
    }

    // MARK: - Permission fix callbacks (wired from OverlayView)

    private func fixScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        Task.detached {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func fixAccessibility() {
        _ = AXIsProcessTrustedWithOptions([
            "AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue
        ] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func fixApiKey() {
        let alert = NSAlert()
        alert.messageText = "Cerebras API Key"
        alert.informativeText = "Stored in macOS Keychain. Get a key at cloud.cerebras.ai."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.stringValue = Keychain.load() ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Keychain.save(input.stringValue)
            refreshPermissionStatus()
        }
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true

        let view = OverlayView(
            state: state,
            onRunPrompt:  { [weak self] index in self?.runPromptAt(index) },
            onEditPrompt: { [weak self] index in self?.startEdit(at: index) },
            onStartShortcutCapture: { [weak self] index in self?.startShortcutCapture(at: index) },
            onSaveEdit:   { [weak self] index in self?.saveEdit(at: index) },
            onCancelEdit: { [weak self] in self?.cancelEdit() },
            onFixScreenRecording: { [weak self] in self?.fixScreenRecording() },
            onFixAccessibility:   { [weak self] in self?.fixAccessibility() },
            onFixApiKey:          { [weak self] in self?.fixApiKey() }
        )
        p.contentView = NSHostingView(rootView: view)
        panel = p

        installKeyMonitor()
    }

    // MARK: - Key routing

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let panel = self.panel,
                  panel.isKeyWindow else { return event }
            return self.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Escape: close editor if open; otherwise hide the panel.
        if event.keyCode == 53 {
            if state.editingPromptIndex != nil {
                cancelEdit()
            } else {
                hide()
            }
            return nil
        }

        // While editing a prompt, let all keys reach the TextEditor.
        if state.editingPromptIndex != nil {
            if let idx = state.editingPromptIndex,
               state.capturingShortcutForPromptIndex == idx {
                if let key = ListenModeTap.keyForKeyCode(Int64(event.keyCode)) {
                    let keyString = String(key)
                    if state.prompts.enumerated().contains(where: {
                        $0.offset != idx && $0.element.key.lowercased() == keyString
                    }) {
                        state.status = "Key \(keyString.uppercased()) already in use"
                    } else {
                        state.prompts[idx].key = keyString
                        state.capturingShortcutForPromptIndex = nil
                        state.status = "Shortcut set to \(keyString.uppercased()) — ⌘S saves"
                    }
                    return nil
                } else {
                    state.status = "Unsupported key — try letters, numbers, punctuation"
                    return nil
                }
            }

            // ⌘S saves.
            if event.keyCode == 1 && event.modifierFlags.contains(.command),
               let idx = state.editingPromptIndex {
                saveEdit(at: idx)
                return nil
            }
            return event
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        guard !chars.isEmpty else { return event }

        if let index = state.prompts.firstIndex(where: { $0.key.lowercased() == chars }) {
            state.lastKey = chars
            run(state.prompts[index])
            return nil
        }

        return event
    }

    // MARK: - Prompt execution

    /// Called from a mouse click on a BigKey tile. Same effect as typing
    /// the prompt's key in config mode — captures (already done on show),
    /// runs the LLM, copies to clipboard, pastes into the frontmost app.
    private func runPromptAt(_ index: Int) {
        guard index < state.prompts.count else { return }
        state.lastKey = state.prompts[index].key.lowercased()
        run(state.prompts[index])
    }

    private func run(_ prompt: Prompt) {
        guard let ocr = state.ocrText, !ocr.isEmpty else {
            // Capture hasn't completed or failed — status already explains.
            return
        }
        streamTask?.cancel()
        state.output = ""
        state.isStreaming = true
        state.status = "→ \(prompt.name)…"

        streamTask = Task { @MainActor in
            do {
                try await CerebrasClient().stream(
                    model: prompt.model ?? "llama3.1-8b",
                    system: prompt.template,
                    user: ocr,
                    onDelta: { [weak self] delta in
                        Task { @MainActor in self?.state.output += delta }
                    }
                )
                guard !Task.isCancelled else { return }
                self.state.isStreaming = false
                self.state.status = "Pasting…"
                try? await Task.sleep(nanoseconds: 250_000_000)
                self.pasteOutput()
            } catch {
                if !Task.isCancelled {
                    self.state.isStreaming = false
                    self.state.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func pasteOutput() {
        let text = state.output
        guard !text.isEmpty else { return }
        hide()
        // No focus-restoration delay — we never stole focus.
        Paster.paste(text)
    }

    // MARK: - Edit flow

    private func startEdit(at index: Int) {
        guard index < state.prompts.count else { return }
        state.editingPromptIndex = index
        state.capturingShortcutForPromptIndex = nil
        state.status = "Editing — ⌘S saves, Esc cancels"
    }

    private func startShortcutCapture(at index: Int) {
        guard state.editingPromptIndex == index else { return }
        state.status = "Shortcuts are fixed to ⌃Space + ⌃⇧5/6/7/8/9/0"
    }

    private func saveEdit(at index: Int) {
        guard index < state.prompts.count else { return }
        var normalizedPrompts = Self.promptsWithHardcodedKeys(state.prompts)

        for i in normalizedPrompts.indices {
            guard let normalized = Self.normalizedShortcutKey(normalizedPrompts[i].key) else {
                state.status = "Invalid key in \(normalizedPrompts[i].name) — pick from key buttons"
                return
            }
            normalizedPrompts[i].key = normalized
        }

        var seen = Set<String>()
        for prompt in normalizedPrompts {
            if seen.contains(prompt.key) {
                state.status = "Duplicate key \(prompt.key.uppercased()) — choose unique keys"
                return
            }
            seen.insert(prompt.key)
        }

        do {
            try PromptLibrary.save(normalizedPrompts)
            state.prompts = normalizedPrompts
            state.editingPromptIndex = nil
            state.capturingShortcutForPromptIndex = nil
            state.status = state.isConfigMode ? "Saved" : "Saved — ready"
        } catch {
            state.status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func cancelEdit() {
        // Reload from disk to discard unsaved changes.
        state.prompts = Self.promptsWithHardcodedKeys(PromptLibrary.load().prompts)
        state.editingPromptIndex = nil
        state.capturingShortcutForPromptIndex = nil
        state.status = state.isConfigMode ? "Configure" : "Ready"
    }

    private static func promptsWithHardcodedKeys(_ prompts: [Prompt]) -> [Prompt] {
        var out = prompts
        for i in 0..<min(out.count, hardcodedTriggerKeys.count) {
            out[i].key = String(hardcodedTriggerKeys[i])
        }
        return out
    }

    private static func normalizedShortcutKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = trimmed.first else { return nil }
        guard ListenModeTap.supportedKeySet.contains(first) else { return nil }
        return String(first)
    }
}
