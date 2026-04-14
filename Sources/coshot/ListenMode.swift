import AppKit
import CoreGraphics

/// A CGEventTap that, while active, intercepts A/S/D/F/G keydown events
/// system-wide and fires a callback. Non-letter keys pass through untouched.
///
/// Requires Accessibility permission — the same one we already need for
/// `CGEventPost` auto-paste.
final class ListenModeTap {
    /// Called with the captured letter, on the main thread.
    var onLetter: ((Character) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let letterKeyCodes: [Int64: Character] = [
        0: "a",
        1: "s",
        2: "d",
        3: "f",
        5: "g"
    ]

    var isActive: Bool { tap != nil }

    func start() {
        if tap != nil {
            Log.listen.info("start() called but tap already active")
            return
        }

        Log.listen.info("start() creating CGEventTap")

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
            Log.listen.error("CGEvent.tapCreate FAILED — Accessibility permission not granted?")
            return
        }

        self.tap = machPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)

        Log.listen.info("tap ACTIVE, listening for A/S/D/F/G")
    }

    func stop() {
        guard let tap = tap else {
            Log.listen.info("stop() called but tap already inactive")
            return
        }
        Log.listen.info("stop() disabling tap")
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.runLoopSource = nil
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.listen.error("tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"), re-enabling")
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        Log.listen.debug("keydown keyCode=\(keyCode, privacy: .public)")

        guard let letter = Self.letterKeyCodes[keyCode] else {
            return Unmanaged.passUnretained(event)
        }

        Log.listen.info("MATCHED letter=\(String(letter), privacy: .public) keyCode=\(keyCode, privacy: .public)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                Log.listen.error("self nil when firing onLetter callback")
                return
            }
            guard let cb = self.onLetter else {
                Log.listen.error("onLetter callback is nil")
                return
            }
            Log.listen.info("invoking onLetter callback")
            cb(letter)
        }
        return nil  // consume
    }
}
