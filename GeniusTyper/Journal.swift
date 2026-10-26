import Foundation

/// One line of the behaviour journal. Never contains text: only layouts, lengths, verdicts and
/// timings, enough to see how often and how the layout goes wrong and what a detector would do.
struct JournalEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case word, rewrite, flagKept, start, pause, resume
        /// Genius Typer fixed a word itself / the user undid that with Caps Lock.
        case autoFix, autoUndo
        /// A word the auto-fixer would fix, ended with ⇧+Space: the user kept it on purpose.
        case autoSkip
        /// Caps Lock in the middle of a word: the letters typed so far were retyped in the other
        /// layout (the user noticed the wrong layout before the detector could).
        case capsFix
        /// ё restored after the space ("еще" → "ещё") / put back to е with Caps Lock.
        case yoFix, yoUndo
        /// Caps Lock twice: the whole phrase converted to one layout / put back with Caps Lock.
        case phraseFix, phraseUndo
        case switchLayout = "switch"
    }

    var t: Date
    var kind: Kind
    var app: String?

    // word / flagKept
    var lang: String?
    var len: Int?
    var verdict: Verdict?
    var mixed: Bool?
    /// space / enter / tab / punct / reset
    var end: String?

    // rewrite
    var from: String?
    var to: String?
    /// The retyped keys vs the erased ones: full (same keys), prefix, none.
    var match: String?
    var erased: Int?
    var retyped: Int?
    /// The erased part crossed a space: the word was finished before it was noticed.
    var late: Bool?
    var words: Int?
    var overflow: Bool?
    /// Seconds from typing the first erased key to the first backspace.
    var noticeSec: Double?

    // switch
    /// caps (Caps Lock in Genius Typer) / auto (auto-fix) / other (macOS shortcut, menu, Fn…)
    var method: String?
    /// wordStart / midWord / afterErase
    var context: String?
    var sinceKeySec: Double?

    init(t: Date, kind: Kind, app: String? = nil) {
        self.t = t
        self.kind = kind
        self.app = app
    }

    /// Erased, switched the layout, typed the same keys again: a manual wrong-layout fix.
    var isWrongLayoutFix: Bool {
        kind == .rewrite && from != nil && to != nil && from != to && match != nil && match != "none"
    }
}

/// Counters for the menu, rebuilt from the day's journal at launch.
struct DayStats: Equatable {
    var words = 0
    var wordsByLanguage: [String: Int] = [:]
    var wrongLayoutFixes = 0
    var lateFixes = 0
    var typoFixes = 0
    var detectorCaught = 0
    var detectorMissed = 0
    var detectorExtra = 0
    var switches = 0
    var capsSwitches = 0
    var midWordSwitches = 0
    var autoFixes = 0
    var autoUndos = 0
    var autoSkips = 0
    var capsFixes = 0
    var yoFixes = 0
    var yoUndos = 0

    mutating func add(_ entry: JournalEntry) {
        switch entry.kind {
        case .word:
            words += 1
            if let lang = entry.lang { wordsByLanguage[lang, default: 0] += 1 }
        case .rewrite:
            if entry.isWrongLayoutFix {
                wrongLayoutFixes += 1
                if entry.late == true { lateFixes += 1 }
                if entry.verdict == .fix { detectorCaught += 1 } else { detectorMissed += 1 }
            } else if entry.from == entry.to {
                typoFixes += 1
            }
        case .flagKept:
            detectorExtra += 1
        case .switchLayout:
            switches += 1
            if entry.method == "caps" { capsSwitches += 1 }
            if entry.context == "midWord" { midWordSwitches += 1 }
        case .autoFix:
            autoFixes += 1
        case .autoUndo, .phraseUndo:
            autoUndos += 1
        case .autoSkip:
            autoSkips += 1
        case .capsFix, .phraseFix:
            capsFixes += 1
        case .yoFix:
            yoFixes += 1
        case .yoUndo:
            yoUndos += 1
        case .start, .pause, .resume:
            break
        }
    }
}

/// One fix with its words, for finding what the detector gets wrong ("rtl" fixed into "кед", "ии"
/// into "bb"). Unlike `JournalEntry` this is text, so only fixes go here, never plain typing, and
/// never from the apps where auto-fix is off (terminals, code editors: a password retyped in the
/// other layout must not end up in a file). Off with the switch in the statistics window.
struct WordLogEntry: Codable, Equatable {
    var t: Date
    var kind: JournalEntry.Kind
    var app: String?
    /// The word (or phrase) as it was on screen before the fix.
    var typed: String
    /// After the fix; nil when nothing changed (flagKept, autoSkip).
    var result: String?
    /// For a manual fix or a word the detector flagged: what the detector said about `typed`.
    var verdict: Verdict?
}

/// `~/Library/Application Support/GeniusTyper/journal/YYYY-MM-DD.jsonl`, one JSON object per line,
/// kept for 90 days; fixes with their words in `words/`, kept for 30 days.
final class Journal {
    static let base: URL = AppDelegate.isRunningTests
        ? FileManager.default.temporaryDirectory.appendingPathComponent("GeniusTyperTests", isDirectory: true)
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeniusTyper", isDirectory: true)
    static let directory = folder("journal")
    static let wordsDirectory = folder("words")
    static let wordsDays = 30

    private static func folder(_ name: String) -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let queue = DispatchQueue(label: "com.dmemruk.GeniusTyper.journal")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Words with "/" stay as typed in the words log.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func file(for date: Date, in directory: URL = directory) -> URL {
        directory.appendingPathComponent("\(dayFormat.string(from: date)).jsonl")
    }

    func append(_ entries: [JournalEntry]) {
        write(entries.compactMap { entry in line(entry).map { (Self.file(for: entry.t), $0) } })
    }

    func append(words entries: [WordLogEntry]) {
        write(entries.compactMap { entry in line(entry).map { (Self.file(for: entry.t, in: Self.wordsDirectory), $0) } })
    }

    private func line(_ entry: some Encodable) -> Data? {
        guard var data = try? encoder.encode(entry) else { return nil }
        data.append(0x0A)
        return data
    }

    private func write(_ lines: [(URL, Data)]) {
        guard !lines.isEmpty else { return }
        queue.async {
            for (url, data) in lines {
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    FileManager.default.createFile(atPath: url.path, contents: data)
                }
            }
        }
    }

    static func load(_ date: Date) -> [JournalEntry] {
        guard let text = try? String(contentsOf: file(for: date), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(JournalEntry.self, from: Data($0.utf8)) }
    }

    static func prune(keepingDays days: Int = 90) {
        prune(directory, days: days)
        prune(wordsDirectory, days: wordsDays)
    }

    private static func prune(_ directory: URL, days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    func deleteAll() {
        queue.async { [Self.directory, Self.wordsDirectory].forEach(Self.deleteFiles(in:)) }
    }

    func deleteWords() {
        queue.async { Self.deleteFiles(in: Self.wordsDirectory) }
    }

    private static func deleteFiles(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
