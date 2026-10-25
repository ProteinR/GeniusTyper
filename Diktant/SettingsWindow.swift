import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, model, history, statistics
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "Основное"
        case .model: return "Модель"
        case .history: return "История"
        case .statistics: return "Статистика"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .model: return "cpu"
        case .history: return "clock.arrow.circlepath"
        case .statistics: return "chart.bar"
        }
    }
}

/// The settings window: four pages in a sidebar. Made on open and dropped on close, so it costs no
/// memory while hidden (lessons from MXCtl: no `TabView`, no system switches, `sizingOptions` off).
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
            window.title = String(localized: "Diktant — настройки")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = NSSize(width: 600, height: 420)
            if !window.setFrameUsingName(Self.frameName) {
                window.setContentSize(NSSize(width: 700, height: 520))
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

    private static let frameName = "DiktantSettings"

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
                            Image(systemName: page.symbol).frame(width: 20)
                            Text(page.title)
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
                Text("Diktant \(AppDelegate.appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            .padding(10)
            .frame(width: 170)
            .background(Color.primary.opacity(0.04))
            Divider()
            Group {
                switch navigation.page {
                case .general: GeneralPage()
                case .model: ModelPage()
                case .history: HistoryPage()
                case .statistics: StatisticsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
