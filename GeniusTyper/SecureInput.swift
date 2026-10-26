import AppKit
import Carbon

/// macOS "Secure Input": while any process has it on (a password field, Terminal's "Secure
/// Keyboard Entry"…), the key taps get no key presses, only modifiers: Caps Lock (F18), Esc while
/// dictating, the auto-fix and ё stop, the dictation modifier still works. loginwindow sometimes
/// keeps it on after the screen was locked (2026-10-26: Caps Lock and Esc did nothing until the
/// screen was locked and unlocked again), so the left-click panel says who holds it.
enum SecureInput {
    /// The name of the process holding Secure Input, or nil when it is off.
    static func holder() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else {
            return String(localized: "другом приложении")
        }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "pid \(pid)"
    }
}
