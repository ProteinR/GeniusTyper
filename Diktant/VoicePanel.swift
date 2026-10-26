import AppKit
import Combine
import SwiftUI

/// The "Голосовые из Telegram" popup: the latest voice messages and their text, in a small panel
/// near the top centre of the screen with the pointer. Built on show and released on close; Esc,
/// a click elsewhere or the hot key again closes it. Does not take the focus from Telegram. Scrolling
/// on past the end, ↓ at the end or the "Ещё" button adds the next few older ones.
@MainActor
final class VoicePanel {
    static let shared = VoicePanel()

    private var panel: Panel?
    private var host: NSHostingView<VoicesView>?
    private var monitors: [Any] = []
    private var changes: AnyCancellable?

    var isShown: Bool { panel != nil }

    func toggle() {
        isShown ? close() : show()
    }

    func show() {
        if panel == nil { build() }
        VoiceTranscripts.shared.refresh()
        fit(anchorTop: false)
        panel?.makeKeyAndOrderFront(nil)
        watchForClose()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        changes = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
        VoiceTranscripts.shared.clear()
        Memory.giveBackSoon()
    }

    private func build() {
        let host = NSHostingView(rootView: VoicesView(
            close: { [weak self] in self?.close() },
            resized: { [weak self] in self?.fit(anchorTop: true) }))
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
        // The text arrives after opening: grow with it, keeping the top edge in place.
        changes = VoiceTranscripts.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit(anchorTop: true) } }
        }
    }

    private func fit(anchorTop: Bool) {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if anchorTop {
            guard size != panel.frame.size else { return }
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
            return
        }
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

struct VoicesView: View {
    let close: () -> Void
    let resized: () -> Void
    @ObservedObject private var model = VoiceTranscripts.shared
    @State private var listHeight: CGFloat = 0
    @State private var more = MoreTrigger()

    /// Taller than this, the list scrolls.
    private let maxListHeight: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text("Голосовые из Telegram").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Закрыть (Esc)")
            }
            if model.isLoading && model.items.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Ищу голосовые…").foregroundStyle(.secondary)
                }
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.items.isEmpty { list }
            Text(model.hasMore
                 ? "Новое сверху · ещё — прокрутите вниз или ↓ · \(HotkeyMonitor.shared.voicesShortcut.title)"
                 : "Новое сверху · \(HotkeyMonitor.shared.voicesShortcut.title)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 460)
        .onAppear(perform: more.start)
        .onDisappear(perform: more.stop)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        VoiceRow(item: item)
                            .id(item.id)
                    }
                    if model.hasMore || model.isLoading {
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
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(listHeight, maxListHeight))
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { _, height in
                listHeight = height
                DispatchQueue.main.async(execute: resized)
            }
            .onScrollGeometryChange(for: Bool.self, of: { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 8
            }, action: { _, end in more.atEnd = end })
            // A new page: bring its first item into view.
            .onChange(of: model.items.count) { old, new in
                guard old > 0, new > old else { return }
                withAnimation { proxy.scrollTo(model.items[old].id, anchor: .top) }
            }
        }
    }
}

/// Scrolling down at the end of the list, or ↓ there, loads more: an event monitor while the list is
/// shown (momentum after a flick does not count, so one flick adds one page).
@MainActor
private final class MoreTrigger {
    var atEnd = true
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard self?.atEnd == true else { return event }
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

    private var meta: String {
        let seconds = Int(item.file.duration.rounded())
        let time = item.file.date.formatted(.relative(presentation: .named))
        return "\(time) · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Sounds.play(.success)
    }
}
