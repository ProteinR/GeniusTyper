import Foundation

/// Dictation settings stored in UserDefaults (the dictation key is `Shortcut`, the engine `Engines`).
enum Prefs {
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            "dictationEnabled": false,
            "voicesEnabled": true,
            "voicesKeepDays": 7,
            "dictationKeepDays": 0,
            "voicesSenders": true,
            "dictationYo": true,
            "dictationSounds": true,
            "escCancels": true,
            "unloadAfterMinutes": 5,
            "engine": EngineID.parakeetUltra.rawValue,
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

    /// Texts of Telegram voice messages are kept and shown for this many days; 0 = forever.
    static var voicesKeepDays: Int {
        get { max(0, defaults.integer(forKey: "voicesKeepDays")) }
        set { defaults.set(newValue, forKey: "voicesKeepDays") }
    }

    /// Dictations are kept in the history for this many days; 0 = forever (the default). The
    /// statistics are computed from the history, so older dictations leave them too.
    static var dictationKeepDays: Int {
        get { max(0, defaults.integer(forKey: "dictationKeepDays")) }
        set { defaults.set(newValue, forKey: "dictationKeepDays") }
    }

    /// Who sent a voice message, read from Telegram's database (`TelegramPostbox`).
    static var voicesSenders: Bool {
        get { defaults.bool(forKey: "voicesSenders") }
        set { defaults.set(newValue, forKey: "voicesSenders") }
    }

    /// Voice messages of these days not transcribed yet are transcribed on opening: the days kept,
    /// or the last 7 when kept forever (not every voice message still in Telegram's cache).
    static var voicesScanDays: Int {
        voicesKeepDays == 0 ? 7 : voicesKeepDays
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

    /// How the pill shows the microphone level (`LevelStyle` raw value).
    static var levelStyle: String {
        get { defaults.string(forKey: "levelStyle") ?? LevelStyle.bars.rawValue }
        set { defaults.set(newValue, forKey: "levelStyle") }
    }

    /// The level bars' scale per microphone (`LevelScale`, by the input's name), learnt while
    /// dictating: a new dictation starts where the last one with that microphone ended.
    static var levelScales: [String: LevelScale] {
        get { defaults.data(forKey: "levelScales").flatMap { try? JSONDecoder().decode([String: LevelScale].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "levelScales") }
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
