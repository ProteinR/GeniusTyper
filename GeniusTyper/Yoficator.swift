import Foundation

/// Puts ё back where it is always right: "еще" → "ещё", "Артем" → "Артём" (as Caramba's
/// "Ёфикатор"). Only words with one possible spelling: "все"/"всё", "узнаем"/"узнаём" are not in
/// the dictionary and stay as typed.
///
/// The dictionary is `yo.txt` (`scripts/make-yo-dictionary.py`, from eyo-kernel, MIT): ~107 000
/// forms, 2.5 MB, memory-mapped and binary-searched, so it costs no heap.
struct Yoficator {
    static let shared: Yoficator = {
        guard let url = Bundle.main.url(forResource: "yo", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            Log.warning("yo.txt missing: ё is not restored", "yo")
            return Yoficator(dictionary: Data())
        }
        return Yoficator(dictionary: data)
    }()

    /// Sorted lines (see the script); a trailing "*" = only in lowercase.
    private let dictionary: Data

    init(dictionary: Data) {
        self.dictionary = dictionary
    }

    /// The word with ё, or nil when it has none to restore. Lowercase words match lowercase forms,
    /// capitalized ones also names, all-caps ones come back all-caps.
    func restore(_ word: String) -> String? {
        guard word.contains(where: { $0 == "е" || $0 == "Е" }),
              !word.contains(where: { $0 == "ё" || $0 == "Ё" }) else { return nil }
        if let found = lookup(word) { return found.form }
        let lower = word.lowercased()
        if word == Self.capitalized(lower) {
            if let found = lookup(lower), !found.lowercaseOnly { return Self.capitalized(found.form) }
        } else if word.count > 1, word == word.uppercased() {
            if let found = lookup(lower) ?? lookup(Self.capitalized(lower)) { return found.form.uppercased() }
        }
        return nil
    }

    /// Every word of a text (dictation): "Еще раз, Артем" → "Ещё раз, Артём". Words are runs of
    /// letters, so "кое-что" is two words and punctuation stays where it was.
    func restoreText(_ text: String) -> String {
        var result = ""
        var word = ""
        func flush() {
            result += restore(word) ?? word
            word = ""
        }
        for character in text {
            if character.isLetter {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    private static func capitalized(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst()
    }

    /// `key` has е only; lines are compared with their ё read as е.
    private func lookup(_ key: String) -> (form: String, lowercaseOnly: Bool)? {
        let key = Array(key.utf8)
        return dictionary.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> (String, Bool)? in
            var low = 0, high = bytes.count  // lines starting in low..<high
            while low < high {
                var start = (low + high) / 2
                while start > low, bytes[start - 1] != 0x0A { start -= 1 }
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                let lowercaseOnly = end > start && bytes[end - 1] == 0x2A  // "*"
                let line = UnsafeRawBufferPointer(rebasing: bytes[start..<(lowercaseOnly ? end - 1 : end)])
                switch Self.compare(line, key) {
                case .orderedSame: return (String(decoding: line, as: UTF8.self), lowercaseOnly)
                case .orderedAscending: low = end + 1
                case .orderedDescending: high = start
                }
            }
            return nil
        }
    }

    /// Byte order with ё (D1 91) read as е (D0 B5) and Ё (D0 81) as Е (D0 95): same length, so
    /// only the bytes themselves change.
    private static func compare(_ line: UnsafeRawBufferPointer, _ key: [UInt8]) -> ComparisonResult {
        var index = 0
        while index < line.count, index < key.count {
            var byte = line[index]
            if index + 1 < line.count {
                let pair = (line[index], line[index + 1])
                if pair == (0xD1, 0x91) || pair == (0xD0, 0x81) { byte = 0xD0 }
            }
            if index > 0 {
                let pair = (line[index - 1], line[index])
                if pair == (0xD1, 0x91) { byte = 0xB5 } else if pair == (0xD0, 0x81) { byte = 0x95 }
            }
            if byte != key[index] { return byte < key[index] ? .orderedAscending : .orderedDescending }
            index += 1
        }
        return line.count == key.count ? .orderedSame : line.count < key.count ? .orderedAscending : .orderedDescending
    }
}
