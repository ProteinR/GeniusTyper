import AVFoundation

/// Records the default microphone into 16 kHz mono samples (what Parakeet and Whisper take).
/// The audio engine exists only while recording: built on start, torn down on stop, so idle
/// Genius Typer holds no audio resources and the microphone indicator goes off.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// Loudness 0…1, about 12 times a second, on the main thread (for the indicator).
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                             channels: 1, interleaved: false)!

    var isRecording: Bool { engine != nil }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "GeniusTyper", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Нет микрофона")])
        }
        converter = AVAudioConverter(from: format, to: outputFormat)
        lock.withLock { samples.removeAll(keepingCapacity: false); samples.reserveCapacity(Int(Self.sampleRate) * 20) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        Log.info("Recording from \(Self.inputName) (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)", "audio")
    }

    /// Stops and returns everything recorded.
    @discardableResult
    func stop() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
        let result = lock.withLock {
            let result = samples
            samples = []
            return result
        }
        return result
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
        let level = Self.level(of: chunk)
        if let onLevel {
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    /// 16 kHz samples per level: the tap takes 4096 frames of the 48 kHz microphone.
    static let levelChunk = 1365

    /// Loudness 0…1 of one chunk. Speech is ~0.02–0.2 RMS: a log scale makes quiet speech visible.
    static func level(of chunk: UnsafeBufferPointer<Float>) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for value in chunk { sum += value * value }
        let rms = (sum / Float(chunk.count)).squareRoot()
        return max(0, min(1, (20 * log10(max(rms, 1e-5)) + 50) / 40))
    }

    /// The levels the indicator would get for these samples (for tests on a recorded voice).
    static func levels(of samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer { all in
            stride(from: 0, to: all.count, by: levelChunk).map { start in
                level(of: UnsafeBufferPointer(rebasing: all[start..<min(start + levelChunk, all.count)]))
            }
        }
    }

    /// A whole audio file as 16 kHz mono samples (for `--transcribe-file`).
    static func samples(fromFile url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / file.processingFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// The default input, which the engine records from (the level scale is kept per name).
    static var inputName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "default input"
    }
}
