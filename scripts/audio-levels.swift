#!/usr/bin/env swift
// Levels of a recorded voice, one per line, as the dictation pill gets them (AudioRecorder.levels:
// 16 kHz mono, 1365 samples per level, RMS on a log scale). The tests keep only these numbers, not
// the voice: swift scripts/audio-levels.swift voice.wav > Tests/GeniusTyperTests/Fixtures/owner-speech-levels.txt
import AVFoundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let sampleRate = 16_000.0, levelChunk = 1365
let file = try AVAudioFile(forReading: url)
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
let converter = AVAudioConverter(from: file.processingFormat, to: format)!
let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: input)
let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * sampleRate / file.processingFormat.sampleRate) + 64)!
var fed = false; var error: NSError?
converter.convert(to: output, error: &error) { _, status in
    if fed { status.pointee = .endOfStream; return nil }
    fed = true; status.pointee = .haveData; return input
}
let s = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
for start in stride(from: 0, to: s.count, by: levelChunk) {
    let c = s[start..<min(start + levelChunk, s.count)]
    let rms = (c.reduce(0) { $0 + $1 * $1 } / Float(c.count)).squareRoot()
    print(String(format: "%.4f", max(0, min(1, (20 * log10(max(rms, 1e-5)) + 50) / 40))))
}
