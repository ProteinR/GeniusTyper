import SwiftUI

/// Диктовка → Распознавание: "На этом Mac" (Parakeet Ultra: download, delete, unload) or "Через
/// интернет" (a provider, its key and one of the models its list names). Choosing a provider opens
/// nothing; the key field opens by a button and closes with "Отмена" or after saving (asked
/// 2026-11-19: "Готово" was the only way out and saved whatever was typed).
struct RecognitionPage: View {
    @ObservedObject private var store = EngineStore.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Segments(items: [(false, "На этом Mac"), (true, "Через интернет")],
                             selection: Binding(get: { store.usesCloud }, set: { store.usesCloud = $0 }))
                    Spacer()
                }
            }
            if store.usesCloud {
                CloudSection(id: store.cloudProvider)
                    .id(store.cloudProvider)
            } else {
                LocalSection()
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refreshLocal() }
    }
}

private struct LocalSection: View {
    @ObservedObject private var store = EngineStore.shared
    @State private var confirmDelete = false
    @State private var confirmDeleteV3 = false

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 10) {
                SettingsTile(symbol: "bolt.fill", tint: .indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parakeet Ultra")
                    Text("Moondream на основе NVIDIA v3 · ~630 МБ · Neural Engine · 25 языков, язык определяет сама")
                        .font(.caption).foregroundStyle(.secondary)
                    if case .failed(let message) = store.local {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                switch store.local {
                case .missing:
                    Button("Скачать") { store.downloadLocal(.parakeetUltra) }
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 80)
                    Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                case .failed:
                    Button(ParakeetEngine.isDownloaded(.parakeetUltra) ? "Удалить" : "Повторить") {
                        ParakeetEngine.isDownloaded(.parakeetUltra) ? (confirmDelete = true) : store.downloadLocal(.parakeetUltra)
                    }
                case .onDisk, .loading, .loaded:
                    Text("Скачана").foregroundStyle(.secondary)
                    Button("Удалить") { confirmDelete = true }
                }
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
                Text("Выгружать из памяти")
                Text(memoryNote).font(.caption).foregroundStyle(.secondary)
            }
            if store.hasLegacyV3 {
                LabeledContent {
                    Button("Удалить") { confirmDeleteV3 = true }
                } label: {
                    Text("Старая модель Parakeet v3")
                    Text("~470 МБ на диске. Больше не используется: Ultra точнее при той же скорости")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Звук не покидает Mac.").font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Удалить Parakeet Ultra с диска?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { store.deleteLocal(.parakeetUltra) }
        } message: {
            Text("Её можно будет скачать снова. Без неё диктовка работает только через интернет.")
        }
        .confirmationDialog("Удалить Parakeet v3 с диска?", isPresented: $confirmDeleteV3) {
            Button("Удалить", role: .destructive) { store.deleteLegacyV3() }
        } message: {
            Text("Освободится ~470 МБ.")
        }
    }

    private var memoryNote: String {
        switch store.local {
        case .loaded: return String(localized: "Сейчас в памяти (отдельный процесс GeniusTyperEngine)")
        case .loading: return String(localized: "Загружается…")
        default: return String(localized: "Сейчас не в памяти; загружается за доли секунды, пока вы говорите")
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

/// One provider: which one, its address ("Другой сервис"), its key and its model.
private struct CloudSection: View {
    let id: EngineID
    @ObservedObject private var store = EngineStore.shared
    @State private var editing = false
    @State private var draft = ""
    @State private var address = ""
    @State private var hasKey = false
    @State private var keyTail = ""
    @State private var manualModel = ""

    var body: some View {
        Section {
            LabeledContent {
                Menu {
                    ForEach(EngineID.cloud) { provider in
                        Button {
                            store.chooseProvider(provider)
                        } label: {
                            Text(provider.title)
                            Text(provider.note)
                        }
                    }
                    Divider()
                    Button {} label: {
                        Text("Anthropic")
                        Text("В API Claude нет распознавания речи")
                    }
                    .disabled(true)
                } label: {
                    Text(id.title)
                }
                .fixedSize()
            } label: {
                Text("Провайдер")
                Text(id.note).font(.caption).foregroundStyle(.secondary)
            }
            if id == .custom {
                LabeledContent {
                    TextField("", text: $address, prompt: Text("https://example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit(saveAddress)
                } label: {
                    Text("Адрес")
                    Text("Сервис с /audio/transcriptions, как у OpenAI").font(.caption).foregroundStyle(.secondary)
                }
            }
            keyRow
            if editing {
                VStack(alignment: .trailing, spacing: 8) {
                    SecureField("", text: $draft, prompt: Text("Вставьте ключ \(id.title)"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                        .onExitCommand { cancel() }
                    HStack {
                        Button("Отмена", action: cancel)
                        Button("Сохранить и проверить", action: saveKey)
                            .keyboardShortcut(.defaultAction)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            modelRow
        } footer: {
            Text("Звук отправляется провайдеру, ключ хранится в связке ключей macOS. Если сервис не ответит или ключа нет, диктовка распознаётся на этом Mac (Parakeet Ultra), когда модель скачана.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            address = store.baseURL(for: id)
            readKey()
            if (hasKey || id == .custom) && store.models[id] == nil && !(id == .custom && address.isEmpty) { store.loadModels(id) }
        }
        .onDisappear { if id == .custom { saveAddress() } }
    }

    private var keyRow: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if !editing {
                    Button(hasKey ? "Заменить" : "Добавить ключ") {
                        draft = ""
                        editing = true
                    }
                    if hasKey {
                        Button("Удалить") {
                            store.setKey("", for: id)
                            readKey()
                        }
                    }
                }
            }
        } label: {
            Text(id == .custom ? "Ключ API (если нужен)" : "Ключ API")
            if hasKey {
                Text("Сохранён · …\(keyTail)").font(.caption).foregroundStyle(.secondary)
            } else if let page = id.keyPage {
                HStack(spacing: 4) {
                    Text("Нет ключа ·").foregroundStyle(.secondary)
                    Link("получить", destination: page)
                }
                .font(.caption)
            } else {
                Text("Нет ключа").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        let list = store.models[id] ?? []
        LabeledContent {
            HStack(spacing: 6) {
                if store.loadingModels == id {
                    ProgressView().controlSize(.small)
                } else if !list.isEmpty {
                    Menu {
                        ForEach(list, id: \.self) { model in
                            Button(model == id.defaultModel ? "\(model) — рекомендуется" : model) { store.setModel(model, for: id) }
                        }
                        Divider()
                        Button("Обновить список") { store.loadModels(id) }
                    } label: {
                        Text(store.model(for: id))
                    }
                    .fixedSize()
                } else if id == .custom {
                    // A service may have no model list: the name is typed.
                    TextField("", text: $manualModel, prompt: Text("Название модели"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .onSubmit { store.setModel(manualModel, for: id) }
                }
                if list.isEmpty, store.modelsError[id] != nil, store.loadingModels != id {
                    Button("Повторить") { store.loadModels(id) }
                }
            }
        } label: {
            Text("Модель")
            if let error = store.modelsError[id] {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if store.loadingModels == id {
                Text("Загружаю список моделей…").font(.caption).foregroundStyle(.secondary)
            } else if list.isEmpty {
                Text(id == .custom ? "Список моделей сервиса или название вручную" : "Список появится, когда ключ сохранён")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Из списка \(id.title): только модели для распознавания речи").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { manualModel = store.model(for: id) }
    }

    private func readKey() {
        let key = Keychain.key(for: id)
        hasKey = !key.isEmpty
        keyTail = String(key.suffix(4))
    }

    private func cancel() {
        draft = ""
        editing = false
    }

    private func saveKey() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        store.setKey(key, for: id)
        draft = ""
        editing = false
        readKey()
        if id == .custom { saveAddress() }
        store.loadModels(id)
    }

    private func saveAddress() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != store.baseURL(for: .custom) else { return }
        store.setBaseURL(value, for: .custom)
        if !value.isEmpty { store.loadModels(.custom) }
    }
}
