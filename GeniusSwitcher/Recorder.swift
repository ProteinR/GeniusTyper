import Foundation

/// Turns what the tracker saw into journal entries (no text) and runs the shadow detector.
struct Recorder {
    let renderer: LayoutRendering
    let detector: LayoutDetector

    /// Words the detector would have switched, waiting to see whether the user fixes them.
    private var flagged: [Int: (time: TimeInterval, app: String?, language: String, length: Int)] = [:]
    /// A flagged word not rewritten within this time counts as a detector false alarm.
    static let flagWindow: TimeInterval = 20

    /// The last wrong-layout fixes as text ("ghbdtn → привет"), for the menu only: never saved.
    private(set) var recentFixes: [String] = []

    init(renderer: LayoutRendering, detector: LayoutDetector) {
        self.renderer = renderer
        self.detector = detector
    }

    mutating func record(_ outputs: [TrackerOutput], app: String?) -> [JournalEntry] {
        outputs.map { output in
            switch output {
            case let .word(word): return entry(for: word, app: app)
            case let .rewrite(rewrite): return entry(for: rewrite, app: app)
            }
        }
    }

    /// Flagged words that were left as typed: the detector would have been wrong.
    mutating func expire(now: TimeInterval) -> [JournalEntry] {
        let old = flagged.filter { now - $0.value.time >= Self.flagWindow }
        old.keys.forEach { flagged.removeValue(forKey: $0) }
        return old.values.sorted { $0.time < $1.time }.map { value in
            var entry = JournalEntry(t: Date(timeIntervalSince1970: value.time), kind: .flagKept, app: value.app)
            entry.lang = value.language
            entry.len = value.length
            return entry
        }
    }

    /// The auto-fixer changed this word: it is not a false alarm.
    mutating func markAutoFixed(_ wordID: Int) {
        flagged.removeValue(forKey: wordID)
    }

    private mutating func entry(for word: FinishedWord, app: String?) -> JournalEntry {
        var entry = JournalEntry(t: Date(timeIntervalSince1970: word.time), kind: .word, app: app)
        entry.lang = word.language
        entry.len = word.keys.count
        entry.mixed = word.mixed ? true : nil
        entry.end = Self.endKind(word.endedBy)
        let verdict = detector.verdict(word.keys, language: word.language, renderer: renderer)
        entry.verdict = verdict
        if verdict == .fix {
            flagged[word.id] = (word.time, app, word.language, word.keys.count)
        }
        return entry
    }

    private mutating func entry(for rewrite: Rewrite, app: String?) -> JournalEntry {
        rewrite.erasedWordIDs.forEach { flagged.removeValue(forKey: $0) }
        var entry = JournalEntry(t: Date(timeIntervalSince1970: rewrite.time), kind: .rewrite, app: app)
        entry.from = rewrite.erasedLanguage
        entry.to = rewrite.retypedLanguage
        entry.match = Self.match(erased: rewrite.erasedKeys, retyped: rewrite.retypedKeys)
        entry.erased = rewrite.erasedKeys.count
        entry.retyped = rewrite.retypedKeys.count
        entry.late = rewrite.crossedBoundary
        entry.words = rewrite.erasedWordIDs.count
        entry.overflow = rewrite.overflow ? true : nil
        if let typedAt = rewrite.typedAt {
            entry.noticeSec = ((rewrite.erasedAt - typedAt) * 10).rounded() / 10
        }
        if let language = rewrite.erasedLanguage, !rewrite.erasedKeys.isEmpty {
            entry.verdict = detector.verdict(rewrite.erasedKeys, language: language, renderer: renderer)
        }
        if entry.isWrongLayoutFix, let from = entry.from, let to = entry.to {
            let example = "\(renderer.text(rewrite.erasedKeys, language: from)) → \(renderer.text(rewrite.retypedKeys, language: to))"
            recentFixes = Array(([example] + recentFixes).prefix(5))
        }
        return entry
    }

    static func match(erased: [TypedKey], retyped: [TypedKey]) -> String {
        let a = erased.map(\.code), b = retyped.map(\.code)
        guard !a.isEmpty, !b.isEmpty else { return "none" }
        if a == b { return "full" }
        return b.starts(with: a) || a.starts(with: b) ? "prefix" : "none"
    }

    static func endKind(_ endedBy: String) -> String {
        switch endedBy {
        case " ": return "space"
        case "\n": return "enter"
        case "\t": return "tab"
        case "reset": return "reset"
        default: return "punct"
        }
    }
}
