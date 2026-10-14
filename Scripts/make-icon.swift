// Draws the app icon into Sweep/Assets.xcassets/AppIcon.appiconset.
// Run from the repository root: swift Scripts/make-icon.swift
import AppKit

func broom(in rect: NSRect, color: NSColor) {
    let scale = rect.width / 18
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
    color.set()

    let handle = NSBezierPath()
    handle.move(to: point(15.9, 16.4))
    handle.line(to: point(10.3, 10.8))
    handle.lineWidth = 1.6 * scale
    handle.lineCapStyle = .round
    handle.stroke()

    let band = NSBezierPath()
    band.move(to: point(8.0, 12.5))
    band.line(to: point(12.0, 8.5))
    band.lineWidth = 2.0 * scale
    band.lineCapStyle = .round
    band.stroke()

    let bristles = NSBezierPath()
    bristles.move(to: point(7.2, 11.9))
    bristles.line(to: point(2.3, 8.9))
    bristles.curve(to: point(8.4, 2.6), controlPoint1: point(3.4, 6.2), controlPoint2: point(5.6, 3.8))
    bristles.line(to: point(11.4, 7.7))
    bristles.close()
    bristles.fill()

    for (center, radius, alpha) in [(point(12.6, 3.4), 0.9, 0.95), (point(15.2, 5.6), 0.75, 0.75), (point(15.6, 2.2), 0.6, 0.55)] {
        color.withAlphaComponent(color.alphaComponent * alpha).set()
        let r = radius * scale
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
    }
}

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

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.set()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.40, green: 0.90, blue: 0.78, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.66, alpha: 1),
    ])!.draw(in: shape, angle: -70)

    // A soft highlight across the top, like light on glass.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let highlight = NSBezierPath(ovalIn: NSRect(x: body.minX - body.width * 0.2, y: body.midY + body.height * 0.08,
                                                width: body.width * 1.4, height: body.height * 0.9))
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!.draw(in: highlight, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let glyph = body.insetBy(dx: body.width * 0.2, dy: body.width * 0.2)
    broom(in: glyph.offsetBy(dx: 0, dy: -size * 0.012), color: NSColor.black.withAlphaComponent(0.12))
    broom(in: glyph, color: .white)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let folder = "Sweep/Assets.xcassets/AppIcon.appiconset"
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try icon(pixels: points * scale).write(to: URL(fileURLWithPath: "\(folder)/\(name)"))
    images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(folder)/Contents.json"))
print("Wrote \(images.count) icon sizes to \(folder)")
