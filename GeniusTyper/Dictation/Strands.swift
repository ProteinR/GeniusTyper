import CoreGraphics
import Foundation

/// The "Нити" level style (asked 2026-11-21 after an iPhone dictation video and an interactive
/// preview the owner tuned): a matrix of dots on which two mirrored sine strands braid into a
/// chain of lenses, the band between them lit dimmer, their ends narrowing and fading, as in the
/// reference video (0.24.0 had three thin strands and almost no fill: on a real screen they read
/// as a blur, and the owner asked for the reference's two clear lines). Ordinary speech raises them to about half the height and makes them
/// run; a sudden sound (a voiced consonant, the start of a syllable) makes them jump, fan out up
/// and down and light two more strands for a moment, so it is plain that the microphone caught
/// it. A steady vowel keeps them in an even braid.
///
/// `StrandsMotion` is the motion, pure and tested; `StrandsPainter` draws one frame into a bitmap
/// (one layer's contents, no layer per dot).
struct StrandsMotion {
    // The owner's settings from the preview (2026-11-21).
    static let height: CGFloat = 0.8 // of the half height, by ordinary speech (0.62 in the preview: too low on a real screen)
    static let life: CGFloat = 0.45 // how much the strands run and change with speech
    static let hit: CGFloat = 0.65 // how much a sudden sound jumps and fans them
    static let hold: CGFloat = 0.35 // seconds the fan lasts
    static let silentHeight: CGFloat = 0.07
    static let speed: CGFloat = 1
    static let strands = 2
    static let extraStrands = 2
    /// Sine periods across the field: three lenses, as in the reference.
    static let waves: CGFloat = 1.6

    /// A sudden sound: the fast envelope this far above the slow one (0…1 of the scale). Tuned on
    /// the owner's levels (`StrandsMotionTests`): ~0.5–1 strong hits a second in ordinary speech.
    static let hitThreshold: CGFloat = 0.3
    static let hitGain: CGFloat = 3

    // Each strand's own speed while even and while fanned, and how slowly it follows the voice.
    // The two strands run together (a mirror) and part only in a fan; the extra ones go their own way.
    private static let evenSpeeds: [CGFloat] = [1, 1, 1.2, 0.9]
    private static let hitSpeeds: [CGFloat] = [1, -0.8, 1.4, -1.2]
    private static let lags: [CGFloat] = [0.05, 0.14, 0.08, 0.16]

    private var fast: CGFloat = 0
    private var slow: CGFloat = 0
    private var lastHit: CFTimeInterval = -1
    private(set) var speech: CGFloat = 0
    /// The fan after a sudden sound, 1 at once, then fading over `hold`.
    private(set) var burst: CGFloat = 0
    private(set) var levels: [CGFloat] = Array(repeating: 0, count: 4)
    private(set) var phases: [CGFloat] = [0, 0, 1.3, 2.9]
    /// Waves running from the middle to both ends after a sudden sound: start time and strength.
    private(set) var ripples: [(start: CFTimeInterval, strength: CGFloat)] = []
    private(set) var hits = 0

    /// One frame: `value` is the newest loudness on the microphone's `LevelScale` (0…1, as the
    /// bars, held between the ~12 levels a second). 0.24.0 kept its own dB scale, whose background
    /// crept up into the owner's quiet speech: the strands lay flat during speech
    /// (2026-11-21); the bars' scale is learnt per microphone and tested on his voice.
    mutating func step(value: CGFloat, elapsed: CGFloat, now: CFTimeInterval) {
        let dt = max(0.001, elapsed)
        let value = min(1, max(0, value))
        fast = value > fast ? value : fast + (value - fast) * (1 - exp(-dt / 0.05))
        slow += (value - slow) * (1 - exp(-dt / 0.28))
        speech += (value - speech) * (1 - exp(-dt / (value > speech ? 0.05 : 0.18)))
        let onset = fast - slow
        burst *= exp(-dt / Self.hold)
        if onset > Self.hitThreshold {
            let strength = min(1, (onset - Self.hitThreshold * 0.6) * Self.hitGain * Self.hit)
            if strength > 0.5, burst <= 0.5 { hits += 1 }
            burst = max(burst, strength)
            if now - lastHit > 0.1 {
                ripples.append((now, min(1, onset * 2)))
                lastHit = now
            }
        }
        ripples.removeAll { now - $0.start > 1.2 }
        for index in levels.indices {
            levels[index] += (value - levels[index]) * (1 - exp(-dt / (Self.lags[index] * (0.4 + Self.life))))
        }
        let pace = Self.speed * 2.2 * (0.4 + Self.life * 1.5 * speech + Self.hit * 2.2 * burst)
        let fanned = min(1, burst * 1.3)
        for index in phases.indices {
            let speed = Self.evenSpeeds[index] + (Self.hitSpeeds[index] - Self.evenSpeeds[index]) * fanned
            phases[index] = (phases[index] + dt * pace * speed).truncatingRemainder(dividingBy: 2 * .pi * 100)
        }
    }

    /// Counting starts again (tests count hits after the scale has learnt the levels).
    mutating func resetHits() { hits = 0 }

