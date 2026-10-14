import SweepDesign
import SweepKit
import SwiftUI

/// A short sweep of particles across the popover when a clean finishes, about 600 ms.
struct ParticleSweep: View {
    let trigger: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?

    private struct Particle {
        var lane: Double
        var delay: Double
        var size: Double
        var drift: Double
    }

    private static let particles: [Particle] = {
        var generator = SystemRandomNumberGenerator()
        return (0..<36).map { _ in
            Particle(
                lane: Double.random(in: 0.05...0.95, using: &generator),
                delay: Double.random(in: 0...0.25, using: &generator),
                size: Double.random(in: 2...5, using: &generator),
                drift: Double.random(in: -18...18, using: &generator)
            )
        }
    }()

    private let duration = 0.6

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { timeline in
            Canvas { context, size in
                guard let start else { return }
                let elapsed = timeline.date.timeIntervalSince(start)
                for particle in Self.particles {
                    let progress = (elapsed - particle.delay) / (duration - 0.25)
                    guard progress > 0, progress < 1 else { continue }
                    let eased = 1 - pow(1 - progress, 3)
                    let x = eased * (size.width + 20) - 10
                    let y = particle.lane * size.height + particle.drift * eased
                    let alpha = sin(progress * .pi) * 0.7
                    let rect = CGRect(x: x, y: y, width: particle.size, height: particle.size)
                    context.fill(Path(ellipseIn: rect), with: .style(.tint.opacity(alpha)))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, newValue in
            guard newValue != nil, !reduceMotion else { return }
            start = Date()
            Task {
                try? await Task.sleep(for: .seconds(duration + 0.1))
                start = nil
            }
        }
    }
}

/// The capsule shown by the hotkey: the running total while cleaning, then what was freed.
struct HUDView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if model.cleaning != nil || model.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: model.banner?.id)
            }
            if let cleaning = model.cleaning {
                Text("Cleaning")
                SizeText(cleaning.freed, font: .system(.title3, design: .rounded).weight(.semibold))
            } else if model.isScanning {
                Text("Scanning caches")
            } else if let banner = model.banner {
                Text("Freed")
                SizeText(banner.bytes, font: .system(.title3, design: .rounded).weight(.semibold))
            } else {
                Text("Nothing to clean")
            }
        }
        .font(.title3)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glassOrMaterial(in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Rows fade in one after another, 30 ms apart.
struct StaggeredAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 4)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25).delay(reduceMotion ? 0 : Double(min(index, 12)) * 0.03)) { shown = true }
            }
    }
}

extension View {
    func staggered(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}
