// Writes Diktant's own sounds as 16-bit mono WAV.
// success.wav: a soft, short "ding" for text pasted — a sine bell (C6 with a quiet octave and a
// fifth above), 4 ms attack, ~0.4 s exponential decay, low level, so it is heard but not sharp.
// Usage: swift scripts/make-sounds.swift Diktant/Sounds
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
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

/// partials: (frequency, level, decay seconds)
func bell(_ partials: [(Double, Double, Double)], length: Double, level: Double) -> [Double] {
    let count = Int(length * rate)
    return (0..<count).map { i in
        let t = Double(i) / rate
        let attack = min(1, t / 0.004)
        let tail = min(1, (length - t) / 0.03) // no click at the end
        let sum = partials.reduce(0.0) { $0 + $1.1 * exp(-t / $1.2) * sin(2 * .pi * $1.0 * t) }
        return level * attack * tail * sum
    }
}

let success = bell([(1046.5, 1.0, 0.16), (2093.0, 0.18, 0.08), (1568.0, 0.22, 0.12)], length: 0.55, level: 0.28)
try wav(success).write(to: outDir.appendingPathComponent("success.wav"))
print("Wrote success.wav")
