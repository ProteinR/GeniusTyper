import AppKit
import SwiftUI

/// The clipboard history window (⇧⌘C), at the mouse pointer, like Maccy's: a search field and the
/// list with app icons; the preview of the selected entry opens beside it after a pause.
/// ⏎ pastes, ⌥⏎ only copies, ⇧⏎ pastes without formatting, ⌥1…⌥9 paste an entry, ⌥⌫ deletes, Esc closes.
/// Two tabs while dictation is on (asked 2026-11-19: a dictation pasted nowhere, with the menu bar
/// icon hidden, could not be found): "Буфер обмена", always the one it opens on, and "Диктовки",
/// the dictation history; Tab, ⌘1 and ⌘2 switch.
///
/// A non-activating panel that still takes the keyboard: the app the user is in stays active, so
/// ⌘V after the panel closes goes to it.
@MainActor
enum ClipboardWindow {
    static let width: CGFloat = 450
    static let height: CGFloat = 520
    static let previewWidth: CGFloat = 400
    static let previewDelay: TimeInterval = 1.5
    /// Room around the card for its own shadow: the window is this much bigger on every side.
    static let margin: CGFloat = 28

    private static var panel: KeyPanel?
    private static var preview: NSPanel?
    private static var previewHost: NSHostingView<ClipboardPreview>?
    private static var monitor: Any?
    private static let model = ClipboardPanelModel()

    /// Open, not fading out (a closing panel is still visible for 0.1 s).
    static var isVisible: Bool { panel?.isVisible == true && !closing }
    private static var closing = false

    static func toggle() {
        isVisible ? dismiss() : show()
    }

