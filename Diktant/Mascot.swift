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

    fileprivate var resource: String? {
        switch self {
        case .none: nil
        case .monkey: "monkey"
        case .greyCat: "grey-cat"
        case .wigCat: "wig-cat"
        case .bruce: "bruce"
        }
    }

    static var current: Mascot { Mascot(rawValue: Prefs.mascot) ?? .none }
}

/// Shows one frame of the animation at a time: the frame is decoded when it is shown and the one
/// before is dropped, so a 44-frame animation costs one frame of memory. The frame timer runs only
/// while `typing` is true.
final class MascotView: NSView {
    static let height: CGFloat = 96

    private let source: CGImageSource
    private let delays: [TimeInterval]
    private var index = 0
    private var timer: Timer?

    init?(_ mascot: Mascot) {
        guard let name = mascot.resource,
              let url = Bundle.main.url(forResource: name, withExtension: "apng"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        self.source = source
        delays = (0..<CGImageSourceGetCount(source)).map { i in
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let delay = (png?[kCGImagePropertyAPNGUnclampedDelayTime] ?? png?[kCGImagePropertyAPNGDelayTime]) as? Double
            return max(0.04, delay ?? 0.08)
        }
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

    var typing = false {
        didSet {
            guard typing != oldValue else { return }
            if typing { scheduleNext() } else { timer?.invalidate(); timer = nil }
        }
    }

    override func removeFromSuperview() {
        typing = false
        super.removeFromSuperview()
    }

    private func scheduleNext() {
        let timer = Timer(timeInterval: delays[index], repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.typing else { return }
                self.index = (self.index + 1) % self.delays.count
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
        layer?.contents = CGImageSourceCreateImageAtIndex(source, index, options)
    }
}
