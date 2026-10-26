import AppKit

/// The small dark pill at the bottom centre of the screen (TypeWhisper's "Overlay", "Classic"
/// theme): red dot, timer and level bars while recording; "Распознаю…" while transcribing; a
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

    func show(_ state: State) {
        hideWork?.cancel()
        hideWork = nil
        let pill = makeIfNeeded()
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
        pill.bars.push(CGFloat(value))
        mascot?.heard(loud: value > 0.3)
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
        case .recording: interval = 0.5 // the clock
        case .transcribing: interval = 0.3 // the dots
        case .message: return
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

/// The pill: background, dot and text, redrawn twice a second at most (the clock). The level bars
/// are their own small view, so the ~12 level updates a second redraw only them.
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
        case .recording(let since):
            let seconds = max(0, Int(Date().timeIntervalSince(since)))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .transcribing:
            return String(localized: "Распознаю") + String(repeating: ".", count: tick % 4)
        case .message(let message):
            return message
        }
    }

    override var fittingSize: NSSize {
        let textWidth: CGFloat
        switch state {
        case .recording: textWidth = ("00:00" as NSString).size(withAttributes: Self.textAttributes).width
        case .transcribing: textWidth = ((String(localized: "Распознаю") + "...") as NSString).size(withAttributes: Self.textAttributes).width
        case .message: textWidth = (text as NSString).size(withAttributes: Self.textAttributes).width
        }
        var width = 14 + 8 + 8 + textWidth + 14
        if case .recording = state { width += 8 + bars.frame.width }
        return NSSize(width: ceil(width), height: 38)
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
/// the quiet ones short bars, not dots. Wave: 16 thin bars scrolling, like Voice Memos. Line: a
/// smooth oscilloscope line that swings with the voice, redrawn 60 times a second while recording
/// (at 30 it moved half as fast as the preview the owner chose, 2026-10-26).
private final class BarsView: NSView {
    static let maxHeight: CGFloat = 30
    static let quietHeight: CGFloat = 10
    static let lineHeight: CGFloat = 2

    private var style = LevelStyle.bars
    private var levels: [CGFloat] = []
    private var heardSound = false
    private var smooth: CGFloat = 0
    private var target: CGFloat = 0
    private var phase: CGFloat = 0
    private var trace: [CGFloat] = []
    private var animation: Timer?
    private var lineLayer: CAShapeLayer?

    func reset(style: LevelStyle) {
        self.style = style
        setFrameSize(NSSize(width: style.width, height: Self.maxHeight))
        levels = Array(repeating: 0, count: style.historyCount)
        trace = Array(repeating: 0, count: LevelStyle.traceCount)
        heardSound = false
        smooth = 0
        target = 0
        stopAnimating()
        lineLayer?.removeFromSuperlayer()
        lineLayer = nil
        if style == .line {
            wantsLayer = true
            let layer = CAShapeLayer()
            layer.frame = bounds
            layer.fillColor = nil
            layer.strokeColor = NSColor(white: 0.95, alpha: 1).cgColor
            layer.lineWidth = 2
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer?.addSublayer(layer)
            lineLayer = layer
            updateLine()
            startAnimating()
        }
        needsDisplay = true
    }

    func push(_ level: CGFloat) {
        let loudness = LevelBars.loudness(level)
        if loudness > 0 { heardSound = true }
        target = loudness
        guard !levels.isEmpty else { return }
        levels.removeFirst()
        levels.append(level)
        if style != .line { needsDisplay = true }
    }

    func stopAnimating() {
        animation?.invalidate()
        animation = nil
    }

    private func startAnimating() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        timer.tolerance = 1.0 / 240
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    /// One frame of the line: the shape layer gets a new path, which Core Animation draws, so the
    /// view itself is never redrawn (that took ~9.5 % CPU at 60 fps). In silence, once the line is
    /// flat, nothing changes and nothing is sent.
    private func step() {
        smooth += (target - smooth) * 0.25
        if smooth < 0.001, target == 0 { smooth = 0 }
        let flat = smooth == 0 && trace.allSatisfy { $0 == 0 }
        phase += 0.12 + smooth * 0.3
        trace.removeFirst()
        trace.append(smooth)
        if !flat { updateLine() }
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

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.height / 2
        switch style {
        case .bars: drawBars(midY: midY)
        case .wave: drawWave(midY: midY)
        case .line: break
        }
    }

    private func drawBars(midY: CGFloat) {
        NSColor(white: 0.95, alpha: 1).setFill()
        guard heardSound else {
            NSBezierPath(roundedRect: NSRect(x: 0, y: midY - Self.lineHeight / 2, width: bounds.width - 2, height: Self.lineHeight),
                         xRadius: Self.lineHeight / 2, yRadius: Self.lineHeight / 2).fill()
            return
        }
        var x: CGFloat = 0
        for level in levels {
            let height = max(Self.quietHeight, LevelBars.loudness(level) * Self.maxHeight)
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - height / 2, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
            x += 5
        }
    }

    private func drawWave(midY: CGFloat) {
        NSColor(white: 0.95, alpha: 1).setFill()
        var x: CGFloat = 0
        for level in levels {
            let height = max(2, LevelBars.loudness(level) * (Self.maxHeight - 2))
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - height / 2, width: 2, height: height), xRadius: 1, yRadius: 1).fill()
            x += 3.5
        }
    }
}

/// How the pill shows the microphone level (Настройки → Диктовка → Индикатор).
enum LevelStyle: String, CaseIterable, Identifiable {
    case bars, wave, line

    static let traceCount = 40

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
        case .bars: 5
        case .wave: 16
        case .line: 0
        }
    }

    var width: CGFloat {
        switch self {
        case .bars: 25
        case .wave: 55
        case .line: 54
        }
    }

    static var current: LevelStyle { LevelStyle(rawValue: Prefs.levelStyle) ?? .bars }
}

/// How high a level bar is, 0…1 of its height. Tuned on the owner's voice recorded with the
/// MacBook microphone (`Tests/GeniusTyperTests/Fixtures/owner-speech.wav`, 2026-10-26): silence
/// 0.00, speech mostly 0.15–0.36, peaks ~0.47; so 0.02…0.40 spans the height.
enum LevelBars {
    static func loudness(_ level: CGFloat) -> CGFloat {
        pow(max(0, min(1, (level - 0.02) / 0.38)), 0.7)
    }
}
