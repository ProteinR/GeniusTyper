import SwiftUI

/// Words, dictations, speed and time saved; words per day; by app and by model. Totals come from
/// SQLite; the bars are plain shapes (no Swift Charts or Canvas: on macOS 26 they took ~100 MB of
/// graphics memory in MXCtl).
struct StatisticsPage: View {
    enum Period: String, CaseIterable, Identifiable {
        case week, month, all
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .week: return "Неделя"
            case .month: return "Месяц"
            case .all: return "Всё время"
            }
        }

        func since(_ now: Date) -> Date? {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            switch self {
            case .week: return calendar.date(byAdding: .day, value: -6, to: today)
            case .month: return calendar.date(byAdding: .day, value: -29, to: today)
            case .all: return nil
            }
        }
    }

    @AppStorage("statsPeriod") private var period: Period = .all
    @State private var stats = Stats()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(Period.allCases) { item in
                            Button { period = item } label: {
                                Text(item.title)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .foregroundStyle(period == item ? Color.white : Color.primary)
                                    .background(period == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 10) {
                    Metric(value: stats.words.formatted(), title: "слов")
                    Metric(value: stats.count.formatted(), title: "диктовок")
                    Metric(value: "\(stats.wordsPerMinute)", title: "слов в минуту")
                    Metric(value: Self.duration(stats.timeSaved), title: "сэкономлено")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Слова по дням").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text("дней с диктовкой: \(stats.daysActive)").font(.caption).foregroundStyle(.secondary)
                    }
                    DayBars(days: Array(stats.perDay.suffix(120)))
                        .frame(height: 90)
                }
                HStack(alignment: .top, spacing: 24) {
                    Breakdown(title: "По приложениям", rows: stats.byApp)
                    Breakdown(title: "По моделям", rows: stats.byModel)
                }
            }
            .padding(18)
        }
        .onAppear(perform: reload)
        .onChange(of: period) { reload() }
    }

    private func reload() {
        stats = History.shared.stats(since: period.since(Date()))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes) мин") }
        return String(localized: "\(minutes / 60) ч \(minutes % 60) мин")
    }
}

private struct Metric: View {
    let value: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DayBars: View {
    let days: [(day: String, words: Int)]
    @State private var hovered: Int?

    var body: some View {
        let top = max(1, days.map(\.words).max() ?? 1)
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: days.count > 60 ? 1 : 2) {
                ForEach(days.indices, id: \.self) { index in
                    let words = days[index].words
                    Rectangle()
                        .fill(hovered == index ? Color.accentColor.opacity(0.7) : Color.accentColor)
                        .frame(maxWidth: 28)
                        .frame(height: max(words > 0 ? 2 : 1, geometry.size.height * CGFloat(words) / CGFloat(top)))
                        .opacity(words > 0 ? 1 : 0.25)
                        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                        .help("\(days[index].day): \(words)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .overlay {
            if days.isEmpty { Text("Пока нет данных").foregroundStyle(.secondary) }
        }
    }
}

private struct Breakdown: View {
    let title: LocalizedStringKey
    let rows: [(name: String, words: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            let top = max(1, rows.first?.words ?? 1)
            ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.name).lineLimit(1)
                        Spacer()
                        Text(row.words.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: max(2, geometry.size.width * CGFloat(row.words) / CGFloat(top)))
                    }
                    .frame(height: 4)
                }
            }
            if rows.isEmpty { Text("Пока нет данных").foregroundStyle(.secondary).font(.callout) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
