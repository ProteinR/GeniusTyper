import XCTest
@testable import GeniusSwitcher

/// Enough of ABC / RussianWin for "ghbdtn" = "привет" and a few punctuation keys.
private struct FakeLayouts: LayoutRendering {
    static let map: [UInt16: (en: Character, ru: Character)] = [
        5: ("g", "п"), 4: ("h", "р"), 11: ("b", "и"), 2: ("d", "в"), 17: ("t", "е"), 45: ("n", "т"),
        31: ("o", "щ"), 40: ("k", "л"),
        47: (".", "ю"), 43: (",", "б"), 44: ("/", "."), 18: ("1", "1"),
    ]
    let languages = ["en", "ru"]

    func character(_ key: TypedKey, language: String) -> Character? {
        guard let pair = Self.map[key.code] else { return nil }
        let char = language == "en" ? pair.en : pair.ru
        return key.shift ? Character(char.uppercased()) : char
    }

    static func keys(_ codes: [UInt16]) -> [TypedKey] {
        codes.map { TypedKey(code: $0, shift: false, caps: false) }
    }
}

private let privet: [UInt16] = [5, 4, 11, 2, 17, 45]

final class WordTrackerTests: XCTestCase {
    private var tracker = WordTracker(renderer: FakeLayouts())
    private var time: TimeInterval = 1000

    override func setUp() {
        tracker = WordTracker(renderer: FakeLayouts())
        time = 1000
    }

    @discardableResult
    private func type(_ codes: [UInt16], _ language: String) -> [TrackerOutput] {
        var outputs: [TrackerOutput] = []
        for key in FakeLayouts.keys(codes) {
            time += 0.1
            let typed = FakeLayouts().character(key, language: language).map(String.init) ?? ""
            outputs += tracker.key(key, typed: typed, language: language, time: time)
        }
        return outputs
    }

    private func backspaces(_ count: Int) {
        for _ in 0..<count {
            time += 0.1
            _ = tracker.backspace(time: time)
        }
    }

    private func space() -> [TrackerOutput] {
        time += 0.1
        return tracker.separator(" ", time: time)
    }

    private func rewrites(_ outputs: [TrackerOutput]) -> [Rewrite] {
        outputs.compactMap { if case let .rewrite(r) = $0 { return r } else { return nil } }
    }

    private func words(_ outputs: [TrackerOutput]) -> [FinishedWord] {
        outputs.compactMap { if case let .word(w) = $0 { return w } else { return nil } }
    }

    func testPlainWord() {
        type(privet, "ru")
        let output = space()
        XCTAssertEqual(words(output).map(\.keys), [FakeLayouts.keys(privet)])
        XCTAssertEqual(words(output).first?.language, "ru")
        XCTAssertTrue(rewrites(output).isEmpty)
    }

    func testFixBeforeSpace() {
        type(privet, "en")
        backspaces(6)
        XCTAssertEqual(tracker.position, "afterErase")
        type(privet, "ru")
        let output = space()
        let rewrite = rewrites(output).first
        XCTAssertEqual(rewrite?.erasedKeys, FakeLayouts.keys(privet))
        XCTAssertEqual(rewrite?.erasedLanguage, "en")
        XCTAssertEqual(rewrite?.retypedLanguage, "ru")
        XCTAssertEqual(rewrite?.crossedBoundary, false)
        XCTAssertEqual(rewrite?.erasedWordIDs, [])
        XCTAssertEqual(words(output).count, 1)
    }

    func testLateFixAfterSpace() {
        type(privet, "en")
        let first = words(space()).first!
        backspaces(7)
        type(privet, "ru")
        let rewrite = rewrites(space()).first
        XCTAssertEqual(rewrite?.crossedBoundary, true)
        XCTAssertEqual(rewrite?.erasedWordIDs, [first.id])
        XCTAssertEqual(rewrite?.erasedKeys.count, 6)
    }

    func testEarlyFixIsPrefix() {
        type([5, 4, 11], "en")
        backspaces(3)
        type(privet, "ru")
        let rewrite = rewrites(space()).first!
        XCTAssertEqual(Recorder.match(erased: rewrite.erasedKeys, retyped: rewrite.retypedKeys), "prefix")
    }

    func testOptionDeleteErasesWordAndSpace() {
        type(privet, "en")
        _ = space()
        _ = tracker.deleteWord(time: time)
        type(privet, "ru")
        let rewrite = rewrites(space()).first
        XCTAssertEqual(rewrite?.erasedKeys.count, 6)
        XCTAssertEqual(rewrite?.crossedBoundary, true)
    }

