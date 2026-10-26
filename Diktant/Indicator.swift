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
        if case .recording = state { pill.levels = Array(repeating: 0, count: PillView.barCount) }
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
        pill.levels.removeFirst()
        pill.levels.append(CGFloat(value))
        pill.needsDisplay = true
        mascot?.heard(loud: value > 0.3)
    }

    /// The pill as when dictating, with made-up speech: 1.5 s talking, 1 s silent, 6 s in all.
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
                self.level(talking ? Float.random(in: 0.4...0.9) : Float.random(in: 0...0.1))
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
            size.height += mascot.frame.height + 2
            mascot.setFrameOrigin(NSPoint(x: ((size.width - mascot.frame.width) / 2).rounded(), y: pillSize.height + 2))
        }
        pill.frame = NSRect(x: ((size.width - pillSize.width) / 2).rounded(), y: 0, width: pillSize.width, height: pillSize.height)
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

private final class PillView: NSView {
    static let barCount = 5

    var state: Indicator.State = .transcribing { didSet { needsDisplay = true } }
    var levels: [CGFloat] = Array(repeating: 0, count: barCount)
    var tick = 0

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
        if case .recording = state { width += 8 + CGFloat(Self.barCount) * 5 }
        return NSSize(width: ceil(width), height: 30)
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

        guard case .recording = state else { return }
        x = rect.maxX - 14 - CGFloat(Self.barCount) * 5 + 1
        NSColor(white: 0.95, alpha: 1).setFill()
        for level in levels {
            let height = max(3, min(16, 3 + level * 13))
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - height / 2, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
            x += 5
        }
    }
}
