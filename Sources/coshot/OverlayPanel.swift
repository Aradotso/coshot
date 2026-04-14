import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    private var panel: KeyablePanel?
    private let state = OverlayState()
    private var streamTask: Task<Void, Never>?
    private var keyMonitor: Any?

    // MARK: - Public API

    /// Called when the user clicks the Dock icon or the menu bar "Configure…"
    /// item. Activates coshot normally (user intent is explicit), skips
    /// capture, and opens the overlay in config mode for editing prompts.
    func showConfig() {
        show(capture: false)
    }

    /// Fire a prompt without opening the overlay. This is the ⌥Space
    /// listen-mode path: AppDelegate intercepts the letter via CGEventTap
    /// and calls here. We run capture → LLM → paste entirely in the
    /// background; the user's cursor is still in their target app so
    /// CGEventPost ⌘V lands there.
    func fireListenedPrompt(_ letter: Character) {
        Log.fire.info("fireListenedPrompt letter=\(String(letter), privacy: .public)")

        let lib = PromptLibrary.load()
        let key = String(letter).lowercased()
        guard let prompt = lib.prompts.first(where: { $0.key.lowercased() == key }) else {
            Log.fire.error("no prompt mapped to letter=\(String(letter), privacy: .public) — prompts.json has \(lib.prompts.count) entries")
            return
        }
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
        state.prompts = PromptLibrary.load().prompts
        state.output = ""
        state.ocrText = nil
        state.lastKey = ""
        state.editingPromptIndex = nil
        state.isStreaming = false
        state.isConfigMode = !capture
        state.status = capture ? "Capturing…" : "Configure"

        if capture {
            // HOTKEY PATH: orderFrontRegardless shows the panel visually
            // without making it key and without activating coshot. The
            // user's target app stays frontmost, so ⌘V landed via
            // CGEventPost goes where the cursor was. All interaction in
            // capture mode is mouse-only (single-click = run, double-click
            // = edit); no keyboard shortcuts, because key events continue
            // to flow into the target app.
            panel!.orderFrontRegardless()
        } else {
            // CONFIG PATH: user clicked the Dock / menu bar, so activate
            // normally. Paste won't work from here (coshot is frontmost)
            // — that's fine, config mode is for editing prompts and
            // keyboard shortcuts work here.
            NSApp.activate(ignoringOtherApps: true)
            panel!.makeKeyAndOrderFront(nil)
        }

        if capture {
            Task { @MainActor in
                do {
                    let text = try await Capture.captureAndOCR()
                    self.state.ocrText = text
                    self.state.status = text.isEmpty
                        ? "No text detected on screen"
                        : "Press A · S · D · F · G"
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
        panel?.orderOut(nil)
        // No previousApp?.activate() — we never activated in the first place
        // in capture mode, and in config mode the user can pick their own
        // next app.
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
            onSaveEdit:   { [weak self] index in self?.saveEdit(at: index) },
            onCancelEdit: { [weak self] in self?.cancelEdit() }
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
    /// the prompt's letter in config mode — captures (already done on show),
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
        state.status = "Editing — ⌘S saves, Esc cancels"
    }

    private func saveEdit(at index: Int) {
        guard index < state.prompts.count else { return }
        do {
            try PromptLibrary.save(state.prompts)
            state.editingPromptIndex = nil
            state.status = state.isConfigMode ? "Saved" : "Saved — ready"
        } catch {
            state.status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func cancelEdit() {
        // Reload from disk to discard unsaved changes.
        state.prompts = PromptLibrary.load().prompts
        state.editingPromptIndex = nil
        state.status = state.isConfigMode ? "Configure" : "Ready"
    }
}
