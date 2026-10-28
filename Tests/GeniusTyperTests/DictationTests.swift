import Carbon.HIToolbox
import XCTest
@testable import GeniusTyper

final class HybridPressTests: XCTestCase {
    func testHoldIsPushToTalk() {
        var press = HybridPress()
        XCTAssertEqual(press.keyDown(at: 0), .start)
        XCTAssertEqual(press.keyUp(at: 2), .stop)
        XCTAssertFalse(press.isRecording)
    }

    func testTapTogglesUntilNextTap() {
        var press = HybridPress()
        XCTAssertEqual(press.keyDown(at: 0), .start)
        XCTAssertEqual(press.keyUp(at: 0.1), .none)
        XCTAssertTrue(press.isRecording)
        // Second tap stops on the press, its release does nothing.
        XCTAssertEqual(press.keyDown(at: 5), .stop)
        XCTAssertEqual(press.keyUp(at: 5.1), .none)
        XCTAssertFalse(press.isRecording)
    }

    func testLongSecondPressInToggleModeStopsOnce() {
        var press = HybridPress()
        _ = press.keyDown(at: 0)
        _ = press.keyUp(at: 0.1)
        XCTAssertEqual(press.keyDown(at: 3), .stop)
        XCTAssertEqual(press.keyUp(at: 5), .none)
        // And the next press starts again.
        XCTAssertEqual(press.keyDown(at: 6), .start)
    }

    func testTapDuringSlowMicrophoneStartKeepsRecording() {
        var press = HybridPress()
        XCTAssertEqual(press.keyDown(at: 0), .start)
        // The microphone took 0.9 s to start; the release (at 0.1) is handled only after it.
        press.recordingStarted(at: 0.9)
        XCTAssertEqual(press.keyUp(at: 0.92), .none)
        XCTAssertTrue(press.isRecording)
    }

    func testHoldAfterSlowMicrophoneStartIsPushToTalk() {
        var press = HybridPress()
        _ = press.keyDown(at: 0)
        press.recordingStarted(at: 0.9)
        XCTAssertEqual(press.keyUp(at: 2), .stop)
    }

    func testRecordingStartedAfterReleaseChangesNothing() {
        var press = HybridPress()
        _ = press.keyDown(at: 0)
        _ = press.keyUp(at: 0.1)
        press.recordingStarted(at: 0.9)
        XCTAssertEqual(press.keyDown(at: 3), .stop)
    }

    func testKeyRepeatIgnored() {
        var press = HybridPress()
        XCTAssertEqual(press.keyDown(at: 0), .start)
        XCTAssertEqual(press.keyDown(at: 0.5), .none)
        XCTAssertEqual(press.keyUp(at: 1), .stop)
    }

    func testResetAfterCancel() {
        var press = HybridPress()
        _ = press.keyDown(at: 0)
        press.reset()
        XCTAssertEqual(press.keyUp(at: 2), .none)
        XCTAssertEqual(press.keyDown(at: 3), .start)
    }
}

final class ShortcutTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(Shortcut.rightOption.title, "Правый ⌥")
        XCTAssertTrue(Shortcut.rightOption.isModifierOnly)
        let combo = Shortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
        XCTAssertEqual(combo.title, "⌃⌥D")
        XCTAssertFalse(combo.isModifierOnly)
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_Function)).title, "Fn")
    }

    func testSaveAndLoad() {
        let defaults = UserDefaults(suiteName: "DictationTests-\(UUID())")!
        XCTAssertEqual(Shortcut.load(from: defaults), .rightOption)
        let combo = Shortcut(keyCode: UInt16(kVK_F5))
        combo.save(to: defaults)
        XCTAssertEqual(Shortcut.load(from: defaults), combo)
    }

    func testUsableAlone() {
        XCTAssertTrue(Shortcut.isUsableAlone(UInt16(kVK_F5)))
        XCTAssertFalse(Shortcut.isUsableAlone(UInt16(kVK_F18))) // Caps Lock in Genius Switcher
        XCTAssertFalse(Shortcut.isUsableAlone(UInt16(kVK_ANSI_A)))
    }
}

final class WordsTests: XCTestCase {
    func testCount() {
        XCTAssertEqual(Words.count("Привет, мир — это тест"), 4)
        XCTAssertEqual(Words.count("  "), 0)
        XCTAssertEqual(Words.count("asset-ы в метод save 2 раза"), 6)
    }
}

