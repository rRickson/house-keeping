import AppKit
import SwiftUI

/// The menu bar icon: a monochrome template broom, so it adapts to light and dark menu bars.
/// SF Symbols has no broom, so it is drawn here on an 18-point grid.
enum BroomIcon {
    /// - Parameters:
    ///   - activeDot: which of the three dust specks is lit (cycles while scanning or cleaning); nil lights none.
    ///   - badge: draws the small dot that says reclaimable space passed the threshold.
    ///   - tilt: degrees of rotation, for the one-off wiggle.
    static func image(activeDot: Int? = nil, badge: Bool = false, tilt: CGFloat = 0, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = size / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }

            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 9 * scale, yBy: 9 * scale)
            transform.rotate(byDegrees: tilt)
            transform.translateX(by: -9 * scale, yBy: -9 * scale)
            transform.concat()
            NSColor.black.set()

            // Handle, top right down to the head.
            let handle = NSBezierPath()
            handle.move(to: point(15.9, 16.4))
            handle.line(to: point(10.3, 10.8))
            handle.lineWidth = 1.6 * scale
            handle.lineCapStyle = .round
            handle.stroke()

            // Band where the bristles are bound.
            let band = NSBezierPath()
            band.move(to: point(8.0, 12.5))
            band.line(to: point(12.0, 8.5))
            band.lineWidth = 2.0 * scale
            band.lineCapStyle = .round
            band.stroke()

            // Bristles fanning out to the bottom left.
            let bristles = NSBezierPath()
            bristles.move(to: point(7.2, 11.9))
            bristles.line(to: point(2.3, 8.9))
            bristles.curve(to: point(8.4, 2.6), controlPoint1: point(3.4, 6.2), controlPoint2: point(5.6, 3.8))
            bristles.line(to: point(11.4, 7.7))
            bristles.close()
            bristles.fill()

            // Gaps between the bristles.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for (from, to) in [(point(4.3, 7.0), point(7.9, 9.6)), (point(6.3, 4.6), point(9.5, 8.2))] {
                let gap = NSBezierPath()
                gap.move(to: from)
                gap.line(to: to)
                gap.lineWidth = 0.9 * scale
                gap.lineCapStyle = .round
                gap.stroke()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSGraphicsContext.restoreGraphicsState()

            // Dust specks being swept away.
            let specks = [point(12.6, 3.4), point(15.2, 5.6), (point(15.6, 2.2))]
            for (index, center) in specks.enumerated() {
                let lit = activeDot.map { $0 % specks.count == index } ?? false
                NSColor.black.withAlphaComponent(activeDot == nil ? 0.55 : (lit ? 1 : 0.25)).set()
                let radius = (lit ? 1.15 : 0.9) * scale
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }

            if badge {
                NSColor.black.set()
                let radius = 1.7 * scale
                let center = point(3.0, 15.6)
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sweep"
        return image
    }
}

/// The icon as a SwiftUI view, for the app's own windows.
struct BroomMark: View {
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: BroomIcon.image(size: size))
            .renderingMode(.template)
            .accessibilityHidden(true)
    }
}
