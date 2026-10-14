import SweepDesign
import SweepKit
import SwiftUI

/// What a card says under its name, and whether that is bad news.
@MainActor
private func cardStatus(_ row: QuickRow, model: AppModel, withTier: Bool = true) -> (text: String, isError: Bool) {
    guard let result = row.result else { return ("Measuring…", false) }
    if model.cleaning?.active.contains(row.id) == true { return ("Erasing…", false) }
    switch model.outcomes[row.id] {
    case .freed(let bytes) where bytes > 0: return ("Freed \(ByteFormat.string(bytes))", false)
    case .failed(let reason): return (reason, true)
    case .skipped(let reason): return (reason, false)
    default: break
    }
    if let reason = result.status.reason { return (reason, false) }
    if result.selectable {
        let picked = model.pickedTargets[result.id]?.count ?? 0
        let text = picked > 0 ? "\(picked) of \(result.targets.count) picked" : "\(ByteFormat.string(result.bytes)) · pick entries"
        return (text, false)
    }
    let size = (result.isUpperBound ? "up to " : "") + ByteFormat.string(result.bytes)
    return (withTier ? "\(size) · \(result.item.risk.title)" : size, false)
}

/// A cache as a card: tap it to tick or untick it, like switching a light on.
/// The chevron opens its detail.
struct CacheCard: View {
    @Environment(AppModel.self) private var model
    let row: QuickRow
    /// The largest size in view, for the bar along the bottom.
    let largest: Int64
    let open: () -> Void

    private var isSelected: Bool {
        guard let result = row.result else { return false }
        if result.selectable { return !(model.pickedTargets[result.id] ?? []).isEmpty }
        return model.isChecked(result)
    }
    private var isWorking: Bool { row.result == nil || row.isLoading || model.cleaning?.active.contains(row.id) == true }

    var body: some View {
        let status = cardStatus(row, model: model, withTier: false)
        HStack(spacing: 10) {
            ToolGlyph(item: row.item, size: 36)
                .grayscale(isSelected ? 0 : 1)
                .opacity(isSelected ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isSelected ? Night.text : Night.text.opacity(0.85))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 5) {
                    Circle().fill(row.item.risk.color).frame(width: 5, height: 5)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(status.isError ? Night.failure : Night.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 26)
        .frame(height: 74)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            Group {
                if isWorking {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Button(action: open) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Night.tertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Details")
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 6)
        }
        .overlay(alignment: .bottomLeading) { sizeBar }
        .nightCard(glow: isSelected ? row.item.tintColor : nil)
        .contentShape(RoundedRectangle(cornerRadius: Night.cardRadius, style: .continuous))
        .onTapGesture { toggle() }
        .contextMenu {
            Button("Details", action: open)
            if let root = row.result?.roots.first {
                Button("Reveal in Finder") { Finder.reveal(root) }
            }
        }
        .animation(.sweep, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Details", open)
    }

    /// A thin bar along the bottom, as long as the cache is big compared with the largest one in view.
    private var sizeBar: some View {
        GeometryReader { proxy in
            let bytes = row.result?.bytes ?? 0
            let fraction = largest > 0 ? min(Double(bytes) / Double(largest), 1) : 0
            Capsule()
                .fill(row.item.tintColor)
                .frame(width: max((proxy.size.width - 28) * fraction, bytes > 0 ? 6 : 0), height: 3)
                .opacity(isSelected ? 0.95 : 0.25)
                .position(x: 14 + max((proxy.size.width - 28) * fraction, 6) / 2, y: proxy.size.height - 5)
        }
        .allowsHitTesting(false)
    }

    private func toggle() {
        // Items whose entries are picked one by one open their detail instead.
        if row.result?.selectable == true { return open() }
        guard let result = row.result, model.isCheckable(result), model.cleaning == nil else { return }
        model.setChecked(result, !isSelected)
    }
}

/// The biggest cache in view, full width, with its own erase button.
struct FeaturedCacheCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sweepAccent) private var accent
    let result: ScanResult
    let open: () -> Void
    let erase: () -> Void

    private var isSelected: Bool { model.isChecked(result) }
    private var isErasing: Bool { model.cleaning?.active.contains(result.id) == true }

    var body: some View {
        let status = cardStatus(QuickRow(item: result.item, result: result, isLoading: model.pending.contains(result.id)), model: model)
        HStack(spacing: 12) {
            ToolGlyph(item: result.item, size: 44)
                .grayscale(isSelected ? 0 : 1)
                .opacity(isSelected ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.item.name)
                    .font(.headline)
                    .foregroundStyle(Night.text)
                    .lineLimit(1)
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(status.isError ? Night.failure : Night.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                SizeText(result.bytes, font: .system(size: 22, weight: .light, design: .rounded),
                         unitFont: .system(.caption, design: .rounded))
                    .foregroundStyle(Night.text)
            }
            NightCircleButton(symbol: isErasing ? "hourglass" : "sparkles", size: 40, prominent: true,
                              isEnabled: result.status.isReady && result.bytes > 0 && model.cleaning == nil, action: erase)
                .help("Erase \(result.item.name) now")
        }
        .padding(14)
        .nightCard(glow: isSelected ? accent : nil)
        .contentShape(RoundedRectangle(cornerRadius: Night.cardRadius, style: .continuous))
        .onTapGesture {
            guard model.isCheckable(result), model.cleaning == nil else { return }
            model.setChecked(result, !isSelected)
        }
        .contextMenu {
            Button("Details", action: open)
            if let root = result.roots.first {
                Button("Reveal in Finder") { Finder.reveal(root) }
            }
        }
        .animation(.sweep, value: isSelected)
    }
}

/// One of the five presets at the top, like a lighting scene.
struct PresetTile: View {
    @Environment(\.sweepAccent) private var accent
    let preset: CleanPreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                Text(preset.title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(isActive ? Night.text : Night.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background {
                let shape = RoundedRectangle(cornerRadius: Night.tileRadius, style: .continuous)
                if isActive {
                    shape
                        .fill(LinearGradient(colors: [accent.opacity(0.45), accent.opacity(0.18)], startPoint: .top, endPoint: .bottom))
                        .overlay(shape.strokeBorder(accent.lightened(0.3).opacity(0.7), lineWidth: 1))
                        .shadow(color: accent.opacity(0.4), radius: 10, y: 3)
                } else {
                    shape.fill(Night.card).overlay(shape.strokeBorder(Night.stroke, lineWidth: 1))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Night.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Select the \(preset.title.lowercased()) caches")
    }
}

/// A group filter pill with the number of caches ticked in it.
struct GroupPill: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Night.text : Night.secondary)
                if count > 0, !isSelected || title != "All" {
                    CountBadge(count: count)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(Night.cardRaised).overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
