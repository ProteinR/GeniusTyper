import AppKit

/// The small dark pill at the bottom centre of the screen (TypeWhisper's "Overlay", "Classic"
/// theme): red dot and level bars while recording (no timer since 2026-10-27: the bars got its place); "Распознаю…" while transcribing; a
/// short message otherwise; the chosen `Mascot` above it while recording and transcribing.
/// Plain AppKit drawing, no SwiftUI. The window exists only while shown:
/// it is built on show and released on hide, and its timer runs only then.
@MainActor
final class Indicator {
    static let shared = Indicator()

    enum State: Equatable {
        case recording(since: Date)
        case transcribing
        case message(String)
    }

    private var panel: NSPanel?
    private var pill: PillView?
    private var mascot: MascotView?
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var demoTimer: Timer?
    /// The level bars' scale while recording, learnt from the levels (`LevelScale`); kept for
    /// `microphone` when the recording ends (the demo and tests have none: nothing is kept).
    private var scale = LevelScale.standard
    private var microphone: String?
    private var lastLevel: CFTimeInterval = 0
    private var speechSeconds: Double = 0

    func show(_ state: State, microphone: String? = nil) {
        hideWork?.cancel()
        hideWork = nil
        let pill = makeIfNeeded()
        if case .recording = pill.state, case .recording = state {} else { endRecording() }
        if case .recording = state, pill.state != state {
            self.microphone = microphone
            scale = microphone.flatMap { Prefs.levelScales[$0] } ?? .standard
            lastLevel = CACurrentMediaTime()
            speechSeconds = 0
        }
        pill.state = state
        if case .recording = state { pill.bars.reset(style: LevelStyle.current) }
        if case .message = state {
            removeMascot()
        } else if mascot == nil, let view = MascotView(Mascot.current) {
            panel?.contentView?.addSubview(view)
            panel?.hasShadow = false // a stale shadow of the previous frame would stay around
            mascot = view
        }
        place()
        startTimer(for: state)
        if case .message = state {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }

    /// Microphone level 0…1 (about 12 times a second while recording).
    func level(_ value: Float) {
        guard let pill, case .recording = pill.state else { return }
        let now = CACurrentMediaTime()
        let elapsed = min(0.25, now - lastLevel)
        lastLevel = now
        let level = CGFloat(value)
        scale.update(level, elapsed: elapsed)
        let loudness = scale.loudness(level)
        if loudness > 0.3 { speechSeconds += elapsed }
        pill.bars.push(loudness)
        mascot?.heard(loud: loudness > 0.8)
    }

    /// The recording is over: keep what the scale learnt for this microphone, if it heard speech.
    private func endRecording() {
        guard let microphone, speechSeconds >= 1 else { return }
        self.microphone = nil
        Prefs.levelScales[microphone] = scale
        Log.info(String(format: "Level scale for %@: floor %.2f, peak %.2f", microphone, scale.floor, scale.peak), "dictation")
    }

    /// The pill as when dictating, with made-up speech at the owner's levels (silence 0, speech
    /// 0.15–0.36, now and then louder): 1.5 s talking, 1 s silent, 6 s in all.
    /// For choosing the animation in the settings and for `--indicator-demo`.
    func demo() {
        demoTimer?.invalidate()
        let started = Date()
        show(.recording(since: started))
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let elapsed = Date().timeIntervalSince(started)
                // A real dictation started meanwhile: leave it alone.
                guard let self, elapsed < 6, self.pill?.state == .recording(since: started) else {
                    timer.invalidate()
                    if elapsed >= 6, self?.pill?.state == .recording(since: started) { self?.hide() }
                    return
                }
                let talking = elapsed.truncatingRemainder(dividingBy: 2.5) < 1.5
                self.level(talking ? Float.random(in: 0.15...0.36) + (Float.random(in: 0...1) < 0.15 ? 0.1 : 0) : 0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        endRecording()
        timer?.invalidate()
        timer = nil
        removeMascot()
        pill?.bars.stopAnimating()
        panel?.orderOut(nil)
        panel = nil
        pill = nil
    }

    private func makeIfNeeded() -> PillView {
        if let pill { return pill }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 34), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let pill = PillView(frame: panel.contentLayoutRect)
        panel.contentView = NSView(frame: panel.contentLayoutRect)
        panel.contentView?.addSubview(pill)
        self.panel = panel
        self.pill = pill
        return pill
    }

    private func removeMascot() {
        mascot?.removeFromSuperview()
        mascot = nil
        panel?.hasShadow = true
    }

    /// Bottom centre of the screen with the pointer, above the Dock; the mascot above the pill.
    private func place() {
        guard let panel, let pill else { return }
        let pillSize = pill.fittingSize
        var size = pillSize
        if let mascot {
            size.width = max(size.width, mascot.frame.width)
            size.height += mascot.frame.height + 2 - MascotView.shadowPad
            mascot.setFrameOrigin(NSPoint(x: ((size.width - mascot.frame.width) / 2).rounded(), y: pillSize.height + 2 - MascotView.shadowPad))
        }
        pill.frame = NSRect(x: ((size.width - pillSize.width) / 2).rounded(), y: 0, width: pillSize.width, height: pillSize.height)
        pill.placeBars()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 24, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private func startTimer(for state: State) {
        timer?.invalidate()
        timer = nil
        let interval: TimeInterval
        switch state {
        case .transcribing: interval = 0.3 // the dots
        case .recording, .message: return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let pill = self.pill else { return }
                pill.tick += 1
                let width = pill.frame.width
                if pill.fittingSize.width != width { self.place() }
                pill.needsDisplay = true
            }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// The pill: background, dot and text, drawn once per state ("Распознаю…" a few times a second for
/// its dots). The level bars are their own layers, so their motion never redraws the pill.
private final class PillView: NSView {
    var state: Indicator.State = .transcribing {
        didSet {
            needsDisplay = true
            if case .recording = state { bars.isHidden = false } else { bars.isHidden = true; bars.stopAnimating() }
        }
    }
    let bars = BarsView(frame: NSRect(x: 0, y: 0, width: LevelStyle.bars.width, height: BarsView.maxHeight))
    var tick = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(bars)
        bars.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeBars()
    }

    func placeBars() {
        bars.setFrameOrigin(NSPoint(x: bounds.width - 14 - bars.frame.width + 1, y: ((bounds.height - bars.frame.height) / 2).rounded()))
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let textAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.95, alpha: 1)]

    override var isFlipped: Bool { false }

    private var text: String {
        switch state {
        case .recording:
            return ""
        case .transcribing:
            return String(localized: "Распознаю") + String(repeating: ".", count: tick % 4)
        case .message(let message):
            return message
        }
    }

    override var fittingSize: NSSize {
        let textWidth: CGFloat
        switch state {
        case .recording: return NSSize(width: 14 + 8 + 8 + bars.frame.width + 14, height: 38)
        case .transcribing: textWidth = ((String(localized: "Распознаю") + "...") as NSString).size(withAttributes: Self.textAttributes).width
        case .message: textWidth = (text as NSString).size(withAttributes: Self.textAttributes).width
        }
        return NSSize(width: ceil(14 + 8 + 8 + textWidth + 14), height: 38)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(white: 0.09, alpha: 0.96).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        path.lineWidth = 1
        path.stroke()

        var x: CGFloat = 14
        let midY = rect.midY
        switch state {
        case .recording:
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: midY - 4, width: 8, height: 8)).fill()
        case .transcribing:
            NSColor(white: 0.8, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: midY - 4, width: 8, height: 8)).fill()
        case .message:
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: midY - 4, width: 8, height: 8)).fill()
        }
        x += 16
        let string = text as NSString
        let size = string.size(withAttributes: Self.textAttributes)
        string.draw(at: NSPoint(x: x, y: midY - size.height / 2), withAttributes: Self.textAttributes)
    }
}