final class HistoryTests: XCTestCase {
    private var url: URL!
    private var history: History!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("diktant-\(UUID()).sqlite")
        history = History(url: url)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func testAddPageSearchDelete() {
        let now = Date()
        history.add(text: "Первая запись", duration: 2, appBundle: "a", appName: "Telegram", model: "Parakeet v3", date: now.addingTimeInterval(-60))
        history.add(text: "Вторая ЗАПИСЬ про Ёлку", duration: 3, appBundle: "b", appName: "Claude", model: "Parakeet v3", date: now)
        let page = history.page(offset: 0, limit: 10)
        XCTAssertEqual(page.map(\.text), ["Вторая ЗАПИСЬ про Ёлку", "Первая запись"])
        XCTAssertEqual(page.first?.words, 4)
        // Case-insensitive for Cyrillic.
        XCTAssertEqual(history.page(search: "запись", offset: 0, limit: 10).count, 2)
        XCTAssertEqual(history.page(search: "ёлку", offset: 0, limit: 10).count, 1)
        XCTAssertEqual(history.page(offset: 1, limit: 1).map(\.text), ["Первая запись"])
        history.delete(id: page[0].id)
        XCTAssertEqual(history.page(offset: 0, limit: 10).count, 1)
    }

    func testStats() {
        let now = Date()
        history.add(text: "раз два три", duration: 6, appBundle: "a", appName: "Telegram", model: "Parakeet v3", date: now)
        history.add(text: "четыре пять", duration: 4, appBundle: "b", appName: "Claude", model: "Groq", date: now)
        history.add(text: "старое", duration: 1, appBundle: "b", appName: "Claude", model: "Groq", date: now.addingTimeInterval(-40 * 86400))
        let all = history.stats(since: nil, now: now)
        XCTAssertEqual(all.words, 6)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.daysActive, 2)
        XCTAssertEqual(all.byApp.first?.name, "Telegram")
        XCTAssertEqual(all.perDay.count, 41)
        XCTAssertEqual(all.perDay.last?.words, 5)
        let week = history.stats(since: Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now)), now: now)
        XCTAssertEqual(week.words, 5)
        XCTAssertEqual(week.perDay.count, 7)
        XCTAssertEqual(week.wordsPerMinute, 30) // 5 words in 10 s
    }

    func testTimeSaved() {
        var stats = Stats()
        stats.words = 21164
        stats.duration = 21164.0 / 85 * 60
        // TypeWhisper showed 3 h 43 min for the same words and speed.
        XCTAssertEqual(stats.timeSaved / 60, 221, accuracy: 3)
    }
}

final class WAVTests: XCTestCase {
    func testHeader() {
        let data = WAV.encode([0, 0.5, -0.5, 1], sampleRate: 16000)
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
    }
}

