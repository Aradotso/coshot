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

        state.commandMode = false
        state.output = ""
        state.ocrText = nil
        state.lastKey = ""
        state.status = "Capturing…"

        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            do {
                let text = try await Capture.captureAndOCR()
                self.state.ocrText = text
                self.state.status = text.isEmpty
                    ? "No text detected on screen"
                    : "Ready — press Space for command mode"
            } catch {
                self.state.status = "Capture failed: \(error.localizedDescription)"
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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
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
            onSubmit: { [weak self] prompt in self?.run(prompt) },
            onPaste: { [weak self] in self?.pasteOutput() },
            onEscape: { [weak self] in self?.hide() }
        )
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

        // ⌘↩ → paste result
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            pasteOutput()
            return nil
        }

        // Space → toggle command mode (unless already in it — then it's a key press)
        if event.keyCode == 49 && !state.commandMode {
            state.commandMode = true
            state.lastKey = ""
            return nil
        }

        if state.commandMode {
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            state.lastKey = chars
            let lib = PromptLibrary.load()
            if let p = lib.prompts.first(where: { $0.key.lowercased() == chars }) {
                state.commandMode = false
                run(p)
            }
            return nil
        }

        return event
    }

    private func run(_ prompt: Prompt) {
        guard let ocr = state.ocrText, !ocr.isEmpty else {
            state.status = "Nothing to send — capture failed or screen empty"
            return
        }
        streamTask?.cancel()
        state.output = ""
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
                if !Task.isCancelled {
                    self.state.status = "Done — ⌘↩ to paste, Esc to dismiss"
                }
            } catch {
                if !Task.isCancelled {
                    self.state.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func pasteOutput() {
        let text = state.output
        guard !text.isEmpty else { return }
        hide()
        // Let the previous app regain focus, then synthesise ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Paster.paste(text)
        }
    }
}
