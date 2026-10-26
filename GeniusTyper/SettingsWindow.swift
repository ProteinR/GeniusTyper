import AppKit
import SwiftUI

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
        case .general: return "gearshape"
        case .typing: return "keyboard"
        case .clipboard: return "doc.on.clipboard"
        case .dictation: return "mic"
        case .history: return "clock.arrow.circlepath"
        case .statistics: return "chart.bar"
        }
    }
}

/// The settings window: everything that is not used daily (the left-click panel has that). Pages
/// in a sidebar; the three parts of the app (Раскладка, Буфер обмена, Диктовка) each start with
/// their own switch, and the sidebar shows which are on. Made on open and dropped on close, so it
/// costs no memory while hidden (lessons from MXCtl: no `TabView`, no system switches,
/// `sizingOptions` off).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    final class Navigation: ObservableObject {
        @Published var page: SettingsPage = .general
    }

    private var window: NSWindow?
    private var navigation: Navigation?

    func show(page: SettingsPage? = nil) {
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
        // A menu bar app may be refused activation and the window opened behind other apps: force it.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
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
    @ObservedObject private var observer = Observer.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @AppStorage("dictationEnabled") private var dictation = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    Button {
                        navigation.page = page
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: page.symbol).frame(width: 20)
                            Text(page.title)
                            Spacer(minLength: 4)
                            if let on = isOn(page) {
                                Circle()
                                    .fill(on ? Color.green : Color.primary.opacity(0.2))
                                    .frame(width: 6, height: 6)
                                    .help(on ? "Включено" : "Выключено")
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .foregroundStyle(navigation.page == page ? Color.white : Color.primary)
                            .background(navigation.page == page ? Color.accentColor : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("Genius Typer \(AppDelegate.appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
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
                case .dictation: DictationPage()
                case .history: HistoryPage(navigation: navigation)
                case .statistics: StatisticsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The dot beside the three parts with their own switch.
    private func isOn(_ page: SettingsPage) -> Bool? {
        switch page {
        case .typing: return !observer.paused
        case .clipboard: return clipboard.enabled
        case .dictation: return dictation
        default: return nil
        }
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
