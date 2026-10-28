// GeniusTyperEngine: runs Parakeet TDT 0.6B v3 (FluidAudio, Neural Engine) for Genius Typer in a process of
// its own. Loading the model leaves ~30 MB of fragmented malloc memory that macOS never takes back
// from a process that keeps running; this process exits when Genius Typer unloads the model, so all of
// it goes back. Genius Typer itself does not link FluidAudio.
//
// Modes (one JSON object per line on stdout):
//   download   → {"progress": 0.42} … {"done": true} | {"error": "…"}
//   serve      → {"ready": true, "seconds": 0.17} | {"error": "…"}, then for each request on stdin
//                (UInt32 little-endian sample count + Float32 samples, 16 kHz mono) one
//                {"text": "…", "seconds": 0.07} | {"error": "…"}. Exits when stdin closes (Genius Typer
//                unloaded the model, or quit or crashed).
import FluidAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

/// Exactly `count` bytes from stdin, or nil at end of input.
func readExactly(_ count: Int) -> Data? {
    var data = Data(count: count)
    var filled = 0
    while filled < count {
        let read = data.withUnsafeMutableBytes { buffer in
            Foundation.read(0, buffer.baseAddress! + filled, count - filled)
        }
        if read <= 0 { return nil }
        filled += read
    }
    return data
}

func readSamples() -> [Float]? {
    guard let header = readExactly(4) else { return nil }
    let count = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
    guard count > 0 else { return [] }
    guard let body = readExactly(count * 4) else { return nil }
    return body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

// Second argument: the model, "v3" (default) or "ultra" (Moondream's post-trained v3).
let version: AsrModelVersion = CommandLine.arguments.dropFirst(2).first == "ultra" ? .ultra : .v3

switch CommandLine.arguments.dropFirst().first {
case "download":
    do {
        try await AsrModels.download(version: version) { emit(["progress": $0.fractionCompleted]) }
        emit(["done": true])
    } catch {
        emit(["error": error.localizedDescription])
        exit(1)
    }

case "serve":
    let manager = AsrManager(config: .default)
    do {
        let start = Date()
        let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: version), version: version)
        try await manager.loadModels(models)
        emit(["ready": true, "seconds": Date().timeIntervalSince(start)])
    } catch {
        emit(["error": error.localizedDescription])
        exit(1)
    }
    let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
    while var samples = readSamples() {
        // Shorter than the model's minimum (a quick word): pad with silence.
        if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }
        do {
            let start = Date()
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples, decoderState: &state)
            emit(["text": result.text, "seconds": Date().timeIntervalSince(start)])
        } catch {
            emit(["error": error.localizedDescription])
        }
    }
    exit(0)

default:
    FileHandle.standardError.write("usage: GeniusTyperEngine download | serve [v3 | ultra]\n".data(using: .utf8)!)
    exit(2)
}