    static func show() {
        let panel = panel ?? makePanel()
        Self.panel = panel
        model.open()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x, y: mouse.y - height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        }
        let card = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.setFrame(card.insetBy(dx: -margin, dy: -margin), display: false)
        closing = false
        panel.ignoresMouseEvents = false
        panel.contentView?.layer?.removeAnimation(forKey: "close")
        panel.makeKeyAndOrderFront(nil)
        animateOpening(panel, from: NSPoint(x: mouse.x - origin.x + margin, y: mouse.y - origin.y + margin))
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let key = Key(window: event.windowNumber, code: event.keyCode,
                              flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                              characters: event.charactersIgnoringModifiers)
                return MainActor.assumeIsolated { handle(key) } ? nil : event
            }
        }
    }

    /// Built and laid out ahead (the first build took ~165 ms, a visible jerk on the first opening).
    static func prepare() {
        guard panel == nil else { return }
        let panel = makePanel()
        Self.panel = panel
        model.open()
        panel.setContentSize(NSSize(width: width + 2 * margin, height: height + 2 * margin))
        panel.contentView?.layoutSubtreeIfNeeded()
        model.close()
    }

    /// Grows from the pointer (92 % → 100 %) while it fades in, 0.18 s; only a fade with Reduce
    /// Motion (asked 2026-11-20, chosen from four in a preview). Nothing is redrawn: the content
    /// layer, already drawn, gets a Core Animation opacity and transform, run by the render server
    /// on the GPU. (Animating the window's `alphaValue` instead cost ~18 ms of CPU per opening: AppKit
    /// steps it frame by frame.) The model values stay as they are, so nothing is left half done if
    /// the animation is cut short.
    private static func animateOpening(_ panel: NSPanel, from pointer: NSPoint) {
        guard let layer = panel.contentView?.layer else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        var animations: [CAAnimation] = [fade]
        if !reduce {
            // The scale is about the pointer; the transform works about the layer's anchor point.
            let anchor = NSPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
            let dx = min(max(pointer.x, margin), margin + width) - anchor.x
            let dy = min(max(pointer.y, margin), margin + height) - anchor.y
            var start = CATransform3DMakeTranslation(dx, dy, 0)
            start = CATransform3DScale(start, 0.92, 0.92, 1)
            start = CATransform3DTranslate(start, -dx, -dy, 0)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: start)
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animations.append(grow)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = reduce ? 0.12 : 0.18
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(group, forKey: "open")
    }

    /// Esc, ⌘W, a click elsewhere, the shortcut again: fades out in 0.1 s (the content layer's
    /// opacity, as on opening). Choosing an entry closes at once (`hide`): the ⌘V that pastes must
    /// reach the app in front, not this panel.
    static func dismiss() {
        guard let panel, panel.isVisible, !closing else { return }
        guard let layer = panel.contentView?.layer else { return hide() }
        closing = true
        model.close()
        hidePreview()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.ignoresMouseEvents = true
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard closing else { return }  // opened again meanwhile
                hide()
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.1
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "close")
        CATransaction.commit()
    }

    static func hide() {
        model.close()
        hidePreview()
        closing = false
        guard let panel, panel.isVisible else { return }
        panel.ignoresMouseEvents = false
        panel.orderOut(nil)
        panel.contentView?.layer?.removeAllAnimations()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Memory.giveBackSoon()
    }

    /// `--history-test`: opens the history `rounds` times, moves down through it until the preview
    /// opens, closes it; logs the longest main-thread stall (a stall = a jerk) and the footprint.
    static func runTest(rounds: Int = 6) {
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
            show()
            for step in 1...12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(step)) { model.move(1) }
            }
            // The preview opens 1.5 s after the last move.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4 + previewDelay) {
                timer.invalidate()
                Log.info(String(format: "History test %d: longest stall %.1f ms, %d over 25 ms, footprint %@ MB",
                                round, longest * 1000, late, AppDelegate.footprintMB()), "clipboard")
                hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }
            }
        }
        next()
    }

    private struct Key: Sendable {
        let window: Int
        let code: UInt16
        let flags: NSEvent.ModifierFlags
        let characters: String?
    }

    /// Keys the list handles; everything else goes to the search field.
    /// Key codes of 1…9 on the number row (the same in every layout; ⌥ turns the characters into symbols).
    private static let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private static func handle(_ key: Key) -> Bool {
        guard let panel, key.window == panel.windowNumber else { return false }
        let flags = key.flags
        if let digit = digitCodes.firstIndex(of: key.code) {
            if flags == .option { model.use(index: digit); return true }
            if flags == .command, digit < 2 { model.switchTo(digit == 0 ? .clipboard : .dictations); return true }
        }
        switch key.code {
        case 48 where flags.isDisjoint(with: [.command, .option, .control]):  // Tab, ⇧Tab
            model.switchTo(model.tab == .clipboard ? .dictations : .clipboard)
            return true
        case 125: model.move(1); return true  // ↓
        case 126: model.move(-1); return true  // ↑
        case 121: model.move(10); return true  // Page Down
        case 116: model.move(-10); return true  // Page Up
        case 36, 76:  // ⏎
            model.useSelected(paste: !flags.contains(.option), plain: flags.contains(.shift))
            return true
        case 53: dismiss(); return true  // Esc
        case 51 where flags.contains(.option):  // ⌥⌫
            model.deleteSelected()
            return true
        default:
            if flags == .command, key.code == 12 || key.code == 13 { dismiss(); return true }  // ⌘Q, ⌘W
            return false
        }
    }

    private static func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Its own shadow and hairline (`CardView`, as MeetRec's panel): the window's, drawn by the
        // WindowServer, stayed full size while the card grew, and its light edge came on top of
        // the window after it had opened (2026-11-20).
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = CardView(card: Background(content: NSHostingView(rootView: ClipboardListView().environmentObject(model)),
                                                      hairline: true),
                                     margin: margin)
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { dismiss() }  // a click elsewhere
        }
        return panel
    }

    // MARK: Preview

    static func showPreview(_ item: ClipboardItem) {
        guard let panel, panel.isVisible else { return }
        showPreview(item, beside: panel, frame: panel.frame.insetBy(dx: margin, dy: margin))
    }

    /// The preview beside `window` (the history window or the left-click panel), on the right when
    /// it fits there (`left`: on the left first), no taller than the window. `hover` hears the
    /// pointer entering and leaving it.
    /// `frame`: the visible part of `window`, when it is not the whole window.
    static func showPreview(_ item: ClipboardItem, beside window: NSWindow, frame: NSRect? = nil, left: Bool = false,
                            hover: ((Bool) -> Void)? = nil) {
        let frame = frame ?? window.frame
        let preview = preview ?? makePreview()
        Self.preview = preview
        let previewHeight = Self.previewHeight(item, max: frame.height)
        let content = ClipboardPreview(item: item, height: previewHeight, hover: hover)
        if let previewHost {
            previewHost.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            previewHost = host
            preview.contentView = Background(content: host)
        }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let right = frame.maxX + 4, leftX = frame.minX - previewWidth - 4
        let fitsRight = right + previewWidth <= visible.maxX, fitsLeft = leftX >= visible.minX
        let x = left ? (fitsLeft || !fitsRight ? leftX : right) : (fitsRight || !fitsLeft ? right : leftX)
        preview.setFrame(NSRect(x: x, y: frame.maxY - previewHeight, width: previewWidth, height: previewHeight), display: true)
        if preview.parent !== window {
            preview.parent?.removeChildWindow(preview)
            window.addChildWindow(preview, ordered: .above)
        }
        preview.orderFront(nil)
    }

    /// As tall as the content (up to the list's height): padding and the details line are ~60 pt.
    private static func previewHeight(_ item: ClipboardItem, max maxHeight: CGFloat) -> CGFloat {
        let content: CGFloat
        switch item.kind {
        case .text, .files:
            let text = String((item.text ?? "").prefix(5_000)) as NSString
            let font: NSFont = item.kind == .text ? .preferredFont(forTextStyle: .callout) : .monospacedSystemFont(ofSize: 12, weight: .regular)
            content = text.boundingRect(with: NSSize(width: previewWidth - 24, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height + 4
        case .image:
            let ratio = CGFloat(item.height ?? 1) / CGFloat(max(item.width ?? 1, 1))
            content = min((previewWidth - 24) * ratio, 400)
        }
        return min(max(content + 60, 100), maxHeight)
    }

    /// `of`: only when it hangs beside that window.
    static func hidePreview(of window: NSWindow? = nil) {
        guard let preview, window == nil || preview.parent === window else { return }
        preview.parent?.removeChildWindow(preview)
        preview.orderOut(nil)
        preview.contentView = nil  // its image goes with it
        previewHost = nil
    }

    private static func makePreview() -> NSPanel {
        let preview = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        preview.level = .popUpMenu
        preview.isReleasedWhenClosed = false
        preview.backgroundColor = .clear
        preview.isOpaque = false
        preview.hasShadow = true
        preview.ignoresMouseEvents = false
        return preview
    }
}

/// A borderless panel does not take the keyboard by default.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A click in the shadow around the card is a click elsewhere.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           let card = (contentView as? CardView)?.card, !card.frame.contains(event.locationInWindow) {
            MainActor.assumeIsolated { ClipboardWindow.dismiss() }
            return
        }
        super.sendEvent(event)
    }
}

