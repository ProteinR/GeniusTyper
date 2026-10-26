import SwiftUI

/// The history, newest first, read from SQLite a page at a time as the list scrolls.
struct HistoryPage: View {
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
                            HistoryRow(item: item, expanded: expanded == item.id) {
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
}

private struct HistoryRow: View {
    let item: HistoryEntry
    let expanded: Bool
    let toggle: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
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

    private var meta: String {
        let date = item.date.formatted(.relative(presentation: .named))
        var parts = [date]
        if !item.appName.isEmpty { parts.append(item.appName) }
        parts.append(String(localized: "\(item.words) сл."))
        parts.append(item.model)
        return parts.joined(separator: " · ")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }
}
