import Foundation

/// A word that was finished (by a space, punctuation, a click…), as physical keys.
struct FinishedWord: Equatable {
    let id: Int
    let keys: [TypedKey]
    /// The layout of the last key; `mixed` = the layout changed inside the word.
    let language: String
    let mixed: Bool
    let endedBy: String
    let time: TimeInterval
}

/// The user erased something and typed again. A rewrite with a layout switch where the retyped
/// keys are the erased keys is the manual "wrong layout" fix this app is here to learn from.
struct Rewrite: Equatable {
    /// Erased letters in typing order (separators left out).
    let erasedKeys: [TypedKey]
    let erasedLanguage: String?
    let erasedWordIDs: [Int]
    /// A space or punctuation was erased too: the word was already finished when noticed.
    let crossedBoundary: Bool
    /// Erased further back than tracked (before a click, from an earlier line…).
    let overflow: Bool
    /// The word typed after erasing (whole word, including keys that were not erased).
    let retypedKeys: [TypedKey]
    let retypedLanguage: String?
    /// When the first erased key was typed and when erasing started.
    let typedAt: TimeInterval?
    let erasedAt: TimeInterval
    let time: TimeInterval
}

enum TrackerOutput: Equatable {
    case word(FinishedWord)
    case rewrite(Rewrite)
}

/// Follows what is being typed into the focused field: words, erasing and retyping. It sees only
/// key presses, so anything that moves the caret (clicks, arrows, shortcuts) resets it.
struct WordTracker {
    private enum Item: Equatable {
        case key(TypedKey, language: String, time: TimeInterval, wordID: Int?)
        case separator(Character)
    }

    private struct Erasing {
        var items: [Item] = []
        var overflow = false
        let startedAt: TimeInterval
    }

    private struct Rewriting {
        let erasing: Erasing
        /// Word keys typed since erasing stopped; backspaces take these first.
        var typed = 0
    }

    let renderer: LayoutRendering
    private var line: [Item] = []
    private var erasing: Erasing?
    private var rewriting: Rewriting?
    private var nextWordID = 1
    private static let maxLine = 400

    init(renderer: LayoutRendering) {
        self.renderer = renderer
    }

    /// A key that types `typed` in layout `language`.
    mutating func key(_ key: TypedKey, typed: String, language: String, time: TimeInterval) -> [TrackerOutput] {
        startRewritingIfErased()
        if renderer.isWordKey(key) {
            line.append(.key(key, language: language, time: time, wordID: nil))
            rewriting?.typed += 1
            trim()
            return []
        }
        // Digits and punctuation that is punctuation in both layouts end the word.
        return separator(typed.first ?? " ", time: time)
    }

    /// Space, return, tab or punctuation.
    mutating func separator(_ character: Character, time: TimeInterval) -> [TrackerOutput] {
        startRewritingIfErased()
        let output = finishWord(endedBy: String(character), time: time)
        line.append(.separator(character))
        trim()
        return output
    }

    mutating func backspace(time: TimeInterval) -> [TrackerOutput] {
        if var current = rewriting {
            if current.typed > 0, !line.isEmpty {
                // Correcting the retyped word itself.
                line.removeLast()
                current.typed -= 1
                rewriting = current
                return []
            }
            // Erased everything retyped so far: back to erasing the original.
            erasing = current.erasing
            rewriting = nil
        }
        var current = erasing ?? Erasing(startedAt: time)
        if let last = line.popLast() {
            current.items.insert(last, at: 0)
        } else {
            current.overflow = true
        }
        erasing = current
        return []
    }

    /// ⌥⌫: trailing separators, then the word before them.
    mutating func deleteWord(time: TimeInterval) -> [TrackerOutput] {
        var count = 0
        var index = line.count - 1
        while index >= 0, case .separator = line[index] { count += 1; index -= 1 }
        while index >= 0, case .key = line[index] { count += 1; index -= 1 }
        for _ in 0..<max(count, 1) { _ = backspace(time: time) }
        return []
    }

