import CoreGraphics
import Foundation

/// The "Нити" level style (asked 2026-11-21 after an iPhone dictation video and an interactive
/// preview the owner tuned): a matrix of dots on which three sine strands run and braid, their
/// ends narrowing and fading. Ordinary speech raises them to about half the height and makes them
/// run; a sudden sound (a voiced consonant, the start of a syllable) makes them jump, fan out up
/// and down and light two more strands for a moment, so it is plain that the microphone caught
/// it. A steady vowel keeps them in an even braid.
///
/// `StrandsMotion` is the motion, pure and tested; `StrandsPainter` draws one frame into a bitmap
/// (one layer's contents, no layer per dot).
struct StrandsMotion {
    // The owner's settings from the preview (2026-11-21).
    static let height: CGFloat = 0.62 // of the half height, by ordinary speech
    static let life: CGFloat = 0.45 // how much the strands run and change with speech
    static let hit: CGFloat = 0.65 // how much a sudden sound jumps and fans them
    static let hold: CGFloat = 0.35 // seconds the fan lasts
    static let silentHeight: CGFloat = 0.07
    static let speed: CGFloat = 1
    static let strands = 3
    static let extraStrands = 2

    /// A sudden sound: the fast envelope this far above the slow one (0…1 of the scale). Tuned on
    /// the owner's levels (`StrandsMotionTests`): ~0.5–1 strong hits a second in ordinary speech.
    static let hitThreshold: CGFloat = 0.3
    static let hitGain: CGFloat = 3

    // Each strand's own speed while even and while fanned, and how slowly it follows the voice.
    private static let evenSpeeds: [CGFloat] = [1, 0.82, 1.2, 0.9, 1.1]
    private static let hitSpeeds: [CGFloat] = [1, -0.8, 1.4, -1.2, 0.7]
    private static let lags: [CGFloat] = [0.04, 0.11, 0.22, 0.08, 0.16]

    /// The scale in dB: a 24 dB window hanging from the loud speech of the last seconds (rises at
    /// once, sinks 2.5 dB a second, 15 while the voice is 12 dB under it), cut 5 dB above the background (falls at once, rises 1.5 dB a
    /// second while the sound is within 6 dB of it). Levels are `(dB + 50) / 40` (`AudioRecorder.level`).
    private var peakDb: CGFloat = -36 // the owner's loud speech on the MacBook microphone (level 0.35)
    private var floorDb: CGFloat = -50 // level 0
    private var fast: CGFloat = 0
    private var slow: CGFloat = 0
    private var lastHit: CFTimeInterval = -1
    private(set) var speech: CGFloat = 0
    /// The fan after a sudden sound, 1 at once, then fading over `hold`.
    private(set) var burst: CGFloat = 0
    private(set) var levels: [CGFloat] = Array(repeating: 0, count: 5)
    private(set) var phases: [CGFloat] = [0, 2.494, 4.989, 7.483, 9.977] // i · (2π/3 + 0.4)
    /// Waves running from the middle to both ends after a sudden sound: start time and strength.
    private(set) var ripples: [(start: CFTimeInterval, strength: CGFloat)] = []
    private(set) var hits = 0

    /// One frame: `level` is the newest microphone level (0…1, held between the ~12 a second).
    mutating func step(level: CGFloat, elapsed: CGFloat, now: CFTimeInterval) {
        let dt = max(0.001, elapsed)
        let db = 40 * level - 50
        // The background creeps up only while the sound is near it: a held vowel never becomes it.
        if db < floorDb { floorDb = db } else if db < floorDb + 6 { floorDb += dt * 1.5 }
        // A voice well under the window brings it down within a second (as `LevelScale`).
        let sink: CGFloat = db > floorDb + 10 && db < peakDb - 12 ? 15 : 2.5
        peakDb = max(db, peakDb - dt * sink, floorDb + 18)
        var value = min(1, max(0, (db - (peakDb - 24)) / 24))
        if db < floorDb + 5 { value = 0 }
        value = pow(value, 1.4)
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
        let pace = Self.speed * 2.2 * (0.25 + Self.life * 1.5 * speech + Self.hit * 2.2 * burst)
        let fanned = min(1, burst * 1.3)
        for index in phases.indices {
            let speed = Self.evenSpeeds[index] + (Self.hitSpeeds[index] - Self.evenSpeeds[index]) * fanned
            phases[index] = (phases[index] + dt * pace * speed).truncatingRemainder(dividingBy: 2 * .pi * 100)
        }
    }

