import SweepKit
import SwiftUI

/// The 8-point grid and corner radii every Sweep view uses.
public enum SweepMetric {
    public static let grid: CGFloat = 8
    public static let panelRadius: CGFloat = 20
    public static let cardRadius: CGFloat = 12
    public static let popoverWidth: CGFloat = 360
}

public enum SweepAccent: String, CaseIterable, Identifiable, Sendable {
    case mint, teal, blue, indigo, purple, pink, orange, green

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var color: Color {
        switch self {
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        }
    }

    public init(name: String) { self = SweepAccent(rawValue: name) ?? .mint }
}

extension RiskTier {
    /// System colours, so they adapt to dark mode: Safe green, Caution orange, Ask purple.
    public var color: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .ask: .purple
        }
    }

    public var explanation: String {
        switch self {
        case .safe: "Rebuilt automatically. The only cost is re-download or rebuild time."
        case .caution: "Rebuilt, but slowly, or breaks offline work until rebuilt."
        case .ask: "May hold things you chose or made. Removed only item by item."
        }
    }
}

/// The small coloured dot that marks a risk tier.
public struct RiskDot: View {
    private let tier: RiskTier
    public init(_ tier: RiskTier) { self.tier = tier }

    public var body: some View {
        Circle()
            .fill(tier.color)
            .frame(width: 7, height: 7)
            .help("\(tier.title): \(tier.explanation)")
            .accessibilityLabel(tier.title)
    }
}

/// A risk tier as a small capsule label, for review lists.
public struct RiskBadge: View {
    private let tier: RiskTier
    public init(_ tier: RiskTier) { self.tier = tier }

    public var body: some View {
        Text(tier.title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tier.color)
            .background(tier.color.opacity(0.14), in: Capsule())
            .help(tier.explanation)
    }
}

extension Animation {
    /// The standard Sweep motion: quick and under 400 ms.
    public static let sweep = Animation.snappy(duration: 0.3)
}

extension View {
    /// Animates with the standard motion, or a plain crossfade when Reduce Motion is on.
    public func sweepAnimation<V: Equatable>(value: V) -> some View {
        modifier(MotionModifier(value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeInOut(duration: 0.2) : .sweep, value: value)
    }
}
