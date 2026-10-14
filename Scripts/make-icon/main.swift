// Draws the app icon: a witch on her broom crossing the moon.
// Run through Scripts/make-icon.sh, which compiles this together with the
// shared outline in HouseKeeping/MenuBar/WitchIcon.swift.
import AppKit

func icon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    // The macOS icon grid: a rounded square inset from the canvas.
    let inset = size * 0.098
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.3)
    drop.shadowBlurRadius = size * 0.03
    drop.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    NSGraphicsContext.saveGraphicsState()
    drop.set()
    NSColor.black.set()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Night sky.
    NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.68, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.08, blue: 0.27, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()

    // Stars, at fixed places so every size matches.
    for (x, y, r, alpha) in [(0.16, 0.80, 0.012, 0.9), (0.30, 0.90, 0.008, 0.7), (0.12, 0.52, 0.008, 0.6), (0.86, 0.22, 0.010, 0.8),
                             (0.72, 0.12, 0.007, 0.6), (0.24, 0.16, 0.009, 0.7), (0.90, 0.60, 0.006, 0.6), (0.44, 0.08, 0.006, 0.5)] {
        NSColor.white.withAlphaComponent(alpha).set()
        let radius = body.width * r
        NSBezierPath(ovalIn: NSRect(x: body.minX + body.width * x - radius, y: body.minY + body.height * y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }

    // The moon, with a soft glow.
    let moonRadius = body.width * 0.31
    let moon = NSRect(x: body.minX + body.width * 0.58 - moonRadius, y: body.minY + body.height * 0.57 - moonRadius,
                      width: moonRadius * 2, height: moonRadius * 2)
    let glow = NSShadow()
    glow.shadowColor = NSColor(calibratedRed: 1, green: 0.93, blue: 0.62, alpha: 0.55)
    glow.shadowBlurRadius = size * 0.07
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    NSColor(calibratedRed: 1, green: 0.95, blue: 0.72, alpha: 1).set()
    NSBezierPath(ovalIn: moon).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.80, alpha: 1),
        NSColor(calibratedRed: 0.97, green: 0.84, blue: 0.48, alpha: 1),
    ])!.draw(in: NSBezierPath(ovalIn: moon), angle: -60)

    // The witch, crossing the moon.
    let scale = body.width * 0.78 / WitchShape.size.width
    let origin = CGPoint(x: body.minX + body.width * 0.10, y: body.minY + body.height * 0.25)
    NSColor(calibratedRed: 0.07, green: 0.05, blue: 0.18, alpha: 1).set()
    WitchShape.draw(scale: scale, origin: origin)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let folder = "HouseKeeping/Assets.xcassets/AppIcon.appiconset"
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try icon(pixels: points * scale).write(to: URL(fileURLWithPath: "\(folder)/\(name)"))
    images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(folder)/Contents.json"))
try icon(pixels: 256).write(to: URL(fileURLWithPath: "docs/icon.png"))
print("Wrote \(images.count) icon sizes to \(folder)")
