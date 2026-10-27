import AppKit
import Compression

/// An animated character above the dictation pill (Настройки → Основное → Анимация): it types
/// while you speak and stops when you pause. The animations are cut out of GIFs by
/// `scripts/make-mascots.swift` into animated PNGs (`scripts/mascots/*.apng`), which
/// `scripts/make-mascot-frames.swift` turns into `Mascots/*.frames`: the size they are shown at,
/// the shadow baked in, raw frames compressed with LZFSE (a PNG frame took ~1 ms to decode, this
/// ~0.15 ms).
enum Mascot: String, CaseIterable, Identifiable {
    /// The monkey and the grey cat were removed on 2026-10-27 (the owner found them poorly cut);
    /// a stored `monkey` / `greyCat` reads as `none`.
    case none, wigCat, bruce

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "Без анимации")
        case .wigCat: String(localized: "Кот в парике")
        case .bruce: String(localized: "Брюс Всемогущий")
        }
    }

    /// The views of the character, one picked at random for each dictation; each view is a slow
    /// loop and, optionally, a fast one it switches to after a few seconds of speech.
    fileprivate var scenes: [[String]] {
        switch self {
        case .none: []
        case .wigCat: [["wig-cat"]]
        // Cut from a green-screen clip with ffmpeg's chromakey (see AGENTS.md), not Vision.
        case .bruce: [["bruce-front-slow", "bruce-front-fast"], ["bruce-side-slow", "bruce-side-fast"]]
        }
    }

    static var current: Mascot { Mascot(rawValue: Prefs.mascot) ?? .none }
}

/// Shows one frame of the animation at a time: the file is memory-mapped (clean pages, not the
/// app's footprint), the frame is decompressed when it is shown and the one before is dropped, so
/// an animation costs one frame of memory (~0.3 MB). The frame timer runs only while it moves:
/// full speed while the voice is heard, then (a pause between words, or the end) it slows down
/// smoothly over `slowDownOver` and stops, so short pauses look like a breath rather than a
/// stutter. With two loops it starts slow and speeds up after `speedUpAfter` of speech; a stop
/// longer than `calmDownAfter` starts slow again.
final class MascotView: NSView {
    /// Room around the figure in the frames for the baked shadow, which may overlap the pill.
    static let shadowPad: CGFloat = 4
    private static let speedUpAfter: TimeInterval = 3
    private static let calmDownAfter: TimeInterval = 1.5
    private static let fullSpeedFor: TimeInterval = 0.2
    private static let slowDownOver: TimeInterval = 1.2
    /// Slower than this, it stops.
    private static let minSpeed = 0.15

    /// One `.frames` file (format in `scripts/make-mascot-frames.swift`).
    private struct Loop {
        let data: Data
        let width: Int
        let height: Int
        let delays: [TimeInterval]
        let ranges: [Range<Int>]
    }

    private let loops: [Loop]
    private var loop = 0
    private var index = 0
    private var timer: Timer?
    private var typingSince = Date.distantPast
    private var stoppedAt = Date.distantPast
    private var lastLoud = Date.distantPast
    /// The speed the pending frame was timed at.
    private var timedAt = 1.0

    init?(_ mascot: Mascot) {
        guard let scene = mascot.scenes.randomElement() else { return nil }
        let loops = scene.compactMap(Self.load)
        guard loops.count == scene.count, let first = loops.first else { return nil }
        self.loops = loops
        // Made for 2× screens: a pixel is half a point.
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(first.width) / 2, height: CGFloat(first.height) / 2))
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        showFrame()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func load(_ name: String) -> Loop? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "frames"),
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count > 16, data.prefix(4) == Data("GTF1".utf8) else { return nil }
        func uint32(_ at: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
        }
        let width = Int(uint32(4)), height = Int(uint32(8)), count = Int(uint32(12))
        guard count > 0, data.count >= 16 + count * 12 else { return nil }
        var delays: [TimeInterval] = [], ranges: [Range<Int>] = []
        for i in 0..<count {
            let entry = 16 + i * 12
            let offset = Int(uint32(entry + 4)), length = Int(uint32(entry + 8))
            guard offset + length <= data.count else { return nil }
            delays.append(max(0.04, TimeInterval(Float32(bitPattern: uint32(entry)))))
            ranges.append(offset..<offset + length)
        }
        return Loop(data: data, width: width, height: height, delays: delays, ranges: ranges)
    }

    /// The microphone level was checked (~12 times a second): `loud` while speaking.
    func heard(loud: Bool) {
        guard loud else { return }
        lastLoud = Date()
        if let timer {
            // Slowed down: a frame may be ~0.5 s away; speak again and it goes on at full speed now.
            guard timedAt < 0.9 else { return }
            timer.invalidate()
        } else if lastLoud.timeIntervalSince(stoppedAt) > Self.calmDownAfter {
            typingSince = lastLoud
        }
        scheduleNext()
    }

    override func removeFromSuperview() {
        timer?.invalidate()
        timer = nil
        super.removeFromSuperview()
    }

    /// 1 while speaking and for `fullSpeedFor` after, then down to 0 over `slowDownOver` (ease in-out).
    private func speed(at now: Date) -> Double {
        let quiet = now.timeIntervalSince(lastLoud) - Self.fullSpeedFor
        guard quiet > 0 else { return 1 }
        let x = min(1, quiet / Self.slowDownOver)
        return 0.5 * (1 + cos(.pi * x))
    }

    private func scheduleNext() {
        let speed = speed(at: Date())
        guard speed >= Self.minSpeed else {
            timer = nil
            stoppedAt = Date()
            return
        }
        timedAt = speed
        let timer = Timer(timeInterval: loops[loop].delays[index] / speed, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wanted = Date().timeIntervalSince(self.typingSince) > Self.speedUpAfter ? self.loops.count - 1 : 0
                if wanted != self.loop {
                    self.loop = wanted
                    self.index = 0
                } else {
                    self.index = (self.index + 1) % self.loops[self.loop].delays.count
                }
                self.showFrame()
                self.scheduleNext()
            }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func showFrame() {
        let current = loops[loop]
        let size = current.width * current.height * 4
        var pixels = Data(count: size)
        let written = pixels.withUnsafeMutableBytes { out in
            current.data[current.ranges[index]].withUnsafeBytes { compressed in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          compressed.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == size, let provider = CGDataProvider(data: pixels as CFData) else { return }
        layer?.contents = CGImage(width: current.width, height: current.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: current.width * 4, space: Self.sRGB,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
}