    func testTypoInRetypedWordKeepsOriginalErase() {
        type(privet, "en")
        backspaces(6)
        type([5, 4, 31], "ru")  // при → прщ, oops
        backspaces(1)
        type([11, 2, 17, 45], "ru")
        let rewrite = rewrites(space()).first
        XCTAssertEqual(rewrite?.erasedKeys, FakeLayouts.keys(privet))
        XCTAssertEqual(rewrite?.retypedKeys, FakeLayouts.keys([5, 4, 11, 2, 17, 45]))
    }

    func testBackspaceOnEmptyLineIsOverflow() {
        backspaces(2)
        type([31, 40], "en")
        XCTAssertEqual(rewrites(space()).first?.overflow, true)
    }

    func testCommaInEnglishIsPartOfWordButSlashIsNot() {
        type([31, 40, 43], "en")  // "ok," – the comma key is "б"
        XCTAssertEqual(tracker.position, "midWord")
        let output = type([44], "ru")  // "." in Russian is on the "/" key: ends the word
        XCTAssertEqual(words(output).first?.keys.count, 3)
        XCTAssertEqual(tracker.position, "wordStart")
    }

    func testMixedLanguageWord() {
        type([5, 4], "en")
        type([11, 2], "ru")
        XCTAssertEqual(words(space()).first?.mixed, true)
    }

    func testCurrentWordRetypedMidWordStaysOneWord() {
        type([5, 4, 11], "en")
        XCTAssertEqual(tracker.currentWord?.keys.count, 3)
        XCTAssertEqual(tracker.currentWord?.language, "en")
        tracker.retypeCurrentWord(in: "ru")
        type([2, 17, 45], "ru")
        let finished = words(space())
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.keys.count, 6)
        XCTAssertEqual(finished.first?.language, "ru")
        XCTAssertEqual(finished.first?.mixed, false)
        XCTAssertNil(tracker.currentWord)
    }

    func testResetFinishesOpenRewrite() {
        type(privet, "en")
        backspaces(6)
        time += 0.1
        let output = tracker.reset(time: time)
        XCTAssertEqual(rewrites(output).first?.retypedKeys, [])
        XCTAssertEqual(tracker.position, "wordStart")
    }
}

final class DetectorTests: XCTestCase {
    private let detector = LayoutDetector { word, language in
        let known: [String: Set<String>] = ["ru": ["привет", "ок"], "en": ["ok", "hello"]]
        return known[language]?.contains(word.lowercased()) == true
    }

    func testVerdicts() {
        let renderer = FakeLayouts()
        XCTAssertEqual(detector.verdict(FakeLayouts.keys(privet), language: "en", renderer: renderer), .fix)
        XCTAssertEqual(detector.verdict(FakeLayouts.keys(privet), language: "ru", renderer: renderer), .keep)
        XCTAssertEqual(detector.verdict(FakeLayouts.keys([31, 40]), language: "en", renderer: renderer), .keep)
        XCTAssertEqual(detector.verdict(FakeLayouts.keys([31]), language: "en", renderer: renderer), .skip)
        XCTAssertEqual(detector.verdict(FakeLayouts.keys([5, 4]), language: "en", renderer: renderer), .unknown)
    }

    func testTrailingPunctuationIsTrimmed() {
        // "ok," typed in English: the comma is not part of the word.
        XCTAssertEqual(detector.verdict(FakeLayouts.keys([31, 40, 43]), language: "en", renderer: FakeLayouts()), .keep)
    }

    func testScriptAndCase() {
        XCTAssertTrue(LayoutDetector.isScript("привет", "ru"))
        XCTAssertFalse(LayoutDetector.isScript("git", "ru"))
        XCTAssertFalse(LayoutDetector.isScript("привет", "en"))
        XCTAssertTrue(LayoutDetector.isMixedCase("camelCase"))
        XCTAssertFalse(LayoutDetector.isMixedCase("Hello"))
        XCTAssertFalse(LayoutDetector.isMixedCase("NASA"))
    }
}

final class RecorderTests: XCTestCase {
    private let renderer = FakeLayouts()

    private func recorder() -> Recorder {
        Recorder(renderer: renderer, detector: LayoutDetector { word, _ in ["привет", "ok"].contains(word) })
    }

