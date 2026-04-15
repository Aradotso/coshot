import AppKit
import CoreGraphics

/// A CGEventTap that, while active, intercepts configured keydown events
/// system-wide and fires a callback. Other keys pass through untouched.
///
/// Requires Accessibility permission — the same one we already need for
/// `CGEventPost` auto-paste.
final class ListenModeTap {
    /// Called with the captured key, on the main thread.
    var onLetter: ((Character) -> Void)?

    /// Only these keys are intercepted; everything else passes through.
    /// AppDelegate refreshes this from `PromptLibrary.load()` on every
    /// `start()`, so any single-char key in prompts.json works automatically.
    var validKeys: Set<Character> = []
    var requiredModifierFlags: CGEventFlags = []

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private static let modifierMask: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand
    ]

    /// Supported key map (ANSI layout, from Carbon.HIToolbox):
    /// a-z + 0-9 (top row + numeric keypad) + common punctuation.
    private static let triggerKeyCodes: [Int64: Character] = [
         0: "a",  1: "s",  2: "d",  3: "f",  4: "h",  5: "g",
         6: "z",  7: "x",  8: "c",  9: "v", 11: "b", 12: "q",
        13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m",

        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",

        83: "1", 84: "2", 85: "3", 86: "4", 87: "5",
        88: "6", 89: "7", 91: "8", 92: "9", 82: "0",

        27: "-", 24: "=", 33: "[", 30: "]", 41: ";",
        39: "'", 43: ",", 47: ".", 44: "/", 50: "`"
    ]

    /// Canonical key order shown in the in-app key picker UI.
    static let keyPickerOrder: [Character] = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
        "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]",
        "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'",
        "z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "-", "="
    ]

    static let supportedKeySet = Set(triggerKeyCodes.values)

    static func keyForKeyCode(_ keyCode: Int64) -> Character? {
        triggerKeyCodes[keyCode]
    }

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

        Log.listen.info("tap ACTIVE, listening for configured keys")
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

        guard let key = Self.keyForKeyCode(keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        // Only swallow keys that are actually bound to a prompt. Other
        // keys pass through so the user can still type normally
        // into the target app (sticky listen mode means the tap stays up
        // between fires).
        guard validKeys.contains(key) else {
            return Unmanaged.passUnretained(event)
        }

        let activeModifiers = event.flags.intersection(Self.modifierMask)
        if !activeModifiers.isSuperset(of: requiredModifierFlags) {
            return Unmanaged.passUnretained(event)
        }

        Log.listen.info("MATCHED key=\(String(key), privacy: .public) keyCode=\(keyCode, privacy: .public)")

        DispatchQueue.main.async { [weak self] in
            self?.onLetter?(key)
        }
        return nil  // consume
    }
}
