import Foundation

/// One line of the behaviour journal. Never contains text: only layouts, lengths, verdicts and
/// timings, enough to see how often and how the layout goes wrong and what a detector would do.
struct JournalEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case word, rewrite, flagKept, start, pause, resume
        /// Genius Switcher fixed a word itself / the user undid that with Caps Lock.
        case autoFix, autoUndo
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
    /// caps (Caps Lock in Genius Switcher) / auto (auto-fix) / other (macOS shortcut, menu, Fn…)
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
        case .autoUndo:
            autoUndos += 1
        case .start, .pause, .resume:
            break
        }
    }
}

/// `~/Library/Application Support/GeniusSwitcher/journal/YYYY-MM-DD.jsonl`, one JSON object per line,
/// kept for 90 days.
final class Journal {
    static let directory: URL = {
        let base = AppDelegate.isRunningTests
            ? FileManager.default.temporaryDirectory.appendingPathComponent("GeniusSwitcherTests", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GeniusSwitcher", isDirectory: true)
        let dir = base.appendingPathComponent("journal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let queue = DispatchQueue(label: "com.dmemruk.GeniusSwitcher.journal")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func file(for date: Date) -> URL {
        directory.appendingPathComponent("\(dayFormat.string(from: date)).jsonl")
    }

    func append(_ entries: [JournalEntry]) {
        guard !entries.isEmpty else { return }
        let lines = entries.compactMap { entry -> (URL, Data)? in
            guard var data = try? encoder.encode(entry) else { return nil }
            data.append(0x0A)
            return (Self.file(for: entry.t), data)
        }
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
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    func deleteAll() {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}
