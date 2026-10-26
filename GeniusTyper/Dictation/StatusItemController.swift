import AppKit

/// The menu bar icon: left click opens `MenuPanel` (Telegram voices, history, last dictations),
/// right click a small menu with the settings and "Завершить Diktant". Red while recording.
///
/// Made by hand rather than with SwiftUI's `MenuBarExtra`: when the icon is turned off in System
/// Settings → Menu Bar, a `MenuBarExtra`-only app quits right after launch.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        show(.idle)
    }

    func show(_ phase: Dictation.Phase) {
        guard let button = statusItem.button else { return }
        switch phase {
        case .idle:
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Diktant")
            button.contentTintColor = nil
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: String(localized: "Diktant: запись"))
            button.contentTintColor = .systemRed
        case .transcribing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: String(localized: "Diktant: распознавание"))
            button.contentTintColor = nil
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            MenuPanel.shared.close()
            showMenu()
        } else if let button = statusItem.button {
            MenuPanel.shared.toggle(under: button)
        }
    }

    /// `--menu [voices|history]`: the left-click panel at launch, for screenshots.
    func openPanel(side: String? = nil) {
        if let button = statusItem.button { MenuPanel.shared.show(under: button, side: side) }
    }

    private func showMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: String(localized: "Настройки…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let history = NSMenuItem(title: String(localized: "История…"), action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Завершить Diktant"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Attached only for this click, so a left click still opens the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() { SettingsWindow.shared.show() }
    @objc private func openHistory() { SettingsWindow.shared.show(page: .history) }
}
