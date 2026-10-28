import AppKit
import SwiftUI

/// The "Голосовые из Telegram" popup: the latest voice messages and their text, in a small panel
/// near the top centre of the screen with the pointer. Built on show and released on close; Esc,
/// a click elsewhere or the hot key again closes it. Does not take the focus from Telegram. The
/// stored texts of the last days show at once; a quiet status under the list tells while new
/// voice messages are looked for and transcribed. Scrolling on past the end, ↓ at the end or the
/// "Ещё" button adds the next few older ones. Same size as the left-click panel's column
/// (`SideColumn`), which never changes while texts arrive.
@MainActor
final class VoicePanel {
    static let shared = VoicePanel()

    private var panel: Panel?
    private var host: NSHostingView<VoicesView>?
    private var monitors: [Any] = []

    var isShown: Bool { panel != nil }

    func toggle() {
        isShown ? close() : show()
    }

    func show() {
        if panel == nil { build() }
        VoiceTranscripts.shared.refresh()
        place()
        panel?.makeKeyAndOrderFront(nil)
        watchForClose()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        host = nil
        VoiceTranscripts.shared.clear()
        Memory.giveBackSoon()
    }

    private func build() {
        let host = NSHostingView(rootView: VoicesView(close: { [weak self] in self?.close() }, titled: true))
        let size = host.fittingSize
        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.panel = panel
        self.host = host
    }

    private func place() {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let top = visible.maxY - visible.height * 0.18
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// A click anywhere else or Esc closes it, like a menu.
    private func watchForClose() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { self?.close(); return nil } // Esc
                return event
            }
        }) { monitors.append(local) }

    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

/// The voices with a search over their texts, laid out like the history column: search field, a
/// list filling the column's fixed size, one line under it. The popup adds a title row with a
/// close button.
struct VoicesView: View {
    let close: () -> Void
    var titled = false
    @ObservedObject private var model = VoiceTranscripts.shared
    @State private var more = MoreTrigger()
    @State private var search = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if titled {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    Text("Голосовые из Telegram").font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Закрыть (Esc)")
                }
            }
            TextField("Поиск по голосовым", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            VStack(alignment: .leading, spacing: 8) {
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !shown.isEmpty {
                    list
                } else if !query.isEmpty {
                    Text("Ничего не найдено").foregroundStyle(.secondary).padding(.vertical, 6)
                } else if model.problem == nil && !model.isChecking {
                    Text("Голосовых пока нет").foregroundStyle(.secondary).padding(.vertical, 6)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 8) {
                status
                Spacer()
                Text(HotkeyMonitor.shared.voicesShortcut.title).foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .padding(10)
        .frame(width: SideColumn.width, height: SideColumn.height)
        .onAppear {
            more.start()
            focused = true
        }
        .onDisappear(perform: more.stop)
        .onChange(of: search) { more.searching = !query.isEmpty }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    /// While searching: only the texts with every word of the query (also typed in the wrong
    /// layout, ё as е), as in the clipboard history; "more" is off.
    private var shown: [VoiceTranscripts.Item] {
        guard !query.isEmpty else { return model.items }
        let alternative = ClipboardRules.retyped(query, renderer: Observer.shared.layouts)
        return model.items.filter { item in
            guard case .done(let text) = item.text else { return false }
            return ClipboardRules.matches(text, query: query, alternative: alternative)
        }
    }

    /// Quiet, under the list: the stored texts are already shown while the cache is checked.
    @ViewBuilder private var status: some View {
        let pending = model.pending
        HStack(spacing: 5) {
            if model.isChecking {
                ProgressView().controlSize(.mini)
                Text("Проверяю новые голосовые…")
            } else if pending > 0 && model.problem == nil {
                ProgressView().controlSize(.mini)
                Text("Расшифровываю: \(pending)")
            } else if !model.items.isEmpty && model.problem == nil {
                Image(systemName: "checkmark")
                Text("Все голосовые расшифрованы")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        VoiceRow(item: item)
                            .id(item.id)
                    }
                    if query.isEmpty && (model.hasMore || model.isLoading) {
                        Button { model.loadMore() } label: {
                            HStack(spacing: 6) {
                                if model.isLoading {
                                    ProgressView().controlSize(.small)
                                    Text("Ищу ещё…")
                                } else {
                                    Image(systemName: "chevron.down")
                                    Text("Ещё \(VoiceTranscripts.pageSize)")
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isLoading)
                        .help("Или прокрутите вниз, или ↓")
                    }
                }
                // Room for the scroll bar, which is drawn over the content (the copy buttons).
                .padding(.trailing, 14)
            }
            .scrollIndicators(.automatic)
            .onScrollGeometryChange(for: Bool.self, of: { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 8
            }, action: { _, end in more.atEnd = end })
            // A page from "more": bring its first item into view.
            .onChange(of: model.newPage) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }
}

/// Scrolling down at the end of the list, or ↓ there, loads more: an event monitor while the list is
/// shown (momentum after a flick does not count, so one flick adds one page).
@MainActor
private final class MoreTrigger {
    var atEnd = true
    var searching = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard self?.atEnd == true, self?.searching == false else { return event }
                if event.type == .scrollWheel, event.scrollingDeltaY < 0, event.momentumPhase.isEmpty {
                    VoiceTranscripts.shared.loadMore()
                } else if event.type == .keyDown, event.keyCode == 125 { // ↓
                    VoiceTranscripts.shared.loadMore()
                    return nil
                }
                return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// One voice message with its whole text (folding to two lines and unfolding on click left the
/// unfolded text drawn over the rows below).
private struct VoiceRow: View {
    let item: VoiceTranscripts.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meta).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if case .done(let text) = item.text, !text.isEmpty {
                    Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Скопировать")
                }
                if deletable {
                    Button { VoiceTranscripts.shared.delete(item) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Удалить расшифровку")
                }
            }
            switch item.text {
            case .waiting:
                Text("В очереди…").foregroundStyle(.secondary)
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Распознаю…").foregroundStyle(.secondary)
                }
            case .done(let text):
                Text(text.isEmpty ? String(localized: "Речь не распознана") : text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
    }

    /// Not while it waits or is transcribed: the result would bring it back.
    private var deletable: Bool {
        switch item.text {
        case .done, .failed: true
        case .waiting, .transcribing: false
        }
    }

    private var meta: String {
        let seconds = Int(item.file.duration.rounded())
        let time = item.file.date.formatted(.relative(presentation: .named))
        // Texts stored before 0.13.0 have no duration.
        guard seconds > 0 else { return time }
        return "\(time) · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Sounds.play(.success)
    }
}
