// Writes Diktant's own sounds as 16-bit mono WAV.
// success.wav: text pasted. In the spirit of Claude's voice-mode sounds (soft, almost pure sine
// taps, 650–950 Hz) rather than a bell: the first own "ding" (C6 with overtones) was too sharp.
// Usage: swift scripts/make-sounds.swift <dir> [variant]   variant: tap (default, the one in use) | rise
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "tap"
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let rate = 44_100.0

func wav(_ samples: [Double]) -> Data {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
    u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(bytes)
    for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
    return data
}

/// A soft sine tap: smooth (raised-cosine) 12 ms attack, gentle exponential decay, a whisper of
/// the octave for body, faded to silence at the end (no click).
func tap(_ frequency: Double, length: Double, decay: Double) -> [Double] {
    let count = Int(length * rate)
    return (0..<count).map { i in
        let t = Double(i) / rate
        let attack = t < 0.012 ? 0.5 - 0.5 * cos(.pi * t / 0.012) : 1
        let release = min(1, (length - t) / 0.02)
        let tone = sin(2 * .pi * frequency * t) + 0.06 * sin(4 * .pi * frequency * t)
        return attack * release * exp(-t / decay) * tone
    }
}

func mix(_ parts: [(start: Double, samples: [Double])], level: Double) -> [Double] {
    let total = parts.map { Int($0.start * rate) + $0.samples.count }.max() ?? 0
    var out = [Double](repeating: 0, count: total)
    for part in parts {
        let offset = Int(part.start * rate)
        for (i, s) in part.samples.enumerated() { out[offset + i] += s }
    }
    let peak = out.map(abs).max() ?? 1
    return out.map { $0 / peak * level }
}

let success: [Double]
switch variant {
case "rise":
    // Two quick soft taps rising a fourth (E5 → A5): "done". Offered, not chosen.
    success = mix([(0, tap(659, length: 0.16, decay: 0.05)), (0.085, tap(880, length: 0.24, decay: 0.07))], level: 0.16)
default:
    // One soft tap, like the end of Claude's voice mode (chosen by the owner, 2026-10-26).
    success = mix([(0, tap(740, length: 0.22, decay: 0.07))], level: 0.16)
}
try wav(success).write(to: outDir.appendingPathComponent("success.wav"))
print("Wrote success.wav (\(variant))")
