import Foundation

/// Settings stored in UserDefaults (the dictation key is `Shortcut`, the engine `Engines`).
enum Prefs {
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            "sounds": true,
            "escCancels": true,
            "unloadAfterMinutes": 5,
            "engine": EngineID.parakeetV3.rawValue,
        ])
    }

    /// Short sounds when recording starts and stops.
    static var sounds: Bool {
        get { defaults.bool(forKey: "sounds") }
        set { defaults.set(newValue, forKey: "sounds") }
    }

    /// Esc while recording cancels it without inserting.
    static var escCancels: Bool {
        get { defaults.bool(forKey: "escCancels") }
        set { defaults.set(newValue, forKey: "escCancels") }
    }

    /// The local model leaves memory after this many minutes without dictation; 0 = never.
    static var unloadAfterMinutes: Int {
        get { defaults.integer(forKey: "unloadAfterMinutes") }
        set { defaults.set(newValue, forKey: "unloadAfterMinutes") }
    }
}
