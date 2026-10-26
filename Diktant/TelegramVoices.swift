import AVFoundation
import Foundation

/// A voice message found in Telegram's media cache.
struct VoiceFile: Equatable {
    let url: URL
    let date: Date
    let duration: TimeInterval
}

/// Telegram voice messages from the official app's media cache. Telegram (macOS, "keepcoder")
/// keeps each downloaded file under
/// `~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable/account-*/postbox/media/`
/// without an extension; voice messages are Ogg Opus, which `AVAudioFile` decodes. Which chat a
/// file came from is only in Telegram's encrypted database, so "latest" means the newest files;
/// leaving voice auto-download on for private chats only (Telegram → Data and Storage) keeps
/// group messages out unless played.
enum TelegramVoices {
    /// `-voicesRoot <folder>` (a launch argument) points it at a test folder.
    static var root: URL {
        if let path = UserDefaults.standard.string(forKey: "voicesRoot") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable", isDirectory: true)
    }

    /// Voice messages are small: an hour of Opus at Telegram's bitrate is ~15 MB.
    private static let maxSize = 20 * 1024 * 1024

    /// A cached file that may be a voice message, before its header is read.
    struct Candidate: Sendable {
        let url: URL
        let date: Date
    }

    /// The newest `limit` complete voice messages, newest first.
    static func latest(limit: Int = 3, in root: URL = root) -> [VoiceFile] {
        voices(in: candidates(in: root), from: 0, limit: limit).files
    }

    /// Complete files that may be voice messages, newest first. Reads the folder listing only
    /// (~10 000 entries: a second or more), so the popup does it once and pages through the result.
    static func candidates(in root: URL = root) -> [Candidate] {
        let manager = FileManager.default
        let accounts = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("account-") }
        var candidates: [Candidate] = []
        for account in accounts {
            let media = root.appendingPathComponent(account).appendingPathComponent("postbox/media", isDirectory: true)
            guard let files = try? manager.contentsOfDirectory(at: media, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { continue }
            let names = Set(files.map(\.lastPathComponent))
            for file in files {
                let name = file.lastPathComponent
                // Telegram downloads into "<name>_partial"; once complete, "<name>" is a hard link to
                // it and both stay. A "<name>" next to a different "_partial" file is not finished.
                guard !name.hasSuffix("_partial"),
                      !names.contains(name + "_partial") || isSameFile(file, file.deletingLastPathComponent().appendingPathComponent(name + "_partial")),
                      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, let size = values.fileSize, size > 0, size < maxSize,
                      let date = values.contentModificationDate else { continue }
                candidates.append(Candidate(url: file, date: date))
            }
        }
        return candidates.sorted { $0.date > $1.date }
    }

    /// Up to `limit` voice messages among `candidates` from index `start` on (reads the first bytes
    /// of each), and the index to continue from.
    static func voices(in candidates: [Candidate], from start: Int, limit: Int) -> (files: [VoiceFile], next: Int) {
        var result: [VoiceFile] = []
        var index = start
        while index < candidates.count, result.count < limit {
            let candidate = candidates[index]
            index += 1
            guard isOggOpus(candidate.url), let file = try? AVAudioFile(forReading: candidate.url) else { continue }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            result.append(VoiceFile(url: candidate.url, date: candidate.date, duration: duration))
        }
        return (result, index)
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let manager = FileManager.default
        guard let first = (try? manager.attributesOfItem(atPath: a.path))?[.systemFileNumber] as? Int,
              let second = (try? manager.attributesOfItem(atPath: b.path))?[.systemFileNumber] as? Int else { return false }
        return first == second
    }

    /// "OggS" page with an "OpusHead" header: a voice message (stickers and videos are other formats).
    static func isOggOpus(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), head.count >= 36 else { return false }
        return head.prefix(4) == Data("OggS".utf8) && head.range(of: Data("OpusHead".utf8)) != nil
    }
}

