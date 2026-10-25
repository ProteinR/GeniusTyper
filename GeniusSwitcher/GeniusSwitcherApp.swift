import AppKit
import SwiftUI

@main
struct GeniusSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item is made by AppDelegate (left click: panel, right click: menu);
        // SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// "0.1.1", shown next to the title in the panel.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var statusItem: StatusItemController?
    private static weak var shared: AppDelegate?

    /// The panel (the app's settings), e.g. from the gear in the clipboard history.
    @MainActor static func showPanel() { shared?.statusItem?.showPanel() }
    @MainActor static func closePanel() { shared?.statusItem?.closePanel() }

    /// "G" (Genius) with a text cursor, like SF Symbols' "character.cursor.ibeam" ("A" with a cursor).
    static let menuBarImage: NSImage = {
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let letter = "G" as NSString
        let letterSize = letter.size(withAttributes: attributes)
        let size = NSSize(width: ceil(letterSize.width) + 5, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            letter.draw(at: NSPoint(x: 0, y: (rect.height - letterSize.height) / 2), withAttributes: attributes)
            // The I-beam: a stem with short serifs, the height of the capital letter and a bit more.
            let x = rect.width - 2
            let beam = NSBezierPath()
            beam.move(to: NSPoint(x: x, y: 1.5)); beam.line(to: NSPoint(x: x, y: rect.height - 1.5))
            beam.move(to: NSPoint(x: x - 1.75, y: 1)); beam.line(to: NSPoint(x: x + 1.75, y: 1))
            beam.move(to: NSPoint(x: x - 1.75, y: rect.height - 1)); beam.line(to: NSPoint(x: x + 1.75, y: rect.height - 1))
            beam.lineWidth = 1.25
            NSColor.black.setStroke()
            beam.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Genius Switcher"
        return image
    }()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.info("Genius Switcher \(Self.appVersion) (\(build)) started")
        Self.shared = self
        statusItem = StatusItemController(
            image: Self.menuBarImage, title: "Genius Switcher",
            content: { AnyView(MenuView().environmentObject(Observer.shared)) },
            menuItems: { [weak self] in self?.contextMenuItems() ?? [] })
        Observer.shared.start()
        ClipboardStore.shared.start()

        let arguments = CommandLine.arguments
        if arguments.contains("--panel-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.statusItem?.runPanelTest() }
        }
        if arguments.contains("--history-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ClipboardWindow.runTest() }
        }
        if arguments.contains("--stress-test") { runStressTest() }
    }

    /// `--stress-test`: three rounds of opening the panel 10 times and the clipboard history 10 times
    /// (moving through it until the preview opens), logging the memory footprint after each round.
    /// Growing every round = a leak; growing once and then flat = caches. `leaks <pid>` afterwards
    /// lists unreachable memory (install with `PROFILE=1 scripts/install.sh`).
    @MainActor
    private func runStressTest() {
        var cycle = 0
        @MainActor func round() {
            guard cycle < 3 else { return }
            cycle += 1
            statusItem?.runPanelTest(rounds: 10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 13) {
                ClipboardWindow.runTest(rounds: 10)
                DispatchQueue.main.asyncAfter(deadline: .now() + 50) {
                    MainActor.assumeIsolated {
                        Log.info("Stress round \(cycle): footprint \(Self.footprintMB()) MB", "stress")
                        round()
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                Log.info("Stress test start: footprint \(Self.footprintMB()) MB", "stress")
                round()
            }
        }
    }

    /// The memory footprint, as Activity Monitor shows it.
    static func footprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? String(format: "%.1f", Double(info.phys_footprint) / 1_048_576) : "?"
    }

    /// Opened again from Spotlight or Finder: show the panel (the icon may be hidden).
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showPanel()
        return false
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        // Caps Lock goes back to normal when Genius Switcher is not running.
        Observer.shared.stop()
        ClipboardStore.shared.flush()
    }

    /// Right click on the icon, above "Завершить".
    @MainActor private func contextMenuItems() -> [NSMenuItem] {
        let observer = Observer.shared
        let auto = NSMenuItem(title: "Автопереключение", action: #selector(toggleAutoFix), keyEquivalent: "")
        auto.target = self
        auto.state = observer.autoFix ? .on : .off
        let pause = NSMenuItem(title: "Пауза наблюдения", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = observer.paused ? .on : .off
        let exceptions = NSMenuItem(title: "Исключения…", action: #selector(showExceptions), keyEquivalent: "")
        exceptions.target = self
        let stats = NSMenuItem(title: "Статистика…", action: #selector(showStats), keyEquivalent: "")
        stats.target = self
        var items = [auto, pause, .separator(), exceptions, stats]
        if ClipboardStore.shared.enabled {
            let history = NSMenuItem(title: "История буфера", action: #selector(showClipboard), keyEquivalent: "")
            history.target = self
            items.append(history)
        }
        return items
    }

    @MainActor @objc private func showStats() { StatsWindow.show() }

    @MainActor @objc private func showExceptions() { ExceptionsEditor.show() }

    @MainActor @objc private func showClipboard() { ClipboardWindow.show() }

    @MainActor @objc private func toggleAutoFix() { Observer.shared.autoFix.toggle() }
    @MainActor @objc private func togglePause() { Observer.shared.paused.toggle() }
}

/// Memory freed by a closed window goes back to macOS (malloc keeps it for reuse otherwise, and
/// Activity Monitor goes on showing it).
enum Memory {
    @MainActor
    static func giveBackSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let freed = malloc_zone_pressure_relief(nil, 0)
            Log.debug("Memory given back: \(freed / 1024) KB, footprint now \(AppDelegate.footprintMB()) MB", "memory")
        }
    }
}