final class TelegramVoicesTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func put(_ name: String, _ data: Data, age: TimeInterval, account: String = "account-1") throws {
        let media = root.appendingPathComponent("\(account)/postbox/media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let url = media.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func testLatestVoicesNewestFirstSkippingOthers() throws {
        let voice = try Data(contentsOf: Bundle(for: Self.self).url(forResource: "voice", withExtension: "ogg")!)
        try put("telegram-cloud-document-old", voice, age: 300)
        try put("telegram-cloud-document-new", voice, age: 10, account: "account-2")
        try put("telegram-cloud-photo", Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 100)), age: 1)
        try put("telegram-cloud-document-loading", voice, age: 2)
        try put("telegram-cloud-document-loading_partial", voice + voice, age: 2)
        try put("telegram-cloud-document-started_partial", voice, age: 2)
        // A finished download: the file is a hard link to its "_partial" and both stay.
        try put("telegram-cloud-document-done_partial", voice, age: 20)
        let media = root.appendingPathComponent("account-1/postbox/media", isDirectory: true)
        try FileManager.default.linkItem(at: media.appendingPathComponent("telegram-cloud-document-done_partial"),
                                         to: media.appendingPathComponent("telegram-cloud-document-done"))
        try put("accounts-metadata", Data(), age: 0, account: "other")

        let found = TelegramVoices.latest(limit: 3, in: root)
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["telegram-cloud-document-new", "telegram-cloud-document-done", "telegram-cloud-document-old"])
        XCTAssertEqual(found[0].duration, 2.5, accuracy: 2.0)
        XCTAssertEqual(TelegramVoices.latest(limit: 1, in: root).count, 1)

        // Pages: the next call continues after the last file looked at, photos skipped.
        let candidates = TelegramVoices.candidates(in: root)
        let first = TelegramVoices.voices(in: candidates, from: 0, limit: 2)
        XCTAssertEqual(first.files.map(\.url.lastPathComponent), ["telegram-cloud-document-new", "telegram-cloud-document-done"])
        let second = TelegramVoices.voices(in: candidates, from: first.next, limit: 2)
        XCTAssertEqual(second.files.map(\.url.lastPathComponent), ["telegram-cloud-document-old"])
        XCTAssertEqual(second.next, candidates.count)
    }

    func testScanFindsNewVoicesOfTheLastDays() throws {
        let voice = try Data(contentsOf: Bundle(for: Self.self).url(forResource: "voice", withExtension: "ogg")!)
        try put("telegram-cloud-document-stored", voice, age: 60)
        try put("telegram-cloud-document-new", voice, age: 10)
        try put("telegram-cloud-document-week", voice, age: 8 * 86_400)
        try put("telegram-cloud-photo", Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 100)), age: 5)
        let candidates = TelegramVoices.candidates(in: root)
        let stored = candidates.first { $0.url.lastPathComponent.hasSuffix("stored") }!
        let known: Set = [stored.url.path]
        let since = Date().addingTimeInterval(-7 * 86_400)

        let first = TelegramVoices.scan(candidates, since: since, known: known, notVoices: [])
        XCTAssertEqual(first.fresh.map(\.url.lastPathComponent), ["telegram-cloud-document-new"])
        XCTAssertEqual(first.others.count, 1)
        XCTAssertEqual(first.older.map(\.url.lastPathComponent), ["telegram-cloud-document-week"])
        // The photo's header is not read again.
        let second = TelegramVoices.scan(candidates, since: since, known: known, notVoices: Set(first.others))
        XCTAssertEqual(second.others, [])
        XCTAssertEqual(second.fresh.count, 1)
    }

    func testStoredTextsKeptForDaysAndOldFormatRead() throws {
        let now = Date()
        let day: TimeInterval = 86_400
        let texts = [
            VoiceText(path: "/a", date: now.addingTimeInterval(-2 * day), duration: 3, text: "свежее", added: now.addingTimeInterval(-2 * day)),
            VoiceText(path: "/b", date: now.addingTimeInterval(-10 * day), duration: 3, text: "старое", added: now.addingTimeInterval(-10 * day)),
            VoiceText(path: "/c", date: now.addingTimeInterval(-10 * day), duration: 3, text: "по запросу", added: now.addingTimeInterval(-day)),
        ]
        XCTAssertEqual(VoiceText.kept(texts, days: 7, now: now).map(\.text), ["свежее", "по запросу"])
        XCTAssertEqual(VoiceText.kept(texts, days: 1, now: now).map(\.text), ["по запросу"])
        XCTAssertEqual(VoiceText.kept(texts, days: 0, now: now), texts) // forever
        XCTAssertEqual(VoiceText.decode(try JSONEncoder().encode(texts)), texts)

        let old = Data(#"[{"key":"/media/telegram-cloud-document-1|1792000000.123456","text":"привет"}]"#.utf8)
        let migrated = VoiceText.decode(old)
        XCTAssertEqual(migrated.map(\.path), ["/media/telegram-cloud-document-1"])
        XCTAssertEqual(migrated[0].date.timeIntervalSince1970, 1_792_000_000.123456, accuracy: 0.001)
        XCTAssertEqual(migrated[0].text, "привет")
        XCTAssertEqual(migrated[0].key, VoiceText.key(path: "/media/telegram-cloud-document-1", date: Date(timeIntervalSince1970: 1_792_000_000.123456)))
    }

    func testOneStoredTextPerFile() {
        let day = Date(timeIntervalSince1970: 1_792_000_000)
        let first = VoiceText(path: "/a", date: day, duration: 47, text: "первая", added: day)
        let touched = VoiceText(path: "/a", date: day.addingTimeInterval(10), duration: 47, text: "вторая", added: day.addingTimeInterval(400))
        let other = VoiceText(path: "/b", date: day, duration: 3, text: "другое", added: day)
        XCTAssertEqual(VoiceText.unique([first, other, touched]), [other, touched])
        let deleted = VoiceText(path: "/a", date: day, duration: 47, text: "", added: day.addingTimeInterval(100), deleted: true)
        XCTAssertEqual(VoiceText.unique([first, deleted, touched]), [deleted])
        XCTAssertEqual(VoiceText.decode(try! JSONEncoder().encode([deleted, other])), [deleted, other])
    }

    func testDecodesToSixteenKilohertz() throws {
        let url = Bundle(for: Self.self).url(forResource: "voice", withExtension: "ogg")!
        XCTAssertTrue(TelegramVoices.isOggOpus(url))
        let samples = try AudioRecorder.samples(fromFile: url)
        XCTAssertGreaterThan(samples.count, 16_000)
    }
}

