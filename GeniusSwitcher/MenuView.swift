import SwiftUI

/// The menu bar dropdown: what is used daily. Statistics and the journal live in their own window,
/// lists of words and apps in the "Исключения" window.
struct MenuView: View {
    @EnvironmentObject private var observer: Observer

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
