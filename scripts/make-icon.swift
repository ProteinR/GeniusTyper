// Draws the Switcher app icon and writes AppIcon.appiconset: the "Genius" meme face (the one who
// types gibberish in the wrong layout) crossed out with a red "no" sign, and two keycaps "A" / "Я".
// The face is scripts/genius.png (black lines on white).
// Usage: swift scripts/make-icon.swift Switcher/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreImage

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// The face as white lines on a transparent background.
let face: CGImage = {
    let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("genius.png")
    let input = CIImage(contentsOf: url)!
    // Thicker lines than the original, so they survive the small icon sizes.
    let lines = input.applyingFilter("CIColorInvert")
        .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1.6])
        .applyingFilter("CIMaskToAlpha")
    return CIContext().createCGImage(lines, from: input.extent)!
}()

func drawKeycap(_ rect: NSRect, letter: String, top: NSColor, bottom: NSColor, text: NSColor, s: CGFloat) {
    // Keycap details scale with the key (designed for a 380 pt wide key).
    let s = s * rect.width / (380 * s)
    // Shadow under the key.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -18 * s)
    shadow.shadowBlurRadius = 36 * s
    shadow.set()
    let base = NSBezierPath(roundedRect: rect, xRadius: 70 * s, yRadius: 70 * s)
    bottom.setFill()
    base.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Key top, slightly inset towards the top like a real keycap.
    let topRect = NSRect(x: rect.minX + 26 * s, y: rect.minY + 44 * s, width: rect.width - 52 * s, height: rect.height - 66 * s)
    NSGradient(starting: top, ending: top.blended(withFraction: 0.12, of: bottom)!)!
        .draw(in: NSBezierPath(roundedRect: topRect, xRadius: 52 * s, yRadius: 52 * s), angle: -90)

    let font = NSFont.systemFont(ofSize: 230 * s, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
    let string = NSAttributedString(string: letter, attributes: attributes)
    let size = string.size()
    string.draw(at: NSPoint(x: topRect.midX - size.width / 2, y: topRect.midY - size.height / 2 + 8 * s))
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Background: macOS-style rounded square, blue to indigo, inset like system icons.
    let inset = 100 * s
    let bgRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.27, green: 0.52, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.29, green: 0.22, blue: 0.78, alpha: 1))!
        .draw(in: bg, angle: -90)

    // The face inside a red "no" sign.
    let center = NSPoint(x: 450 * s, y: 600 * s)
    let radius: CGFloat = 290 * s
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)).addClip()
    let faceSize = NSSize(width: 640 * s, height: 612 * s)
    // The face's centre is at about 47 % across and 55 % up the picture.
    let faceRect = NSRect(x: center.x - 0.47 * faceSize.width, y: center.y - 0.55 * faceSize.height,
                          width: faceSize.width, height: faceSize.height)
    NSGraphicsContext.current!.cgContext.draw(face, in: faceRect)
    NSGraphicsContext.restoreGraphicsState()

    let red = NSColor(calibratedRed: 0.95, green: 0.20, blue: 0.22, alpha: 1)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.3)
    glow.shadowOffset = NSSize(width: 0, height: -8 * s)
    glow.shadowBlurRadius = 20 * s
    glow.set()
    red.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    ring.lineWidth = 52 * s
    ring.stroke()
    let slash = NSBezierPath()
    let d = radius * 0.7071
    slash.move(to: NSPoint(x: center.x - d, y: center.y + d))
    slash.line(to: NSPoint(x: center.x + d, y: center.y - d))
    slash.lineWidth = 52 * s
    slash.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Back key: "A", light. Front key: "Я", white, lower right, overlapping.
    drawKeycap(NSRect(x: 560 * s, y: 300 * s, width: 210 * s, height: 220 * s), letter: "A",
               top: NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.97, alpha: 1),
               bottom: NSColor(calibratedRed: 0.62, green: 0.67, blue: 0.82, alpha: 1),
               text: NSColor(calibratedRed: 0.25, green: 0.30, blue: 0.55, alpha: 1), s: s)
    drawKeycap(NSRect(x: 680 * s, y: 175 * s, width: 210 * s, height: 220 * s), letter: "Я",
               top: NSColor(calibratedWhite: 1, alpha: 1),
               bottom: NSColor(calibratedRed: 0.76, green: 0.79, blue: 0.88, alpha: 1),
               text: NSColor(calibratedRed: 0.24, green: 0.33, blue: 0.86, alpha: 1), s: s)

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
print("Wrote \(images.count) icons to \(outDir.path)")
