import AppKit
import SwiftUI

/// Whether the menu bar icon is shown: the "Значок в строке меню" switch in the panel. The state is
/// the status item's own (AppKit saves it per app); it is also off after ⌘-dragging the icon out.
@MainActor
final class MenuBarIcon: ObservableObject {
    static let shared = MenuBarIcon()

    fileprivate weak var statusItem: NSStatusItem?
    private var observation: NSKeyValueObservation?

    /// The current layout on the icon, instead of macOS's own input menu (turned off in System
    /// Settings → Keyboard → Input Sources): none, "RU"/"EN", or a flag.
    enum LanguageMark: String, CaseIterable, Identifiable {
        case none, text, flag
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "нет"
            case .text: "RU / EN"
            case .flag: "флаг"
            }
        }
    }

    /// With the app's symbol the language mark is small, beside it; without it the mark is the whole icon.
    @Published var showsSymbol: Bool {
        didSet {
            UserDefaults.standard.set(showsSymbol, forKey: "iconShowsSymbol")
            render()
        }
    }

    @Published var languageMark: LanguageMark {
        didSet {
            UserDefaults.standard.set(languageMark.rawValue, forKey: "iconLanguageMark")
            render()
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        // 0.5.0 had one choice, "iconStyle": symbol / text / flag (text and flag without the symbol).
        let old = defaults.string(forKey: "iconStyle")
        showsSymbol = defaults.object(forKey: "iconShowsSymbol") as? Bool ?? (old == nil || old == "symbol")
        languageMark = LanguageMark(rawValue: defaults.string(forKey: "iconLanguageMark") ?? old ?? "") ?? .none
    }

    /// The current layout ("en" / "ru"), set by the Observer.
    var language: String? {
        didSet { if language != oldValue { render() } }
    }

    fileprivate var symbolImage: NSImage?

    @Published var isShown = true {
        didSet {
            guard let statusItem, statusItem.isVisible != isShown else { return }
            statusItem.isVisible = isShown
            Log.info("Menu bar icon \(isShown ? "shown" : "hidden")")
        }
    }

    fileprivate func attach(_ item: NSStatusItem, symbol: NSImage?) {
        statusItem = item
        symbolImage = symbol
        render()
        isShown = item.isVisible
        observation = item.observe(\.isVisible) { item, _ in
            Task { @MainActor in
                if MenuBarIcon.shared.isShown != item.isVisible { MenuBarIcon.shared.isShown = item.isVisible }
            }
        }
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        button.image = nil
        button.title = ""
        button.attributedTitle = NSAttributedString()
        guard languageMark != .none, let language else {
            button.image = symbolImage
            return
        }
        let text = language.uppercased()
        let flag = language == "ru" ? "🇷🇺" : "🇺🇸"
        switch (showsSymbol, languageMark) {
        case (false, .text):
            button.image = Self.textImage(text)
        case (false, _):
            button.title = flag
        case (true, .text):
            button.image = symbolImage.map { Self.symbol($0, withSmall: text) } ?? Self.textImage(text)
        case (true, _):
            // A flag has colours, so it cannot be part of a template image: the symbol stays the
            // image and the flag is a small title next to it, lowered to the bottom edge.
            button.image = symbolImage
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: flag, attributes: [
                .font: NSFont.systemFont(ofSize: 14), .baselineOffset: -2,
            ])
        }
    }

    /// The app's symbol with a small "RU"/"EN" at its bottom right, a bit over half its height.
    private static func symbol(_ symbol: NSImage, withSmall text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let height = max(symbol.size.height, 16)
        let size = NSSize(width: ceil(symbol.size.width + 1 + textSize.width), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
            (text as NSString).draw(at: NSPoint(x: symbol.size.width + 1, y: -2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = text
        return image
    }

    /// "EN" / "RU" in a rounded frame, like macOS's own input menu; a template, so it follows
    /// the menu bar's light or dark look.
    private static func textImage(_ text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + 8, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
            frame.lineWidth = 1.5
            NSColor.black.setStroke()
            frame.stroke()
            (text as NSString).draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2),
                                    withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = text
        return image
    }
}

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
    convenience init(symbol: String, title: String, content: @escaping () -> AnyView, menuItems: @escaping () -> [NSMenuItem] = { [] }) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title), title: title, content: content, menuItems: menuItems)
    }

    /// `image`: a template image drawn by the app, for an icon SF Symbols does not have.
    init(image: NSImage?, title: String, content: @escaping () -> AnyView, menuItems: @escaping () -> [NSMenuItem] = { [] }) {
        // Variable length: the layout text or flag (a choice in the panel) is wider than a symbol.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.content = content
        self.menuItems = menuItems
        quitTitle = "Завершить \(title)"
        super.init()
        statusItem.behavior = .removalAllowed
        MenuBarIcon.shared.attach(statusItem, symbol: image)
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

    /// Hidden with the switch, in System Settings → Menu Bar, or pushed out by a full menu bar.
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

/// "Значок в строке меню" for the panel. Off: the app keeps working; open it again from
/// Spotlight or Finder to get the panel back.
struct MenuBarIconToggle: View {
    @ObservedObject private var icon = MenuBarIcon.shared

    var body: some View {
        Toggle("Значок в строке меню", isOn: $icon.isShown)
            .help("Без значка приложение продолжает работать; панель открывается повторным запуском из Spotlight или Finder")
    }
}

/// "Значок приложения" and "Язык": the language mark is small beside the symbol, or the whole icon.
struct MenuBarIconStylePicker: View {
    @ObservedObject private var icon = MenuBarIcon.shared

    var body: some View {
        HStack {
            Picker("Язык на значке:", selection: $icon.languageMark) {
                ForEach(MenuBarIcon.LanguageMark.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Раскладка на значке заменяет системный значок языка: его можно убрать в Системных настройках → Клавиатура → Источники ввода")
            Toggle("с иконкой", isOn: $icon.showsSymbol)
                .disabled(icon.languageMark == .none)
                .help("Включено: язык мелко рядом с иконкой Genius Switcher. Выключено: только язык, крупно")
        }
    }
}