/// The microphone level in the pill, drawn in the chosen `LevelStyle`.
/// Bars: newest on the right; a flat white line until the first sound (asked 2026-10-26: dots,
/// dim bars and bars filling in one by one all read as "wait, loading"), then bars to the end,
/// the quiet ones short bars, not dots. Wave: 28 thin bars scrolling, like Voice Memos. Line: a
/// smooth oscilloscope line that swings with the voice. All three move 60 times a second while
/// recording (the line at 30 moved half as fast as the preview the owner chose, 2026-10-26; bars
/// and wave jumping 12 times a second, once per level, looked late and jerky next to the line,
/// 2026-10-27): the bars and the wave glide left at a steady speed, the newest one on the right
/// follows the voice at once. Since the timer was dropped (2026-10-27) they fill its place: 14 bars,
/// 28 thin ones, a 75-point line, each moving as fast as before (points a second), so the longer
/// row only shows more of the past.
/// Every style is Core Animation layers: a bar is a `CALayer` whose frame changes, the line a
/// `CAShapeLayer` whose path changes; the view itself never draws.
private final class BarsView: NSView {
    static let maxHeight: CGFloat = 30
    static let quietHeight: CGFloat = 10
    static let lineHeight: CGFloat = 2

    private var style = LevelStyle.bars
    private var heardSound = false
    private var smooth: CGFloat = 0
    private var target: CGFloat = 0
    private var phase: CGFloat = 0
    private var trace: [CGFloat] = []
    /// Loudness 0…1 of the bars, oldest first: one more than fit, the newest coming in on the right.
    private var columns: [CGFloat] = []
    /// How far the bars have moved left since the last new one, 0 up to one spacing.
    private var offset: CGFloat = 0
    private var lastStep: CFTimeInterval = 0
    private var animation: Timer?
    private var lineLayer: CAShapeLayer?
    private var barLayers: [CALayer] = []
    private var flatLayer: CALayer?

