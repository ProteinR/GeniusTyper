import SwiftUI

/// The model on the Диктовка page: a local one (download, unload) or one by API.
struct ModelSections: View {
    @ObservedObject private var store = EngineStore.shared

    var body: some View {
        Section("Модель на этом Mac") {
            ForEach(EngineID.local) { model in
                LocalModelRow(model: model)
            }
            LabeledContent {
                Menu {
                    ForEach([1, 5, 15, 60, 0], id: \.self) { minutes in
                        Button(Self.unloadTitle(minutes)) { store.unloadAfterMinutes = minutes }
                    }
                } label: {
                    Text(Self.unloadTitle(store.unloadAfterMinutes))
                }
                .fixedSize()
            } label: {
                Text("Выгружать модель из памяти")
                Text(memoryNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { store.refreshLocal() }
        Section {
            ForEach([EngineID.groq, .openAI, .custom]) { id in
                CloudRow(id: id)
            }
        } header: {
            Text("Или через интернет, по API")
        } footer: {
            Text("Звук отправляется в сервис. Ключи хранятся в связке ключей macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var memoryNote: String {
        switch store.local {
        case .loaded: return String(localized: "Сейчас в памяти (отдельный процесс GeniusTyperEngine)")
        case .loading: return String(localized: "Загружается…")
        default: return String(localized: "Сейчас не в памяти; загружается при начале диктовки")
        }
    }

    static func unloadTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: return String(localized: "никогда")
        case 60: return String(localized: "через час")
        default: return String(localized: "через \(minutes) мин")
        }
    }
}

private struct SelectMark: View {
    let selected: Bool
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .font(.system(size: 15))
    }
}

private struct LocalModelRow: View {
    let model: EngineID
    @ObservedObject private var store = EngineStore.shared
    @State private var confirmDelete = false

    private var vendor: String { model == .parakeetUltra ? "Moondream, дообученная v3" : "NVIDIA" }
    private var note: String {
        model == .parakeetUltra
            ? String(localized: "~630 МБ на диске · Neural Engine · точнее v3, особенно английский с акцентом")
            : String(localized: "~470 МБ на диске · Neural Engine")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { choose() } label: { SelectMark(selected: store.selected == model) }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.title)
                    Text(vendor).font(.caption).foregroundStyle(.secondary)
                }
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = store.local(model) {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch store.local(model) {
            case .missing:
                Button("Скачать") { store.downloadLocal(model) }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 80)
                Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
            case .failed:
                Button(ParakeetEngine.isDownloaded(model) ? "Удалить" : "Повторить") {
                    ParakeetEngine.isDownloaded(model) ? (confirmDelete = true) : store.downloadLocal(model)
                }
            case .onDisk, .loading, .loaded:
                Text("Скачана").foregroundStyle(.secondary)
                Button("Удалить") { confirmDelete = true }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { choose() }
        .confirmationDialog("Удалить модель с диска?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { store.deleteLocal(model) }
        } message: {
            Text("Её можно будет скачать снова.")
        }
    }

    /// Choosing a model not on disk yet starts its download.
    private func choose() {
        store.selected = model
        if store.local(model) == .missing { store.downloadLocal(model) }
    }
}

/// A cloud engine: choose it, enter its key; the model (and the address for "Другой сервис").
private struct CloudRow: View {
    let id: EngineID
    @ObservedObject private var store = EngineStore.shared
    @State private var expanded = false
    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var hasKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { choose() } label: { SelectMark(selected: store.selected == id) }
                    .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(id == .custom ? id.title : "\(id.title) · \(store.model(for: id))")
                    Text(hasKey ? "Ключ сохранён" : "Нет ключа").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(expanded ? "Готово" : (hasKey ? "Изменить" : "Добавить ключ")) {
                    if expanded { save() }
                    expanded.toggle()
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Ключ API", text: $key)
                    TextField("Модель", text: $model)
                    if id == .custom {
                        TextField("Адрес, например https://example.com/v1", text: $baseURL)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.leading, 25)
            }
        }
        .onAppear {
            key = Keychain.key(for: id)
            hasKey = !key.isEmpty
            model = store.model(for: id)
            baseURL = store.baseURL(for: id)
        }
    }

    private func choose() {
        guard hasKey else {
            expanded = true
            return
        }
        store.selected = id
    }

    private func save() {
        Keychain.setKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: id)
        hasKey = !key.isEmpty
        if !model.isEmpty { store.setModel(model, for: id) }
        if id == .custom { store.setBaseURL(baseURL, for: id) }
        if !hasKey, store.selected == id { store.selected = .parakeetUltra }
    }
}
