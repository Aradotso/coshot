import AppKit
import CoreGraphics

/// A CGEventTap that, while active, intercepts A/S/D/F/G keydown events
/// system-wide and fires a callback. Non-letter keys pass through untouched.
///
/// This is how ⌥Space "listen mode" works: the user presses ⌥Space to arm
/// coshot (we call `start()`), then the very next letter keypress is
/// captured by the tap, consumed (never reaches the target app), and the
/// callback fires. After one capture we `stop()` so typing resumes normally.
///
/// Requires Accessibility permission — the same one we already need for
/// `CGEventPost` auto-paste.
final class ListenModeTap {
    /// Called with the captured letter, on the main thread.
    var onLetter: ((Character) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Virtual keycodes for the default five prompt keys. If you remap
    /// prompts in prompts.json to different letters you'd extend this map —
    /// for v0.2.x we hard-code a/s/d/f/g because the default set is those.
    private static let letterKeyCodes: [Int64: Character] = [
        0: "a",
        1: "s",
        2: "d",
        3: "f",
        5: "g"
    ]

    func start() {
        guard tap == nil else { return }

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let selfRef = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            let tap = Unmanaged<ListenModeTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(event: event, type: type)
        }

        guard let machPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfRef
        ) else {
            NSLog("coshot: CGEventTap.create failed — Accessibility permission missing?")
            return
        }

        self.tap = machPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    func stop() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.runLoopSource = nil
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // If the OS disables the tap (e.g. because a callback took too long),
        // re-enable it silently so listen mode keeps working on the next run.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let letter = Self.letterKeyCodes[keyCode] else {
            return Unmanaged.passUnretained(event)
        }

        // Fire the callback on main, after returning nil to swallow the key.
        DispatchQueue.main.async { [weak self] in
            self?.onLetter?(letter)
        }
        return nil  // consume — the target app never sees this letter
    }
}