final class LevelBarsTests: XCTestCase {
    /// The levels of the owner's recorded voice (`scripts/audio-levels.swift`; the audio is not kept).
    private func ownerLevels() throws -> [CGFloat] {
        let url = Bundle(for: Self.self).url(forResource: "owner-speech-levels", withExtension: "txt")!
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { Double($0) }.map { CGFloat($0) }
    }

    func testSilenceIsFlat() throws {
        let silence = try ownerLevels().filter { $0 < 0.01 }
        XCTAssertGreaterThan(silence.count, 50)
        XCTAssertTrue(silence.allSatisfy { LevelBars.loudness($0) == 0 })
    }

    func testAverageSpeechFillsMostOfTheHeight() throws {
        let speech = try ownerLevels().filter { $0 >= 0.1 }.map(LevelBars.loudness).sorted()
        XCTAssertGreaterThan(speech.count, 150)
        let median = speech[speech.count / 2]
        XCTAssertGreaterThan(median, 0.6)
        XCTAssertLessThan(median, 0.85)
        XCTAssertGreaterThan(speech[speech.count / 10], 0.4)
    }

    func testLoudSpeechReachesTheTopWithoutStickingThere() throws {
        let speech = try ownerLevels().filter { $0 >= 0.1 }.map(LevelBars.loudness)
        XCTAssertEqual(speech.max(), 1)
        XCTAssertLessThan(Double(speech.filter { $0 >= 1 }.count) / Double(speech.count), 0.1)
    }
}

final class LevelScaleTests: XCTestCase {
    private func ownerLevels() throws -> [CGFloat] {
        let url = Bundle(for: Self.self).url(forResource: "owner-speech-levels", withExtension: "txt")!
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { Double($0) }.map { CGFloat($0) }
    }

    /// Runs the levels (12 a second) through `scale` and returns the bar heights.
    private func heights(_ levels: [CGFloat], _ scale: inout LevelScale) -> [CGFloat] {
        levels.map { level in
            scale.update(level, elapsed: 1.0 / 12)
            return scale.loudness(level)
        }
    }

    /// Median and share at the top of the bars that show something.
    private func shape(_ heights: [CGFloat]) -> (median: CGFloat, full: Double) {
        let shown = heights.filter { $0 > 0.05 }.sorted()
        return (shown[shown.count / 2], Double(shown.filter { $0 >= 1 }.count) / Double(shown.count))
    }

    func testStandardIsTheFixedScale() {
        for level in stride(from: CGFloat(0), through: 0.6, by: 0.01) {
            XCTAssertEqual(LevelScale.standard.loudness(level), LevelBars.loudness(level), accuracy: 0.001)
        }
    }

    /// As recorded, 10 dB louder over room noise (AirPods), 4 dB quieter: once the scale has
    /// learnt the microphone (one pass), the bars look alike, and silence stays flat.
    func testBarsLookAlikeOnLouderAndQuieterMicrophones() throws {
        let own = try ownerLevels()
        let cases: [(String, [CGFloat])] = [
            ("as recorded", own),
            ("louder, room noise", own.map { $0 > 0 ? $0 + 0.25 : 0.1 }),
            ("quieter", own.map { $0 > 0 ? max(0, $0 - 0.1) : 0 }),
        ]
        for (name, levels) in cases {
            var scale = LevelScale.standard
            _ = heights(levels, &scale)
            let bars = heights(levels, &scale)
            let (median, full) = shape(bars)
            XCTAssertGreaterThan(median, 0.6, name)
            XCTAssertLessThan(median, 0.85, name)
            XCTAssertLessThanOrEqual(full, 0.12, name)
            let silence = zip(own, bars).filter { $0.0 == 0 }.map(\.1)
            XCTAssertTrue(silence.allSatisfy { $0 == 0 }, name)
        }
        // The fixed scale on the louder microphone: mostly at the top.
        XCTAssertGreaterThan(shape(cases[1].1.map(LevelBars.loudness)).full, 0.4)
    }