/// The popup's model: the latest voice messages and their text, transcribed newest first when the
/// popup opens; older ones a page at a time on request. Texts are kept for the last few files only
/// (by path and date), so opening it again is instant; nothing goes into the dictation history or
/// statistics.
@MainActor
final class VoiceTranscripts: ObservableObject {
    static let shared = VoiceTranscripts()

    enum Text: Equatable {
        case waiting, transcribing, done(String), failed(String)
    }

    struct Item: Identifiable, Equatable {
        let file: VoiceFile
        var text: Text
        var id: String { file.url.path }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var problem: String?

    /// How many more each "more" (scroll past the end, ↓, the button) adds.
    nonisolated static let pageSize = 3

    private var cache: [String: String] = [:]
    private var candidates: [TelegramVoices.Candidate] = []
    private var next = 0
    private var loader: Task<Void, Never>?
    private var job: Task<Void, Never>?

    private static func key(_ file: VoiceFile) -> String { "\(file.url.path)|\(file.date.timeIntervalSince1970)" }

    func refresh() {
        clear()
        problem = nil
        isLoading = true
        loader = Task {
            let found = await Task.detached(priority: .userInitiated) { TelegramVoices.candidates() }.value
            guard !Task.isCancelled else { return }
            candidates = found
            next = 0
            await loadPage()
        }
    }

    /// The next few older voice messages, transcribed after the ones already shown.
    func loadMore() {
        guard hasMore, !isLoading else { return }
        isLoading = true
        loader = Task { await loadPage() }
    }

    private func loadPage() async {
        let candidates = candidates, start = next
        let page = await Task.detached(priority: .userInitiated) {
            TelegramVoices.voices(in: candidates, from: start, limit: Self.pageSize)
        }.value
        guard !Task.isCancelled else { return }
        isLoading = false
        next = page.next
        hasMore = page.next < candidates.count
        items += page.files.map { file in Item(file: file, text: cache[Self.key(file)].map(Text.done) ?? .waiting) }
        if items.isEmpty {
            problem = FileManager.default.fileExists(atPath: TelegramVoices.root.path)
                ? String(localized: "Голосовых в кеше Telegram нет. Откройте сообщение и нажмите воспроизведение — оно скачается за секунду.")
                : String(localized: "Не найден Telegram для macOS (или нет доступа к его данным).")
            return
        }
        transcribeWaiting()
    }

    /// Transcribes the waiting items in order, newest first; items added meanwhile join the queue.
    private func transcribeWaiting() {
        guard job == nil else { return }
        if let engineProblem = EngineStore.shared.problem {
            problem = engineProblem
            return
        }
        job = Task {
            while let index = items.firstIndex(where: { $0.text == .waiting }) {
                guard !Task.isCancelled else { return }
                items[index].text = .transcribing
                let file = items[index].file
                do {
                    let samples = try await Task.detached(priority: .userInitiated) {
                        try AudioRecorder.samples(fromFile: file.url)
                    }.value
                    let start = Date()
                    let text = try await EngineStore.shared.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.info(String(format: "Telegram voice %.0f s transcribed in %.2f s", file.duration, Date().timeIntervalSince(start)), "voices")
                    guard !Task.isCancelled, index < items.count, items[index].file == file else { return }
                    items[index].text = .done(text)
                    remember(text, for: file)
                } catch {
                    Log.error("Telegram voice failed: \(Log.describe(error))", "voices")
                    guard !Task.isCancelled, index < items.count, items[index].file == file else { return }
                    items[index].text = .failed(String(localized: "Не удалось распознать"))
                }
            }
            job = nil
            Memory.giveBackSoon()
        }
    }

    /// The popup closed: drop the list (texts stay in the small cache).
    func clear() {
        loader?.cancel()
        loader = nil
        job?.cancel()
        job = nil
        items = []
        candidates = []
        next = 0
        hasMore = false
        isLoading = false
    }

    private func remember(_ text: String, for file: VoiceFile) {
        cache[Self.key(file)] = text
        if cache.count > 30 { cache.removeAll() } // tiny; just keep it bounded
    }
}
