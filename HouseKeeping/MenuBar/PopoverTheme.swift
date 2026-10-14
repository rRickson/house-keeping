import SweepDesign
import SweepKit
import SwiftUI

/// The popover's own look: a dark night-sky panel with soft cards, glowing
/// selections and one bright blue action. It stays dark in light mode too.
enum Night {
    static let skyTop = Color(red: 0.27, green: 0.19, blue: 0.40)
    static let skyMiddle = Color(red: 0.13, green: 0.10, blue: 0.22)
    static let background = Color(red: 0.055, green: 0.06, blue: 0.10)
    static let card = Color.white.opacity(0.055)
    static let cardRaised = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.32)
    static let blue = Color(red: 0.19, green: 0.49, blue: 0.98)
    static let blueLight = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let green = Color(red: 0.32, green: 0.86, blue: 0.47)
    static let badge = Color(red: 0.98, green: 0.62, blue: 0.22)
    static let failure = Color(red: 1.0, green: 0.45, blue: 0.42)

    static let cardRadius: CGFloat = 22
    static let tileRadius: CGFloat = 18
}

/// A round icon button. `prominent` is the glowing blue one; the rest are quiet.
struct NightCircleButton: View {
    let symbol: String
    var size: CGFloat = 40
    var prominent = false
    /// Draws a progress ring around a prominent button, 0 to 1.
    var progress: Double?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(prominent ? AnyShapeStyle(LinearGradient(colors: [Night.blueLight, Night.blue], startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(Night.cardRaised))
                    .overlay(Circle().strokeBorder(Color.white.opacity(prominent ? 0.25 : 0.08), lineWidth: 1))
                    .shadow(color: prominent && isEnabled ? Night.blue.opacity(0.55) : .clear, radius: 12, y: 3)
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

/// A capsule button for small secondary actions ("All", "None").
struct NightCapsuleButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(Night.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Night.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Night.stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The orange count bubble on a group pill.
struct CountBadge: View {
    let count: Int

    var body: some View {
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
struct NightSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.4)
            .foregroundStyle(Night.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// A dark card; when `glow` is set, the card takes that colour and lights up.
    func nightCard(radius: CGFloat = Night.cardRadius, glow: Color? = nil) -> some View {
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
    var tintColor: Color { tint.flatMap(Color.init(hex:)) ?? Night.blue }
}