    /// The line's amplitude on the same microphones: ordinary speech swings about half way, quiet
    /// syllables hardly at all, few reach the top; the bars' loudness puts speech near the top.
    func testLineSwingsWithLoudAndQuietSpeech() throws {
        let own = try ownerLevels()
        let cases: [(String, [CGFloat])] = [
            ("as recorded", own),
            ("louder, room noise", own.map { $0 > 0 ? $0 + 0.25 : 0.1 }),
            ("quieter", own.map { $0 > 0 ? max(0, $0 - 0.1) : 0 }),
        ]
        for (name, levels) in cases {
            var scale = LevelScale.standard
            _ = heights(levels, &scale)
            var swings: [CGFloat] = []
            var bars: [CGFloat] = []
            for level in levels {
                scale.update(level, elapsed: 1.0 / 12)
                swings.append(scale.amplitude(level))
                bars.append(scale.loudness(level))
            }
            let shown = swings.filter { $0 > 0.05 }.sorted()
            let median = shown[shown.count / 2]
            XCTAssertGreaterThan(median, 0.35, name)
            XCTAssertLessThan(median, 0.6, name)
            XCTAssertLessThan(shown[shown.count / 10], 0.2, name)
            XCTAssertLessThanOrEqual(Double(shown.filter { $0 >= 0.9 }.count) / Double(shown.count), 0.2, name)
            XCTAssertLessThan(median, shape(bars).median - 0.2, name)
            XCTAssertTrue(zip(own, swings).filter { $0.0 == 0 }.allSatisfy { $0.1 == 0 }, name)
        }
    }

    /// A pause does not lower the scale: the next word is not blown up.
    func testPausesKeepTheScale() {
        var scale = LevelScale(floor: 0.1, peak: 0.7)
        for _ in 0..<120 { scale.update(0.1, elapsed: 1.0 / 12) }
        XCTAssertEqual(scale.peak, 0.7, accuracy: 0.001)
        XCTAssertEqual(scale.loudness(0.1), 0)
    }

    /// A peak far above the voice (0.91 was kept for the MacBook microphone, 2026-10-27, and the
    /// line stayed flat): within the first seconds of speech the voice shows again, and it counts
    /// as speech all along, so the corrected scale is kept.
    func testScaleFarAboveTheVoiceComesDown() throws {
        var scale = LevelScale(floor: 0, peak: 0.91)
        let own = try ownerLevels()
        let first = Array(own.prefix(12 * 3))
        XCTAssertGreaterThan(first.filter { scale.isSpeech($0) }.count, first.count / 3)
        let bars = heights(first, &scale)
        XCTAssertGreaterThan(bars.suffix(24).filter { $0 > 0.3 }.count, 3)
        XCTAssertLessThan(scale.peak, 0.75)
        // From then on the voice shows at about the usual height.
        XCTAssertGreaterThan(shape(heights(own, &scale)).median, 0.5)
    }

    /// A noisy room raises the floor; its hiss shows no bars.
    func testNoiseIsFlat() {
        var scale = LevelScale.standard
        for _ in 0..<(12 * 20) { scale.update(0.25, elapsed: 1.0 / 12) }
        XCTAssertEqual(scale.floor, 0.25, accuracy: 0.001)
        XCTAssertEqual(scale.loudness(0.25), 0)
        XCTAssertGreaterThan(scale.loudness(0.45), 0.5)
    }

    func testStoredAsJSON() throws {
        let scales = ["AirPods": LevelScale(floor: 0.1, peak: 0.7)]
        XCTAssertEqual(try JSONDecoder().decode([String: LevelScale].self, from: JSONEncoder().encode(scales)), scales)
    }
}
