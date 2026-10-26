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

    /// One opening's look at the cache: voice messages since `since` not yet `known` (keys of
    /// stored texts), keys of the files there that are not voices (so the next opening skips their
    /// headers), and the older files left for "more", newest first.
    static func scan(_ candidates: [Candidate], since: Date, known: Set<String>, notVoices: Set<String>)
        -> (fresh: [VoiceFile], others: [String], older: [Candidate]) {
        var recent: [Candidate] = [], older: [Candidate] = []
        for candidate in candidates {
            let key = VoiceText.key(path: candidate.url.path, date: candidate.date)
            guard !known.contains(key) else { continue }
            if candidate.date >= since {
                if !notVoices.contains(key) { recent.append(candidate) }
            } else {
                older.append(candidate)
            }
        }
        let fresh = voices(in: recent, from: 0, limit: .max).files
        let voicePaths = Set(fresh.map(\.url.path))
        let others = recent.filter { !voicePaths.contains($0.url.path) }.map { VoiceText.key(path: $0.url.path, date: $0.date) }
        return (fresh, others, older)
    }

    /// "OggS" page with an "OpusHead" header: a voice message (stickers and videos are other formats).
    static func isOggOpus(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), head.count >= 36 else { return false }
        return head.prefix(4) == Data("OggS".utf8) && head.range(of: Data("OpusHead".utf8)) != nil
    }
}

/// A transcribed voice message, kept in `voice-texts.json` after the file leaves Telegram's cache.
struct VoiceText: Codable, Equatable {
    let path: String
    /// The file's date (when Telegram downloaded it).
    let date: Date
    /// 0 for texts kept before 0.13.0 (only path, date and text were stored).
    let duration: TimeInterval
    let text: String
    /// When it was transcribed.
    let added: Date

    var key: String { Self.key(path: path, date: date) }
    var file: VoiceFile { VoiceFile(url: URL(fileURLWithPath: path), date: date, duration: duration) }

    static func key(path: String, date: Date) -> String {
        "\(path)|\(Int((date.timeIntervalSince1970 * 1000).rounded()))"
    }

    /// Kept for `days`: by the message's date, or by when it was transcribed (an older one asked
    /// for with "more" stays as long).
    static func kept(_ texts: [VoiceText], days: Int, now: Date = Date()) -> [VoiceText] {
        let since = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return texts.filter { max($0.date, $0.added) >= since }
    }

    /// The stored list; also the format before 0.13.0 (`key` = "path|seconds since 1970", `text`).
    static func decode(_ data: Data) -> [VoiceText] {
        if let texts = try? JSONDecoder().decode([VoiceText].self, from: data) { return texts }
        struct Old: Decodable { let key: String; let text: String }
        let old = (try? JSONDecoder().decode([Old].self, from: data)) ?? []
        return old.compactMap { item in
            guard let bar = item.key.lastIndex(of: "|"), let seconds = Double(item.key[item.key.index(after: bar)...]) else { return nil }
            let date = Date(timeIntervalSince1970: seconds)
            return VoiceText(path: String(item.key[..<bar]), date: date, duration: 0, text: item.text, added: date)
        }
    }
}

