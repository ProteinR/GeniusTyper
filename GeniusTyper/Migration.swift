import Foundation
import ServiceManagement

/// Genius Typer = Genius Switcher + Diktant (2026-10-26), with a new bundle ID. On the first launch
/// their settings and data are copied over once: the settings of both apps into Genius Typer's
/// (Diktant's keys renamed where they were too generic), `Application Support/GeniusSwitcher/*`
/// into `GeniusTyper/` and `Application Support/Diktant/*` into `GeniusTyper/dictation/`. The old
/// folders stay until the old apps are deleted. Runs before anything reads the settings or the
/// journal.
enum Migration {
    private static let doneKey = "migratedFromSwitcherAndDiktant"

    static func run() {
        let defaults = UserDefaults.standard
        guard !AppDelegate.isRunningTests, !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        let switcher = copyDefaults(from: "com.dmemruk.GeniusSwitcher", renaming: [:])
        let diktant = copyDefaults(from: "com.dmemruk.Diktant", renaming: ["sounds": "dictationSounds", "shortcut": "dictationShortcut"])

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("GeniusTyper", isDirectory: true)
        let files = copyContents(of: support.appendingPathComponent("GeniusSwitcher"), to: base)
        let dictationFiles = copyContents(of: support.appendingPathComponent("Diktant"), to: base.appendingPathComponent("dictation"))

        // Diktant was in use: dictation stays on (a fresh install starts with it off).
        if diktant > 0 || dictationFiles > 0 { defaults.set(true, forKey: "dictationEnabled") }
        // Both old apps started at login; the new one should too.
        if switcher > 0 || diktant > 0, SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() } catch { Log.warning("Login item not registered: \(Log.describe(error))", "migration") }
        }
        Log.info("Migrated: \(switcher) Genius Switcher settings, \(diktant) Diktant settings, \(files) + \(dictationFiles) data items", "migration")
    }

    /// Window frames and the menu bar position belong to the old apps' windows and icon.
    private static func copyDefaults(from domain: String, renaming: [String: String]) -> Int {
        guard let old = UserDefaults.standard.persistentDomain(forName: domain) else { return 0 }
        var count = 0
        for (key, value) in old where !key.hasPrefix("NSWindow Frame") && !key.hasPrefix("NSStatusItem") {
            UserDefaults.standard.set(value, forKey: renaming[key] ?? key)
            count += 1
        }
        return count
    }

    /// Copies (not moves) each item that is not there yet; returns how many were copied.
    private static func copyContents(of source: URL, to destination: URL) -> Int {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return 0 }
        try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var count = 0
        for item in items where item.lastPathComponent != ".DS_Store" {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            guard !manager.fileExists(atPath: target.path) else { continue }
            do {
                try manager.copyItem(at: item, to: target)
                count += 1
            } catch {
                Log.error("Copying \(item.path) failed: \(Log.describe(error))", "migration")
            }
        }
        return count
    }
}
