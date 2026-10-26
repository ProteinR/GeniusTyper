import SwiftUI

struct ModelPage: View {
    @ObservedObject private var store = EngineStore.shared

    var body: some View {
        Form {
            Section("На этом Mac") {
                LocalModelRow()
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
            Section {
                ForEach([EngineID.groq, .openAI, .custom]) { id in
                    CloudRow(id: id)
                }
            } header: {
                Text("По API")
            } footer: {
                Text("Звук отправляется в сервис. Ключи хранятся в связке ключей macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refreshLocal() }
    }

    private var memoryNote: String {
        switch store.local {
        case .loaded: return String(localized: "Сейчас в памяти (отдельный процесс DiktantEngine)")
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
    @ObservedObject private var store = EngineStore.shared
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { store.selected = .parakeetV3 } label: { SelectMark(selected: store.selected == .parakeetV3) }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(EngineID.parakeetV3.title)
                    Text("NVIDIA").font(.caption).foregroundStyle(.secondary)
                }
                Text("Русский и английский, язык определяется сам · ~470 МБ на диске · Neural Engine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = store.local {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch store.local {
            case .missing:
                Button("Скачать") { store.downloadLocal() }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 80)
                Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
            case .failed:
                Button(ParakeetEngine.isDownloaded ? "Удалить" : "Повторить") {
                    ParakeetEngine.isDownloaded ? (confirmDelete = true) : store.downloadLocal()
                }
            case .onDisk, .loading, .loaded:
                Text("Скачана").foregroundStyle(.secondary)
                Button("Удалить") { confirmDelete = true }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selected = .parakeetV3 }
        .confirmationDialog("Удалить модель с диска?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { store.deleteLocal() }
        } message: {
            Text("Её можно будет скачать снова.")
        }
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
        if !hasKey, store.selected == id { store.selected = .parakeetV3 }
    }
}