    func testWrongLayoutFixIsCountedAndCaught() {
        var recorder = recorder()
        let rewrite = Rewrite(erasedKeys: FakeLayouts.keys(privet), erasedLanguage: "en", erasedWordIDs: [],
                              crossedBoundary: false, overflow: false, retypedKeys: FakeLayouts.keys(privet),
                              retypedLanguage: "ru", typedAt: 10, erasedAt: 11.24, time: 13)
        let entry = recorder.record([.rewrite(rewrite)], app: "app").first!
        XCTAssertTrue(entry.isWrongLayoutFix)
        XCTAssertEqual(entry.match, "full")
        XCTAssertEqual(entry.verdict, .fix)
        XCTAssertEqual(entry.noticeSec, 1.2)
        XCTAssertEqual(recorder.recentFixes, ["ghbdtn → привет"])
        var stats = DayStats()
        stats.add(entry)
        XCTAssertEqual(stats.wrongLayoutFixes, 1)
        XCTAssertEqual(stats.detectorCaught, 1)
    }

    func testEntriesHaveNoText() throws {
        var recorder = recorder()
        let word = FinishedWord(id: 1, keys: FakeLayouts.keys(privet), language: "en", mixed: false, endedBy: " ", time: 5)
        let entry = recorder.record([.word(word)], app: "app").first!
        let json = String(data: try JSONEncoder().encode(entry), encoding: .utf8)!
        XCTAssertFalse(json.contains("ghbdtn"))
        XCTAssertFalse(json.contains("привет"))
        XCTAssertTrue(json.contains("\"len\":6"))
    }

    func testFlaggedWordLeftAloneBecomesFalseAlarm() {
        var recorder = recorder()
        let word = FinishedWord(id: 7, keys: FakeLayouts.keys(privet), language: "en", mixed: false, endedBy: " ", time: 100)
        _ = recorder.record([.word(word)], app: nil)
        XCTAssertTrue(recorder.expire(now: 110).isEmpty)
        XCTAssertEqual(recorder.expire(now: 121).map(\.kind), [.flagKept])
    }

    func testFlaggedWordFixedIsNotFalseAlarm() {
        var recorder = recorder()
        let word = FinishedWord(id: 7, keys: FakeLayouts.keys(privet), language: "en", mixed: false, endedBy: " ", time: 100)
        _ = recorder.record([.word(word)], app: nil)
        let rewrite = Rewrite(erasedKeys: FakeLayouts.keys(privet), erasedLanguage: "en", erasedWordIDs: [7],
                              crossedBoundary: true, overflow: false, retypedKeys: FakeLayouts.keys(privet),
                              retypedLanguage: "ru", typedAt: 100, erasedAt: 102, time: 104)
        _ = recorder.record([.rewrite(rewrite)], app: nil)
        XCTAssertTrue(recorder.expire(now: 200).isEmpty)
    }

    func testTypoIsNotWrongLayout() {
        var stats = DayStats()
        var entry = JournalEntry(t: Date(), kind: .rewrite)
        entry.from = "ru"
        entry.to = "ru"
        entry.match = "prefix"
        stats.add(entry)
        XCTAssertEqual(stats.typoFixes, 1)
        XCTAssertEqual(stats.wrongLayoutFixes, 0)
    }
}

final class AutoFixTests: XCTestCase {
    private let detector = LayoutDetector { word, _ in ["привет", "ok"].contains(word) }

    func testWholeWordVerdictForAutoFix() {
        // "ghbdtn," : trimmed it is "привет" (journal says fix), but every key converted gives
        // "приветб", so the auto-fixer must leave it.
        let keys = FakeLayouts.keys(privet + [43])
        XCTAssertEqual(detector.verdict(keys, language: "en", renderer: FakeLayouts()), .fix)
        XCTAssertNotEqual(detector.verdict(keys, language: "en", renderer: FakeLayouts(), trimEdges: false), .fix)
        XCTAssertEqual(detector.verdict(FakeLayouts.keys(privet), language: "en", renderer: FakeLayouts(), trimEdges: false), .fix)
    }

    func testExceptionsStoreNoText() {
        var exceptions = FixExceptions()
        exceptions.add(FakeLayouts.keys(privet), language: "en")
        XCTAssertTrue(exceptions.contains(FakeLayouts.keys(privet), language: "en"))
        XCTAssertFalse(exceptions.contains(FakeLayouts.keys(privet), language: "ru"))
        // Case does not matter: the same keys with Shift are the same word.
        XCTAssertTrue(exceptions.contains(privet.map { TypedKey(code: $0, shift: true, caps: false) }, language: "en"))
        let stored = exceptions.hashes.first!
        XCTAssertEqual(stored.count, 24)
        XCTAssertFalse(stored.contains("5,4"))
    }

