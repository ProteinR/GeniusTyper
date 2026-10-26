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

    /// Complete files that may be voice messages, newest first. Reads the folder listing with
    /// plain `lstat` (~10 000 entries in ~50 ms; FileManager's resource values took 3 s), so the
    /// popup does it once per opening and pages through the result.
    static func candidates(in root: URL = root) -> [Candidate] {
        let accounts = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("account-") }
        var candidates: [Candidate] = []
        for account in accounts {
            let media = root.appendingPathComponent(account).appendingPathComponent("postbox/media", isDirectory: true)
            var entries: [String: stat] = [:]
            guard let dir = opendir(media.path) else { continue }
            let fd = dirfd(dir)
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                guard name != ".", name != ".." else { continue }
                var info = stat()
                if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { entries[name] = info }
            }
            closedir(dir)
            for (name, info) in entries {
                // Telegram downloads into "<name>_partial"; once complete, "<name>" is a hard link to
                // it and both stay. A "<name>" next to a different "_partial" file is not finished.
                guard !name.hasSuffix("_partial"),
                      (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size < maxSize else { continue }
                if let partial = entries[name + "_partial"], partial.st_ino != info.st_ino { continue }
                let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
                candidates.append(Candidate(url: media.appendingPathComponent(name), date: date))
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

    /// "OggS" page with an "OpusHead" header: a voice message (stickers and videos are other formats).
    static func isOggOpus(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), head.count >= 36 else { return false }
        return head.prefix(4) == Data("OggS".utf8) && head.range(of: Data("OpusHead".utf8)) != nil
    }
}

/// The popup's model: the latest voice messages and their text, transcribed newest first when the
/// popup opens; older ones a page at a time on request. Texts of the last 200 files (by path and
/// date) are kept in `voice-texts.json` next to the history, so opening it again, also after a
/// restart, does not transcribe them again; nothing goes into the dictation history or statistics.
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

    /// Loaded on the first opening, so it costs nothing until the popup is used.
    private lazy var cache: [CachedText] = Self.loadCache()
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

    /// The menu panel's voices column shown again: keep what is there (still transcribing, maybe).
    func refreshIfEmpty() {
        if items.isEmpty, !isLoading { refresh() }
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
        items += page.files.map { file in
            let key = Self.key(file)
            return Item(file: file, text: cache.last { $0.key == key }.map { .done($0.text) } ?? .waiting)
        }
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

    private struct CachedText: Codable {
        let key: String
        let text: String
    }

    private static let cacheLimit = 200
    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeniusTyper/dictation/voice-texts.json")
    }

    private static func loadCache() -> [CachedText] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([CachedText].self, from: data)) ?? []
    }

    private func remember(_ text: String, for file: VoiceFile) {
        let key = Self.key(file)
        cache.removeAll { $0.key == key }
        cache.append(CachedText(key: key, text: text))
        if cache.count > Self.cacheLimit { cache.removeFirst(cache.count - Self.cacheLimit) }
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
}
