import AppKit
import SwiftUI
import ProteinKit

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, typing, clipboard, dictation, history, statistics
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "Основное"
        case .typing: return "Раскладка"
        case .clipboard: return "Буфер обмена"
        case .dictation: return "Диктовка"
        case .history: return "История"
        case .statistics: return "Статистика"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .typing: return "keyboard.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .dictation: return "mic.fill"
        case .history: return "clock.fill"
        case .statistics: return "chart.bar.fill"
        }
    }

    /// The icon's tile, as in System Settings (and MeetRec): each page its own colour.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .typing: return .blue
        case .clipboard: return .teal
        case .dictation: return .red
        case .history: return .orange
        case .statistics: return .purple
        }
    }
}

/// The settings window: everything that is not used daily (the left-click panel has that). Pages
/// in a sidebar; the three parts of the app (Раскладка, Буфер обмена, Диктовка) each start with
/// their own switch (the sidebar had green dots for the parts that are on; the owner found them
/// unclear, 2026-10-29). Made on open and dropped on close, so it
/// costs no memory while hidden (lessons from MXCtl: no `TabView`, no system switches,
/// `sizingOptions` off).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    final class Navigation: ObservableObject {
        @Published var page: SettingsPage = .general {
            didSet { if page != oldValue { dictationSub = nil } }
        }
        /// A page of Диктовка opened from its list ("‹ Диктовка" goes back).
        @Published var dictationSub: DictationSubpage?
    }

    private var window: NSWindow?
    private var navigation: Navigation?

    func show(page: SettingsPage? = nil, dictation sub: DictationSubpage? = nil) {
        if window == nil {
            let navigation = Navigation()
            self.navigation = navigation
            let host = NSHostingController(rootView: SettingsView(navigation: navigation))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "Genius Typer — настройки")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = NSSize(width: 640, height: 460)
            if !window.setFrameUsingName(Self.frameName) {
                window.setContentSize(NSSize(width: 720, height: 560))
                window.center()
            }
            window.setFrameAutosaveName(Self.frameName)
            self.window = window
        }
        if let page { navigation?.page = page }
        if let sub { navigation?.dictationSub = sub }
        // A menu bar app may be refused activation and the window opened behind other apps: force it.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// История on one of its tabs ("Вся история…" under the panel's columns).
    func show(history kind: HistoryPage.Kind) {
        UserDefaults.standard.set(kind.rawValue, forKey: "historyKind")
        show(page: .history)
    }

    private static let frameName = "Settings"

    /// Lays out and draws the window at once (for timing how long a page takes to open).
    func layoutNow() {
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        HotkeyMonitor.shared.isPaused = false
        window?.contentViewController = nil
        window = nil
        navigation = nil
        Memory.giveBackSoon()
    }
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsWindow.Navigation

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    Button {
                        navigation.page = page
                    } label: {
                        HStack(spacing: 8) {
                            SettingsTile(symbol: page.symbol, tint: page.tint)
                            Text(page.title)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .foregroundStyle(navigation.page == page ? Color.white : Color.primary)
                            .background(navigation.page == page ? Color.accentColor : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Divider().padding(.horizontal, 6)
                AboutFooter(appName: "Genius Typer", axis: .vertical)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
            }
            .padding(10)
            .frame(width: 200)
            .background(Color.primary.opacity(0.04))
            Divider()
            Group {
                switch navigation.page {
                case .general: GeneralPage()
                case .typing: TypingPage()
                case .clipboard: ClipboardPage()
                case .dictation: DictationPage(navigation: navigation)
                case .history: HistoryPage(navigation: navigation)
                case .statistics: StatisticsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

/// A page's icon: a white symbol on a coloured rounded tile (System Settings, MeetRec).
struct SettingsTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
    }
}

/// A setting's label with its tile: title and a line under it (Раскладка, Буфер обмена).
struct TiledLabel: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            SettingsTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row in a settings form that opens its own page: tile, title, a one-line summary, chevron.
/// `trailing` goes before the chevron (a switch).
struct SettingsLinkRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let summary: String
    var opens = true
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            SettingsTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            trailing()
            if opens {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if opens { action() } }
    }
}

extension SettingsLinkRow where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: LocalizedStringKey, summary: String, action: @escaping () -> Void) {
        self.init(symbol: symbol, tint: tint, title: title, summary: summary, action: action) { EmptyView() }
    }
}

/// The top of a page opened from a list: "‹ back" on the left, the title in the middle.
struct SubpageHeader: View {
    let back: LocalizedStringKey
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        ZStack {
            Text(title).font(.headline)
            HStack {
                Button(action: action) {
                    Label(back, systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }
}

/// The switch at the top of a part of the app, with what it does and what turning it off means.
struct ModuleSwitch: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// Under a part's switch: grey and inactive while the part is off.
    func active(_ on: Bool) -> some View {
        disabled(!on).opacity(on ? 1 : 0.45)
    }
}

/// A small segmented control drawn by SwiftUI (the system one is a `Picker`, see `LightSwitchStyle`).
struct Segments<Value: Hashable>: View {
    let items: [(Value, LocalizedStringKey)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let (value, title) = items[index]
                Button { selection = value } label: {
                    Text(title)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(selection == value ? Color.white : Color.primary)
                        .background(selection == value ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
