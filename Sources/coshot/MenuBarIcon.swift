import AppKit

/// Composes the menu-bar status item image. When `listening` is true, a
/// small green dot is drawn in the lower-right corner of the Ara logo
/// to signal "⌥Space listen mode is armed".
enum MenuBarIcon {
    static var base: NSImage?

    static func load() {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            NSLog("coshot: failed to load MenuBarIcon.png from bundle")
            return
        }
        img.size = NSSize(width: 18, height: 18)
        base = img
    }

    static func compose(listening: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let composite = NSImage(size: size)

        composite.lockFocus()
        defer { composite.unlockFocus() }

        if let base = base {
            base.draw(in: NSRect(origin: .zero, size: size))
        } else {
            // Fallback: bolt glyph so we're not blank
            let symbol = NSImage(systemSymbolName: "bolt.fill",
                                 accessibilityDescription: nil)
            symbol?.draw(in: NSRect(origin: .zero, size: size))
        }

        if listening {
            let dotDiameter: CGFloat = 7
            let dotRect = NSRect(
                x: size.width - dotDiameter - 0.5,
                y: 0.5,
                width: dotDiameter,
                height: dotDiameter
            )
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            // Thin dark ring so the dot reads on any menu-bar background.
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let ring = NSBezierPath(ovalIn: dotRect)
            ring.lineWidth = 0.6
            ring.stroke()
        }

        return composite
    }
}
