import AppKit

/// What the future auto-switcher would do with a word. For now it only runs "in the shadow": its
/// verdicts are compared with what the user actually did.
enum Verdict: String, Codable {
    /// Valid in the layout it was typed in, not in the other one.
    case keep
    /// Not a word as typed, a word in the other layout: would be switched.
    case fix
    /// A word in both layouts (often short ones).
    case ambiguous
    /// A word in neither (names, code, typos).
    case unknown
    /// Too short, or mixed case like camelCase: not judged.
    case skip
}

/// Detector v0: macOS spell checking in both layouts, plus a script check (the Russian spell
/// checker accepts Latin words like "ok" and "git", the English one ignores Cyrillic).
struct LayoutDetector {
    /// word, language ("en"/"ru") → known word.
    let isWord: (String, String) -> Bool

    static let system = LayoutDetector { word, language in
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// `trimEdges`: punctuation at the edges as typed ("ok," "(hello") is not part of the word.
    /// The auto-fixer converts every key, so it judges the whole word (`false`): "ghbdtn," would
    /// become "приветб".
    func verdict(_ keys: [TypedKey], language: String, renderer: LayoutRendering, trimEdges: Bool = true) -> Verdict {
        guard let other = renderer.other(than: language) else { return .skip }
        let typedChars = keys.map { renderer.character($0, language: language) }
        guard let first = typedChars.firstIndex(where: { $0?.isLetter == true }),
              let last = typedChars.lastIndex(where: { $0?.isLetter == true }) else { return .skip }
        let core = trimEdges ? Array(keys[first...last]) : keys
        guard core.count >= 2 else { return .skip }
        let typed = renderer.text(core, language: language)
        let alternative = renderer.text(core, language: other)
        if Self.isMixedCase(typed) || Self.isAbbreviation(typed) { return .skip }

        let typedValid = Self.isScript(typed, language) && isWord(typed, language)
        let otherValid = Self.isScript(alternative, other) && Self.hasVowel(alternative) && isWord(alternative, other)
        switch (typedValid, otherValid) {
        case (true, false): return .keep
        case (false, true): return .fix
        case (true, true): return .ambiguous
        case (false, false): return .unknown
        }
    }

    /// The auto-fixer's decision: a `fix` verdict, unless the word is short and the words just
    /// before it in the line (`before`, nearest first) are real words typed in the same layout.
    /// "сделай мне ии": "ии" is meant, the user is writing Russian (2026-10-26: ии, смс, мд, сиви,
    /// вифи were all in the exceptions). One word of context is not enough: "ok ns" is still "ok ты".
    func fixes(_ keys: [TypedKey], language: String, before: [(keys: [TypedKey], language: String)],
               renderer: LayoutRendering) -> Bool {
        guard verdict(keys, language: language, renderer: renderer, trimEdges: false) == .fix else { return false }
        guard keys.count <= Self.shortWord else { return true }
        let context = before.prefix(2)
        return !(context.count == 2 && context.allSatisfy {
            $0.language == language && verdict($0.keys, language: language, renderer: renderer) == .keep
        })
    }

    /// Up to this many keys a word is "short" for `fixes(_:language:before:renderer:)`.
    static let shortWord = 4

    /// Caps Lock in the middle of a word retypes the letters in the other layout, unless they
    /// already are a word where they were typed: then Caps Lock only switches, for what comes next
    /// ("пишут" + Caps Lock + ":" must stay "пишут:", not become "gbien:", 2026-10-20).
    func retypesOnCapsLock(_ keys: [TypedKey], language: String, renderer: LayoutRendering) -> Bool {
        verdict(keys, language: language, renderer: renderer) != .keep
    }

    static func isScript(_ word: String, _ language: String) -> Bool {
        word.unicodeScalars.allSatisfy { scalar in
            switch language {
            case "ru": return (0x0400...0x04FF).contains(scalar.value) || scalar == "-"
            case "en": return scalar.isASCII && (CharacterSet.letters.contains(scalar) || scalar == "'" || scalar == "-")
            default: return false
            }
        }
    }

    /// A word needs a vowel ("y" counts: "my", "gym"). The English spell checker accepts runs of
    /// consonants like "bb", "cvc", "vl" (from "ии", "смс", "мд"), which made them look like English.
    static func hasVowel(_ word: String) -> Bool {
        word.lowercased().contains { "aeiouyаеёиоуыэюя".contains($0) }
    }

    /// "RTL", "DTO", "API": all capitals, 2–5 letters, typed on purpose. "КЕД" for "RTL" is a word,
    /// so without this rule abbreviations get "fixed".
    static func isAbbreviation(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return (2...5).contains(letters.count) && letters.allSatisfy(\.isUppercase)
    }

    /// "camelCase", "iPhone": typed on purpose, not judged. "Hello" and "NASA" are fine.
    static func isMixedCase(_ word: String) -> Bool {
        let rest = word.dropFirst()
        return rest.contains { $0.isUppercase } && rest.contains { $0.isLowercase }
    }
}