/// The card with its own soft shadow, `margin` inside the window. One layer each, the shadow from a
/// path: nothing is drawn per frame, and the opening animation scales them together.
private final class CardView: NSView {
    let card: NSView
    private let margin: CGFloat
    private let shadowView = NSView()

    init(card: NSView, margin: CGFloat) {
        self.card = card
        self.margin = margin
        super.init(frame: .zero)
        wantsLayer = true
        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.35
        shadowView.layer?.shadowRadius = 10
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -5)
        addSubview(shadowView)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: margin, dy: margin)
        shadowView.frame = frame
        card.frame = frame
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: Background.cornerRadius,
                                          cornerHeight: Background.cornerRadius, transform: nil)
    }
}

/// The menu's own background (not SwiftUI materials: cheap in memory), rounded.
/// `hairline`: a 0.5 pt light edge (MeetRec's panel), for a window without the system shadow.
private final class Background: NSVisualEffectView {
    static let cornerRadius: CGFloat = 10

    init(content: NSView, hairline: Bool = false) {
        super.init(frame: .zero)
        material = .menu
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        if hairline {
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// What the list shows: the history filtered by the search, and the selected entry.
@MainActor
final class ClipboardPanelModel: ObservableObject {
    enum Tab { case clipboard, dictations }

    @Published private(set) var tab = Tab.clipboard
    /// The tabs show only while dictation is on.
    @Published private(set) var showsTabs = false
    @Published var query = "" {
        didSet { filter() }
    }
    @Published private(set) var results: [ClipboardItem] = []
    @Published private(set) var selection: UUID?
    /// Bumped on every open: the search field takes the focus again.
    @Published private(set) var opened = 0
    /// Set by keyboard moves: the list scrolls to it (the hovered row is on screen already).
    @Published private(set) var scrollTarget: UUID?

    private let store = ClipboardStore.shared
    private var previewWork: DispatchWorkItem?
    private var previewShown = false
    /// The list moves under a still mouse pointer (opening at the pointer, scrolling with the keys):
    /// hovering selects only after the pointer itself moves.
    private var mouse = NSPoint.zero

    /// The newest dictations as list entries (read from the history on switching to the tab), and
    /// the history row behind each.
    private var dictationItems: [ClipboardItem] = []
    private var dictationIDs: [UUID: Int64] = [:]
    private static let dictationLimit = 500

    func open() {
        showsTabs = Prefs.dictationEnabled
        tab = .clipboard
        dictationItems = []
        dictationIDs = [:]
        query = ""
        filter()
        mouse = NSEvent.mouseLocation
        opened += 1
    }

    func close() {
        previewWork?.cancel()
        previewShown = false
    }

    func switchTo(_ tab: Tab) {
        guard showsTabs, tab != self.tab else { return }
        self.tab = tab
        if tab == .dictations { loadDictations() }
        selection = nil
        filter()
        opened += 1  // back to the top, the search field focused
    }

    private func loadDictations() {
        dictationIDs = [:]
        dictationItems = History.shared.page(offset: 0, limit: Self.dictationLimit).map { entry in
            let id = Self.uuid(entry.id)
            dictationIDs[id] = entry.id
            return ClipboardItem(id: id, date: entry.date, kind: .text, app: entry.appBundle.isEmpty ? nil : entry.appBundle,
                                 text: entry.text, stored: [:], hash: "dictation-\(entry.id)")
        }
    }

    private static func uuid(_ id: Int64) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: id.bigEndian) { for (index, byte) in $0.enumerated() { bytes[8 + index] = byte } }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func filter() {
        let source = tab == .clipboard ? store.items : dictationItems
        let query = query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            results = source
        } else {
            let alternative = ClipboardRules.retyped(query, renderer: Observer.shared.layouts)
            results = source.filter { ClipboardRules.matches($0, query: query, alternative: alternative) }
        }
        select(results.first?.id)
    }

    func select(_ id: UUID?) {
        guard id != selection || id == nil else { return }
        selection = id
        previewWork?.cancel()
        guard let item = results.first(where: { $0.id == id }) else {
            ClipboardWindow.hidePreview()
            previewShown = false
            return
        }
        if previewShown {
            ClipboardWindow.showPreview(item)
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.previewShown = true
                ClipboardWindow.showPreview(item)
            }
            previewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + ClipboardWindow.previewDelay, execute: work)
        }
    }

    func move(_ step: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selection } ?? -1
        let id = results[min(max(index + step, 0), results.count - 1)].id
        select(id)
        scrollTarget = id
    }

    func hover(_ id: UUID) {
        let location = NSEvent.mouseLocation
        guard location != mouse else { return }
        mouse = location
        select(id)
    }

    func useSelected(paste: Bool, plain: Bool) {
        guard let item = results.first(where: { $0.id == selection }) else { return }
        use(item, paste: paste, plain: plain)
    }

    func use(index: Int) {
        guard results.indices.contains(index) else { return }
        use(results[index], paste: true, plain: false)
    }

    func use(_ item: ClipboardItem, paste: Bool, plain: Bool) {
        ClipboardWindow.hide()
        if dictationIDs[item.id] != nil {
            // A dictation goes in as dictation does: the clipboard is given back afterwards.
            let text = item.text ?? ""
            if paste && KeyPoster.canPost {
                DispatchQueue.main.async { _ = Paster.paste(text) }
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Log.info("Dictation from the history \(paste ? "pasted" : "copied")", "clipboard")
            return
        }
        store.use(item, paste: paste && KeyPoster.canPost, plain: plain)
    }

    func deleteSelected() {
        guard let index = results.firstIndex(where: { $0.id == selection }) else { return }
        if let id = dictationIDs[results[index].id] {
            History.shared.delete(id: id)
            dictationItems.removeAll { $0.id == results[index].id }
        } else {
            store.delete(results[index])
        }
        results.remove(at: index)
        selection = nil
        select(results.indices.contains(index) ? results[index].id : results.last?.id)
    }
}

