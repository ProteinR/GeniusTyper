import AppKit

/// The dictation cycle: key press → record (the model loads meanwhile) → release or second press →
/// transcribe → paste into the app that was in front → history.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase: Equatable {
        case idle, recording, transcribing
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { onPhase?(phase) }
    }
    var onPhase: ((Phase) -> Void)?

    private var press = HybridPress()
    private let recorder = AudioRecorder()
    private var startedAt = Date()
    private var targetApp: NSRunningApplication?
    private var job: Task<Void, Never>?

    /// Shorter recordings are a slip of the finger: dropped without a sound.
    static let minimumDuration: TimeInterval = 0.3

    /// The "Диктовка" switch. Off: the keys are no longer watched and the model leaves memory.
    func setEnabled(_ on: Bool) {
        Prefs.dictationEnabled = on
        if on {
            start()
            let store = EngineStore.shared
            if store.selected.isLocal, store.local == .missing { store.downloadLocal(store.selected) }
            if AudioRecorder.permission == .notDetermined { Task { _ = await AudioRecorder.requestPermission() } }
        } else {
            cancel(reason: "dictation off")
            HotkeyMonitor.shared.stop()
            VoicePanel.shared.close()
            EngineStore.shared.unloadNow()
        }
        Log.info("Dictation \(on ? "on" : "off")", "dictation")
    }

    func start() {
        let keys = HotkeyMonitor.shared
        keys.onPress = { [weak self] in self?.keyDown() }
        keys.onRelease = { [weak self] in self?.keyUp() }
        keys.onEscape = { [weak self] in self?.cancel(reason: "Esc") }
        keys.onChord = { [weak self] in self?.cancel(reason: "chord") }
        keys.onVoices = { VoicePanel.shared.toggle() }
        recorder.onLevel = { Indicator.shared.level($0) }
        keys.start()
    }

    private func keyDown() {
        let now = ProcessInfo.processInfo.systemUptime
        if phase == .transcribing { return } // one at a time
        switch press.keyDown(at: now) {
        case .start: begin()
        case .stop: finish()
        case .none: break
        }
    }

    private func keyUp() {
        if press.keyUp(at: ProcessInfo.processInfo.systemUptime) == .stop { finish() }
    }

    private func begin() {
        if let problem = EngineStore.shared.problem {
            press.reset()
            Indicator.shared.show(.message(problem))
            Log.warning("Dictation not started: \(problem)", "dictation")
            return
        }
        guard AudioRecorder.permission != .denied, AudioRecorder.permission != .restricted else {
            press.reset()
            Indicator.shared.show(.message(String(localized: "Нет доступа к микрофону")))
            return
        }
        if AudioRecorder.permission == .notDetermined {
            press.reset()
            Task { _ = await AudioRecorder.requestPermission() }
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        let pressed = ProcessInfo.processInfo.systemUptime
        do {
            try recorder.start()
        } catch {
            press.reset()
            Indicator.shared.show(.message(String(localized: "Микрофон не запустился")))
            Log.error("Recording failed to start: \(Log.describe(error))", "dictation")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - pressed > 0.3 { Log.info(String(format: "Microphone took %.2f s to start", now - pressed), "audio") }
        press.recordingStarted(at: now)
        let started = Date()
        startedAt = started
        phase = .recording
        HotkeyMonitor.shared.watchKeys(true)
        // A modifier may turn out to be ⌥+key a moment later: no sound or pill for that.
        let delay = HotkeyMonitor.shared.shortcut.isModifierOnly ? 0.15 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                guard self.phase == .recording, self.startedAt == started else { return }
                Sounds.play(.start)
                Indicator.shared.show(.recording(since: started), microphone: AudioRecorder.inputName)
            }
        }
        EngineStore.shared.prepare()
        Log.info("Recording into \(targetApp?.localizedName ?? "?")", "dictation")
    }

    /// `-saveDictationAudio <file.wav>` (a launch argument): each dictation's audio is written
    /// there, as recorded (16 kHz mono), for tests on a real voice. Never on otherwise.
    private func saveAudioIfAsked(_ samples: [Float]) {
        guard let path = UserDefaults.standard.string(forKey: "saveDictationAudio") else { return }
        do {
            try WAV.encode(samples, sampleRate: Int(AudioRecorder.sampleRate)).write(to: URL(fileURLWithPath: path))
            let levels = AudioRecorder.levels(of: samples).sorted()
            let percentile = { (p: Double) in levels.isEmpty ? 0 : levels[min(levels.count - 1, Int(Double(levels.count) * p))] }
            Log.info(String(format: "Audio saved to %@: levels p10 %.2f, p50 %.2f, p90 %.2f, max %.2f", path,
                            percentile(0.1), percentile(0.5), percentile(0.9), levels.last ?? 0), "dictation")
        } catch {
            Log.error("Audio not saved: \(Log.describe(error))", "dictation")
        }
    }

    private func finish() {
        guard phase == .recording else { return }
        HotkeyMonitor.shared.watchKeys(false)
        let samples = recorder.stop()
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        saveAudioIfAsked(samples)
        guard duration >= Self.minimumDuration else {
            phase = .idle
            Indicator.shared.hide()
            Log.info(String(format: "Recording too short (%.2f s): dropped", duration), "dictation")
            return
        }
        phase = .transcribing
        Indicator.shared.show(.transcribing)
        let target = targetApp
        let model = EngineStore.shared.currentModelName
        job = Task {
            let start = Date()
            do {
                let raw = try await EngineStore.shared.transcribe(samples)
                guard !Task.isCancelled else { return }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = Prefs.dictationYo ? Yoficator.shared.restoreText(trimmed) : trimmed
                Log.info(String(format: "Transcribed %.1f s of audio in %.2f s: %d words", duration,
                                Date().timeIntervalSince(start), Words.count(text)), "dictation")
                phase = .idle
                if text.isEmpty {
                    Sounds.play(.failure)
                    Indicator.shared.show(.message(String(localized: "Ничего не распознано")))
                    return
                }
                Indicator.shared.hide()
                if Paster.paste(text) {
                    Sounds.play(.success)
                } else {
                    Sounds.play(.failure)
                    Indicator.shared.show(.message(String(localized: "Текст в буфере: нет доступа «Универсальный доступ»")))
                }
                History.shared.add(text: text, duration: duration, appBundle: target?.bundleIdentifier ?? "",
                                   appName: target?.localizedName ?? "", model: model)
            } catch {
                phase = .idle
                Sounds.play(.failure)
                Indicator.shared.show(.message(String(localized: "Ошибка распознавания")))
                Log.error("Transcription failed: \(Log.describe(error))", "dictation")
            }
            Memory.giveBackSoon()
        }
    }

    /// Esc, or the dictation modifier turned out to be part of a shortcut (⌥+key).
    private func cancel(reason: String) {
        guard phase == .recording else { return }
        HotkeyMonitor.shared.watchKeys(false)
        recorder.stop()
        press.reset()
        phase = .idle
        Indicator.shared.hide()
        if reason == "Esc" { Sounds.play(.cancel) }
        Log.info("Recording cancelled (\(reason))", "dictation")
    }
}

/// Short sounds (switch "Звуки"): start (a Funk-like bass blip of our own), text pasted (a soft
/// ding of our own; both from `scripts/make-sounds.swift`), failure (nothing recognised, error,
/// no paste), Esc.
enum Sounds {
    enum Kind { case start, success, failure, cancel }

    private static let start = own("start")
    private static let success = own("success")

    private static func own(_ name: String) -> NSSound? {
        Bundle.main.url(forResource: name, withExtension: "wav")
            .flatMap { NSSound(contentsOf: $0, byReference: true) }
    }

    static func play(_ kind: Kind) {
        guard Prefs.sounds else { return }
        let sound: NSSound?
        switch kind {
        case .start: sound = start
        case .success: sound = success
        case .failure: sound = NSSound(named: "Pop")
        case .cancel: sound = NSSound(named: "Funk")
        }
        sound?.stop()
        sound?.play()
    }
}
