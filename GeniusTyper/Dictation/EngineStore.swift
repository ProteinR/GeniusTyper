import Foundation

/// Which engine dictation uses, the local model's state (downloaded, in memory) and the cloud
/// engines' settings (address, key, the list of models and the one chosen). A cloud engine without a
/// key, or one that fails, falls back to the local model when it is on disk. The local model is loaded when recording starts and unloaded after
/// `Prefs.unloadAfterMinutes` without dictation: a single one-shot timer, nothing polls.
@MainActor
final class EngineStore: ObservableObject {
    static let shared = EngineStore()

    enum LocalState: Equatable {
        case missing
        case downloading(Double)
        case onDisk
        case loading
        case loaded
        case failed(String)
    }

    @Published var selected: EngineID {
        didSet {
            UserDefaults.standard.set(selected.rawValue, forKey: "engine")
            Log.info("Engine: \(selected.rawValue)", "engine")
            // Another model (or a cloud engine): the helper holding the old one goes.
            if selected != oldValue { unloadNow() }
        }
    }
    /// State of each local model (`EngineID.local`).
    @Published private(set) var locals: [EngineID: LocalState] = [:]
    @Published var unloadAfterMinutes = Prefs.unloadAfterMinutes {
        didSet {
            Prefs.unloadAfterMinutes = unloadAfterMinutes
            scheduleUnload()
        }
    }

    let parakeet = ParakeetEngine()
    private var loadTask: Task<Void, Error>?
    private var unloadTimer: DispatchWorkItem?

    /// The provider "Через интернет" shows; kept while the local model is used.
    @Published var cloudProvider: EngineID {
        didSet { UserDefaults.standard.set(cloudProvider.rawValue, forKey: "cloudProvider") }
    }
    /// Each provider's speech models, as its list last said (kept, so the menu needs no request).
    @Published private(set) var models: [EngineID: [String]] = [:]
    @Published private(set) var loadingModels: EngineID?
    @Published private(set) var modelsError: [EngineID: String] = [:]

    private init() {
        let stored = UserDefaults.standard.string(forKey: "engine") ?? ""
        let engine = EngineID(rawValue: stored) ?? .parakeetUltra
        selected = engine
        let provider = EngineID(rawValue: UserDefaults.standard.string(forKey: "cloudProvider") ?? "")
        cloudProvider = provider.flatMap { $0.isLocal ? nil : $0 } ?? (engine.isLocal ? .groq : engine)
        for id in EngineID.cloud {
            if let list = UserDefaults.standard.stringArray(forKey: "models.\(id.rawValue)") { models[id] = list }
        }
        refreshLocal()
        if stored == "parakeetV3" {
            // Parakeet TDT v3 is no longer offered (0.22.0): Ultra takes its place.
            UserDefaults.standard.set(EngineID.parakeetUltra.rawValue, forKey: "engine")
            Log.info("Engine: parakeetV3 is gone, using Parakeet Ultra", "engine")
            if Prefs.dictationEnabled && !ParakeetEngine.isDownloaded(.parakeetUltra) { downloadLocal(.parakeetUltra) }
        }
    }

    /// "На этом Mac" or "Через интернет" (the provider chosen last).
    var usesCloud: Bool {
        get { !selected.isLocal }
        set { selected = newValue ? cloudProvider : .parakeetUltra }
    }

    func chooseProvider(_ id: EngineID) {
        cloudProvider = id
        if usesCloud { selected = id }
    }

    func hasKey(_ id: EngineID) -> Bool { !Keychain.key(for: id).isEmpty }

    /// The cloud engine dictation really uses: the selected one when it has a key (a service of
    /// one's own may need none), else nil (the local model).
    private var activeCloud: EngineID? {
        guard !selected.isLocal else { return nil }
        if hasKey(selected) || (selected == .custom && !baseURL(for: .custom).isEmpty) { return selected }
        return nil
    }

    func local(_ model: EngineID) -> LocalState { locals[model] ?? .missing }

    /// The local model's state.
    var local: LocalState { local(.parakeetUltra) }

    var hasLegacyV3: Bool { FileManager.default.fileExists(atPath: ParakeetEngine.legacyV3Directory.path) }

    func deleteLegacyV3() {
        try? FileManager.default.removeItem(at: ParakeetEngine.legacyV3Directory)
        Log.info("Parakeet v3 deleted from disk", "engine")
        objectWillChange.send()
    }

    func refreshLocal() {
        for model in EngineID.local {
            switch local(model) {
            case .downloading, .loading, .loaded: continue
            default: locals[model] = ParakeetEngine.isDownloaded(model) ? .onDisk : .missing
            }
        }
    }

    func isDownloading(_ model: EngineID) -> Bool {
        if case .downloading = local(model) { return true }
        return false
    }

    /// Downloads a local model from Hugging Face into Application Support/FluidAudio.
    func downloadLocal(_ model: EngineID) {
        guard !isDownloading(model) else { return }
        locals[model] = .downloading(0)
        Log.info("\(model.title) download started", "engine")
        Task {
            do {
                try await ParakeetEngine.download(model) { fraction in
                    Task { @MainActor in
                        let store = EngineStore.shared
                        if store.isDownloading(model) { store.locals[model] = .downloading(fraction) }
                    }
                }
                locals[model] = .onDisk
                Log.info("\(model.title) downloaded", "engine")
            } catch {
                locals[model] = .failed(String(localized: "Не удалось скачать: \(error.localizedDescription)"))
                Log.error("\(model.title) download failed: \(Log.describe(error))", "engine")
            }
        }
    }

    func deleteLocal(_ model: EngineID) {
        if selected == model { unloadNow() }
        try? FileManager.default.removeItem(at: ParakeetEngine.directory(model))
        locals[model] = .missing
        Log.info("\(model.title) deleted from disk", "engine")
    }

