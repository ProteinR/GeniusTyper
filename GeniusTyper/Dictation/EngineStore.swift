import Foundation

/// Which engine dictation uses, the local models' state (downloaded, in memory) and the cloud
/// engines' settings. The local model is loaded when recording starts and unloaded after
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

    private init() {
        selected = EngineID(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .parakeetUltra
        refreshLocal()
    }

    func local(_ model: EngineID) -> LocalState { locals[model] ?? .missing }

    /// The selected local model's state (`.missing` while a cloud engine is selected).
    var local: LocalState { selected.isLocal ? local(selected) : .missing }

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
    func prepare() {
        unloadTimer?.cancel()
        let model = selected
        guard model.isLocal, loadTask == nil else { return }
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
        if selected.isLocal {
            switch local {
            case .missing: return String(localized: "Модель не скачана — откройте настройки")
            case .downloading(let fraction): return String(localized: "Модель скачивается: \(Int(fraction * 100))%")
            // A failed load is tried again on the next recording.
            case .failed(let message): return ParakeetEngine.isDownloaded(selected) ? nil : message
            default: return nil
            }
        }
        if Keychain.key(for: selected).isEmpty { return String(localized: "Нет ключа API для \(selected.title)") }
        return nil
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        defer { scheduleUnload() }
        if selected.isLocal {
            let model = selected
            prepare()
            try await loadTask?.value
            return try await parakeet.transcribe(samples, model: model)
        }
        let engine = CloudEngine(id: selected, baseURL: baseURL(for: selected), model: model(for: selected),
                                 key: Keychain.key(for: selected))
        return try await engine.transcribe(samples)
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

    func setModel(_ value: String, for id: EngineID) {
        UserDefaults.standard.set(value, forKey: "model.\(id.rawValue)")
        objectWillChange.send()
    }

    /// History and statistics name: "Parakeet v3", "Groq · whisper-large-v3-turbo".
    var currentModelName: String {
        selected.isLocal ? selected.shortTitle : "\(selected.title) · \(model(for: selected))"
    }
}
