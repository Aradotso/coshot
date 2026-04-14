import AppKit
import CoreGraphics

enum Paster {
    /// Copies `text` to the clipboard and synthesises ⌘V into the frontmost app.
    /// Requires Accessibility permission.
    static func paste(_ text: String) {
        Log.paste.info("paste() \(text.count, privacy: .public) chars, frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public)")
        let pb = NSPasteboard.general
        let prior = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        if down == nil || up == nil {
            Log.paste.error("CGEvent keyboardEventSource returned nil")
        }
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        Log.paste.info("CGEventPost ⌘V fired")

        // Restore the previous clipboard shortly after the paste is consumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let prior = prior else { return }
            pb.clearContents()
            pb.setString(prior, forType: .string)
        }
    }
}
