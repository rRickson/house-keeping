import AppKit
import SweepKit
import SwiftUI

/// House Keeping's look: a dark night-sky panel with soft cards, glowing
/// selections and one bright accent colour. Used by the popover and the main
/// window alike, in light mode too.
public enum Night {
    public static let skyTop = Color(red: 0.27, green: 0.19, blue: 0.40)
    public static let skyMiddle = Color(red: 0.13, green: 0.10, blue: 0.22)
    public static let background = Color(red: 0.055, green: 0.06, blue: 0.10)
    public static let card = Color.white.opacity(0.055)
    public static let cardRaised = Color.white.opacity(0.09)
    public static let stroke = Color.white.opacity(0.08)
    public static let text = Color.white
    public static let secondary = Color.white.opacity(0.56)
    public static let tertiary = Color.white.opacity(0.32)
    /// The default accent; Settings can pick another.
    public static let blue = Color(red: 0.19, green: 0.49, blue: 0.98)
    public static let green = Color(red: 0.32, green: 0.86, blue: 0.47)
    public static let badge = Color(red: 0.98, green: 0.62, blue: 0.22)
    public static let failure = Color(red: 1.0, green: 0.45, blue: 0.42)

    public static let cardRadius: CGFloat = 22
    public static let tileRadius: CGFloat = 18

    /// The window background: night sky at the top, fading to the panel colour.
    public static var backdrop: some View {
        LinearGradient(colors: [skyMiddle, background, background], startPoint: .top, endPoint: .bottom)
    }
}

extension EnvironmentValues {
    /// The accent colour of buttons, fills and glows.
    @Entry public var sweepAccent: Color = Night.blue
}

extension Color {
    /// The colour mixed with white, for the light end of a gradient.
    public func lightened(_ fraction: CGFloat = 0.3) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return Color(nsColor: base.blended(withFraction: fraction, of: .white) ?? base)
    }
}

/// A round icon button. `prominent` is the glowing accent one; the rest are quiet.
public struct NightCircleButton: View {
    @Environment(\.sweepAccent) private var accent
    let symbol: String
    var size: CGFloat
    var prominent: Bool
    /// Draws a progress ring around a prominent button, 0 to 1.
    var progress: Double?
    var isEnabled: Bool
    let action: () -> Void

    public init(symbol: String, size: CGFloat = 40, prominent: Bool = false, progress: Double? = nil, isEnabled: Bool = true,
                action: @escaping () -> Void) {
        self.symbol = symbol
        self.size = size
        self.prominent = prominent
        self.progress = progress
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(prominent ? AnyShapeStyle(LinearGradient(colors: [accent.lightened(0.25), accent], startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(Night.cardRaised))
                    .overlay(Circle().strokeBorder(Color.white.opacity(prominent ? 0.25 : 0.08), lineWidth: 1))
                    .shadow(color: prominent && isEnabled ? accent.opacity(0.55) : .clear, radius: 12, y: 3)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(progress, 0.02))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(4)
                        .animation(.easeOut(duration: 0.3), value: progress)
                }
                Image(systemName: symbol)
                    .font(.system(size: size * (prominent ? 0.4 : 0.36), weight: .semibold))
                    .foregroundStyle(prominent ? Color.white : Night.secondary)
            }
            .frame(width: size, height: size)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// A capsule button for small actions. `isOn` lights it in the accent colour,
/// for buttons that also show a state, such as "All" when everything is selected.
public struct NightCapsuleButton: View {
    @Environment(\.sweepAccent) private var accent
    let title: String
    var isOn: Bool
    let action: () -> Void

    public init(title: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Night.text : Night.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isOn ? AnyShapeStyle(accent.opacity(0.35)) : AnyShapeStyle(Night.card), in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? accent.lightened(0.3).opacity(0.8) : Night.stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The orange count bubble on a group pill.
public struct CountBadge: View {
    let count: Int

    public init(count: Int) { self.count = count }

    public var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Color.black.opacity(0.8))
            .frame(minWidth: 17, minHeight: 17)
            .padding(.horizontal, count > 9 ? 3 : 0)
            .background(Night.badge, in: Capsule())
    }
}

/// Small spaced capitals above a group of cards.
public struct NightSectionLabel: View {
    let title: String

    public init(title: String) { self.title = title }

    public var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.4)
            .foregroundStyle(Night.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The accent capsule for a screen's main action.
public struct NightProminentButtonStyle: ButtonStyle {
    @Environment(\.sweepAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(LinearGradient(colors: [accent.lightened(0.25), accent], startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: isEnabled ? accent.opacity(0.45) : .clear, radius: 10, y: 3)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A quiet capsule for secondary actions.
public struct NightSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Night.text.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Night.cardRaised : Night.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Night.stroke, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    /// A dark card; when `glow` is set, the card takes that colour and lights up.
    public func nightCard(radius: CGFloat = Night.cardRadius, glow: Color? = nil) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            if let glow {
                shape
                    .fill(LinearGradient(colors: [glow.opacity(0.34), glow.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(shape.strokeBorder(glow.opacity(0.55), lineWidth: 1))
                    .shadow(color: glow.opacity(0.35), radius: 14, y: 4)
            } else {
                shape
                    .fill(Night.card)
                    .overlay(shape.strokeBorder(Night.stroke, lineWidth: 1))
            }
        }
    }
}

extension CatalogItem {
    /// The colour of the item's icon tile, used for its glow when selected.
    public var tintColor: Color { tint.flatMap(Color.init(hex:)) ?? Night.blue }
}
