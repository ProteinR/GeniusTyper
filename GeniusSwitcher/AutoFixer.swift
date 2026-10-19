import CryptoKit
import CoreGraphics
import Foundation

/// Types on the user's behalf: erases the word just typed and types it in the other layout.
/// Needs the Accessibility permission (posting keyboard events).
enum KeyPoster {
    /// Marks Genius Switcher's own events, so its key tap ignores them.
    static let marker: Int64 = 0x5357_4954  // "SWIT"

    static var canPost: Bool { CGPreflightPostEventAccess() }

    /// `count` backspaces, then `text` as Unicode (independent of the selected layout).
    static func replace(deleting count: Int, with text: String) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            post(source: source, keyCode: 51, text: nil)
        }
        for character in text {
            post(source: source, keyCode: 0, text: String(character))
        }
    }

    /// ⌘V: pastes what the clipboard history has just put on the pasteboard.
    static func pressPaste() {
        post(source: CGEventSource(stateID: .privateState), keyCode: 9, text: nil, flags: .maskCommand)
    }

    private static func post(source: CGEventSource?, keyCode: CGKeyCode, text: String?, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Words the user undid an auto-fix for: never fixed again. Stored as hashes of the key codes, not
/// as text.
struct FixExceptions {
    private(set) var hashes: Set<String>

    init(hashes: Set<String> = []) {
        self.hashes = hashes
    }

    static func hash(_ keys: [TypedKey], language: String) -> String {
        let text = language + ":" + keys.map { String($0.code) }.joined(separator: ",")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func contains(_ keys: [TypedKey], language: String) -> Bool {
        hashes.contains(Self.hash(keys, language: language))
    }

    mutating func add(_ keys: [TypedKey], language: String) {
        hashes.insert(Self.hash(keys, language: language))
    }
}

/// The user's own exceptions dictionary: words typed as is are never auto-fixed ("git", "ок",
/// names). Unlike `FixExceptions` this is text: the user typed it in the panel. It lives in the
/// settings only, never in the journal.
struct UserExceptions: Equatable {
    /// Lowercased, without punctuation at the edges, sorted, no duplicates.
    private(set) var words: [String]

    init(words: [String] = []) {
        self.words = Array(Set(words.compactMap(Self.normalize))).sorted()
    }

    /// One word per line; commas, semicolons and spaces separate words too.
    init(text: String) {
        self.init(words: text.components(separatedBy: CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)))
    }

    var text: String { words.joined(separator: "\n") }

    /// Several words at once are fine ("rtl, ctx").
    mutating func add(_ text: String) {
        self = UserExceptions(words: words + UserExceptions(text: text).words)
    }

    mutating func remove(_ word: String) {
        words.removeAll { $0 == word }
    }

    func contains(_ word: String) -> Bool {
        Self.normalize(word).map { words.contains($0) } ?? false
    }

    /// The word as typed, in the layout it was typed in.
    func contains(_ keys: [TypedKey], language: String, renderer: LayoutRendering) -> Bool {
        contains(renderer.text(keys, language: language))
    }

    static func normalize(_ word: String) -> String? {
        let core = word.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased()
        return core.isEmpty ? nil : core
    }
}

/// Counts how often the user kept a word the auto-fixer wanted to fix (⇧+Space), to suggest adding
/// it to the exceptions. Memory only, keyed by `FixExceptions.hash`.
struct SkipCounter {
    static let threshold = 2
    private var counts: [String: Int] = [:]

    /// True when the word reached the threshold (then it starts over).
    mutating func register(_ hash: String) -> Bool {
        let count = counts[hash, default: 0] + 1
        counts[hash] = count < Self.threshold ? count : 0
        return count >= Self.threshold
    }
}

/// What the auto-fixer changed last, so Caps Lock right after it can put it back.
struct LastFix {
    let keys: [TypedKey]
    let originalLanguage: String
    let fixedLanguage: String
    /// What was on screen before (word + separator as typed) and after the fix.
    let original: String
    let fixed: String
    let time: TimeInterval
    /// Caps Lock within this time, with no key typed in between, undoes the fix.
    static let undoWindow: TimeInterval = 5
}

enum AutoFixRules {
    /// Separators after which a word is fixed. Not Enter: the message is usually sent already.
    static func fixes(after endedBy: String) -> Bool {
        endedBy != "\n" && endedBy != "\t" && endedBy != "reset"
    }

    /// Terminals and code editors: auto-fix off by default (commands, identifiers); the journal
    /// still runs there.
    static let defaultOff: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.dt.Xcode",
        "com.microsoft.VSCode", "com.jetbrains.goland", "com.google.antigravity", "com.google.antigravity-ide",
    ]
}
