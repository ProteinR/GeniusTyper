import Foundation

/// Which engine dictation uses, the local model's state (downloaded, in memory) and the cloud
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
            if !selected.isLocal { unloadNow() }
        }
    }
    @Published private(set) var local: LocalState = .missing
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
        selected = EngineID(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .parakeetV3
        refreshLocal()
    }

    func refreshLocal() {
        switch local {
        case .downloading, .loading, .loaded: return
        default: local = ParakeetEngine.isDownloaded ? .onDisk : .missing
        }
    }

    var isDownloading: Bool {
        if case .downloading = local { return true }
        return false
    }

    /// Downloads the local model (~470 MB) from Hugging Face into Application Support/FluidAudio.
    func downloadLocal() {
        guard !isDownloading else { return }
        local = .downloading(0)
        Log.info("Parakeet download started", "engine")
        Task {
            do {
                try await ParakeetEngine.download { fraction in
                    Task { @MainActor in
                        if case .downloading = EngineStore.shared.local { EngineStore.shared.local = .downloading(fraction) }
                    }
                }
                local = .onDisk
                Log.info("Parakeet downloaded", "engine")
            } catch {
                local = .failed(String(localized: "Не удалось скачать: \(error.localizedDescription)"))
                Log.error("Parakeet download failed: \(Log.describe(error))", "engine")
            }
        }
    }

    func deleteLocal() {
        unloadNow()
        try? FileManager.default.removeItem(at: ParakeetEngine.directory)
        local = .missing
        Log.info("Parakeet deleted from disk", "engine")
    }

    /// Recording started: get the local model into memory while the user speaks.
    func prepare() {
        unloadTimer?.cancel()
        guard selected.isLocal, loadTask == nil else { return }
        guard ParakeetEngine.isDownloaded else { return }
        if local != .loaded { local = .loading }
        let parakeet = parakeet
        loadTask = Task {
            do {
                try await parakeet.load()
                self.local = .loaded
            } catch {
                self.loadTask = nil
                self.local = .failed(String(localized: "Не удалось загрузить модель: \(error.localizedDescription)"))
                Log.error("Parakeet load failed: \(Log.describe(error))", "engine")
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
            case .failed(let message): return ParakeetEngine.isDownloaded ? nil : message
            default: return nil
            }
        }
        if Keychain.key(for: selected).isEmpty { return String(localized: "Нет ключа API для \(selected.title)") }
        return nil
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        defer { scheduleUnload() }
        if selected.isLocal {
            prepare()
            try await loadTask?.value
            return try await parakeet.transcribe(samples)
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
            if self.local == .loaded || self.local == .loading { self.local = .onDisk }
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
