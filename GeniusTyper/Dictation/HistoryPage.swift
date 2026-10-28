import SwiftUI

/// История: the dictations or the stored texts of Telegram voice messages (tabs as in Статистика).
struct HistoryPage: View {
    enum Kind: String { case dictations, voices }
    @ObservedObject var navigation: SettingsWindow.Navigation
    @AppStorage("historyKind") private var kind = Kind.dictations

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Segments(items: [(Kind.dictations, "Диктовки"), (.voices, "Голосовые из Telegram")], selection: $kind)
                .padding([.horizontal, .top], 12)
            switch kind {
            case .dictations: DictationHistory(navigation: navigation)
            case .voices: VoiceHistory(navigation: navigation)
            }
        }
    }
}

/// The dictations, newest first, read from SQLite a page at a time as the list scrolls.
private struct DictationHistory: View {
    @ObservedObject var navigation: SettingsWindow.Navigation
    @AppStorage("dictationEnabled") private var dictation = false
    @State private var search = ""
    @State private var items: [HistoryEntry] = []
    @State private var hasMore = true
    @State private var expanded: Int64?

    private static let pageSize = 50

    var body: some View {
        VStack(spacing: 0) {
            if !dictation {
                HStack {
                    Text("Диктовка выключена: новые тексты сюда не попадают.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Включить…") { navigation.page = .dictation }
                }
                .font(.callout)
                .padding([.horizontal, .top], 12)
            }
            TextField("Поиск по истории", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.title).foregroundStyle(.secondary)
                    Text(search.isEmpty ? "Здесь появятся надиктованные тексты" : "Ничего не найдено")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            TextRow(text: item.text, meta: meta(item), expanded: expanded == item.id) {
                                expanded = expanded == item.id ? nil : item.id
                            } delete: {
                                History.shared.delete(id: item.id)
                                items.removeAll { $0.id == item.id }
                            }
                            .onAppear { if item.id == items.last?.id { loadMore() } }
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: search) { reload() }
    }

    private func reload() {
        items = History.shared.page(search: search, offset: 0, limit: Self.pageSize)
        hasMore = items.count == Self.pageSize
    }

    private func loadMore() {
        guard hasMore else { return }
        let next = History.shared.page(search: search, offset: items.count, limit: Self.pageSize)
        items += next
        hasMore = next.count == Self.pageSize
    }

    private func meta(_ item: HistoryEntry) -> String {
        let date = item.date.formatted(.relative(presentation: .named))
        var parts = [date]
        if !item.appName.isEmpty { parts.append(item.appName) }
        parts.append(String(localized: "\(item.words) сл."))
        parts.append(item.model)
        return parts.joined(separator: " · ")
    }
}

/// The stored texts of Telegram voice messages, newest first; the search as in the panel (every
/// word, е finds ё, the wrong layout too). Under the list: how many and the space they take.
private struct VoiceHistory: View {
    @ObservedObject var navigation: SettingsWindow.Navigation
    @AppStorage("dictationEnabled") private var dictation = false
    @AppStorage("voicesEnabled") private var voices = true
    @AppStorage("voicesKeepDays") private var keepDays = 7
    @State private var search = ""
    @State private var all: [VoiceText] = []
    @State private var bytes: Int64 = 0
    @State private var expanded: String?

    var body: some View {
        VStack(spacing: 0) {
            if !dictation || !voices {
                HStack {
                    Text("Голосовые из Telegram выключены: новые не расшифровываются.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Включить…") { navigation.page = .dictation }
                }
                .font(.callout)
                .padding([.horizontal, .top], 12)
            }
            TextField("Поиск по голосовым", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            let items = shown
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.title).foregroundStyle(.secondary)
                    Text(query.isEmpty ? "Здесь появятся расшифровки голосовых из Telegram" : "Ничего не найдено")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.path) { item in
                            TextRow(text: item.text, meta: meta(item), expanded: expanded == item.path) {
                                expanded = expanded == item.path ? nil : item.path
                            } delete: {
                                VoiceTranscripts.shared.delete(item)
                                reload()
                            }
                            Divider()
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Расшифровок: \(all.count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Хранить: \(DictationPage.daysTitle(keepDays))")
                    .foregroundStyle(.secondary)
                Button("Изменить…") { navigation.page = .dictation }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear(perform: reload)
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var shown: [VoiceText] {
        guard !query.isEmpty else { return all }
        let alternative = ClipboardRules.retyped(query, renderer: Observer.shared.layouts)
        return all.filter { ClipboardRules.matches(($0.sender.map { "\($0.title) " } ?? "") + $0.text,query: query, alternative: alternative) }
    }

    private func reload() {
        all = VoiceTranscripts.shared.storedTexts()
        bytes = VoiceTranscripts.storedBytes
    }

    private func meta(_ item: VoiceText) -> String {
        var parts = [item.date.formatted(.relative(presentation: .named))]
        if let sender = item.sender { parts.insert(sender.title, at: 0) }
        // Texts stored before 0.13.0 have no duration.
        let seconds = Int(item.duration.rounded())
        if seconds > 0 { parts.append("\(seconds / 60):\(String(format: "%02d", seconds % 60))") }
        return parts.joined(separator: " · ")
    }
}

/// One text in the history (a dictation or a voice message): two lines, all of it on click; copy
/// and delete beside it, as in the left-click panel.
private struct TextRow: View {
    let text: String
    let meta: String
    let expanded: Bool
    let toggle: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: copy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Скопировать")
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Удалить")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button("Скопировать", action: copy)
            Button("Удалить", role: .destructive, action: delete)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