    /// The caret may have moved: finish what is open and forget the line.
    mutating func reset(time: TimeInterval) -> [TrackerOutput] {
        startRewritingIfErased()
        let output = finishWord(endedBy: "reset", time: time)
        line = []
        erasing = nil
        rewriting = nil
        return output
    }

    /// Where the caret is relative to typing, for layout switches: wordStart / midWord / afterErase.
    var position: String {
        if erasing != nil { return "afterErase" }
        if case .key = line.last { return "midWord" }
        return "wordStart"
    }

    /// The word being typed (keys since the last separator), when all in one layout and not
    /// erasing. For Caps Lock in the middle of a word.
    var currentWord: (keys: [TypedKey], language: String)? {
        guard erasing == nil else { return nil }
        var keys: [TypedKey] = []
        var languages: Set<String> = []
        for item in line.reversed() {
            guard case let .key(key, language, _, _) = item else { break }
            keys.insert(key, at: 0)
            languages.insert(language)
        }
        guard let language = languages.first, languages.count == 1 else { return nil }
        return (keys, language)
    }

    /// The current word was retyped in `language` (Caps Lock mid-word): its keys now count as
    /// typed there, so the word goes on as one word.
    mutating func retypeCurrentWord(in language: String) {
        var index = line.count - 1
        while index >= 0, case let .key(key, _, time, wordID) = line[index] {
            line[index] = .key(key, language: language, time: time, wordID: wordID)
            index -= 1
        }
    }

    // MARK: - Internals

    private mutating func startRewritingIfErased() {
        if let current = erasing {
            rewriting = Rewriting(erasing: current)
            erasing = nil
        }
    }

    private mutating func finishWord(endedBy: String, time: TimeInterval) -> [TrackerOutput] {
        var start = line.count
        while start > 0, case .key = line[start - 1] { start -= 1 }
        var output: [TrackerOutput] = []
        var keys: [TypedKey] = []
        var languages: [String] = []
        if start < line.count {
            let id = nextWordID
            nextWordID += 1
            for index in start..<line.count {
                guard case let .key(key, language, keyTime, _) = line[index] else { continue }
                line[index] = .key(key, language: language, time: keyTime, wordID: id)
                keys.append(key)
                languages.append(language)
            }
            output.append(.word(FinishedWord(id: id, keys: keys, language: languages.last!,
                                             mixed: Set(languages).count > 1, endedBy: endedBy, time: time)))
        }
        if let current = rewriting {
            output.append(.rewrite(rewrite(from: current.erasing, retyped: keys, language: languages.last, time: time)))
            rewriting = nil
        }
        return output
    }

    private func rewrite(from erasing: Erasing, retyped: [TypedKey], language: String?, time: TimeInterval) -> Rewrite {
        var keys: [TypedKey] = []
        var erasedLanguage: String?
        var wordIDs: [Int] = []
        var typedAt: TimeInterval?
        var crossedBoundary = false
        for item in erasing.items {
            switch item {
            case let .key(key, keyLanguage, keyTime, wordID):
                keys.append(key)
                erasedLanguage = keyLanguage
                typedAt = typedAt ?? keyTime
                if let wordID, !wordIDs.contains(wordID) { wordIDs.append(wordID) }
            case .separator:
                crossedBoundary = true
            }
        }
        return Rewrite(erasedKeys: keys, erasedLanguage: erasedLanguage, erasedWordIDs: wordIDs,
                       crossedBoundary: crossedBoundary, overflow: erasing.overflow,
                       retypedKeys: retyped, retypedLanguage: language,
                       typedAt: typedAt, erasedAt: erasing.startedAt, time: time)
    }

    private mutating func trim() {
        if line.count > Self.maxLine { line.removeFirst(line.count - Self.maxLine) }
    }
}
