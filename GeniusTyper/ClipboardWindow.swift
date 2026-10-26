import AppKit
import SwiftUI

/// The clipboard history window (⇧⌘C), at the mouse pointer, like Maccy's: a search field and the
/// list with app icons; the preview of the selected entry opens beside it after a pause.
/// ⏎ pastes, ⌥⏎ only copies, ⇧⏎ pastes without formatting, ⌘1…⌘9 paste an entry, ⌥⌫ deletes, Esc closes.
///
/// A non-activating panel that still takes the keyboard: the app the user is in stays active, so
/// ⌘V after the panel closes goes to it.
@MainActor
enum ClipboardWindow {
    static let width: CGFloat = 450
    static let height: CGFloat = 520
    static let previewWidth: CGFloat = 400
    static let previewDelay: TimeInterval = 1.5

    private static var panel: KeyPanel?
    private static var preview: NSPanel?
    private static var previewHost: NSHostingView<ClipboardPreview>?
    private static var monitor: Any?
    private static let model = ClipboardPanelModel()

    static var isVisible: Bool { panel?.isVisible == true }

    static func toggle() {
        isVisible ? hide() : show()
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
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        panel.makeKeyAndOrderFront(nil)
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
        panel.setContentSize(NSSize(width: width, height: height))
        panel.contentView?.layoutSubtreeIfNeeded()
        model.close()
    }

    static func hide() {
        model.close()
        hidePreview()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
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
    private static func handle(_ key: Key) -> Bool {
        guard let panel, key.window == panel.windowNumber else { return false }
        let flags = key.flags
        switch key.code {
        case 125: model.move(1); return true  // ↓
        case 126: model.move(-1); return true  // ↑
        case 121: model.move(10); return true  // Page Down
        case 116: model.move(-10); return true  // Page Up
        case 36, 76:  // ⏎
            model.useSelected(paste: !flags.contains(.option), plain: flags.contains(.shift))
            return true
        case 53: hide(); return true  // Esc
        case 51 where flags.contains(.option):  // ⌥⌫
            model.deleteSelected()
            return true
        default:
            if flags == .command, let digit = key.characters.flatMap(Int.init), (1...9).contains(digit) {
                model.use(index: digit - 1)
                return true
            }
            if flags == .command, key.code == 12 || key.code == 13 { hide(); return true }  // ⌘Q, ⌘W
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
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = Background(content: NSHostingView(rootView: ClipboardListView().environmentObject(model)))
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { hide() }  // a click elsewhere
        }
        return panel
    }

    // MARK: Preview

    static func showPreview(_ item: ClipboardItem) {
        guard let panel, panel.isVisible else { return }
        let preview = preview ?? makePreview()
        Self.preview = preview
        let previewHeight = Self.previewHeight(item)
        let content = ClipboardPreview(item: item, height: previewHeight)
        if let previewHost {
            previewHost.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            previewHost = host
            preview.contentView = Background(content: host)
        }
        let frame = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let x = frame.maxX + previewWidth + 4 <= visible.maxX ? frame.maxX + 4 : frame.minX - previewWidth - 4
        preview.setFrame(NSRect(x: x, y: frame.maxY - previewHeight, width: previewWidth, height: previewHeight), display: true)
        if preview.parent == nil { panel.addChildWindow(preview, ordered: .above) }
        preview.orderFront(nil)
    }

    /// As tall as the content (up to the list's height): padding and the details line are ~60 pt.
    private static func previewHeight(_ item: ClipboardItem) -> CGFloat {
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
        return min(max(content + 60, 100), height)
    }

    static func hidePreview() {
        guard let preview else { return }
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
}

/// The menu's own background (not SwiftUI materials: cheap in memory), rounded.
private final class Background: NSVisualEffectView {
    init(content: NSView) {
        super.init(frame: .zero)
        material = .menu
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
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

    func open() {
        query = ""
        filter()
        mouse = NSEvent.mouseLocation
        opened += 1
    }

    func close() {
        previewWork?.cancel()
        previewShown = false
    }

    private func filter() {
        let query = query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            results = store.items
        } else {
            let alternative = ClipboardRules.retyped(query, renderer: Observer.shared.layouts)
            results = store.items.filter { ClipboardRules.matches($0, query: query, alternative: alternative) }
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
        store.use(item, paste: paste && KeyPoster.canPost, plain: plain)
    }

    func deleteSelected() {
        guard let index = results.firstIndex(where: { $0.id == selection }) else { return }
        store.delete(results[index])
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if model.results.isEmpty {
                Text(model.query.isEmpty ? "История пуста" : "Ничего не найдено")
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
                Text("⏎ вставить · ⌥⏎ скопировать · ⇧⏎ без форматирования · ⌥⌫ удалить")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                // As in Maccy: the settings from the history itself (the clipboard page).
                Button {
                    ClipboardWindow.hide()
                    DispatchQueue.main.async { SettingsWindow.shared.show(page: .clipboard) }
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
                Text("⌘\(index + 1)").font(.caption).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
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
