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
        let otherValid = Self.isScript(alternative, other) && isWord(alternative, other)
        switch (typedValid, otherValid) {
        case (true, false): return .keep
        case (false, true): return .fix
        case (true, true): return .ambiguous
        case (false, false): return .unknown
        }
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
