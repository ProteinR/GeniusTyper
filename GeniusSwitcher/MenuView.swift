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
            if observer.autoFix && !observer.canPost {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Нужен «Универсальный доступ», чтобы исправлять текст", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Открыть настройки…") { observer.requestPostPermission() }
                }
            }

            Toggle("Автоисправление раскладки", isOn: $observer.autoFix)
            if observer.autoFix, let app = observer.lastApp {
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

/// "История буфера обмена (⇧⌘C)" and its size limit.
private struct ClipboardSettings: View {
    @ObservedObject var clipboard: ClipboardStore
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("История буфера обмена (⇧⌘C)", isOn: $clipboard.enabled)
            if clipboard.enabled {
                HStack(spacing: 6) {
                    Picker("Хранить до", selection: $clipboard.limitMB) {
                        ForEach(ClipboardStore.limits, id: \.self) { Text("\($0) МБ").tag($0) }
                    }
                    .fixedSize()
                    Text("занято \(ByteCountFormatter.string(fromByteCount: Int64(clipboard.totalBytes), countStyle: .file)), \(clipboard.items.count) зап.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Очистить…") { confirmClear = true }
                        .controlSize(.small)
                        .disabled(clipboard.items.isEmpty)
                }
                .padding(.leading, 20)
                if clipboard.hotKeyTaken {
                    Label("⇧⌘C занято другим приложением (Maccy?): закройте его и выключите-включите историю",
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
