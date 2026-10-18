import Carbon
import Foundation
import IOKit
import IOKit.hid

/// Caps Lock switches between the two layouts, instantly on every press (macOS's own "Caps Lock
/// switches to ABC" waits to tell a press from a hold and misses quick ones).
///
/// Caps Lock is remapped to F18 for the session with `hidutil` (like Karabiner, no driver, gone
/// after a restart); F18 does nothing on its own, so a listen-only key tap sees it and switches.
/// ⇧ + Caps Lock toggles the real Caps Lock. The mapping is removed when Genius Switcher quits.
enum CapsLockSwitch {
    static let f18KeyCode: UInt16 = 79
    private static let capsLockUsage: UInt64 = 0x7_0000_0039
    private static let f18Usage: UInt64 = 0x7_0000_006D

    static func install() {
        setMapping(enabled: true)
    }

    static func uninstall() {
        setMapping(enabled: false)
    }

    /// Keeps other mappings in place, adds or removes only Caps Lock → F18.
    private static func setMapping(enabled: Bool) {
        var mappings = currentMappings().filter { ($0["HIDKeyboardModifierMappingSrc"] as? UInt64) != capsLockUsage }
        if enabled {
            mappings.append(["HIDKeyboardModifierMappingSrc": capsLockUsage, "HIDKeyboardModifierMappingDst": f18Usage])
        }
        let items = mappings.compactMap { mapping -> String? in
            guard let source = mapping["HIDKeyboardModifierMappingSrc"] as? UInt64,
                  let destination = mapping["HIDKeyboardModifierMappingDst"] as? UInt64 else { return nil }
            return "{\"HIDKeyboardModifierMappingSrc\":\(source),\"HIDKeyboardModifierMappingDst\":\(destination)}"
        }
        let status = run(["property", "--set", "{\"UserKeyMapping\":[\(items.joined(separator: ","))]}"])
        Log.info("Caps Lock → F18 \(enabled ? "on" : "off") (hidutil exit \(status.code))", "caps")
    }

    private static func currentMappings() -> [[String: Any]] {
        // hidutil prints the property as a plist-like text; asking for XML is not supported, so
        // the two numbers per entry are read with a regex.
        let output = run(["property", "--get", "UserKeyMapping"]).output
        let pattern = /HIDKeyboardModifierMappingDst = (\d+);\s*HIDKeyboardModifierMappingSrc = (\d+);/
        return output.matches(of: pattern).compactMap { match in
            guard let destination = UInt64(match.1), let source = UInt64(match.2) else { return nil }
            return ["HIDKeyboardModifierMappingSrc": source, "HIDKeyboardModifierMappingDst": destination]
        }
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error("hidutil failed: \(Log.describe(error))", "caps")
            return (-1, "")
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    // MARK: - Switching

    /// Selects the other of the two layouts.
    static func switchLayout(renderer: SystemLayouts) {
        guard let current = renderer.currentLanguage(), let other = renderer.other(than: current) else { return }
        select(other, renderer: renderer)
    }

    static func select(_ language: String, renderer: SystemLayouts) {
        guard renderer.currentLanguage() != language, let id = renderer.layoutID(for: language) else { return }
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let source = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first else { return }
        let status = TISSelectInputSource(source)
        if status != noErr { Log.warning("TISSelectInputSource(\(id)) = \(status)", "caps") }
    }

    /// ⇧ + Caps Lock: the real Caps Lock, through the HID system.
    static func toggleCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        var state = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state)
    }
}
