import AppKit
import SweepKit
import SwiftUI

/// A byte count whose digits roll when the value changes. Numbers use SF Pro
/// Rounded with monospaced digits so totals do not jitter while counting.
public struct SizeText: View {
    private let bytes: Int64
    private let font: Font
    private let unitFont: Font?

    /// - Parameters:
    ///   - font: font of the number.
    ///   - unitFont: font of the unit; defaults to the number's font.
    public init(_ bytes: Int64, font: Font = .system(.body, design: .rounded), unitFont: Font? = nil) {
        self.bytes = bytes
        self.font = font
        self.unitFont = unitFont
    }

    public var body: some View {
        let parts = ByteFormat.parts(bytes)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.value)
                .font(font)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(bytes)))
            Text(parts.unit)
                .font(unitFont ?? font)
                .foregroundStyle(.secondary)
        }
        .sweepAnimation(value: bytes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ByteFormat.string(bytes))
    }
}

/// The glowing capsule that floats at the bottom of a tool: "Clean 12 items · 8.2 GB".
public struct FloatingActionBar<Accessory: View>: View {
    private let title: String
    private let bytes: Int64?
    private let systemImage: String
    private let isBusy: Bool
    private let isEnabled: Bool
    private let action: () -> Void
    private let accessory: Accessory

    public init(
        _ title: String,
        bytes: Int64? = nil,
        systemImage: String = "sparkles",
        isBusy: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.bytes = bytes
        self.systemImage = systemImage
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.action = action
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: 12) {
            accessory
            Button(action: action) {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: systemImage)
                    }
                    Text(title)
                    if let bytes {
                        Text("·").opacity(0.7)
                        SizeText(bytes, font: .system(.body, design: .rounded).weight(.semibold))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .prominentActionStyle()
            .controlSize(.large)
            .disabled(!isEnabled || isBusy)
        }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .padding(.bottom, 18)
    }
}

extension FloatingActionBar where Accessory == EmptyView {
    public init(
        _ title: String,
        bytes: Int64? = nil,
        systemImage: String = "sparkles",
        isBusy: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(title, bytes: bytes, systemImage: systemImage, isBusy: isBusy, isEnabled: isEnabled, action: action) { EmptyView() }
    }
}

/// The header every tool starts with: a title, one line of context, and trailing controls.
public struct ToolHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String
    private let trailing: Trailing

    public init(_ title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

extension ToolHeader where Trailing == EmptyView {
    public init(_ title: String, subtitle: String) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// Used and free space of a volume as one rounded bar. The fill slides when the value changes.
public struct DiskBar: View {
    @Environment(\.sweepAccent) private var accent
    private let space: DiskSpace
    private let height: CGFloat

    public init(_ space: DiskSpace, height: CGFloat = 8) {
        self.space = space
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            let fraction = space.total > 0 ? Double(space.used) / Double(space.total) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [accent, accent.lightened(0.3)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * fraction))
            }
        }
        .frame(height: height)
        .sweepAnimation(value: space.used)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ByteFormat.string(space.used)) used, \(ByteFormat.string(space.free)) free")
    }
}

/// A tool's icon, in the style of System Settings: a coloured rounded tile
/// with a white monogram or SF Symbol. The colour and letters come from the
/// catalog entry, so rules added through `catalog.d` get an icon too. An image
/// named `glyph-<id>` in the app's asset catalog replaces the drawn tile.
public struct ToolGlyph: View {
    private let id: String
    private let symbol: String
    private let tint: Color
    private let monogram: String?
    private let size: CGFloat

    public init(item: CatalogItem, size: CGFloat = 22) {
        self.id = item.id
        self.symbol = item.symbol ?? "shippingbox.fill"
        self.tint = item.tint.flatMap(Color.init(hex:)) ?? Color(nsColor: .systemGray)
        self.monogram = item.monogram.flatMap { $0.isEmpty ? nil : String($0.prefix(4)) }
        self.size = size
    }

    public init(id: String, symbol: String?, size: CGFloat = 22) {
        self.id = id
        self.symbol = symbol ?? "shippingbox.fill"
        self.tint = Color(nsColor: .systemGray)
        self.monogram = nil
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = NSImage(named: "glyph-\(id)") {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(tint.gradient)
                    .overlay {
                        Group {
                            if let monogram {
                                Text(monogram)
                                    .font(.system(size: size * Self.scale(for: monogram.count), weight: .bold, design: .rounded))
                                    .minimumScaleFactor(0.6)
                                    .lineLimit(1)
                            } else {
                                Image(systemName: symbol)
                                    .font(.system(size: size * 0.5, weight: .semibold))
                            }
                        }
                        // Dark ink on pale tiles, white on everything else.
                        .foregroundStyle(tint.isLight ? Color.black.opacity(0.75) : Color.white)
                        .padding(size * 0.08)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func scale(for letters: Int) -> CGFloat {
        switch letters {
        case 1: 0.6
        case 2: 0.48
        case 3: 0.37
        default: 0.3
        }
    }
}

extension Color {
    /// A colour from "#RRGGBB" or "RRGGBB". Nil when the text is not a hex colour.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// True when white text on this colour would be hard to read.
    var isLight: Bool {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent > 0.68
    }
}

public enum Finder {
    @MainActor
    public static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor
    public static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }
}

public enum Haptics {
    /// The trackpad tap that marks a finished clean.
    @MainActor
    public static func done() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }
}

extension Date {
    /// "3 days ago"
    public var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // The interface is English only, so the phrase must be too.
        formatter.locale = Locale(identifier: "en_US")
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