    /// Recording started: get the local model into memory while the user speaks.
    /// `force`: also while a cloud engine is selected (it failed; the local model takes over).
    func prepare(force: Bool = false) {
        unloadTimer?.cancel()
        let model = EngineID.parakeetUltra
        guard force || activeCloud == nil, loadTask == nil else { return }
        guard ParakeetEngine.isDownloaded(model) else { return }
        if local(model) != .loaded { locals[model] = .loading }
        let parakeet = parakeet
        loadTask = Task {
            do {
                try await parakeet.load(model)
                self.locals[model] = .loaded
            } catch {
                self.loadTask = nil
                self.locals[model] = .failed(String(localized: "Не удалось загрузить модель: \(error.localizedDescription)"))
                Log.error("\(model.title) load failed: \(Log.describe(error))", "engine")
                throw error
            }
        }
    }

    /// Engine state the user must fix before dictating, or nil.
    var problem: String? {
        if activeCloud == nil {
            if !selected.isLocal && !ParakeetEngine.isDownloaded(.parakeetUltra) {
                return String(localized: "Нет ключа API для \(selected.title)")
            }
            switch local {
            case .missing: return String(localized: "Модель не скачана — откройте настройки")
            case .downloading(let fraction): return String(localized: "Модель скачивается: \(Int(fraction * 100))%")
            // A failed load is tried again on the next recording.
            case .failed(let message): return ParakeetEngine.isDownloaded(.parakeetUltra) ? nil : message
            default: return nil
            }
        }
        return nil
    }

    /// The text and the name of the model that made it (for the history): a cloud engine that
    /// fails hands the audio to the local model when it is on disk.
    func transcribe(_ samples: [Float]) async throws -> (text: String, model: String) {
        defer { scheduleUnload() }
        if let cloud = activeCloud {
            let engine = CloudEngine(id: cloud, baseURL: baseURL(for: cloud), model: model(for: cloud),
                                     key: Keychain.key(for: cloud))
            do {
                return (try await engine.transcribe(samples), "\(cloud.title) · \(model(for: cloud))")
            } catch {
                guard ParakeetEngine.isDownloaded(.parakeetUltra) else { throw error }
                Log.warning("\(cloud.title) failed (\(Log.describe(error))): Parakeet Ultra instead", "engine")
            }
        } else if !selected.isLocal {
            Log.info("\(selected.title) has no key: Parakeet Ultra", "engine")
        }
        let model = EngineID.parakeetUltra
        prepare(force: true)
        try await loadTask?.value
        return (try await parakeet.transcribe(samples, model: model), model.shortTitle)
    }

    // MARK: - Unloading

    private func scheduleUnload() {
        unloadTimer?.cancel()
        unloadTimer = nil
        guard unloadAfterMinutes > 0, loadTask != nil else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.unloadNow() } }
        unloadTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(unloadAfterMinutes * 60), execute: work)
    }

    func unloadNow() {
        unloadTimer?.cancel()
        unloadTimer = nil
        guard loadTask != nil else { return }
        loadTask = nil
        let parakeet = parakeet
        Task {
            await parakeet.unload()
            for (model, state) in self.locals where state == .loaded || state == .loading { self.locals[model] = .onDisk }
            Memory.giveBackSoon()
        }
    }

    // MARK: - Cloud settings

    func baseURL(for id: EngineID) -> String {
        UserDefaults.standard.string(forKey: "baseURL.\(id.rawValue)") ?? id.defaultBaseURL
    }

    func setBaseURL(_ value: String, for id: EngineID) {
        UserDefaults.standard.set(value, forKey: "baseURL.\(id.rawValue)")
        objectWillChange.send()
    }

    func model(for id: EngineID) -> String {
        UserDefaults.standard.string(forKey: "model.\(id.rawValue)") ?? id.defaultModel
    }

    /// Asks the provider for its speech models (after a key is saved, or "Обновить список"). The
    /// chosen model stays when it is still listed, else the recommended (first) one is taken.
    func loadModels(_ id: EngineID) {
        guard loadingModels != id else { return }
        loadingModels = id
        modelsError[id] = nil
        let baseURL = baseURL(for: id), key = Keychain.key(for: id)
        Task {
            do {
                let list = try await CloudModels.fetch(id, baseURL: baseURL, key: key)
                models[id] = list
                UserDefaults.standard.set(list, forKey: "models.\(id.rawValue)")
                if list.isEmpty {
                    modelsError[id] = String(localized: "Сервис не назвал ни одной модели для распознавания речи")
                } else if !list.contains(model(for: id)) {
                    setModel(list[0], for: id)
                }
                Log.info("\(id.title): \(list.count) speech models", "engine")
            } catch {
                modelsError[id] = error.localizedDescription
                Log.error("\(id.title) models: \(Log.describe(error))", "engine")
            }
            loadingModels = nil
        }
    }

    func setKey(_ key: String, for id: EngineID) {
        Keychain.setKey(key, for: id)
        if key.isEmpty {
            models[id] = nil
            modelsError[id] = nil
            UserDefaults.standard.removeObject(forKey: "models.\(id.rawValue)")
        }
        objectWillChange.send()
    }

    func setModel(_ value: String, for id: EngineID) {
        UserDefaults.standard.set(value, forKey: "model.\(id.rawValue)")
        objectWillChange.send()
    }

    /// One line for the settings: what dictation uses now.
    var summary: String {
        if let cloud = activeCloud { return "\(cloud.title) · \(model(for: cloud))" }
        if !selected.isLocal { return String(localized: "\(selected.title): нет ключа, пока Parakeet Ultra на этом Mac") }
        return String(localized: "Parakeet Ultra на этом Mac")
    }
}