    private static let color = NSColor(white: 0.95, alpha: 1).cgColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset(style: LevelStyle) {
        self.style = style
        setFrameSize(NSSize(width: style.width, height: Self.maxHeight))
        columns = Array(repeating: 0, count: style.historyCount + 1)
        offset = 0
        trace = Array(repeating: 0, count: LevelStyle.traceCount)
        heardSound = false
        smooth = 0
        target = 0
        stopAnimating()
        lineLayer?.removeFromSuperlayer()
        lineLayer = nil
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers = []
        flatLayer?.removeFromSuperlayer()
        flatLayer = nil
        switch style {
        case .bars, .wave:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let radius: CGFloat = style == .bars ? 1.5 : 1
            barLayers = columns.map { _ in
                let bar = CALayer()
                bar.backgroundColor = Self.color
                bar.cornerRadius = radius
                layer?.addSublayer(bar)
                return bar
            }
            if style == .bars {
                let flat = CALayer()
                flat.backgroundColor = Self.color
                flat.cornerRadius = Self.lineHeight / 2
                flat.frame = CGRect(x: 0, y: bounds.height / 2 - Self.lineHeight / 2, width: bounds.width - 2, height: Self.lineHeight)
                layer?.addSublayer(flat)
                flatLayer = flat
            }
            CATransaction.commit()
            updateBars()
        case .line:
            let layer = CAShapeLayer()
            layer.frame = bounds
            layer.fillColor = nil
            layer.strokeColor = Self.color
            layer.lineWidth = 2
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer?.addSublayer(layer)
            lineLayer = layer
            updateLine()
        }
        startAnimating()
    }

    /// How loud, 0…1 of the height (`LevelScale.loudness`).
    func push(_ loudness: CGFloat) {
        if loudness > 0 { heardSound = true }
        target = loudness
    }

    func stopAnimating() {
        animation?.invalidate()
        animation = nil
    }

    private func startAnimating() {
        lastStep = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        timer.tolerance = 1.0 / 240
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    /// One frame: the layers get new frames or a new path, which Core Animation draws, so the view
    /// itself is never redrawn (the line drawn in `draw(_:)` took ~9.5 % CPU at 60 fps). In
    /// silence, once everything is flat, nothing changes and nothing is sent.
    private func step() {
        let now = CACurrentMediaTime()
        let elapsed = CGFloat(min(0.05, now - lastStep))
        lastStep = now
        // The bars rise fast and fall a little slower, so syllables stay visible and a pause shows
        // within ~0.1 s; the line keeps the smoothing it was chosen with.
        let rate: CGFloat = style == .line ? 0.25 : (target > smooth ? 0.5 : 0.3)
        smooth += (target - smooth) * rate
        if smooth < 0.001, target == 0 { smooth = 0 }
        switch style {
        case .line:
            let flat = smooth == 0 && trace.allSatisfy { $0 == 0 }
            phase += 0.12 + smooth * 0.3
            trace.removeFirst()
            trace.append(smooth)
            if !flat { updateLine() }
        case .bars, .wave:
            // Quiet bars still move on to the next place, so they stop evenly, none half faded.
            let quiet = smooth == 0 && columns.allSatisfy { $0 == 0 }
            if quiet, offset == 0 { return }
            offset += style.speed * elapsed
            while offset >= style.spacing {
                offset = quiet ? 0 : offset - style.spacing
                columns.removeFirst()
                columns.append(smooth)
            }
            columns[columns.count - 1] = smooth
            updateBars()
        }
    }

    private func updateLine() {
        guard let lineLayer else { return }
        let midY = bounds.height / 2
        let path = CGMutablePath()
        for (index, value) in trace.enumerated() {
            let point = CGPoint(x: 1 + CGFloat(index) * 1.3, y: midY + value * (Self.maxHeight / 2 - 2) * sin(CGFloat(index) * 0.9 + phase * 2))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.path = path
        CATransaction.commit()
    }

    /// New frames for the bars, actions off; Core Animation draws them. The oldest fades out on
    /// the left while the newest fades in on the right.
    /// Bars: the flat line until the first sound, then 3 pt bars 5 pt apart, at least 10 pt high.
    /// Wave: 2 pt bars 3.5 pt apart, at least 2 pt.
    private func updateBars() {
        guard !barLayers.isEmpty else { return }
        let midY = bounds.height / 2
        let bars = style == .bars
        let spacing = style.spacing
        let last = columns.count - 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flatLayer?.isHidden = heardSound
        for (index, (bar, value)) in zip(barLayers, columns).enumerated() {
            bar.isHidden = bars && !heardSound
            let height = bars ? max(Self.quietHeight, value * Self.maxHeight) : max(2, value * (Self.maxHeight - 2))
            bar.frame = CGRect(x: CGFloat(index) * spacing - offset, y: midY - height / 2, width: bars ? 3 : 2, height: height)
            bar.opacity = index == 0 ? Float(1 - offset / spacing) : index == last ? Float(offset / spacing) : 1
        }
        CATransaction.commit()
    }
}

/// How the pill shows the microphone level (Настройки → Диктовка → Индикатор).
enum LevelStyle: String, CaseIterable, Identifiable {
    case bars, wave, line

    static let traceCount = 75

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bars: String(localized: "Полоски")
        case .wave: String(localized: "Плотная волна")
        case .line: String(localized: "Линия")
        }
    }

