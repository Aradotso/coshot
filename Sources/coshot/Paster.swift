import AppKit
import CoreGraphics

enum Paster {
    /// Copies `text` to the clipboard and synthesises ⌘V into the frontmost app.
    /// Requires Accessibility permission.
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let prior = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        // Restore the previous clipboard shortly after the paste is consumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let prior = prior else { return }
            pb.clearContents()
            pb.setString(prior, forType: .string)
        }
    }
}
