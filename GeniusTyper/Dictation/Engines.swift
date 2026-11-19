import Darwin
import Foundation
import Security

/// Speech-to-text engines. The local one (Parakeet Ultra, Moondream's post-trained NVIDIA v3, on
/// the Neural Engine) and cloud ones through the OpenAI-compatible `/audio/transcriptions` API
/// (Groq, OpenAI, OpenRouter, any compatible service). Parakeet TDT v3 was dropped in 0.22.0: Ultra
/// is as fast and better everywhere it was compared (2026-10-28); a stored `parakeetV3` becomes Ultra.
enum EngineID: String, CaseIterable, Identifiable {
    case parakeetUltra, groq, openAI, openRouter, custom
    var id: String { rawValue }

    static let local: [EngineID] = [.parakeetUltra]
    static let cloud: [EngineID] = [.groq, .openAI, .openRouter, .custom]

    var isLocal: Bool { Self.local.contains(self) }

    /// Name in the settings and in the history.
    var title: String {
        switch self {
        case .parakeetUltra: return "Parakeet Ultra"
        case .groq: return "Groq"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .custom: return String(localized: "Другой сервис")
        }
    }

    /// Short name for the history and statistics.
    var shortTitle: String { title }

    /// One line under the provider in the settings.
    var note: String {
        switch self {
        case .parakeetUltra: return String(localized: "На этом Mac, звук никуда не уходит")
        case .groq: return String(localized: "Быстрее всех, есть бесплатный лимит")
        case .openAI: return String(localized: "Модели GPT-4o для речи")
        case .openRouter: return String(localized: "Много моделей по одному ключу")
        case .custom: return String(localized: "Любой сервис, совместимый с OpenAI, по своему адресу")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .parakeetUltra, .custom: return ""
        }
    }

    /// Picked when the provider's list of models arrives and nothing was chosen yet.
    var defaultModel: String {
        switch self {
        case .groq: return "whisper-large-v3-turbo"
        case .openAI: return "gpt-4o-transcribe"
        case .openRouter: return "openai/whisper-large-v3"
        case .parakeetUltra, .custom: return ""
        }
    }

    /// Where the user gets a key.
    var keyPage: URL? {
        switch self {
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .parakeetUltra, .custom: return nil
        }
    }

    /// The local model's name for GeniusTyperEngine (its second argument).
    var helperModel: String { "ultra" }
}

/// The local Parakeet model, run by the GeniusTyperEngine helper (FluidAudio, Neural Engine). The helper is
/// started when recording starts (the model loads while the user speaks) and stopped after a pause
/// (`EngineStore`): loading the model leaves ~30 MB of fragmented memory that a running process
/// never gives back to macOS, so it is a separate process that exits with the model.
actor ParakeetEngine {
    private var process: Process?
    private var input: FileHandle?
    private var reader: LineReader?
    private var loading: Task<Void, Error>?
    /// The model the running helper has loaded.
    private var model: EngineID?

    /// FluidAudio's model folder (`AsrModels.defaultCacheDirectory(for: .ultra)`).
    static func directory(_ model: EngineID) -> URL {
        modelsFolder.appendingPathComponent("parakeet-ultra", isDirectory: true)
    }

    /// Parakeet TDT v3 downloaded by a version before 0.22.0 (~470 MB): the settings offer to delete it.
    static let legacyV3Directory = modelsFolder.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)

    private static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    static func isDownloaded(_ model: EngineID) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory(model).path)) ?? []
        return ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"].allSatisfy(files.contains)
            && files.contains { $0.hasSuffix("vocab.json") }
    }

    var isLoaded: Bool { loading != nil && process?.isRunning == true }

    /// The helper's memory footprint in MB (for the stress test), nil when it is not running.
    var helperFootprintMB: Double? {
        guard let process, process.isRunning else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : nil
    }

    /// Downloads the model (~630 MB) from Hugging Face into FluidAudio's folder.
    static func download(_ model: EngineID, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (process, _, reader) = try launch("download", model)
        defer { if process.isRunning { process.terminate() } }
        while let json = await reader.nextJSON() {
            if let fraction = json["progress"] as? Double { progress(fraction) }
            if json["done"] as? Bool == true { return }
            if let error = json["error"] as? String { throw EngineError(error) }
        }
        throw EngineError(String(localized: "Загрузка прервалась"))
    }

    func load(_ model: EngineID) async throws {
        if let loading, process?.isRunning == true, self.model == model { return try await loading.value }
        stop()
        self.model = model
        let task = Task { try await start(model) }
        loading = task
        do {
            try await task.value
        } catch {
            stop()
            throw error
        }
    }

    private func start(_ model: EngineID) async throws {
        let (process, input, reader) = try Self.launch("serve", model)
        self.process = process
        self.input = input
        self.reader = reader
        guard let json = await reader.nextJSON() else { throw EngineError(String(localized: "Модель не запустилась")) }
        if let error = json["error"] as? String { throw EngineError(error) }
        Log.info(String(format: "%@ loaded in %.2f s (helper pid %d)", model.title, json["seconds"] as? Double ?? 0, process.processIdentifier), "engine")
    }

    func transcribe(_ samples: [Float], model: EngineID) async throws -> String {
        try await load(model)
        guard let input, let reader else { throw EngineError(String(localized: "Модель не запустилась")) }
        var data = Data(capacity: 4 + samples.count * 4)
        withUnsafeBytes(of: UInt32(samples.count).littleEndian) { data.append(contentsOf: $0) }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        do {
            try input.write(contentsOf: data)
        } catch {
            stop()
            throw EngineError(String(localized: "Модель завершилась с ошибкой"))
        }
        guard let json = await reader.nextJSON() else {
            stop()
            throw EngineError(String(localized: "Модель завершилась с ошибкой"))
        }
        if let error = json["error"] as? String { throw EngineError(error) }
        Log.debug(String(format: "Parakeet: %.2f s", json["seconds"] as? Double ?? 0), "engine")
        return json["text"] as? String ?? ""
    }

    /// Closing its input makes the helper exit; its memory goes back to macOS.
    func unload() {
        guard process != nil else { return }
        stop()
        Log.info("Parakeet unloaded (helper stopped)", "engine")
    }

    private func stop() {
        try? input?.close()
        if let process, process.isRunning {
            // It exits on end of input; make sure it does not linger.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { process.terminate() } }
        }
        process = nil
        input = nil
        reader = nil
        loading = nil
        model = nil
    }

    private static func launch(_ mode: String, _ model: EngineID) throws -> (Process, FileHandle, LineReader) {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "GeniusTyperEngine") else {
            throw EngineError(String(localized: "Нет GeniusTyperEngine в приложении"))
        }
        let process = Process()
        process.executableURL = url
        process.arguments = [mode, model.helperModel]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, stdin.fileHandleForWriting, LineReader(stdout.fileHandleForReading))
    }
}

