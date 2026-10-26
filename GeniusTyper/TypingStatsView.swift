import AppKit
import SwiftUI

/// Статистика → Печать: numbers from the journal, the last fixes (from memory) and the journal
/// itself (it is for analysing the detector).
struct TypingStatsView: View {
    @ObservedObject private var observer = Observer.shared
    @ObservedObject private var typing = Observer.shared.typing
    @State private var confirmDelete = false
    @AppStorage("statsShowWeek") private var showWeek = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Segments(items: [(false, "Сегодня"), (true, "7 дней")], selection: $showWeek)
            }
            JournalNumbers(stats: showWeek ? typing.weekStats : typing.stats)

            if !typing.recentFixes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Последние исправления (только здесь, не сохраняются)")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(typing.recentFixes, id: \.self) { Text($0).font(.callout.monospaced()) }
                }
            }

            Divider()

            HStack {
                Button("Открыть журнал") { NSWorkspace.shared.open(Journal.base) }
                Button("Удалить журнал…") { confirmDelete = true }
            }
            Text("В журнал пишутся только раскладки, длины слов и действия, без текста.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Записывать слова исправлений", isOn: $observer.wordLog)
                Spacer()
                Button("Удалить слова") { observer.deleteWordLog() }
                    .controlSize(.small)
            }
            Text("Только исправленные слова (автоматически, Caps Lock, вручную) и ложные срабатывания, в папку words, \(Journal.wordsDays) дней. Обычный набор не пишется, в терминалах и редакторах кода — тоже.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(LightSwitchStyle())
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Удалить весь журнал (и слова)?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { observer.deleteJournal() }
            Button("Отмена", role: .cancel) {}
        }
    }
}

private struct JournalNumbers: View {
    let stats: DayStats

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Слов", "\(stats.words)" + languages)
            row("Исправлено автоматически", "\(stats.autoFixes)" + (stats.autoUndos > 0 ? " (отменено: \(stats.autoUndos))" : ""))
            row("Поставлено ё", "\(stats.yoFixes)" + (stats.yoUndos > 0 ? " (отменено: \(stats.yoUndos))" : ""))
            row("Не дал исправить (⇧ + пробел)", "\(stats.autoSkips)")
            row("Исправил раскладку вручную", "\(stats.wrongLayoutFixes)" + (stats.lateFixes > 0 ? " (после пробела: \(stats.lateFixes))" : ""))
            row("Исправил Caps Lock посреди слова", "\(stats.capsFixes)")
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