    /// Counting starts again (tests count hits after the scale has learnt the levels).
    mutating func resetHits() { hits = 0 }

    /// How visible each strand is: the three always, the extra ones only in a fan.
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
        let side = CGFloat(count / 2)
        return (0..<count).map { index in
            let extra = index >= Self.strands
            let amplitude = min(1, Self.silentHeight + Self.height * levels[index] + Self.hit * 0.35 * burst) * half * (extra ? 0.7 : 1)
            let phase = extra ? (CGFloat(index) + 0.5) * 2 * .pi / CGFloat(count) : CGFloat(index) * 2 * .pi / CGFloat(Self.strands)
            let waves: CGFloat = extra ? 2 * 1.45 : 2
            let rank = index == 0 ? 0 : (index % 2 == 1 ? 1 : -1) * CGFloat((index + 1) / 2) / side
            return amplitude * jump * envelope * sin(2 * .pi * waves * u + phase + phases[index]) + rank * fan
        }
    }
}

/// Draws `StrandsMotion` as a dot matrix into a reused bitmap: 2.5 pt between dots, 1.5 pt dots,
/// faint background dots (7 %), each dot as bright as the nearest strand, a little bigger when
/// bright, everything a bit brighter in a fan. ~430 dots, well under a millisecond a frame.
final class StrandsPainter {
    static let pitch: CGFloat = 2.5
    static let dot: CGFloat = 1.5
    static let background: CGFloat = 0.07
    static let fill: CGFloat = 0.05
    static let brightness: CGFloat = 0.92
    static let thickness: CGFloat = pitch * 0.55

    let size: CGSize
    let fieldHeight: CGFloat
    private let scale: CGFloat
    private let context: CGContext?

    init(size: CGSize, fieldHeight: CGFloat, scale: CGFloat) {
        self.size = size
        self.fieldHeight = fieldHeight
        self.scale = scale
        context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.scaleBy(x: scale, y: scale)
    }

    func image(_ motion: StrandsMotion, now: CFTimeInterval) -> CGImage? {
        guard let context else { return nil }
        context.clear(CGRect(origin: .zero, size: size))
        let pitch = Self.pitch
        let columns = Int(size.width / pitch), rows = Int(fieldHeight / pitch)
        let x0 = (size.width - CGFloat(columns) * pitch) / 2 + pitch / 2
        let midY = size.height / 2
        let y0 = (fieldHeight - CGFloat(rows) * pitch) / 2 + pitch / 2 - fieldHeight / 2
        let weights = motion.weights
        let fill = Self.fill * (1 - motion.burst * 0.75)
        let flash = 1 + 0.35 * min(1, motion.burst * StrandsMotion.hit)
        for column in 0..<columns {
            let x = x0 + CGFloat(column) * pitch
            let offsets = motion.offsets(at: x / size.width, now: now, height: fieldHeight, dot: Self.dot)
            var low = CGFloat.infinity, high = -CGFloat.infinity
            for (offset, weight) in zip(offsets, weights) where weight > 0.4 {
                low = min(low, offset)
                high = max(high, offset)
            }
            for row in 0..<rows {
                let y = y0 + CGFloat(row) * pitch
                var bright = Self.background
                if fill > 0, y >= low - pitch * 0.3, y <= high + pitch * 0.3 { bright = max(bright, fill) }
                for (offset, weight) in zip(offsets, weights) {
                    let distance = (y - offset) / Self.thickness
                    if abs(distance) < 2.5 { bright = max(bright, weight * exp(-distance * distance)) }
                }
                bright = min(1, bright * Self.brightness * flash)
                guard bright >= 0.02 else { continue }
                let radius = Self.dot / 2 * (0.75 + 0.25 * bright)
                context.setFillColor(red: 0.95, green: 0.95, blue: 0.95, alpha: bright)
                context.fillEllipse(in: CGRect(x: x - radius, y: midY + y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
        return context.makeImage()
    }
}