    func testAbbreviationsAreSkipped() {
        XCTAssertTrue(LayoutDetector.isAbbreviation("RTL"))
        XCTAssertTrue(LayoutDetector.isAbbreviation("ГОСТ"))
        XCTAssertFalse(LayoutDetector.isAbbreviation("Rtl"))
        XCTAssertFalse(LayoutDetector.isAbbreviation("GHBDTN"))
        let caps = privet.map { TypedKey(code: $0, shift: true, caps: false) }
        XCTAssertEqual(detector.verdict(Array(caps.prefix(3)), language: "en", renderer: FakeLayouts()), .skip)
    }

    func testUserExceptions() {
        let exceptions = UserExceptions(text: "Привет\n  ok, git;\n\n(кто-то)\nprivet\nпривет")
        XCTAssertEqual(exceptions.words, ["git", "ok", "privet", "кто-то", "привет"])
        XCTAssertTrue(exceptions.contains("ПРИВЕТ,"))
        XCTAssertFalse(exceptions.contains("..."))
        // Matched as typed: "привет" typed in Russian is an exception, "ghbdtn" typed in English is not.
        XCTAssertTrue(exceptions.contains(FakeLayouts.keys(privet), language: "ru", renderer: FakeLayouts()))
        XCTAssertFalse(exceptions.contains(FakeLayouts.keys(privet), language: "en", renderer: FakeLayouts()))
        XCTAssertTrue(exceptions.contains(FakeLayouts.keys(privet + [44]), language: "ru", renderer: FakeLayouts()))
    }

    func testUserExceptionsAddRemove() {
        var exceptions = UserExceptions(words: ["rtl"])
        exceptions.add("Ctx, rtl")
        XCTAssertEqual(exceptions.words, ["ctx", "rtl"])
        exceptions.remove("rtl")
        XCTAssertEqual(exceptions.words, ["ctx"])
    }

    func testSkipCounterSuggestsOnSecondSkip() {
        var counter = SkipCounter()
        XCTAssertFalse(counter.register("a"))
        XCTAssertFalse(counter.register("b"))
        XCTAssertTrue(counter.register("a"))
        // Starts over after a suggestion.
        XCTAssertFalse(counter.register("a"))
        XCTAssertTrue(counter.register("a"))
    }

    func testNoFixAfterEnterOrReset() {
        XCTAssertTrue(AutoFixRules.fixes(after: " "))
        XCTAssertTrue(AutoFixRules.fixes(after: "."))
        XCTAssertFalse(AutoFixRules.fixes(after: "\n"))
        XCTAssertFalse(AutoFixRules.fixes(after: "reset"))
    }

    func testStatsCountAutoFixes() {
        var stats = DayStats()
        stats.add(JournalEntry(t: Date(), kind: .autoFix))
        stats.add(JournalEntry(t: Date(), kind: .autoFix))
        stats.add(JournalEntry(t: Date(), kind: .autoUndo))
        XCTAssertEqual(stats.autoFixes, 2)
        XCTAssertEqual(stats.autoUndos, 1)
    }

    func testAutoFixedWordIsNotFalseAlarm() {
        var recorder = Recorder(renderer: FakeLayouts(), detector: detector)
        let word = FinishedWord(id: 3, keys: FakeLayouts.keys(privet), language: "en", mixed: false, endedBy: " ", time: 100)
        _ = recorder.record([.word(word)], app: nil)
        recorder.markAutoFixed(3)
        XCTAssertTrue(recorder.expire(now: 200).isEmpty)
    }
}

final class ClipboardTests: XCTestCase {
    private func item(_ text: String, bytes: Int = 0, kind: ClipboardItem.Kind = .text) -> ClipboardItem {
        ClipboardItem(id: UUID(), date: Date(), kind: kind, app: nil, text: text,
                      stored: bytes > 0 ? ["public.rtf": bytes] : [:], hash: "\(kind):\(text)")
    }

    func testNewestOnTopAndSameContentMoves() {
        var items: [ClipboardItem] = []
        for text in ["a", "b", "c"] { items = ClipboardRules.insert(item(text), into: items, limit: 1000).items }
        XCTAssertEqual(items.map(\.text), ["c", "b", "a"])
        let again = ClipboardRules.insert(item("a"), into: items, limit: 1000)
        XCTAssertEqual(again.items.map(\.text), ["a", "c", "b"])
        XCTAssertEqual(again.removed.map(\.text), ["a"])
    }

