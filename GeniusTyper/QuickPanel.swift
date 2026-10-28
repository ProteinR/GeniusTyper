import AppKit
import SwiftUI

/// What the menu bar icon's left click opens: a short menu-like panel under the icon. Only what is
/// used daily: the dictation and clipboard histories, the Telegram voices (a second column beside
/// it, open at once when they are on, so the latest ones start transcribing), "Исправлять текст"
/// for everything typed and for the app in front, the settings and quit. Rows of switched-off
/// parts are not shown. Built on show and released on close; Esc, a click elsewhere or the icon
/// again closes it. Does not take the focus from the app in front, but becomes key so the history
/// search can be typed in.
@MainActor
final class QuickPanel {
    static let shared = QuickPanel()

    private var panel: Panel?
    private var host: NSHostingView<QuickMenuView>?
    private var monitors: [Any] = []
    private weak var button: NSStatusBarButton?
    /// The icon on the screen; nil when it is hidden (the panel then opens at the top right).
    private var anchor: NSRect?

    var isShown: Bool { panel != nil }

    func show(under button: NSStatusBarButton?, anchor: NSRect?, side: String? = nil) {
        self.button = button
        self.anchor = anchor
        if panel == nil {
            let initial = side.flatMap(Side.init(rawValue:)) ?? (Prefs.dictationEnabled && Prefs.voicesEnabled ? .voices : nil)
            build(side: initial)
        }
        fit(initial: true)
        panel?.makeKeyAndOrderFront(nil)
        button?.highlight(true)
        watchForClose()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        host = nil
        button?.highlight(false)
        VoiceTranscripts.shared.clear()
        Memory.giveBackSoon()
    }

