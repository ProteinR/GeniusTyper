import AppKit
import Carbon.HIToolbox

/// The dictation key: either a single modifier on its own (right ⌥ by default, right ⌘, Fn…) or a
/// key with modifiers (⌃⌥D). Stored by key code, so it works in any keyboard layout.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// Device-independent modifier flags (`NSEvent.ModifierFlags` raw value) for a key combination;
    /// 0 for a single modifier.
    var modifiers: UInt = 0

    static let rightOption = Shortcut(keyCode: UInt16(kVK_RightOption))

    /// A modifier key pressed and released alone.
    var isModifierOnly: Bool { Self.modifierKeys[keyCode] != nil }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevantModifiers)
    }

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// "Правый ⌥", "Fn", "⌃⌥D".
    var title: String {
        if let name = Self.modifierKeys[keyCode]?.title { return name }
        var text = ""
        let flags = modifierFlags
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "#\(keyCode)")
    }

    /// A modifier key: the device-dependent bit it sets in `CGEventFlags` while it is down (left and
    /// right ⌥ share `.maskAlternate`, so that alone cannot tell which one was released), and its name.
    struct ModifierKey {
        let deviceMask: UInt64
        let title: String
    }

    static let modifierKeys: [UInt16: ModifierKey] = [
        UInt16(kVK_RightOption): ModifierKey(deviceMask: 0x40, title: String(localized: "Правый ⌥")),
        UInt16(kVK_Option): ModifierKey(deviceMask: 0x20, title: String(localized: "Левый ⌥")),
        UInt16(kVK_RightCommand): ModifierKey(deviceMask: 0x10, title: String(localized: "Правый ⌘")),
        UInt16(kVK_Command): ModifierKey(deviceMask: 0x08, title: String(localized: "Левый ⌘")),
        UInt16(kVK_RightControl): ModifierKey(deviceMask: 0x2000, title: String(localized: "Правый ⌃")),
        UInt16(kVK_Control): ModifierKey(deviceMask: 0x01, title: String(localized: "Левый ⌃")),
        UInt16(kVK_RightShift): ModifierKey(deviceMask: 0x04, title: String(localized: "Правый ⇧")),
        UInt16(kVK_Shift): ModifierKey(deviceMask: 0x02, title: String(localized: "Левый ⇧")),
        UInt16(kVK_Function): ModifierKey(deviceMask: 0x800000, title: "Fn"),
    ]

    /// Names by key code (ANSI positions), the same in every layout.
    static let keyNames: [UInt16: String] = {
        var names: [UInt16: String] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
            (kVK_ANSI_9, "9"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"),
            (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Backslash, "\\"),
            (kVK_ANSI_Grave, "`"), (kVK_Space, String(localized: "Пробел")), (kVK_Return, "↩"), (kVK_Tab, "⇥"),
            (kVK_Delete, "⌫"), (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"), (kVK_F17, "F17"),
            (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
        ]
        for (code, name) in letters { names[UInt16(code)] = name }
        return names
    }()

    /// Keys that make sense alone, without modifiers (others, like a letter, would stop typing it).
    /// F18 is Caps Lock in Genius Switcher.
    static func isUsableAlone(_ keyCode: UInt16) -> Bool { functionKeys.contains(keyCode) && keyCode != UInt16(kVK_F18) }

    private static let functionKeys: Set<UInt16> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].map(UInt16.init))

    /// Settings key.
    static let defaultsKey = "shortcut"

    /// "Голосовые из Telegram": ⌃⌥V.
    static let voicesDefaultsKey = "voicesShortcut"
    static let voicesDefault = Shortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)

    static func load(from defaults: UserDefaults = .standard, key: String = defaultsKey, default fallback: Shortcut = .rightOption) -> Shortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return fallback }
        return shortcut
    }

    func save(to defaults: UserDefaults = .standard, key: String = defaultsKey) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

/// Hybrid mode: hold the key to talk (release stops), or tap it to start and tap again to stop.
/// Pure logic, fed with key-down / key-up and their times; tested.
struct HybridPress {
    enum Action: Equatable {
        case none, start, stop
    }

    /// Shorter than this = a tap: recording keeps going until the next tap.
    static let tapLimit: TimeInterval = 0.35

    private(set) var isRecording = false
    private var pressedAt: TimeInterval?
    /// The press that started this recording (its release decides hold or tap).
    private var startedByThisPress = false

    mutating func keyDown(at time: TimeInterval) -> Action {
        guard pressedAt == nil else { return .none } // key repeat
        pressedAt = time
        if isRecording {
            // A tap while recording in toggle mode: stop on press, so the text comes at once.
            startedByThisPress = false
            isRecording = false
            return .stop
        }
        isRecording = true
        startedByThisPress = true
        return .start
    }

    mutating func keyUp(at time: TimeInterval) -> Action {
        guard let pressedAt else { return .none }
        self.pressedAt = nil
        guard isRecording, startedByThisPress else { return .none }
        startedByThisPress = false
        if time - pressedAt < Self.tapLimit { return .none } // a tap: keep recording (toggle)
        isRecording = false
        return .stop // held: push-to-talk ends on release
    }

    /// Recording ended some other way (Esc, error): back to idle.
    mutating func reset() {
        isRecording = false
        startedByThisPress = false
        pressedAt = nil
    }

    var isKeyDown: Bool { pressedAt != nil }
}
