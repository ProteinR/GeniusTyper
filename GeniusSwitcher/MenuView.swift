import SwiftUI

/// The menu bar dropdown: today's numbers, Caps Lock switching and privacy controls.
struct MenuView: View {
    @EnvironmentObject private var observer: Observer
    @State private var confirmDelete = false
    @AppStorage("statsShowWeek") private var showWeek = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Genius Switcher").font(.headline)
                Text(AppDelegate.appVersion)
                    .font(.caption).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
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
                Divider()
            }

            Toggle("Caps Lock переключает раскладку", isOn: $observer.capsLockSwitching)
            Text("⇧ + Caps Lock — обычный Caps Lock.").font(.caption).foregroundStyle(.secondary)

            Toggle("Автопереключение раскладки", isOn: $observer.autoFix)
            if observer.autoFix {
                if !observer.canPost {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Нужен «Универсальный доступ», чтобы исправлять текст", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Открыть настройки…") { observer.requestPostPermission() }
                    }
                }
                Text("Слово в неверной раскладке исправляется после пробела. Caps Lock сразу после этого — отменить и больше не трогать это слово.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let app = observer.lastApp {
                    Toggle("Исправлять в «\(app.name)»", isOn: Binding(
                        get: { !observer.autoOffApps.contains(app.id) },
                        set: { observer.setAutoOff(app.id, !$0) }))
                }
                if observer.exceptionCount > 0 {
                    HStack {
                        Text("Исключений: \(observer.exceptionCount)").font(.caption).foregroundStyle(.secondary)
                        Button("Сбросить") { observer.clearExceptions() }.font(.caption)
                    }
                }
            }

            Divider()

            HStack {
                Picker("", selection: $showWeek) {
                    Text("Сегодня").tag(false)
                    Text("7 дней").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Spacer()
                if observer.paused { Text("пауза").font(.caption).foregroundStyle(.orange) }
            }
            StatsView(stats: showWeek ? observer.weekStats : observer.stats)

            if !observer.recentFixes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Последние исправления (только здесь, не сохраняются)")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(observer.recentFixes, id: \.self) { Text($0).font(.callout.monospaced()) }
                }
            }

            Divider()

            Toggle("Пауза наблюдения", isOn: $observer.paused)
            if let app = observer.lastApp {
                Toggle("Не следить в «\(app.name)»", isOn: Binding(
                    get: { observer.excludedApps.contains(app.id) },
                    set: { observer.setExcluded(app.id, $0) }))
            }
            LoginItemToggle()

            HStack {
                Button("Журнал") { NSWorkspace.shared.open(Journal.directory) }
                Button("Удалить журнал…") { confirmDelete = true }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
            Text("В журнал пишутся только раскладки, длины слов и действия, без текста.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 330)
        .alert("Удалить весь журнал?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { observer.deleteJournal() }
            Button("Отмена", role: .cancel) {}
        }
    }
}

private struct StatsView: View {
    let stats: DayStats

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Слов", "\(stats.words)" + languages)
            row("Исправлено автоматически", "\(stats.autoFixes)" + (stats.autoUndos > 0 ? " (отменено: \(stats.autoUndos))" : ""))
            row("Исправил раскладку вручную", "\(stats.wrongLayoutFixes)" + (stats.lateFixes > 0 ? " (после пробела: \(stats.lateFixes))" : ""))
            row("Исправил опечаток", "\(stats.typoFixes)")
            row("Переключений раскладки", "\(stats.switches)" + (stats.switches > 0 ? " (Caps Lock: \(stats.capsSwitches), посреди слова: \(stats.midWordSwitches))" : ""))
            row("Детектор поймал бы", "\(stats.detectorCaught) из \(stats.wrongLayoutFixes)")
            row("Детектор сработал бы зря", "\(stats.detectorExtra)")
        }
        .font(.callout)
    }

    private var languages: String {
        let parts = stats.wordsByLanguage.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
