import AppKit
import SwiftUI

/// The menu bar icon: left click opens the panel, right click a small menu ending with "Завершить".
///
/// Made by hand rather than with SwiftUI's `MenuBarExtra`: when the icon is turned off in System
/// Settings → Menu Bar, a `MenuBarExtra`-only app quits right after launch, and its keys stop
/// working. An `NSStatusItem` just stays hidden; opening the app again (Spotlight, Finder) then
/// shows the panel in a small window instead.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let content: () -> AnyView
    private let menuItems: () -> [NSMenuItem]
    private let quitTitle: String
    private var window: NSPanel?

    /// `menuItems` are built on every right click (so their checkmarks are current).
    init(symbol: String, title: String, content: @escaping () -> AnyView, menuItems: @escaping () -> [NSMenuItem] = { [] }) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.content = content
        self.menuItems = menuItems
        quitTitle = "Завершить \(title)"
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: content())
    }

    /// From the icon, or a window when the icon is hidden (the app was opened again).
    func showPanel() {
        if isIconVisible, let button = statusItem.button {
            window?.orderOut(nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        } else {
            showWindow()
        }
    }

    /// Hidden in System Settings → Menu Bar, or pushed out by a full menu bar.
    private var isIconVisible: Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window else { return false }
        return window.occlusionState.contains(.visible) && window.frame.maxY > 0
    }

    private func showWindow() {
        let panel = window ?? makeWindow()
        window = panel
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSPanel {
        let host = NSHostingController(rootView: content())
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let extra = menuItems()
        extra.forEach(menu.addItem)
        if !extra.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem(title: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Attached only for this click, so a left click still opens the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