private struct ClipboardListView: View {
    @EnvironmentObject private var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.showsTabs {
                HStack(spacing: 2) {
                    tabButton(.clipboard, "Буфер обмена", "⌘1")
                    tabButton(.dictations, "Диктовки", "⌘2")
                }
                .padding(2)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 8).padding(.top, 8)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if model.results.isEmpty {
                Text(!model.query.isEmpty ? "Ничего не найдено" : model.tab == .clipboard ? "История пуста" : "Диктовок пока нет")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                                ClipboardRow(item: item, index: index, selected: item.id == model.selection)
                                    .id(item.id)
                                    .onHover { if $0 { model.hover(item.id) } }
                                    .onTapGesture {
                                        let flags = NSEvent.modifierFlags
                                        model.use(item, paste: !flags.contains(.option), plain: flags.contains(.shift))
                                    }
                            }
                        }
                        .padding(5)
                    }
                    .onChange(of: model.scrollTarget) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                    .onChange(of: model.opened) { _, _ in
                        if let first = model.results.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text(model.tab == .clipboard ? "⏎ вставить · ⌥⏎ скопировать · ⇧⏎ без форматирования · ⌥⌫ удалить"
                                              : "⏎ вставить · ⌥⏎ скопировать · ⌥⌫ удалить · Tab — буфер")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                // As in Maccy: the settings from the history itself (the clipboard page).
                Button {
                    ClipboardWindow.hide()
                    let tab = model.tab
                    DispatchQueue.main.async {
                        if tab == .clipboard {
                            SettingsWindow.shared.show(page: .clipboard)
                        } else {
                            SettingsWindow.shared.show(page: .dictation, dictation: .history)
                        }
                    }
                } label: {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Настройки")
            }
            .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 5)
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.opened) { _, _ in searchFocused = true }
    }

    private func tabButton(_ tab: ClipboardPanelModel.Tab, _ title: LocalizedStringKey, _ key: String) -> some View {
        Button { model.switchTo(tab) } label: {
            HStack(spacing: 4) {
                Text(title).fontWeight(model.tab == tab ? .semibold : .regular)
                Text(key).font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(model.tab == tab ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let index: Int
    let selected: Bool
    private let store = ClipboardStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = store.icon(item.app) {
                    Image(nsImage: icon)
                } else {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            if item.kind == .image, let thumbnail = store.thumbnail(item) {
                Image(nsImage: thumbnail)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 40, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Spacer(minLength: 0)
            } else {
                Text(item.title)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if index < 9 {
                Text("⌥\(index + 1)").font(.caption).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(selected ? .white : .primary)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

struct ClipboardPreview: View {
    let item: ClipboardItem
    let height: CGFloat
    var hover: ((Bool) -> Void)?
    private let store = ClipboardStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item.kind {
            case .text:
                ScrollView {
                    Text(String((item.text ?? "").prefix(20_000)))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .image:
                if let image = store.previewImage(item, maxPixels: Int(ClipboardWindow.previewWidth * 2)) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 400)
                }
            case .files:
                ScrollView {
                    Text(item.text ?? "").font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack(spacing: 6) {
                if let icon = store.icon(item.app) { Image(nsImage: icon) }
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: ClipboardWindow.previewWidth, height: height, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hover?($0) }
    }

    private var details: String {
        var parts: [String] = []
        if let name = store.appName(item.app) { parts.append(name) }
        parts.append(item.date.formatted(date: .abbreviated, time: .shortened))
        if item.kind == .text, let text = item.text { parts.append("\(text.count) симв.") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}