/// The popup's model. Opening shows the stored texts of the last days (`Prefs.voicesKeepDays`) at
/// once, newest first, and meanwhile looks in Telegram's cache for voice messages of those days not
/// transcribed yet: they join the list in their place and are transcribed newest first. Older ones
/// a page at a time on request. Texts are kept in `voice-texts.json` next to the history (also
/// after the file leaves Telegram's cache); nothing goes into the dictation history or statistics.
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
    /// Looking in Telegram's cache for new voice messages.
    @Published private(set) var isChecking = false
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var problem: String?

    /// How many more each "more" (scroll past the end, ↓, the button) adds.
    nonisolated static let pageSize = 3

    /// Waiting or being transcribed.
    var pending: Int {
        items.count { $0.text == .waiting || $0.text == .transcribing }
    }

    /// Loaded on the first opening, so it costs nothing until the popup is used.
    private lazy var texts: [VoiceText] = Self.load()
    /// Files in the cache that are not voice messages (photos, stickers…), for this run: their
    /// headers are read once.
    private var notVoices: Set<String> = []
    private var older: [TelegramVoices.Candidate] = []
    private var next = 0
    private var loader: Task<Void, Never>?
    private var job: Task<Void, Never>?

    func refresh() {
        clear()
        problem = nil
        let now = Date(), days = Prefs.voicesKeepDays
        let kept = VoiceText.kept(texts, days: days, now: now)
        if kept.count != texts.count {
            texts = kept
            save()
        }
        items = texts.sorted { $0.date > $1.date }.map { Item(file: $0.file, text: .done($0.text)) }
        isChecking = true
        let since = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let known = Set(texts.map(\.key)), notVoices = notVoices
        loader = Task {
            let found = await Task.detached(priority: .userInitiated) {
                TelegramVoices.scan(TelegramVoices.candidates(), since: since, known: known, notVoices: notVoices)
            }.value
            guard !Task.isCancelled else { return }
            self.notVoices.formUnion(found.others)
            older = found.older
            next = 0
            hasMore = !older.isEmpty
            isChecking = false
            add(found.fresh)
            if items.isEmpty {
                problem = FileManager.default.fileExists(atPath: TelegramVoices.root.path)
                    ? String(localized: "Голосовых в кеше Telegram нет. Откройте сообщение и нажмите воспроизведение — оно скачается за секунду.")
                    : String(localized: "Не найден Telegram для macOS (или нет доступа к его данным).")
                return
            }
            transcribeWaiting()
        }
    }

    /// The menu panel's voices column shown again: keep what is there (still transcribing, maybe).
    func refreshIfEmpty() {
        if items.isEmpty, !isChecking { refresh() }
    }

    /// The next few older voice messages, transcribed after the ones already shown.
    func loadMore() {
        guard hasMore, !isLoading, !isChecking else { return }
        isLoading = true
        let older = older, start = next
        loader = Task {
            let page = await Task.detached(priority: .userInitiated) {
                TelegramVoices.voices(in: older, from: start, limit: Self.pageSize)
            }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            next = page.next
            hasMore = page.next < older.count
            add(page.files)
            transcribeWaiting()
        }
    }

    /// New voice messages join the list in their place by date, waiting.
    private func add(_ files: [VoiceFile]) {
        guard !files.isEmpty else { return }
        items = (items + files.map { Item(file: $0, text: .waiting) }).sorted { $0.file.date > $1.file.date }
    }

    /// Transcribes the waiting items in order, newest first; items added meanwhile join the queue.
    private func transcribeWaiting() {
        guard job == nil, pending > 0 else { return }
        if let engineProblem = EngineStore.shared.problem {
            problem = engineProblem
            return
        }
        job = Task {
            while let index = items.firstIndex(where: { $0.text == .waiting }) {
                guard !Task.isCancelled else { return }
                items[index].text = .transcribing
                let file = items[index].file
                let result: Text
                do {
                    let samples = try await Task.detached(priority: .userInitiated) {
                        try AudioRecorder.samples(fromFile: file.url)
                    }.value
                    let start = Date()
                    let text = try await EngineStore.shared.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.info(String(format: "Telegram voice %.0f s transcribed in %.2f s", file.duration, Date().timeIntervalSince(start)), "voices")
                    remember(text, for: file)
                    result = .done(text)
                } catch {
                    Log.error("Telegram voice failed: \(Log.describe(error))", "voices")
                    result = .failed(String(localized: "Не удалось распознать"))
                }
                // Items may have been added above it meanwhile.
                guard !Task.isCancelled, let now = items.firstIndex(where: { $0.file == file }) else { return }
                items[now].text = result
            }
            job = nil
            Memory.giveBackSoon()
        }
    }

    /// The popup closed: drop the list (the texts stay stored).
    func clear() {
        loader?.cancel()
        loader = nil
        job?.cancel()
        job = nil
        items = []
        older = []
        next = 0
        hasMore = false
        isChecking = false
        isLoading = false
    }

    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeniusTyper/dictation/voice-texts.json")
    }

    private static func load() -> [VoiceText] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return VoiceText.decode(data)
    }

    private func remember(_ text: String, for file: VoiceFile) {
        let entry = VoiceText(path: file.url.path, date: file.date, duration: file.duration, text: text, added: Date())
        texts.removeAll { $0.key == entry.key }
        texts.append(entry)
        save()
    }

    private func save() {
        let url = Self.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(texts).write(to: url, options: .atomic)
    }
}
