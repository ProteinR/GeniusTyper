import AppKit
import Carbon

/// One global hot key (⇧⌘C for the clipboard history) through Carbon's `RegisterEventHotKey`:
/// needs no permission and works in any layout (it is a key code, not a letter).
@MainActor
enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    private static var action: (() -> Void)?

    /// False when the combination could not be registered (another app holds it).
    static func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) -> Bool {
        unregister()
        Self.action = action
        if handlerRef == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
                return noErr
            }, 1, &type, nil, &handlerRef)
        }
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        let id = EventHotKeyID(signature: OSType(0x4753_4B59), id: 1)  // "GSKY"
        let status = RegisterEventHotKey(keyCode, carbon, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            Log.info("Hot key \(keyCode) not registered: \(status)", "clipboard")
            ref = nil
        }
        return status == noErr
    }

    static func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