    var historyCount: Int {
        switch self {
        case .bars: 14
        case .wave: 28
        case .line: 0
        }
    }

    /// Points from one bar to the next.
    var spacing: CGFloat { self == .bars ? 5 : 3.5 }

    /// How fast the bars move left, points a second: 5 bars used to cross in 0.4 s, 16 thin ones in
    /// ~0.65 s; now the rows are longer and take ~1.1 s.
    var speed: CGFloat { self == .bars ? 62.5 : 86 }

    var width: CGFloat {
        switch self {
        case .bars: 70
        case .wave: 98
        case .line: 100
        }
    }

    static var current: LevelStyle { LevelStyle(rawValue: Prefs.levelStyle) ?? .bars }
}

/// How high a level bar is, 0…1 of its height. Tuned on the owner's voice recorded with the
/// MacBook microphone (2026-10-26; its levels in `Tests/GeniusTyperTests/Fixtures/owner-speech-levels.txt`): silence
/// 0.00, speech mostly 0.15–0.36, peaks ~0.47; so 0.02…0.40 spans the height.
enum LevelBars {
    static func loudness(_ level: CGFloat) -> CGFloat {
        pow(max(0, min(1, (level - 0.02) / 0.38)), 0.7)
    }
}

/// The level bars' scale, adapted to the microphone and the room (asked 2026-10-27: with AirPods,
/// close to the mouth and with their own processing, nearly every word filled the bar on the
/// fixed `LevelBars` scale, tuned on the MacBook microphone). Levels are 40 dB per 1.0
/// (`AudioRecorder.level`). The bars show a 15 dB window (as `LevelBars`) hanging from the loud
/// speech of the last seconds (`peak`: rises at once, sinks 0.4 dB a second while speaking, never in
/// pauses, so the first word after a pause is not huge), cut at the background between words
/// (`floor`: drops at once, rises 0.8 dB a second), never narrower than 8 dB, so a quiet room's
/// hiss is not blown up. Only the pill uses it, the recording is untouched. Kept per microphone
/// (`Prefs.levelScales`). Tuned on the owner's levels (`LevelScaleTests`): as recorded, 10 dB louder
/// over room noise, and 4 dB quieter, the bars look alike (median ~0.7–0.8 of the height).
struct LevelScale: Codable, Equatable {
    var floor: CGFloat
    var peak: CGFloat

    /// The owner's voice on the MacBook microphone (silence 0): exactly `LevelBars` (0.02…0.40).
    static let standard = LevelScale(floor: 0, peak: 0.45)

    /// Just above the background is still silence (0.8 dB).
    static let margin: CGFloat = 0.02
    /// A bar is full this far below the peak (2 dB): the loudest syllables reach the top.
    static let headroom: CGFloat = 0.05
    /// From an empty to a full bar (15 dB), and never less than this (8 dB).
    static let window: CGFloat = 0.38
    static let minimumWindow: CGFloat = 0.2

    mutating func update(_ level: CGFloat, elapsed: TimeInterval) {
        let seconds = CGFloat(elapsed)
        if level < floor { floor = level } else { floor = min(level, floor + 0.02 * seconds) }
        if level > peak {
            peak = level
        } else if level > floor + Self.minimumWindow / 2 {
            peak -= 0.01 * seconds
        }
        peak = max(peak, floor + Self.minimumWindow + Self.headroom)
    }

    /// 0…1 of the bar's height, with `LevelBars`' 0.7 curve.
    func loudness(_ level: CGFloat) -> CGFloat {
        let top = peak - Self.headroom
        let low = max(floor + Self.margin, top - Self.window)
        return pow(max(0, min(1, (level - low) / (top - low))), 0.7)
    }
}
