import SwiftUI

/// История: the dictations, the stored texts of Telegram voice messages or the clipboard (tabs as
/// in Статистика). Each tab is laid out the same: an "off" line when its part is off, search, the
/// list, and `HistoryFooter` (how many, the space, how long they are kept and where to change it).
struct HistoryPage: View {
    enum Kind: String { case dictations, voices, clipboard }
    @ObservedObject var navigation: SettingsWindow.Navigation
    @AppStorage("historyKind") private var kind = Kind.dictations

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Segments(items: [(Kind.dictations, "Диктовки"), (.voices, "Голосовые из Telegram"), (.clipboard, "Буфер обмена")],
                     selection: $kind)
                .padding([.horizontal, .top], 12)
            switch kind {
            case .dictations: DictationHistory(navigation: navigation)
            case .voices: VoiceHistory(navigation: navigation)
            case .clipboard: ClipboardHistory(navigation: navigation)
            }
        }
    }
}

/// The dictations, newest first, read from SQLite a page at a time as the list scrolls.
private struct DictationHistory: View {
    @ObservedObject var navigation: SettingsWindow.Navigation
    @AppStorage("dictationEnabled") private var dictation = false
    @AppStorage("dictationKeepDays") private var keepDays = 0
    @State private var search = ""
    @State private var items: [HistoryEntry] = []
    @State private var hasMore = true
    @State private var expanded: Int64?
    @State private var total = 0
    @State private var bytes: Int64 = 0

    private static let pageSize = 50

    var body: some View {
        VStack(spacing: 0) {
            if !dictation {
                OffLine(text: "Диктовка выключена: новые тексты сюда не попадают.") { navigation.page = .dictation }
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
                                count()
                            }
                            .onAppear { if item.id == items.last?.id { loadMore() } }
                            Divider()
                        }
                    }
                }
            }
            HistoryFooter(summary: "Диктовок: \(total) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))",
                          keep: DictationPage.daysTitle(keepDays)) { navigation.page = .dictation }
        }
        .onAppear(perform: reload)
        .onChange(of: search) { reload() }
    }

    private func reload() {
        items = History.shared.page(search: search, offset: 0, limit: Self.pageSize)
        hasMore = items.count == Self.pageSize
        count()
    }

    private func count() {
        total = History.shared.count()
        bytes = History.shared.bytes
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
                OffLine(text: "Голосовые из Telegram выключены: новые не расшифровываются.") { navigation.page = .dictation }
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
            HistoryFooter(summary: "Расшифровок: \(all.count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))",
                          keep: DictationPage.daysTitle(keepDays)) { navigation.page = .dictation }
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

/// The clipboard entries, newest first; the search as in the history window (also in the wrong
/// layout). A snapshot taken on opening and on each search: the page does not observe
/// `ClipboardStore.items`, which changes with every copy. Pasting, the preview and the formats are
/// in the history window (⇧⌘C); here a click unfolds a text, the buttons copy and delete.
private struct ClipboardHistory: View {
    @ObservedObject var navigation: SettingsWindow.Navigation
    @ObservedObject private var store = ClipboardStore.shared
    @State private var search = ""
    @State private var items: [ClipboardItem] = []
    @State private var expanded: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if !store.enabled {
                OffLine(text: "История буфера выключена: скопированное не сохраняется.") { navigation.page = .clipboard }
            }
            TextField("Поиск по буферу", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.title).foregroundStyle(.secondary)
                    Text(search.isEmpty ? "Здесь появится скопированное" : "Ничего не найдено")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            HistoryRow(meta: meta(item), expanded: expanded == item.id) {
                                expanded = expanded == item.id ? nil : item.id
                            } copy: {
                                store.use(item, paste: false, plain: false)
                            } delete: {
                                store.delete(item)
                                items.removeAll { $0.id == item.id }
                            } content: { expanded in
                                content(item, expanded: expanded)
                            }
                            Divider()
                        }
                    }
                }
            }
            ClipboardFooter(usage: store.usage, limitMB: store.limitMB) { navigation.page = .clipboard }
        }
        .onAppear(perform: reload)
        .onChange(of: search) { reload() }
    }

    @ViewBuilder private func content(_ item: ClipboardItem, expanded: Bool) -> some View {
        switch item.kind {
        case .image:
            if let thumbnail = store.thumbnail(item) {
                Image(nsImage: thumbnail)
                    .resizable().scaledToFit()
                    .frame(maxHeight: expanded ? 240 : 60, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Text(item.title)
            }
        case .files:
            Label(item.title, systemImage: "doc").lineLimit(expanded ? nil : 2)
        case .text:
            // The beginning is enough for two lines (a long text laid out whole is slow).
            let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            Text(expanded ? text : String(text.prefix(400)))
                .lineLimit(expanded ? nil : 2)
                .textSelection(.enabled)
        }
    }

    private func reload() {
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            items = store.items
        } else {
            let alternative = ClipboardRules.retyped(query, renderer: Observer.shared.layouts)
            items = store.items.filter { ClipboardRules.matches($0, query: query, alternative: alternative) }
        }
    }

    private func meta(_ item: ClipboardItem) -> String {
        let date = item.date.formatted(.relative(presentation: .named))
        guard let app = store.appName(item.app) else { return date }
        return "\(date) · \(app)"
    }
}

/// The clipboard's footer: observes only the usage (count and bytes), not the entries.
private struct ClipboardFooter: View {
    @ObservedObject var usage: ClipboardUsage
    let limitMB: Int
    let change: () -> Void

    var body: some View {
        HistoryFooter(summary: "Записей: \(usage.value.count) · \(ByteCountFormatter.string(fromByteCount: Int64(usage.value.bytes), countStyle: .file))",
                      keep: String(localized: "до \(limitMB) МБ"), change: change)
    }
}

/// The line above the search while a tab's part is off.
private struct OffLine: View {
    let text: LocalizedStringKey
    let enable: () -> Void

    var body: some View {
        HStack {
            Text(text).foregroundStyle(.secondary)
            Spacer()
            Button("Включить…", action: enable)
        }
        .font(.callout)
        .padding([.horizontal, .top], 12)
    }
}

/// Under every tab's list: how many and the space on the left, how long they are kept on the right
/// with a link to where that is set.
private struct HistoryFooter: View {
    let summary: String
    let keep: String
    let change: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Text("Хранить: \(keep)").foregroundStyle(.secondary)
                Button("Изменить…", action: change)
                    .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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
        HistoryRow(meta: meta, expanded: expanded, toggle: toggle, copy: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }, delete: delete) { expanded in
            Text(text)
                .lineLimit(expanded ? nil : 2)
                .textSelection(.enabled)
        }
    }
}

/// One row of any tab: the content (folded to two lines, all of it on click), the date line under
/// it on one line (a long group name is cut, not wrapped), copy and delete beside it.
private struct HistoryRow<Content: View>: View {
    let meta: String
    let expanded: Bool
    let toggle: () -> Void
    let copy: () -> Void
    let delete: () -> Void
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                content(expanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
}
