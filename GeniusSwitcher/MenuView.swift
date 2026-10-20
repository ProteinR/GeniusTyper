import SwiftUI

/// The menu bar dropdown: what is used daily. Statistics and the journal live in their own window,
/// lists of words and apps in the "Исключения" window.
struct MenuView: View {
    @EnvironmentObject private var observer: Observer
    @ObservedObject private var clipboard = ClipboardStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Genius Switcher").font(.headline)
                Text(AppDelegate.appVersion)
                    .font(.caption).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Spacer()
                if observer.paused { Text("пауза").font(.caption).foregroundStyle(.orange) }
            }
            if !observer.hasPermission {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Нет доступа к «Мониторингу ввода»", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Без него Genius Switcher не видит нажатий и Caps Lock не переключает раскладку.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Открыть настройки…") { observer.requestPermission() }
                }
            }
            if (observer.autoFix || observer.yoFix) && !observer.canPost {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Нужен «Универсальный доступ», чтобы исправлять текст", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Открыть настройки…") { observer.requestPostPermission() }
                }
            }

            Toggle("Автоисправление раскладки", isOn: $observer.autoFix)
            Toggle("Ставить ё (еще → ещё)", isOn: $observer.yoFix)
            if observer.autoFix || observer.yoFix, let app = observer.lastApp {
                Toggle("Исправлять в «\(app.name)»", isOn: Binding(
                    get: { !observer.autoOffApps.contains(app.id) },
                    set: { observer.setAutoOff(app.id, !$0) }))
            }
            Toggle("Caps Lock переключает раскладку", isOn: $observer.capsLockSwitching)
            ClipboardSettings(clipboard: clipboard)
            Toggle("Пауза", isOn: $observer.paused)
            MenuBarIconStylePicker()

            VStack(alignment: .leading, spacing: 2) {
                Text("**⇧ + пробел** — не исправлять слово")
                Text("**Caps Lock** после исправления — отменить, посреди слова — исправить набранное")
                Text("**⇧ + Caps Lock** — обычный Caps Lock")
                if clipboard.enabled { Text("**\(clipboard.hotKey.title)** — история буфера обмена") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button("Исключения…") { ExceptionsEditor.show() }
                Button("Статистика…") { StatsWindow.show() }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
            HStack(spacing: 16) {
                LoginItemToggle()
                MenuBarIconToggle()
            }
            .font(.caption)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// "История буфера обмена": the shortcut that opens it (changeable) and the size limit.
private struct ClipboardSettings: View {
    @ObservedObject var clipboard: ClipboardStore
    @State private var confirmClear = false

    /// Two apps can register the same global shortcut; the one registered last gets it.
    private var maccyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "org.p0deje.Maccy").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("История буфера обмена", isOn: $clipboard.enabled)
            if clipboard.enabled {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Открывать").foregroundStyle(.secondary)
                        HotKeyRecorder(clipboard: clipboard)
                    }
                    GridRow {
                        Text("Хранить до").foregroundStyle(.secondary)
                        Picker("", selection: $clipboard.limitMB) {
                            ForEach(ClipboardStore.limits, id: \.self) { Text("\($0) МБ").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        ClipboardUsageLine(usage: clipboard.usage) { confirmClear = true }
                    }
                }
                .padding(.leading, 20)
                if maccyRunning {
                    Label("Запущен Maccy: он тоже открывается по ⇧⌘C и перехватывает это сочетание. Закройте его или выберите другое",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                } else if clipboard.hotKeyTaken {
                    Label("\(clipboard.hotKey.title) занято другим приложением: выберите другое сочетание",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
        }
        .alert("Очистить историю буфера?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { clipboard.clear() }
            Button("Отмена", role: .cancel) {}
        }
    }
}

/// The shortcut as a button: click, then press the new combination (Esc cancels).
private struct HotKeyRecorder: View {
    @ObservedObject var clipboard: ClipboardStore
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Нажмите сочетание…" : clipboard.hotKey.title) {
            recording ? stop() : start()
        }
        .help("Нажмите и введите новое сочетание: нужна ⌘, ⌥ или ⌃. Esc — отмена")
        .onDisappear { if recording { stop() } }
        // The panel closed (Esc, a click elsewhere) while recording: the old shortcut comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if recording { stop() }
        }
    }

    private func start() {
        recording = true
        HotKey.unregister()  // pressing the current one now must not open the window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let combo = KeyCombo(keyCode: event.keyCode,
                                 modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
            MainActor.assumeIsolated { record(combo) }
            return nil
        }
    }

    private func record(_ combo: KeyCombo) {
        if combo.keyCode == 53 && combo.flags.isEmpty {  // Esc
            stop()
        } else if combo.isUsable {
            clipboard.hotKey = combo
            stop()
        } else {
            NSSound.beep()
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        clipboard.registerHotKey()
    }
}

/// "занято 1,5 МБ, 70 зап. Очистить…": the only part of the panel that changes with every copy.
private struct ClipboardUsageLine: View {
    @ObservedObject var usage: ClipboardUsage
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("занято \(ByteCountFormatter.string(fromByteCount: Int64(usage.value.bytes), countStyle: .file)), \(usage.value.count) зап.")
                .foregroundStyle(.secondary)
            Button("Очистить…", action: clear)
                .buttonStyle(.link)
                .disabled(usage.value.count == 0)
        }
        .font(.caption)
        .fixedSize()
    }
}
