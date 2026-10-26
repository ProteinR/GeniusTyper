#!/usr/bin/env swift
// Cuts the background out of an animated GIF/WebP with Vision (the same subject lifting as
// "Copy Subject" in Photos) and writes an animated PNG with transparency for the indicator.
// usage: make-mascots.swift <input> <output.png> [height px, default 240] [every Nth frame, default 1]
//        [frames, e.g. "92-151,0-43": only these source frames, in this order]

import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make-mascots.swift <input> <output.png> [height] [step]")
    exit(1)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let height = args.count > 3 ? Int(args[3])! : 240
let step = args.count > 4 ? Int(args[4])! : 1
let ranges = args.count > 5 ? args[5] : nil

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { fatalError("cannot open \(input.path)") }
let count = CGImageSourceGetCount(source)
let order: [Int] = ranges.map { list in
    list.split(separator: ",").flatMap { part -> [Int] in
        let bounds = part.split(separator: "-").map { Int($0)! }
        return Array(bounds[0]...min(bounds.last!, count - 1))
    }
} ?? Array(0..<count)

func delay(_ index: Int) -> Double {
    let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
    for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyWebPDictionary, kCGImagePropertyPNGDictionary] {
        if let dict = props[key] as? [CFString: Any] {
            let value = (dict["UnclampedDelayTime" as CFString] ?? dict["DelayTime" as CFString]) as? Double
            if let value, value > 0 { return value }
        }
    }
    return 0.1
}

let context = CIContext()
var cutouts: [(image: CIImage, delay: Double, bounds: CGRect, area: Int)] = []

for position in Swift.stride(from: 0, to: order.count, by: step) {
    let index = order[position]
    guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: frame)
    try handler.perform([request])
    var frameDelay = 0.0
    for i in order[position..<min(position + step, order.count)] { frameDelay += delay(i) }
    guard let result = request.results?.first else {
        print("frame \(index): nothing found")
        continue
    }
    // Only the largest subject: Vision lifts the laptop in some frames only, and it would blink.
    let mask = try result.generateScaledMaskForImage(forInstances: [largestInstance(result)], from: handler)
    let image = CIImage(cgImage: frame)
    let maskImage = CIImage(cvPixelBuffer: mask)
    let cut = image.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: CIImage.empty(),
        kCIInputMaskImageKey: maskImage,
    ])
    guard let cg = context.createCGImage(cut, from: image.extent) else { continue }
    let (bounds, area) = opaqueBounds(cg)
    cutouts.append((cut.cropped(to: image.extent), frameDelay, bounds, area))
}

// Vision sometimes takes the laptop as part of the animal: such a frame is much larger than the
// rest and is dropped, its time given to the frame before.
let median = cutouts.map(\.area).sorted()[cutouts.count / 2]
var kept: [(image: CIImage, delay: Double, bounds: CGRect, area: Int)] = []
for cutout in cutouts {
    if Double(cutout.area) > Double(median) * 1.2, !kept.isEmpty {
        kept[kept.count - 1].delay += cutout.delay
    } else {
        kept.append(cutout)
    }
}
if kept.count < cutouts.count { print("dropped \(cutouts.count - kept.count) frames with extra objects") }
cutouts = kept
// One crop that fits every frame.
let union = cutouts.reduce(CGRect.null) { $0.union($1.bounds) }

func largestInstance(_ result: VNInstanceMaskObservation) -> Int {
    let buffer = result.instanceMask
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var counts = [Int: Int]()
    for y in 0..<h { for x in 0..<w { let label = Int(base[y * row + x]); if label > 0 { counts[label, default: 0] += 1 } } }
    return counts.max { $0.value < $1.value }?.key ?? result.allInstances.first!
}

func opaqueBounds(_ image: CGImage) -> (CGRect, Int) {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1, area = 0
    for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 24 {
        area += 1
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= 0 else { return (.null, 0) }
    // Rows in the buffer go top-down; CIImage coordinates go bottom-up.
    return (CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1), area)
}

guard !cutouts.isEmpty, !union.isNull else { fatalError("no subject found") }
let crop = union.integral
let scale = CGFloat(height) / crop.height
let size = CGSize(width: (crop.width * scale).rounded(), height: CGFloat(height))

guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, cutouts.count, nil) else {
    fatalError("cannot write \(output.path)")
}
CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
for (cut, frameDelay, _, _) in cutouts {
    let scaled = cut.cropped(to: crop)
        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    let cg = context.createCGImage(scaled, from: CGRect(origin: .zero, size: size))!
    CGImageDestinationAddImage(dest, cg, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: frameDelay]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
print("\(output.lastPathComponent): \(cutouts.count) frames, \(Int(size.width))×\(Int(size.height))")
