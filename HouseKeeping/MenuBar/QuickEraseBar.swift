import SweepDesign
import SweepKit
import SwiftUI

/// A grid of icons, one per developer cache that is safe to erase right now.
/// One click erases that cache; clicks made while another is being erased queue up.
struct QuickEraseBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.quickEraseItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick erase")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                // Six to a row at the popover's width, wrapping onto as many rows as needed.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                    ForEach(items) { result in
                        QuickEraseTile(result: result)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 10)
        }
    }
}

private struct QuickEraseTile: View {
    @Environment(AppModel.self) private var model
    let result: ScanResult
    @State private var isHovered = false

    private enum Phase { case idle, loading, queued, erasing, done }

    private var phase: Phase {
        if model.cleaning?.active.contains(result.id) == true { return .erasing }
        if case .freed(let bytes) = model.outcomes[result.id], bytes > 0 { return .done }
        if model.isQueuedForErase(result.id) { return .queued }
        if model.pending.contains(result.id) { return .loading }
        return .idle
    }

    var body: some View {
        Button {
            model.quickErase(result)
        } label: {
            VStack(spacing: 4) {
                ToolGlyph(item: result.item, size: 34)
                    .opacity(phase == .idle ? 1 : 0.35)
                    .overlay { badge }
                    .scaleEffect(isHovered && phase == .idle ? 1.08 : 1)
                Text(caption)
                    .font(.system(.caption2, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(phase == .done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phase != .idle)
        .onHover { isHovered = $0 }
        .sweepAnimation(value: isHovered)
        .help(help)
        .accessibilityLabel("Erase \(result.item.name) cache, \(ByteFormat.string(result.bytes))")
    }

    @ViewBuilder
    private var badge: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .loading, .erasing:
            ProgressView().controlSize(.small)
        case .queued:
            Image(systemName: "clock").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        case .done:
            Image(systemName: "checkmark")
                .font(.callout.weight(.bold))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: phase == .done)
        }
    }

    private var caption: String {
        switch phase {
        case .erasing: "Erasing"
        case .queued: "Queued"
        case .done:
            if case .freed(let bytes) = model.outcomes[result.id] { MenuBarLabel.short(bytes) } else { "Done" }
        case .idle, .loading: MenuBarLabel.short(result.bytes)
        }
    }

    private var help: String {
        switch phase {
        case .idle: "Erase the \(result.item.name) cache · \(ByteFormat.string(result.bytes))"
        case .loading: "Measuring \(result.item.name)"
        case .queued: "\(result.item.name) is next"
        case .erasing: "Erasing \(result.item.name)"
        case .done: "\(result.item.name) erased"
        }
    }
}
