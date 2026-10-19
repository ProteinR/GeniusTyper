import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Исключения" window: words never fixed, apps where auto-fix is off or nothing is watched.
/// Its own window, not a sheet: the panel is a transient popover and closes as soon as focus moves.
@MainActor
enum ExceptionsEditor {
    enum Tab { case words, apps }
    private static var window: NSWindow?

    static func show(_ tab: Tab = .words) {
        let window = window ?? make()
        Self.window = window
        window.contentViewController = NSHostingController(rootView: ExceptionsView(tab: tab).environmentObject(Observer.shared))
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Исключения"
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct ExceptionsView: View {
    @State var tab: ExceptionsEditor.Tab

    var body: some View {
        TabView(selection: $tab) {
            WordsTab().tabItem { Text("Слова") }.tag(ExceptionsEditor.Tab.words)
            AppsTab().tabItem { Text("Приложения") }.tag(ExceptionsEditor.Tab.apps)
        }
        .padding(12)
        .frame(minWidth: 380, minHeight: 420)
    }
}

private struct WordsTab: View {
    @EnvironmentObject private var observer: Observer
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Эти слова никогда не исправляются автоматически. Пишите их так, как печатаете (git, rtl, ок). Регистр не важен.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Слово или несколько через запятую", text: $draft)
                    .focused($fieldFocused)
                    .onSubmit(add)
                Button("Добавить", action: add).disabled(UserExceptions(text: draft).words.isEmpty)
            }
            List {
                ForEach(observer.userExceptions.words, id: \.self) { word in
                    HStack {
                        Text(word).font(.body.monospaced())
                        Spacer()
                        Button { observer.removeUserException(word) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Удалить")
                    }
                }
            }
            .overlay {
                if observer.userExceptions.words.isEmpty {
                    Text("Пока пусто").foregroundStyle(.tertiary)
                }
            }
            if observer.exceptionCount > 0 {
                HStack {
                    Text("Ещё отменённые раньше исправления (без текста): \(observer.exceptionCount)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Сбросить") { observer.clearExceptions() }.font(.caption)
                }
            }
            Text("Хранится только в настройках Genius Switcher, в журнал не попадает.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .onAppear { fieldFocused = true }
    }

    private func add() {
        guard !UserExceptions(text: draft).words.isEmpty else { return }
        observer.addUserException(draft)
        draft = ""
    }
}

private struct AppsTab: View {
    @EnvironmentObject private var observer: Observer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppListSection(
                title: "Не исправлять в",
                note: "Раскладку не исправляет, журнал ведётся (терминалы и редакторы кода — по умолчанию).",
                apps: observer.autoOffApps,
                set: { observer.setAutoOff($0, $1) })
            AppListSection(
                title: "Не следить в",
                note: "Ни исправлений, ни журнала (менеджеры паролей — по умолчанию).",
                apps: observer.excludedApps,
                set: { observer.setExcluded($0, $1) })
        }
        .padding(8)
    }
}

/// A list of apps (bundle IDs) with "−" per row and an "Добавить" menu: the current app, running
/// apps, or any app chosen in Finder.
private struct AppListSection: View {
    @EnvironmentObject private var observer: Observer
    let title: String
    let note: String
    let apps: Set<String>
    let set: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                addMenu
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(apps.map { AppInfo(id: $0) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { app in
                    HStack {
                        Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                        Text(app.name)
                        Spacer()
                        Button { set(app.id, false) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Убрать")
                    }
                    .help(app.id)
                }
            }
            .frame(minHeight: 110)
        }
    }

    private var addMenu: some View {
        Menu("Добавить") {
            if let current = observer.lastApp, !apps.contains(current.id) {
                Button("Текущее: \(current.name)") { set(current.id, true) }
                Divider()
            }
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { AppInfo(id: $0, name: app.localizedName) } }
                .filter { !apps.contains($0.id) && $0.id != Bundle.main.bundleIdentifier }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !running.isEmpty {
                Section("Запущенные") {
                    ForEach(running) { app in Button(app.name) { set(app.id, true) } }
                }
                Divider()
            }
            Button("Выбрать в Finder…") { chooseInFinder() }
        }
        .fixedSize()
    }

    private func chooseInFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { set(id, true) }
        }
    }
}

private struct AppInfo: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    init(id: String, name: String? = nil) {
        self.id = id
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        self.name = name ?? url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
}
