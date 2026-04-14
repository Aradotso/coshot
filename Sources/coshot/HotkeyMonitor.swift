import AppKit
import Carbon.HIToolbox

final class HotkeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData = userData else { return noErr }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { monitor.callback() }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )

        var carbonMods: UInt32 = 0
        if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }

        let id = EventHotKeyID(signature: OSType(0x434F5348) /* 'COSH' */, id: 1)
        RegisterEventHotKey(keyCode, carbonMods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let h = handlerRef { RemoveEventHandler(h) }
    }
}
