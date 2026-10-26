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

    /// While dictating the icon is a red microphone (an ellipsis while the text is recognised).
    var dictationPhase: Dictation.Phase = .idle {
        didSet { if dictationPhase != oldValue { render() } }
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        button.image = nil
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.contentTintColor = nil
        switch dictationPhase {
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: String(localized: "Genius Typer: запись"))
            button.contentTintColor = .systemRed
            return
        case .transcribing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: String(localized: "Genius Typer: распознавание"))
            return
        case .idle:
            break
        }
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

/// The menu bar icon: left click opens `QuickPanel`, right click a small menu ending with
/// "Завершить".
///
/// Made by hand rather than with SwiftUI's `MenuBarExtra`: when the icon is turned off in System
/// Settings → Menu Bar, a `MenuBarExtra`-only app quits right after launch, and its keys stop
/// working. An `NSStatusItem` just stays hidden; opening the app again (Spotlight, Finder) then
/// shows the panel at the top right of the screen instead.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menuItems: () -> [NSMenuItem]
    private let quitTitle: String

    /// `image`: a template image drawn by the app; `menuItems` are built on every right click (so
    /// their checkmarks are current).
    init(image: NSImage?, title: String, menuItems: @escaping () -> [NSMenuItem] = { [] }) {
        // Variable length: the layout text or flag (a choice in the settings) is wider than a symbol.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menuItems = menuItems
        quitTitle = "Завершить \(title)"
        super.init()
        statusItem.behavior = .removalAllowed
        MenuBarIcon.shared.attach(statusItem, symbol: image)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Under the icon, or at the top right of the screen when the icon is hidden.
    /// `side`: "voices" or "history" opens that column (for `--menu`).
    func showPanel(side: String? = nil) {
        var anchor: NSRect?
        if isIconVisible, let button = statusItem.button, let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        QuickPanel.shared.show(under: anchor == nil ? nil : statusItem.button, anchor: anchor, side: side)
    }

    func closePanel() { QuickPanel.shared.close() }

    /// Hidden with the switch, in System Settings → Menu Bar, or pushed out by a full menu bar.
    private var isIconVisible: Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window else { return false }
        return window.occlusionState.contains(.visible) && window.frame.maxY > 0
    }

    /// `--panel-test`: opens and closes the panel a few times and logs how long the main thread
    /// stalled while it opened (a stall = a jerky opening).
    func runPanelTest(rounds: Int = 6) {
        var round = 0
        func next() {
            guard round < rounds else { return }
            round += 1
            let start = CACurrentMediaTime()
            var last = start
            var longest = 0.0
            var late = 0
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                let now = CACurrentMediaTime()
                longest = max(longest, now - last)
                if now - last > 0.025 { late += 1 }
                last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            showPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                timer.invalidate()
                Log.info(String(format: "Panel test %d: longest stall %.1f ms, %d over 25 ms", round, longest * 1000, late), "panel")
                self.closePanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
            }
        }
        next()
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closePanel()
            showMenu()
        } else if QuickPanel.shared.isShown {
            closePanel()
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
