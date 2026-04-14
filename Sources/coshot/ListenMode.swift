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

    /// Only these letters are intercepted; everything else passes through.
    /// AppDelegate refreshes this from `PromptLibrary.load()` on every
    /// `start()`, so any letter added to prompts.json works automatically.
    var validLetters: Set<Character> = []

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Full a-z → virtual keycode map (ANSI layout, from Carbon.HIToolbox).
    private static let letterKeyCodes: [Int64: Character] = [
         0: "a",  1: "s",  2: "d",  3: "f",  4: "h",  5: "g",
         6: "z",  7: "x",  8: "c",  9: "v", 11: "b", 12: "q",
        13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m"
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

        guard let letter = Self.letterKeyCodes[keyCode] else {
            return Unmanaged.passUnretained(event)
        }

        // Only swallow letters that are actually bound to a prompt. Other
        // letters pass through so the user can still type normal words
        // into the target app (sticky listen mode means the tap stays up
        // between fires).
        guard validLetters.contains(letter) else {
            return Unmanaged.passUnretained(event)
        }

        Log.listen.info("MATCHED letter=\(String(letter), privacy: .public) keyCode=\(keyCode, privacy: .public)")

        DispatchQueue.main.async { [weak self] in
            self?.onLetter?(letter)
        }
        return nil  // consume
    }
}
