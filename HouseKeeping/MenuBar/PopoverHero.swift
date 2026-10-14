import SweepDesign
import SweepKit
import SwiftUI

/// The illustration at the top of the popover: the witch flying across the
/// moon over a night sky. She drifts gently, and trails sparks while a scan
/// or a clean is running.
struct PopoverHero: View {
    let isBusy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let witch = WitchIcon.silhouette(height: 120, color: NSColor(red: 0.07, green: 0.05, blue: 0.16, alpha: 1))

    /// Fixed so the sky looks the same every time.
    private static let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, alpha: Double)] = [
        (0.06, 0.52, 2.2, 0.9), (0.18, 0.62, 1.4, 0.6), (0.30, 0.46, 1.6, 0.7), (0.44, 0.40, 1.2, 0.5),
        (0.88, 0.20, 2.0, 0.8), (0.93, 0.55, 1.3, 0.6), (0.78, 0.85, 1.5, 0.5), (0.12, 0.88, 1.2, 0.4),
        (0.52, 0.92, 1.1, 0.4), (0.70, 0.12, 1.3, 0.6), (0.33, 0.78, 1.0, 0.5), (0.97, 0.36, 1.1, 0.5),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    LinearGradient(colors: [Night.skyTop, Night.skyMiddle, Night.background], startPoint: .top, endPoint: .bottom)

                    ForEach(Array(Self.stars.enumerated()), id: \.offset) { index, star in
                        Circle()
                            .fill(Color.white)
                            .frame(width: star.size, height: star.size)
                            .opacity(star.alpha * (0.75 + 0.25 * sin(time * 1.3 + Double(index))))
                            .position(x: size.width * star.x, y: size.height * star.y)
                    }

                    // The moon and its glow.
                    // Kept below the header so the status line stays readable.
                    let moon = min(size.height * 0.56, 140)
                    let moonCenter = CGPoint(x: size.width * 0.62, y: size.height * 0.66)
                    Circle()
                        .fill(RadialGradient(colors: [Color(red: 1, green: 0.9, blue: 0.6).opacity(0.45), .clear],
                                             center: .center, startRadius: moon * 0.4, endRadius: moon))
                        .frame(width: moon * 2, height: moon * 2)
                        .position(moonCenter)
                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.97, blue: 0.82), Color(red: 0.98, green: 0.83, blue: 0.5)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: moon, height: moon)
                        .position(moonCenter)

                    // Sparks from the broom while work is going on.
                    if isBusy {
                        ForEach(0..<6, id: \.self) { index in
                            let phase = (time * 0.9 + Double(index) / 6).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .fill(Color(red: 1, green: 0.88, blue: 0.55))
                                .frame(width: 4, height: 4)
                                .opacity(1 - phase)
                                .position(x: size.width * 0.3 - phase * 70, y: size.height * 0.76 + phase * 22 + CGFloat(index % 3) * 4)
                        }
                    }

                    Image(nsImage: Self.witch)
                        .resizable()
                        .scaledToFit()
                        .frame(height: moon * 0.82)
                        .rotationEffect(.degrees(-6 + sin(time * 0.8) * 2))
                        .position(x: size.width * 0.52, y: size.height * 0.66 + sin(time * 1.1) * 4)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
