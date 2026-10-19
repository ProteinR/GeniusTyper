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
        statusItem = StatusItemController(
            image: Self.menuBarImage, title: "Genius Switcher",
            content: { AnyView(MenuView().environmentObject(Observer.shared)) },
            menuItems: { [weak self] in self?.contextMenuItems() ?? [] })
        Observer.shared.start()
        ClipboardStore.shared.start()
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
