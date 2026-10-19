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

/// A shortcut as the user set it: a key code (layout-independent) and modifiers.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt

    static let clipboardDefault = KeyCombo(keyCode: 8, modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue)  // ⇧⌘C

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// A global shortcut needs ⌘, ⌥ or ⌃ (⇧ alone would take a letter away from typing). F18 is
    /// Caps Lock (`CapsLockSwitch`).
    var isUsable: Bool {
        !flags.isDisjoint(with: [.command, .option, .control]) && keyCode != 79
    }

    /// "⇧⌘C", in the order macOS menus use.
    @MainActor var title: String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + Self.keyName(keyCode)
    }

    private static let names: [UInt16: String] = [
        49: "Пробел", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 80: "F19",
    ]

    /// The key's letter in the English layout (shortcuts are shown that way in macOS menus too).
    @MainActor static func keyName(_ code: UInt16) -> String {
        if let name = names[code] { return name }
        let key = TypedKey(code: code, shift: false, caps: false)
        return Observer.shared.layouts.character(key, language: "en").map { String($0).uppercased() } ?? "#\(code)"
    }
}
