import AppKit

@main
@MainActor
struct CoshotApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .regular: shows in the Dock, in alt-tab, and makes TCC treat coshot
        // as a first-class app so it registers cleanly in System Settings →
        // Privacy & Security → Screen Recording.
        app.setActivationPolicy(.regular)
        app.run()
    }
}
