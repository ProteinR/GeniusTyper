#!/usr/bin/env swift
// Turns an animated PNG (`scripts/mascots/*.apng`, made by make-mascots.swift or ffmpeg) into the
// `.frames` file the dictation pill shows (`GeniusTyper/Dictation/Mascots/`): scaled to the size it
// is shown at, the drop shadow baked in, each frame as raw premultiplied RGBA compressed with LZFSE.
// Why not the APNG itself: decoding a PNG frame took ~1 ms of CPU, LZFSE ~0.15 ms (HEIC ~4 ms),
// and Core Animation blurred the layer shadow again for every frame.
// usage: make-mascot-frames.swift <input.apng> <output.frames> [figure height px, default 192]
//
// Format (little-endian): "GTF1", UInt32 width, height, count; per frame Float32 delay (s),
// UInt32 offset, UInt32 length (of its LZFSE data, from the start of the file); then the data.
// The output is the figure at that height plus `pad` px on every side for the shadow.
import Compression
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make-mascot-frames.swift <input.apng> <output.frames> [figure height px]")
    exit(1)
}
let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
let figureHeight = args.count > 3 ? Int(args[3])! : 192
/// Matches `MascotView.shadowPad` (4 pt at 2×).
let pad = 8

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { fatalError("cannot read \(input.path)") }
let count = CGImageSourceGetCount(source)
let first = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let scale = CGFloat(figureHeight) / CGFloat(first.height)
let figure = CGSize(width: (CGFloat(first.width) * scale).rounded(), height: CGFloat(figureHeight))
let width = Int(figure.width) + 2 * pad, height = figureHeight + 2 * pad

var delays: [Float32] = []
var blobs: [Data] = []
for index in 0..<count {
    let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
    let delay = (png?[kCGImagePropertyAPNGUnclampedDelayTime] ?? png?[kCGImagePropertyAPNGDelayTime]) as? Double ?? 0.08
    let frame = CGImageSourceCreateImageAtIndex(source, index, nil)!
    var pixels = Data(count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        // As the layer shadow was: black at 35 %, 3 pt blur, 1 pt down.
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(gray: 0, alpha: 0.35))
        ctx.draw(frame, in: CGRect(x: CGFloat(pad), y: CGFloat(pad), width: figure.width, height: figure.height))
    }
    var compressed = Data(count: pixels.count + 4096)
    let size = compressed.withUnsafeMutableBytes { out in
        pixels.withUnsafeBytes { raw in
            compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                                      raw.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZFSE)
        }
    }
    precondition(size > 0, "frame \(index) did not compress")
    delays.append(Float32(max(0.04, delay)))
    blobs.append(compressed.prefix(size))
}

func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}
var file = Data("GTF1".utf8)
append(UInt32(width), to: &file)
append(UInt32(height), to: &file)
append(UInt32(count), to: &file)
var offset = file.count + count * 12
for (delay, blob) in zip(delays, blobs) {
    append(delay.bitPattern, to: &file)
    append(UInt32(offset), to: &file)
    append(UInt32(blob.count), to: &file)
    offset += blob.count
}
blobs.forEach { file.append($0) }
try! file.write(to: output, options: .atomic)
print("\(output.lastPathComponent): \(count) frames, \(width)×\(height), \(file.count / 1024) KB")
