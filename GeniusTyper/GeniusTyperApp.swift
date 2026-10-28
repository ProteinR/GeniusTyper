import AppKit
import SwiftUI

@main
struct GeniusTyperApp: App {
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

    /// The left-click panel, e.g. from the gear in the clipboard history.
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
        image.accessibilityDescription = "Genius Typer"
        return image
    }()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        // Before anything reads the settings or the data folders.
        Migration.run()
        Prefs.register()
        // Writing to the dictation engine helper after it died must fail with an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.info("Genius Typer \(Self.appVersion) (\(build)) started; dictation \(Prefs.dictationEnabled ? "on, engine \(EngineStore.shared.selected.rawValue), key \(HotkeyMonitor.shared.shortcut.title)" : "off")")
        Self.shared = self
        statusItem = StatusItemController(
            image: Self.menuBarImage, title: "Genius Typer",
            menuItems: { [weak self] in self?.contextMenuItems() ?? [] })
        Observer.shared.start()
        ClipboardStore.shared.start()
        Dictation.shared.onPhase = { MenuBarIcon.shared.dictationPhase = $0 }
        if Prefs.dictationEnabled {
            Dictation.shared.start()
            let store = EngineStore.shared
            if store.selected.isLocal, store.local == .missing { store.downloadLocal(store.selected) }
            if AudioRecorder.permission == .notDetermined { Task { _ = await AudioRecorder.requestPermission() } }
        }

        let arguments = CommandLine.arguments
        if arguments.contains("--panel-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.statusItem?.runPanelTest() }
        }
        if arguments.contains("--history-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ClipboardWindow.runTest() }
        }
        if arguments.contains("--stress-test") { runStressTest() }
        if arguments.contains("--dictation-stress-test") { runDictationStressTest() }
        if arguments.contains("--indicator-test") { runIndicatorTest() }
        // `--open-settings [general|typing|clipboard|dictation|history|statistics]`: for screenshots.
        if let index = arguments.firstIndex(of: "--open-settings") {
            let page = arguments.dropFirst(index + 1).first.flatMap(SettingsPage.init(rawValue:))
            SettingsWindow.shared.show(page: page)
        }
        // `--menu [voices|history|clipboard]`: the left-click panel, optionally with a side column open.
        if let index = arguments.firstIndex(of: "--menu") {
            let side = arguments.dropFirst(index + 1).first
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.statusItem?.showPanel(side: side) }
        }
        if arguments.contains("--indicator-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Indicator.shared.demo() }
        }
        if arguments.contains("--voices") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { VoicePanel.shared.show() }
        }
        if let index = arguments.firstIndex(of: "--transcribe-file"), index + 1 < arguments.count {
            transcribeFile(arguments[index + 1])
        }
        Memory.giveBackSoon()
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
        // Caps Lock goes back to normal when Genius Typer is not running.
        Observer.shared.stop()
        ClipboardStore.shared.flush()
        Log.info("Genius Typer quit")
    }

    /// Right click on the icon, above "Завершить".
    @MainActor private func contextMenuItems() -> [NSMenuItem] {
        let fixing = NSMenuItem(title: "Исправлять текст", action: #selector(toggleFixing), keyEquivalent: "")
        fixing.target = self
        fixing.state = Observer.shared.paused ? .off : .on
        var items = [fixing, .separator()]
        if ClipboardStore.shared.enabled {
            let history = NSMenuItem(title: "История буфера", action: #selector(showClipboard), keyEquivalent: "")
            history.target = self
            items.append(history)
        }
        if Prefs.dictationEnabled {
            let history = NSMenuItem(title: "История диктовок…", action: #selector(showDictationHistory), keyEquivalent: "")
            history.target = self
            items.append(history)
        }
        let settings = NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        items.append(settings)
        return items
    }

    @MainActor @objc private func showSettings() { SettingsWindow.shared.show() }
    @MainActor @objc private func showDictationHistory() { SettingsWindow.shared.show(page: .history) }
    @MainActor @objc private func showClipboard() { ClipboardWindow.show() }
    @MainActor @objc private func toggleFixing() { Observer.shared.paused.toggle() }
}

/// Memory freed by a closed window or an unloaded model goes back to macOS (malloc keeps it for
/// reuse otherwise, and Activity Monitor goes on showing it).
enum Memory {
    @MainActor
    static func giveBackSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let freed = malloc_zone_pressure_relief(nil, 0)
            Log.debug("Memory given back: \(freed / 1024) KB, footprint now \(AppDelegate.footprintMB()) MB", "memory")
        }
    }
}