/// Reads the helper's JSON lines without blocking the caller.
final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.dmemruk.GeniusTyper.engine-output")
    private var buffer = Data()

    init(_ handle: FileHandle) { self.handle = handle }

    /// The next line as a JSON object; nil at end of output.
    func nextJSON() async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            queue.async {
                while true {
                    if let newline = self.buffer.firstIndex(of: 10) {
                        let line = self.buffer[self.buffer.startIndex..<newline]
                        self.buffer.removeSubrange(self.buffer.startIndex...newline)
                        if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            continuation.resume(returning: json)
                            return
                        }
                        continue // not ours (a library printing): skip
                    }
                    let chunk = self.handle.availableData
                    if chunk.isEmpty {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.buffer.append(chunk)
                }
            }
        }
    }
}

/// An OpenAI-compatible transcription API.
struct CloudEngine {
    let id: EngineID
    let baseURL: String
    let model: String
    let key: String

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/audio/transcriptions") else {
            throw EngineError(String(localized: "Неверный адрес сервиса"))
        }
        let boundary = "GeniusTyper-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(WAV.encode(samples, sampleRate: Int(AudioRecorder.sampleRate)))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200, let text = json?["text"] as? String else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            Log.error("\(id.rawValue) HTTP \(status): \(message)", "engine")
            throw EngineError(String(localized: "Сервис ответил ошибкой \(status)"))
        }
        return text
    }
}

/// The provider's speech-to-text models, for the menu in the settings (and a check that the key works).
enum CloudModels {
    static func fetch(_ id: EngineID, baseURL: String, key: String) async throws -> [String] {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        // OpenRouter lists only its transcription models when asked; the others list everything.
        let path = id == .openRouter ? "/models?output_modalities=transcription" : "/models"
        guard let url = URL(string: base + path), url.scheme?.hasPrefix("http") == true else {
            throw EngineError(String(localized: "Неверный адрес сервиса"))
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            Log.error("\(id.rawValue) models HTTP \(status)", "engine")
            throw EngineError(status == 401 || status == 403 ? String(localized: "Ключ не подошёл")
                                                              : String(localized: "Сервис ответил ошибкой \(status)"))
        }
        let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return speechModels(ids, for: id)
    }

    /// Only the models that turn speech into text, the recommended one first. Groq and OpenAI list
    /// their chat, image and voice models too.
    static func speechModels(_ ids: [String], for id: EngineID) -> [String] {
        let speech: [String]
        switch id {
        case .groq:
            speech = ids.filter { $0.contains("whisper") }
        case .openAI:
            // "-diarize" needs another request format.
            speech = ids.filter { ($0.contains("transcribe") || $0.contains("whisper")) && !$0.contains("diarize") }
        default:
            speech = ids
        }
        return Array(Set(speech)).sorted { a, b in
            if a == id.defaultModel || b == id.defaultModel { return a == id.defaultModel }
            return a < b
        }
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 16-bit PCM WAV for the cloud APIs.
enum WAV {
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for sample in samples {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * Float(Int16.max))))
        }
        return data
    }
}

/// API keys in the login Keychain, one per engine.
enum Keychain {
    private static let service = "com.dmemruk.GeniusTyper"

    static func key(for id: EngineID) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.rawValue, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func setKey(_ key: String, for id: EngineID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.rawValue]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { Log.error("Keychain: saving the \(id.rawValue) key failed (\(status))", "engine") }
    }
}
