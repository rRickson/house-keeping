import AppKit
import SwiftUI

/// The outline of a witch riding a broom, flying to the right. Drawn on a
/// 110 × 90 grid with the origin at the bottom left; `scale` and `origin`
/// place it. Shared by the menu bar icon and anything else that shows the mark.
enum WitchShape {
    static let size = CGSize(width: 110, height: 90)

    static func draw(scale: CGFloat, origin: CGPoint = .zero) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        func stroke(_ from: NSPoint, _ to: NSPoint, width: CGFloat) {
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = width * scale
            path.lineCapStyle = .round
            path.stroke()
        }

        // Broom: the handle, then the bristles fanning out behind.
        stroke(point(16, 30), point(104, 45), width: 5)
        let bristles = NSBezierPath()
        bristles.move(to: point(24, 35))
        bristles.line(to: point(5, 46))
        bristles.curve(to: point(4, 17), controlPoint1: point(-2, 38), controlPoint2: point(-2, 25))
        bristles.line(to: point(24, 27))
        bristles.close()
        bristles.fill()

        // Cloak: back and shoulders down to the broom.
        let body = NSBezierPath()
        body.move(to: point(38, 33))
        body.curve(to: point(50, 62), controlPoint1: point(33, 48), controlPoint2: point(41, 60))
        body.line(to: point(59, 62))
        body.curve(to: point(69, 39), controlPoint1: point(65, 56), controlPoint2: point(67, 47))
        body.close()
        body.fill()

        // Cape streaming out behind her.
        let cape = NSBezierPath()
        cape.move(to: point(47, 60))
        cape.curve(to: point(20, 56), controlPoint1: point(38, 62), controlPoint2: point(28, 60))
        cape.curve(to: point(40, 40), controlPoint1: point(30, 52), controlPoint2: point(36, 47))
        cape.close()
        cape.fill()

        // Arm reaching for the handle, and a leg with a pointed shoe.
        stroke(point(56, 57), point(77, 42), width: 5)
        stroke(point(61, 38), point(71, 27), width: 5)
        stroke(point(71, 27), point(80, 28), width: 4)

        // Head and a crooked hat.
        NSBezierPath(ovalIn: NSRect(x: origin.x + 48.5 * scale, y: origin.y + 60.5 * scale, width: 15 * scale, height: 15 * scale)).fill()
        stroke(point(43, 71), point(71, 78), width: 4.5)
        let hat = NSBezierPath()
        hat.move(to: point(48, 73))
        hat.line(to: point(67, 77.5))
        hat.curve(to: point(45, 90), controlPoint1: point(63, 86), controlPoint2: point(54, 88))
        hat.curve(to: point(48, 73), controlPoint1: point(51, 85), controlPoint2: point(50, 79))
        hat.close()
        hat.fill()
    }
}

/// The menu bar icon: a monochrome template of the witch on her broom, so it
/// adapts to light and dark menu bars.
enum WitchIcon {
    /// - Parameters:
    ///   - activeDot: which of the three sparks behind the broom is lit (cycles while scanning or cleaning); nil lights none.
    ///   - badge: draws the small dot that says reclaimable space passed the threshold.
    ///   - tilt: degrees of rotation, for the one-off wiggle.
    static func image(activeDot: Int? = nil, badge: Bool = false, tilt: CGFloat = 0, height: CGFloat = 18) -> NSImage {
        let scale = height / WitchShape.size.height
        let size = NSSize(width: WitchShape.size.width * scale, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }

            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: size.width / 2, yBy: size.height / 2)
            transform.rotate(byDegrees: tilt)
            transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
            transform.concat()
            NSColor.black.set()
            WitchShape.draw(scale: scale)
            NSGraphicsContext.restoreGraphicsState()

            // Sparks trailing from the broom.
            let sparks = [point(30, 12), (point(18, 5)), point(8, 10)]
            for (index, center) in sparks.enumerated() {
                let lit = activeDot.map { $0 % sparks.count == index } ?? false
                NSColor.black.withAlphaComponent(activeDot == nil ? 0.5 : (lit ? 1 : 0.25)).set()
                let radius = (lit ? 5.5 : 4.2) * scale
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }

            if badge {
                NSColor.black.set()
                let radius = 8 * scale
                let center = point(98, 78)
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "House Keeping"
        return image
    }
}
