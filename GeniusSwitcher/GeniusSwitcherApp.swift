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

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.info("Genius Switcher \(version) started")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Genius Switcher")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView().environmentObject(Observer.shared))

        Observer.shared.start()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        // Caps Lock goes back to normal when Genius Switcher is not running.
        Observer.shared.stop()
    }

    @MainActor @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @MainActor private func showContextMenu() {
        let observer = Observer.shared
        let menu = NSMenu()
        let auto = NSMenuItem(title: "Автопереключение", action: #selector(toggleAutoFix), keyEquivalent: "")
        auto.target = self
        auto.state = observer.autoFix ? .on : .off
        menu.addItem(auto)
        let pause = NSMenuItem(title: "Пауза наблюдения", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = observer.paused ? .on : .off
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Завершить Genius Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Attached only for this click, so a left click still opens the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @MainActor @objc private func toggleAutoFix() { Observer.shared.autoFix.toggle() }
    @MainActor @objc private func togglePause() { Observer.shared.paused.toggle() }
}