    func testSizeLimitDropsOldest() {
        var items: [ClipboardItem] = []
        for text in ["1", "2", "3"] { items = ClipboardRules.insert(item(text, bytes: 399), into: items, limit: 1000).items }
        // 400 bytes each (399 + 1 letter): two fit in 1000.
        XCTAssertEqual(items.map(\.text), ["3", "2"])
        // An entry bigger than the limit still stays, alone.
        let big = ClipboardRules.insert(item("big", bytes: 5000), into: items, limit: 1000)
        XCTAssertEqual(big.items.map(\.text), ["big"])
        XCTAssertEqual(big.removed.count, 2)
    }

    func testSeedPhrasesAreSecret() {
        let words = Array(repeating: "abandon", count: 11) + ["about"]
        XCTAssertTrue(ClipboardRules.isSecret(words.joined(separator: " ")))
        XCTAssertFalse(ClipboardRules.isSecret("git push origin main"))
    }

    func testSearchAllWordsAnyCase() {
        let entry = item("Привет, мир! Hello World")
        XCTAssertTrue(ClipboardRules.matches(entry, query: "hello мир", alternative: nil))
        XCTAssertFalse(ClipboardRules.matches(entry, query: "hello bye", alternative: nil))
    }

    func testSearchInWrongLayout() {
        let renderer = FakeLayouts()
        XCTAssertEqual(ClipboardRules.retyped("ghbdtn", renderer: renderer), "привет")
        XCTAssertEqual(ClipboardRules.retyped("ПРИВЕТ", renderer: renderer), "GHBDTN")
        XCTAssertNil(ClipboardRules.retyped("123", renderer: renderer))
        let entry = item("скажи привет")
        let alternative = ClipboardRules.retyped("ghbdtn", renderer: renderer)
        XCTAssertTrue(ClipboardRules.matches(entry, query: "ghbdtn", alternative: alternative))
    }

    func testTitles() {
        XCTAssertEqual(item("  first\nsecond  ").title, "first ⏎ second")
        XCTAssertEqual(item("/a/b.txt\n/c/d.png", kind: .files).title, "b.txt и ещё 1")
    }
}

final class YoficatorTests: XCTestCase {
    /// The real dictionary from the app bundle (the test host).
    private let yo = Yoficator.shared

    func testRestoresAlwaysYoWords() {
        XCTAssertEqual(yo.restore("еще"), "ещё")
        XCTAssertEqual(yo.restore("ее"), "её")
        XCTAssertEqual(yo.restore("елка"), "ёлка")
        XCTAssertEqual(yo.restore("идет"), "идёт")
    }

    func testLeavesAmbiguousAndPlainWords() {
        XCTAssertNil(yo.restore("все"))
        XCTAssertNil(yo.restore("узнаем"))
        XCTAssertNil(yo.restore("привет"))
        XCTAssertNil(yo.restore("hello"))
        XCTAssertNil(yo.restore("ещё"))
    }

    func testCase() {
        XCTAssertEqual(yo.restore("Еще"), "Ещё")
        XCTAssertEqual(yo.restore("ЕЩЕ"), "ЕЩЁ")
        XCTAssertEqual(yo.restore("Артем"), "Артём")
        XCTAssertEqual(yo.restore("АРТЕМ"), "АРТЁМ")
        // Names only with a capital letter; mixed case is left alone.
        XCTAssertNil(yo.restore("артем"))
        XCTAssertNil(yo.restore("еЩе"))
    }

    func testLowercaseOnlyForms() {
        let dictionary = Yoficator(dictionary: Data("ёлка\nкиёв*\n".utf8))
        XCTAssertEqual(dictionary.restore("киев"), "киёв")
        XCTAssertNil(dictionary.restore("Киев"))
        XCTAssertEqual(dictionary.restore("Елка"), "Ёлка")
        XCTAssertNil(Yoficator(dictionary: Data()).restore("еще"))
    }

    /// Every form in the file is found again (the sort order matches the search).
    func testWholeDictionaryIsSearchable() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "yo", withExtension: "txt"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 100_000)
        for line in lines where !line.hasSuffix("*") {
            let form = String(line)
            let plain = form.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
            XCTAssertEqual(yo.restore(plain), form)
        }
    }
}
