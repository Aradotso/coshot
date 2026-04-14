import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    private var panel: KeyablePanel?
    private var previousApp: NSRunningApplication?
    private let state = OverlayState()
    private var streamTask: Task<Void, Never>?
    private var keyMonitor: Any?

    func toggle() {
        if let p = panel, p.isVisible { hide() } else { show() }
    }

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication

        if panel == nil { buildPanel() }

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let s = panel!.frame.size
            panel!.setFrameOrigin(NSPoint(
                x: f.midX - s.width / 2,
                y: f.midY - s.height / 2 + 80
            ))
        }

        // Refresh state each show so edited prompts.json is picked up.
        state.prompts = PromptLibrary.load().prompts
        state.output = ""
        state.ocrText = nil
        state.lastKey = ""
        state.isStreaming = false
        state.status = "Capturing…"

        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            do {
                let text = try await Capture.captureAndOCR()
                self.state.ocrText = text
                self.state.status = text.isEmpty
                    ? "No text detected on screen"
                    : "Press A · S · D · F · G"
            } catch {
                // If capture failed because of TCC, surface a helpful status
                // in the overlay and start a silent background poll. Do NOT
                // auto-hide the panel or pop a modal — that was causing
                // ⌥Space to feel like "it quit the app" because the alert's
                // Escape key was mapped to the quit button.
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

    private func hide() {
        streamTask?.cancel()
        panel?.orderOut(nil)
        previousApp?.activate()
    }

    private func buildPanel() {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
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

        let view = OverlayView(state: state)
        p.contentView = NSHostingView(rootView: view)
        panel = p

        installKeyMonitor()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let panel = self.panel,
                  panel.isKeyWindow else { return event }
            return self.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Escape → hide
        if event.keyCode == 53 {
            hide()
            return nil
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        guard !chars.isEmpty else { return event }

        // Direct letter → run immediately
        if let p = state.prompts.first(where: { $0.key.lowercased() == chars }) {
            state.lastKey = chars
            run(p)
            return nil
        }

        return event
    }

    private func run(_ prompt: Prompt) {
        guard let ocr = state.ocrText, !ocr.isEmpty else {
            // Don't overwrite the existing status — it already explains why
            // (still capturing, capture failed, or screen is genuinely empty).
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
                // Brief pause so the user sees the full result before it vanishes.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Paster.paste(text)
        }
    }
}
