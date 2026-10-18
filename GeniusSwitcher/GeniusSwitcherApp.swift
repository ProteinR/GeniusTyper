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

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.info("Genius Switcher \(Self.appVersion) (\(build)) started")
        statusItem = StatusItemController(
            symbol: "character.cursor.ibeam", title: "Genius Switcher",
            content: { AnyView(MenuView().environmentObject(Observer.shared)) },
            menuItems: { [weak self] in self?.contextMenuItems() ?? [] })
        Observer.shared.start()
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
        return [auto, pause]
    }

    @MainActor @objc private func toggleAutoFix() { Observer.shared.autoFix.toggle() }
    @MainActor @objc private func togglePause() { Observer.shared.paused.toggle() }
}
