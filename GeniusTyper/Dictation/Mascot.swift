import AppKit
import ImageIO

/// An animated character above the dictation pill (Настройки → Основное → Анимация): it types
/// while you speak and stops when you pause. The animations are cut out of GIFs by
/// `scripts/make-mascots.swift` into animated PNGs (`Mascots/*.apng`; not .png, so Xcode does not
/// recompress them and drop the animation).
enum Mascot: String, CaseIterable, Identifiable {
    case none, monkey, greyCat, wigCat, bruce

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "Без анимации")
        case .monkey: String(localized: "Обезьяна")
        case .greyCat: String(localized: "Серый кот")
        case .wigCat: String(localized: "Кот в парике")
        case .bruce: String(localized: "Брюс Всемогущий")
        }
    }

    /// The views of the character, one picked at random for each dictation; each view is a slow
    /// loop and, optionally, a fast one it switches to after a few seconds of speech.
    fileprivate var scenes: [[String]] {
        switch self {
        case .none: []
        case .monkey: [["monkey"]]
        case .greyCat: [["grey-cat"]]
        case .wigCat: [["wig-cat"]]
        // Cut from a green-screen clip with ffmpeg's chromakey (see AGENTS.md), not Vision.
        case .bruce: [["bruce-front-slow", "bruce-front-fast"], ["bruce-side-slow", "bruce-side-fast"]]
        }
    }

    static var current: Mascot { Mascot(rawValue: Prefs.mascot) ?? .none }
}

/// Shows one frame of the animation at a time: the frame is decoded when it is shown and the one
/// before is dropped, so a 44-frame animation costs one frame of memory. The frame timer runs only
/// while it moves: full speed while the voice is heard, then (a pause between words, or the end)
/// it slows down smoothly over `slowDownOver` and stops, so short pauses look like a breath rather
/// than a stutter. With two loops it starts slow and speeds up after `speedUpAfter` of speech; a
/// stop longer than `calmDownAfter` starts slow again.
final class MascotView: NSView {
    static let height: CGFloat = 96
    private static let speedUpAfter: TimeInterval = 3
    private static let calmDownAfter: TimeInterval = 1.5
    private static let fullSpeedFor: TimeInterval = 0.2
    private static let slowDownOver: TimeInterval = 1.2
    /// Slower than this, it stops.
    private static let minSpeed = 0.15

    private struct Loop {
        let source: CGImageSource
        let delays: [TimeInterval]
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
        guard loops.count == scene.count,
              let props = CGImageSourceCopyPropertiesAtIndex(loops[0].source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        self.loops = loops
        super.init(frame: NSRect(x: 0, y: 0, width: (width * Self.height / height).rounded(), height: Self.height))
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        showFrame()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func load(_ name: String) -> Loop? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "apng"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let delays = (0..<CGImageSourceGetCount(source)).map { i in
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let delay = (png?[kCGImagePropertyAPNGUnclampedDelayTime] ?? png?[kCGImagePropertyAPNGDelayTime]) as? Double
            return max(0.04, delay ?? 0.08)
        }
        return Loop(source: source, delays: delays)
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
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        layer?.contents = CGImageSourceCreateImageAtIndex(loops[loop].source, index, options)
    }
}
