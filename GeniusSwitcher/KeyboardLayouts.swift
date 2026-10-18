import Carbon
import Foundation

/// A physical key press: the same key gives "g" in English and "п" in Russian, so words are kept as
/// keys and rendered in either layout afterwards.
struct TypedKey: Equatable, Codable {
    let code: UInt16
    let shift: Bool
    let caps: Bool
}

/// The two layouts being switched between (here ABC and RussianWin): what each key types in each.
protocol LayoutRendering {
    /// "en" / "ru".
    var languages: [String] { get }
    func character(_ key: TypedKey, language: String) -> Character?
}

extension LayoutRendering {
    func other(than language: String) -> String? {
        languages.first { $0 != language }
    }

    func text(_ keys: [TypedKey], language: String) -> String {
        String(keys.compactMap { character($0, language: language) })
    }

    /// A key that types a letter in at least one layout belongs to a word: "," in English is "б"
    /// in Russian, so it cannot end a word.
    func isWordKey(_ key: TypedKey) -> Bool {
        languages.contains { character(key, language: $0)?.isLetter == true }
    }

    /// Which layout typed `typed` with this key, when only one of them gives that character.
    func language(typing typed: String, with key: TypedKey) -> String? {
        let matches = languages.filter { character(key, language: $0).map(String.init) == typed }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// The enabled keyboard layouts of the system, read through Text Input Sources and `UCKeyTranslate`.
final class SystemLayouts: LayoutRendering {
    private struct Layout {
        let id: String
        let language: String
        let data: Data
    }

    private var layouts: [Layout] = []
    private var cache: [String: Character?] = [:]

    init() {
        reload()
    }

    var languages: [String] { layouts.map(\.language) }

    var summary: String { layouts.map { "\($0.language)=\($0.id)" }.joined(separator: ", ") }

    /// Picks one enabled layout per language, the first English and the first Russian one.
    func reload() {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        let sources = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        var found: [Layout] = []
        for source in sources {
            guard let id = Self.string(source, kTISPropertyInputSourceID),
                  let language = (Self.value(source, kTISPropertyInputSourceLanguages) as? [String])?.first.map({ String($0.prefix(2)) }),
                  ["en", "ru"].contains(language), !found.contains(where: { $0.language == language }),
                  let data = Self.value(source, kTISPropertyUnicodeKeyLayoutData) as? Data else { continue }
            found.append(Layout(id: id, language: language, data: data))
        }
        layouts = found
        cache = [:]
        Log.info("Layouts: \(summary)", "layouts")
    }

    /// The language of the layout selected right now ("en" / "ru"), nil for anything else.
    func currentLanguage() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = Self.string(source, kTISPropertyInputSourceID) else { return nil }
        return layouts.first { $0.id == id }?.language
    }

    func layoutID(for language: String) -> String? {
        layouts.first { $0.language == language }?.id
    }

    func character(_ key: TypedKey, language: String) -> Character? {
        let cacheKey = "\(language)-\(key.code)-\(key.shift)-\(key.caps)"
        if let cached = cache[cacheKey] { return cached }
        guard let layout = layouts.first(where: { $0.language == language }) else { return nil }
        let result = layout.data.withUnsafeBytes { buffer -> Character? in
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let modifiers = UInt32((key.shift ? shiftKey : 0) | (key.caps ? alphaLock : 0)) >> 8 & 0xFF
            let status = UCKeyTranslate(pointer, key.code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).first
        }
        cache[cacheKey] = result
        return result
    }

    private static func value(_ source: TISInputSource, _ key: CFString) -> Any? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        value(source, key) as? String
    }
}