    /// How visible each strand is: the two always, the extra ones only in a fan.
    var weights: [CGFloat] {
        (0..<(Self.strands + Self.extraStrands)).map { $0 < Self.strands ? 1 : pow(burst, 0.7) }
    }

    /// The strands' heights from the middle at `u` (0…1 along the field), in points, for a field
    /// `height` points high with dots `dot` points wide.
    func offsets(at u: CGFloat, now: CFTimeInterval, height: CGFloat, dot: CGFloat) -> [CGFloat] {
        let count = Self.strands + Self.extraStrands
        let envelope = pow(max(0, sin(.pi * u)), 0.8)
        let half = height / 2 - dot / 2
        var bump: CGFloat = 0
        for ripple in ripples {
            let age = CGFloat(now - ripple.start)
            let distance = age * 1.1
            let fall = exp(-age / 0.35)
            let left = (u - 0.5 - distance) / 0.09, right = (u - 0.5 + distance) / 0.09
            bump += ripple.strength * fall * (exp(-left * left) + exp(-right * right))
        }
        let jump = 1 + bump * 0.6 * Self.hit
        let fan = Self.hit * burst * height * 0.24 * envelope
        // The second strand mirrors the first, a little out of step so the lenses breathe.
        let drift = 0.5 * sin(0.8 * CGFloat(now.truncatingRemainder(dividingBy: 1000)))
        return (0..<count).map { index in
            let extra = index >= Self.strands
            let amplitude = min(1, Self.silentHeight + Self.height * levels[index] + Self.hit * 0.35 * burst) * half * (extra ? 0.7 : 1)
            let phase = extra ? CGFloat(index - Self.strands) * .pi + 0.9 : CGFloat(index) * .pi + (index == 1 ? drift : 0)
            let waves = extra ? Self.waves * 1.45 : Self.waves
            let rank: CGFloat = extra ? (index % 2 == 0 ? 1 : -1) : 0
            return amplitude * jump * envelope * sin(2 * .pi * waves * u + phase + phases[index]) + rank * fan
        }
    }
}

/// Draws `StrandsMotion` as a dot matrix into a reused bitmap, like an LED panel: 2 pt dots 3 pt
/// apart on whole points (crisp on a 1× monitor too, 2 px dots 3 px apart), 11 rows; the
/// strands two dots thick at full brightness, the band between them at a third, the rest a faint
/// grid. Dots keep their size (a dot that shrank when dim blurred the grid). 0.24.0 had 1.5 pt
/// dots 2.5 pt apart, chosen in a preview the owner watched 3.5 times enlarged: on the monitor
/// they merged into a blurred band (2026-11-21). ~660 dots, about a millisecond a frame.
final class StrandsPainter {
    static let pitch: CGFloat = 3
    static let dot: CGFloat = 2
    static let rows = 11
    static let fieldHeight = CGFloat(rows - 1) * pitch + dot
    static let background: CGFloat = 0.09
    static let fill: CGFloat = 0.3
    static let brightness: CGFloat = 0.95
    static let thickness: CGFloat = pitch

    let size: CGSize
    private let scale: CGFloat
    private let context: CGContext?

    init(size: CGSize, scale: CGFloat) {
        self.size = size
        self.scale = scale
        context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.scaleBy(x: scale, y: scale)
    }

    func image(_ motion: StrandsMotion, now: CFTimeInterval) -> CGImage? {
        guard let context else { return nil }
        context.clear(CGRect(origin: .zero, size: size))
        let pitch = Self.pitch, radius = Self.dot / 2
        let columns = Int((size.width - Self.dot) / pitch) + 1
        // Dot centres on whole points, so a 2 pt dot covers whole pixels.
        let x0 = ((size.width - CGFloat(columns - 1) * pitch) / 2).rounded()
        let midY = (size.height / 2).rounded()
        let middle = CGFloat(Self.rows - 1) / 2
        let weights = motion.weights
        let fill = Self.fill * (1 - motion.burst * 0.5)
        let flash = 1 + 0.3 * min(1, motion.burst * StrandsMotion.hit)
        for column in 0..<columns {
            let x = x0 + CGFloat(column) * pitch
            let offsets = motion.offsets(at: x / size.width, now: now, height: Self.fieldHeight, dot: Self.dot)
            var low = CGFloat.infinity, high = -CGFloat.infinity
            for index in 0..<StrandsMotion.strands {
                low = min(low, offsets[index])
                high = max(high, offsets[index])
            }
            for row in 0..<Self.rows {
                let y = (CGFloat(row) - middle) * pitch
                var bright = Self.background
                if y >= low - pitch * 0.5, y <= high + pitch * 0.5 { bright = max(bright, fill) }
                for (offset, weight) in zip(offsets, weights) where weight > 0.02 {
                    let distance = (y - offset) / Self.thickness
                    if abs(distance) < 2.5 { bright = max(bright, weight * exp(-distance * distance)) }
                }
                bright = min(1, bright * Self.brightness * flash)
                context.setFillColor(red: 0.95, green: 0.95, blue: 0.95, alpha: bright)
                context.fillEllipse(in: CGRect(x: x - radius, y: midY + y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
        return context.makeImage()
    }
}
