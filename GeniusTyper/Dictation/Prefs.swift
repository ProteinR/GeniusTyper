import Foundation

/// Dictation settings stored in UserDefaults (the dictation key is `Shortcut`, the engine `Engines`).
enum Prefs {
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            "dictationEnabled": false,
            "voicesEnabled": true,
            "dictationYo": true,
            "dictationSounds": true,
            "escCancels": true,
            "unloadAfterMinutes": 5,
            "engine": EngineID.parakeetV3.rawValue,
        ])
    }

    /// The "Диктовка" switch: off = no key watched, no microphone, no model.
    static var dictationEnabled: Bool {
        get { defaults.bool(forKey: "dictationEnabled") }
        set { defaults.set(newValue, forKey: "dictationEnabled") }
    }

    /// "Голосовые из Telegram" (inside dictation): the hot key and the panel's voices column.
    static var voicesEnabled: Bool {
        get { defaults.bool(forKey: "voicesEnabled") }
        set { defaults.set(newValue, forKey: "voicesEnabled") }
    }

    /// ё in dictated text ("еще" → "ещё"): Parakeet nearly always writes е.
    static var dictationYo: Bool {
        get { defaults.bool(forKey: "dictationYo") }
        set { defaults.set(newValue, forKey: "dictationYo") }
    }

    /// Short sounds when recording starts and stops.
    static var sounds: Bool {
        get { defaults.bool(forKey: "dictationSounds") }
        set { defaults.set(newValue, forKey: "dictationSounds") }
    }

    /// Esc while recording cancels it without inserting.
    static var escCancels: Bool {
        get { defaults.bool(forKey: "escCancels") }
        set { defaults.set(newValue, forKey: "escCancels") }
    }

    /// The character above the pill while dictating (`Mascot` raw value).
    static var mascot: String {
        get { defaults.string(forKey: "mascot") ?? Mascot.none.rawValue }
        set { defaults.set(newValue, forKey: "mascot") }
    }

    /// The local model leaves memory after this many minutes without dictation; 0 = never.
    static var unloadAfterMinutes: Int {
        get { defaults.integer(forKey: "unloadAfterMinutes") }
        set { defaults.set(newValue, forKey: "unloadAfterMinutes") }
    }
}