    private func build(side: Side?) {
        let host = NSHostingView(rootView: QuickMenuView(
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
    }

    /// Hangs from the icon: the top edge stays under the menu bar and the right edge at the icon's
    /// right edge, so the side column opens to the left (moved in if it would leave the screen).
    private func fit(initial: Bool) {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard initial || size != panel.frame.size else { return }
        let mouse = NSEvent.mouseLocation
        let screen = button?.window?.screen ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var top = panel.frame.maxY, right = panel.frame.maxX
        if initial {
            if let anchor {
                top = anchor.minY - 4
                right = anchor.maxX + 8
            } else {
                top = visible.maxY - 8
                right = visible.maxX - 8
            }
        }
        let x = max(visible.minX + 8, min(right - size.width, visible.maxX - size.width - 8))
        panel.setFrame(NSRect(x: x.rounded(), y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// A click anywhere else, Esc, or another Space closes it, like a menu (a click on the icon
    /// toggles it itself).
    private func watchForClose() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
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

/// The size of both side columns (voices and history) and of their lists, so switching between
/// them or new voice texts arriving never resize the panel (it jumped, 2026-10-28).
/// The whole column has a fixed size and its list takes what is left (the footers differ: a link
/// under the history, a status line under the voices).
enum SideColumn {
    static let width: CGFloat = 400
    static let height: CGFloat = 436
}

private struct QuickMenuView: View {
    let initialSide: Side?
    let close: () -> Void
    let resized: () -> Void
    @State private var side: Side?
    @ObservedObject private var observer = Observer.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @AppStorage("dictationEnabled") private var dictation = false
    @AppStorage("voicesEnabled") private var voices = true
    /// Who holds Secure Input, checked when the panel opens.
    @State private var secureInput = SecureInput.holder()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            switch side {
            case .voices:
                VoicesView(close: close)
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
        .toggleStyle(LightSwitchStyle())
        .onAppear { side = initialSide }
        .onChange(of: side) { old, new in
            // The voices keep transcribing while the history is shown; the panel's close clears them.
            if new == .voices { VoiceTranscripts.shared.refreshIfEmpty() }
            DispatchQueue.main.async(execute: resized)
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 2) {
            if dictation && voices {
                MenuRow(icon: "waveform", title: "Голосовые из Telegram",
                        detail: HotkeyMonitor.shared.voicesShortcut.title, opens: true, selected: side == .voices) {
                    side = .voices
                } hover: { side = .voices }
            }
            if dictation {
                MenuRow(icon: "clock.arrow.circlepath", title: "История диктовок", opens: true, selected: side == .history) {
                    side = .history
                } hover: { side = .history }
            }
            if clipboard.enabled {
                MenuRow(icon: "doc.on.clipboard", title: "История буфера", detail: clipboard.hotKey.title) {
                    close()
                    DispatchQueue.main.async { ClipboardWindow.show() }
                } hover: { side = nil }
            }
            if dictation || clipboard.enabled { Divider().padding(.vertical, 4) }

            SwitchRow(icon: "keyboard", title: "Исправлять текст", isOn: Binding(
                get: { !observer.paused }, set: { observer.paused = !$0 }))
                .help("Раскладка и ё. Выключено — Caps Lock только переключает раскладку")
            if let app = observer.lastApp {
                SwitchRow(icon: nil, title: "в «\(app.name)»", isOn: Binding(
                    get: { !observer.autoOffApps.contains(app.id) },
                    set: { observer.setAutoOff(app.id, !$0) }))
                    .disabled(observer.paused)
                    .opacity(observer.paused ? 0.45 : 1)
            }
            Divider().padding(.vertical, 4)

            if let secureInput {
                SecureInputRow(holder: secureInput)
            }
            if missingPermission {
                MenuRow(icon: "exclamationmark.triangle.fill", title: "Нужны разрешения", tint: .orange) {
                    close()
                    SettingsWindow.shared.show(page: .general)
                } hover: { side = nil }
            }
            MenuRow(icon: "gearshape", title: "Настройки…", detail: "⌘,") {
                close()
                SettingsWindow.shared.show()
            } hover: { side = nil }
            MenuRow(icon: "power", title: "Завершить Genius Typer", detail: "⌘Q") {
                NSApp.terminate(nil)
            } hover: { side = nil }
            Text(dictation ? "Genius Typer \(AppDelegate.appVersion) · \(HotkeyMonitor.shared.shortcut.title) — диктовка"
                           : "Genius Typer \(AppDelegate.appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
        .padding(6)
        .frame(width: 280)
    }

    private var missingPermission: Bool {
        !observer.hasPermission || !observer.canPost || (dictation && AudioRecorder.permission != .authorized)
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
    var tint: Color?
    let action: () -> Void
    let hover: () -> Void
    @State private var hovered = false
    @State private var hoverWork: DispatchWorkItem?

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).frame(width: 16).foregroundStyle(tint ?? .primary)
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

/// Secure Input is on: the keys (Caps Lock, Esc, the auto-fix) are not seen. Not a button; the
/// cure is in the text.
private struct SecureInputRow: View {
    let holder: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill").frame(width: 16).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Клавиши не видны: защищённый ввод")
                Text(holder == "loginwindow"
                     ? "Его не отпустил экран входа. Заблокируйте и разблокируйте экран (⌃⌘Q)"
                     : "Включён в «\(holder)» (поле пароля?). Пока он включён, Caps Lock и Esc не работают")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch in the menu, aligned with the rows; without an icon it is indented (it belongs to the
/// switch above).
private struct SwitchRow: View {
    let icon: String?
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).frame(width: 16) } else { Color.clear.frame(width: 16, height: 1) }
                Text(title).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
            Group {
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
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            Button("Вся история…") {
                close()
                SettingsWindow.shared.show(page: .history)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(10)
        .frame(width: SideColumn.width, height: SideColumn.height)
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
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta).font(.caption).foregroundStyle(.secondary)
                Text(entry.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            // Copies and stays open (a click on the row copies and closes the panel).
            Button {
                copy(entry.text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Скопировать")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
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
