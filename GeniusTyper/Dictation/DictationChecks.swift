import AppKit

/// Dictation checks from launch arguments (`--dictation-stress-test`, `--transcribe-file`).
extension AppDelegate {
    /// `--dictation-stress-test`: three rounds of opening every page of the settings window, then loading and
    /// transcribing 5 s of silence with the local model and unloading it, logging the memory
    /// footprint after each step. Growing every round = a leak.
    @MainActor
    func runDictationStressTest() {
        var cycle = 0
        @MainActor func round() {
            guard cycle < 3 else {
                Log.info("Stress test done: footprint \(Self.footprintMB()) MB", "stress")
                return
            }
            cycle += 1
            var pages = SettingsPage.allCases
            @MainActor func nextPage() {
                guard !pages.isEmpty else {
                    SettingsWindow.shared.close()
                    model()
                    return
                }
                let page = pages.removeFirst()
                let start = CACurrentMediaTime()
                SettingsWindow.shared.show(page: page)
                SettingsWindow.shared.layoutNow()
                let took = (CACurrentMediaTime() - start) * 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated {
                        Log.info(String(format: "Stress round %d: %@ opened in %.0f ms, footprint %@ MB", cycle, page.rawValue, took, Self.footprintMB()), "stress")
                        nextPage()
                    }
                }
            }
            @MainActor func model() {
                guard ParakeetEngine.isDownloaded(EngineStore.shared.selected) else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { round() } }
                    return
                }
                Task { @MainActor in
                    let start = Date()
                    let text = (try? await EngineStore.shared.transcribe([Float](repeating: 0, count: 16_000 * 5))) ?? "error"
                    let helper = await EngineStore.shared.parakeet.helperFootprintMB ?? 0
                    Log.info(String(format: "Stress round %d: model loaded and ran in %.2f s (\"%@\"), footprint %@ MB + helper %.1f MB", cycle,
                                    Date().timeIntervalSince(start), text, Self.footprintMB(), helper), "stress")
                    EngineStore.shared.unloadNow()
                    try? await Task.sleep(for: .seconds(4))
                    Log.info("Stress round \(cycle): model unloaded, footprint \(Self.footprintMB()) MB", "stress")
                    round()
                }
            }
            nextPage()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                Log.info("Stress test start: footprint \(Self.footprintMB()) MB", "stress")
                round()
            }
        }
    }

    /// `--indicator-test`: the dictation pill in each level style (no animation), then with each
    /// animation (bars), 10 s of speech at the owner's levels (0.15–0.36, now and then louder, 12
    /// times a second) and 2 s of quiet, logging the CPU time the app used and the footprint for
    /// each; then one more round of all of them (growing = a leak). WindowServer's share is
    /// measured from outside (`ps -o time= -p <WindowServer>`), the log has the times.
    @MainActor
    func runIndicatorTest() {
        let savedMascot = Prefs.mascot, savedStyle = Prefs.levelStyle
        let round = LevelStyle.allCases.map { ($0, Mascot.none) } + Mascot.allCases.filter { $0 != .none }.map { (LevelStyle.bars, $0) }
        var queue = round + round
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        @MainActor func next() {
            guard !queue.isEmpty else {
                Prefs.mascot = savedMascot
                Prefs.levelStyle = savedStyle
                Log.info("Indicator test done: footprint \(Self.footprintMB()) MB", "test")
                return
            }
            let (style, mascot) = queue.removeFirst()
            let name = mascot == .none ? style.rawValue : "\(style.rawValue)+\(mascot.rawValue)"
            Prefs.levelStyle = style.rawValue
            Prefs.mascot = mascot.rawValue
            let cpu = cpuSeconds(), started = Date()
            Log.info("Indicator test \(name) start", "test")
            Indicator.shared.show(.recording(since: started))
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let elapsed = Date().timeIntervalSince(started)
                    guard elapsed < 12 else {
                        timer.invalidate()
                        let used = cpuSeconds() - cpu
                        Log.info(String(format: "Indicator test %@: %.2f s CPU in 12 s (%.1f %%), footprint %@ MB", name,
                                        used, used / 12 * 100, Self.footprintMB()), "test")
                        Indicator.shared.hide()
                        Memory.giveBackSoon()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { next() } }
                        return
                    }
                    let speech = Float.random(in: 0.15...0.36) + (Float.random(in: 0...1) < 0.15 ? 0.1 : 0)
                    Indicator.shared.level(elapsed < 10 ? speech : 0)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                Log.info("Indicator test start: footprint \(Self.footprintMB()) MB", "test")
                next()
            }
        }
    }

    /// `--transcribe-file <audio>`: transcribes a file with the current engine (no microphone, no
    /// paste) and logs the text, the time and the footprint; for checking the model on prepared
    /// speech (`say -v Milena -o test.aiff "…"`).
    @MainActor
    func transcribeFile(_ path: String) {
        Task { @MainActor in
            do {
                let samples = try AudioRecorder.samples(fromFile: URL(fileURLWithPath: path))
                Log.info("Transcribe file: \(path), \(samples.count / 16_000) s, footprint \(Self.footprintMB()) MB", "test")
                for run in 1...2 {
                    let start = Date()
                    let text = try await EngineStore.shared.transcribe(samples)
                    let helper = await EngineStore.shared.parakeet.helperFootprintMB ?? 0
                    Log.info(String(format: "Transcribe file run %d: %.2f s, footprint %@ MB + helper %.1f MB: %@", run,
                                    Date().timeIntervalSince(start), Self.footprintMB(), helper, text), "test")
                }
            } catch {
                Log.error("Transcribe file failed: \(Log.describe(error))", "test")
            }
        }
    }
}
