// Draws the Diktant app icon and writes AppIcon.appiconset: a white microphone with sound waves
// on a dark graphite square, and the red recording pill from the indicator below it.
// Usage: swift scripts/make-icon.swift Diktant/Assets.xcassets/AppIcon.appiconset [preview.png]
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    let inset = 100 * s
    let bgRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.25, green: 0.27, blue: 0.32, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1))!
        .draw(in: bg, angle: -90)

    // Microphone: capsule, stand and base.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 422 * s, y: 470 * s, width: 180 * s, height: 300 * s), xRadius: 90 * s, yRadius: 90 * s).fill()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: 512 * s, y: 560 * s), radius: 150 * s, startAngle: 200, endAngle: 340, clockwise: false)
    arc.lineWidth = 34 * s
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()
    NSBezierPath(roundedRect: NSRect(x: 495 * s, y: 345 * s, width: 34 * s, height: 70 * s), xRadius: 6 * s, yRadius: 6 * s).fill()

    // Sound waves on both sides.
    for (i, x) in [(0, 300.0), (1, 236.0), (0, 724.0), (1, 788.0)] {
        let height = (i == 0 ? 170.0 : 110.0) * s
        NSColor.white.withAlphaComponent(i == 0 ? 0.75 : 0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: x * s - 17 * s, y: 620 * s - height / 2, width: 34 * s, height: height),
                     xRadius: 17 * s, yRadius: 17 * s).fill()
    }

    // The indicator pill: red dot and level bars.
    let pill = NSRect(x: 352 * s, y: 215 * s, width: 320 * s, height: 96 * s)
    NSColor(white: 0.02, alpha: 1).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 48 * s, yRadius: 48 * s).fill()
    NSColor(white: 1, alpha: 0.18).setStroke()
    let border = NSBezierPath(roundedRect: pill, xRadius: 48 * s, yRadius: 48 * s)
    border.lineWidth = 4 * s
    border.stroke()
    NSColor.systemRed.setFill()
    NSBezierPath(ovalIn: NSRect(x: 392 * s, y: 241 * s, width: 44 * s, height: 44 * s)).fill()
    NSColor.white.setFill()
    for (i, h) in [30.0, 54.0, 40.0, 62.0, 26.0].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: (470 + Double(i) * 34) * s, y: 263 * s - h * s / 2, width: 16 * s, height: h * s),
                     xRadius: 8 * s, yRadius: 8 * s).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let data = drawIcon(size: CGFloat(pixels)).representation(using: .png, properties: [:])!
        try data.write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
if CommandLine.arguments.count > 2 {
    try drawIcon(size: 1024).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("Wrote \(images.count) icons to \(outDir.path)")
