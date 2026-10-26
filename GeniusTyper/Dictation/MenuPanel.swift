import AppKit
import Combine
import SwiftUI

/// What the menu bar icon's left click opens: a small panel under the icon with a second column
/// beside it: the latest Telegram voice messages, transcribed as it opens, or (hovering "История")
/// the history with search (the latest dictations are at its top, so they are not repeated under
/// the two items). Built on show and
/// released on close; Esc, a click elsewhere or the icon again closes it. Does not take the focus
/// from the app in front, but becomes key so the search field can be typed in.
@MainActor
final class MenuPanel {
    static let shared = MenuPanel()

    private var panel: Panel?
    private var host: NSHostingView<MenuView>?
    private var monitors: [Any] = []
    private var changes: AnyCancellable?
    private weak var button: NSStatusBarButton?

    var isShown: Bool { panel != nil }

    func toggle(under button: NSStatusBarButton) {
        isShown ? close() : show(under: button)
    }

    func show(under button: NSStatusBarButton, side: String? = nil) {
        self.button = button
        // Opens on the voices: the latest ones start transcribing at once.
        if panel == nil { build(side: side.flatMap(Side.init(rawValue:)) ?? .voices) }
        fit(initial: true)
        panel?.makeKeyAndOrderFront(nil)
        button.highlight(true)
        watchForClose()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        changes = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
        button?.highlight(false)
        VoiceTranscripts.shared.clear()
        Memory.giveBackSoon()
    }

    fileprivate func build(side: Side?) {
        let host = NSHostingView(rootView: MenuView(
            initialSide: side,
            close: { [weak self] in self?.close() },
            resized: { [weak self] in self?.fit(initial: false) }))
        let size = host.fittingSize
        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
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
        // Voice texts arrive after opening: grow with them.
        changes = VoiceTranscripts.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit(initial: false) } }
        }
    }

    /// Hangs from the icon: the top edge stays under the menu bar and the right edge at the icon's
    /// right edge, so the side column opens to the left (moved in if it would leave the screen).
    private func fit(initial: Bool) {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard initial || size != panel.frame.size else { return }
        var top = panel.frame.maxY, right = panel.frame.maxX
        if initial, let button, let window = button.window {
            let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
            top = icon.minY - 4
            right = icon.maxX + 8
        }
        let visible = (button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = max(visible.minX + 8, min(right - size.width, visible.maxX - size.width - 8))
        panel.setFrame(NSRect(x: x.rounded(), y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// A click anywhere else or Esc closes it, like a menu (a click on the icon toggles it itself).
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

private enum Side: String { case voices, history }

private struct MenuView: View {
    let initialSide: Side?
    let close: () -> Void
    let resized: () -> Void
    @State private var side: Side?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            switch side {
            case .voices:
                VoicesView(close: close, resized: resized)
                Divider()
            case .history:
                HistorySide(close: close)
                Divider()
            case nil:
                EmptyView()
            }
            main
        }
        .fixedSize()
        .onAppear { side = initialSide }
        .onChange(of: side) { old, new in
            // The voices keep transcribing while the history is shown; the panel's close clears them.
            if new == .voices { VoiceTranscripts.shared.refreshIfEmpty() }
            DispatchQueue.main.async(execute: resized)
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(icon: "waveform", title: "Голосовые из Telegram",
                    detail: HotkeyMonitor.shared.voicesShortcut.title, opens: true, selected: side == .voices) {
                side = .voices
            } hover: { side = .voices }
            MenuRow(icon: "clock.arrow.circlepath", title: "История", opens: true, selected: side == .history) {
                side = .history
            } hover: { side = .history }
        }
        .padding(6)
        .frame(width: 280)
    }
}

/// One row of the menu: highlighted under the pointer like a menu item. Like a submenu, hovering
/// switches the side column only when the pointer stays on the row (passing over "История" on the
/// way to the voices column does not open the history).
private struct MenuRow: View {
    let icon: String
    let title: String
    var detail: String?
    var opens = false
    var selected = false
    let action: () -> Void
    let hover: () -> Void
    @State private var hovered = false
    @State private var hoverWork: DispatchWorkItem?

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if let detail { Text(detail).foregroundStyle(.secondary) }
                if opens { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered || selected ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            hoverWork?.cancel()
            hoverWork = nil
            guard inside else { return }
            let work = DispatchWorkItem(block: hover)
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}

/// The history column: search as you type, newest first; a click copies.
private struct HistorySide: View {
    let close: () -> Void
    @State private var search = ""
    @State private var items: [HistoryEntry] = []
    @FocusState private var focused: Bool

    private static let limit = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Поиск по истории", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            if items.isEmpty {
                Text(search.isEmpty ? "История пуста" : "Ничего не найдено")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { entry in
                            HistoryRow(entry: entry) {
                                copy(entry.text)
                                close()
                            }
                        }
                    }
                    .padding(.trailing, 14) // room for the scroll bar
                }
                .frame(height: 360)
            }
            Button("Вся история…") {
                close()
                SettingsWindow.shared.show(page: .history)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(10)
        .frame(width: 400)
        .onAppear {
            load()
            focused = true
        }
        .onChange(of: search) { load() }
    }

    private func load() {
        items = History.shared.page(search: search.trimmingCharacters(in: .whitespaces), offset: 0, limit: Self.limit)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta).font(.caption).foregroundStyle(.secondary)
                Text(entry.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Нажмите, чтобы скопировать")
    }

    private var meta: String {
        let date = entry.date.formatted(.relative(presentation: .named))
        return entry.appName.isEmpty ? date : "\(date) · \(entry.appName)"
    }
}

@MainActor
private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    Sounds.play(.success)
}
