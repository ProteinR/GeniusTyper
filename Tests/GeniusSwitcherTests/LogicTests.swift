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
