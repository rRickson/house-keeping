import SweepDesign
import SweepKit
import SweepOptimize
import SwiftUI

/// One task: symbol, title, description, and on the right either a checkbox,
/// the reason it is held back, or how its run is going.
struct OptimizeRow: View {
    let row: OptimizeModel.Row
    /// True while a run is in progress; the selection cannot change then.
    let isLocked: Bool
    let toggle: () -> Void
    let setSelected: (Bool) -> Void

    @State private var showsPreview = false
    @State private var isHovered = false

    private var task: OptimizeTask { row.task }

    var body: some View {
        VStack(alignment: .leading, spacing: SweepMetric.grid) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: task.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.title)
                        if task.needsAdmin { AdminBadge() }
                    }
                    Text(task.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let preview = row.check?.preview, !preview.isEmpty {
                        Button {
                            showsPreview.toggle()
                        } label: {
                            Label(previewTitle(preview.count), systemImage: "chevron.right")
                                .labelStyle(PreviewDisclosureStyle(isOpen: showsPreview))
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 12)
                trailing
            }

            if showsPreview, let preview = row.check?.preview, !preview.isEmpty {
                PreviewList(items: preview)
                    .padding(.leading, 40)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(isHovered && canToggle ? 0.5 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { if canToggle { toggle() } }
        .onHover { isHovered = $0 }
        .sweepAnimation(value: row.phase)
        .sweepAnimation(value: showsPreview)
    }

    private var canToggle: Bool { !isLocked && row.check?.isReady == true }

    /// After a task did its work there is usually nothing left for it to do;
    /// the result says more than "none found" would.
    private var resultReplacesReason: Bool {
        guard case .finished(let outcome) = row.phase, outcome.status != .skipped,
              case .nothingToDo = row.check?.readiness else { return false }
        return true
    }

    private func previewTitle(_ count: Int) -> String {
        showsPreview ? "Hide details" : "Show \(count) \(count == 1 ? "item" : "items")"
    }

    // MARK: Trailing state

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 10) {
            switch row.phase {
            case .idle:
                EmptyView()
            case .authorizing:
                Text("Waiting for password")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Running")
            case .finished(let outcome):
                // A task a gate skipped shows the gate's reason below, once.
                if !(outcome.status == .skipped && row.check?.isReady == false) {
                    OutcomeLabel(outcome: outcome)
                }
            }

            if let check = row.check {
                if let reason = check.reason, !resultReplacesReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .help("Skipped: \(reason)")
                } else if check.isReady, row.phase != .running, row.phase != .authorizing {
                    Toggle(task.title, isOn: Binding(get: { row.isSelected }, set: { setSelected($0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(isLocked)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking")
            }
        }
        // As wide as its content, wrapping only when a reason runs long.
        .frame(maxWidth: 260, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// What a finished task reports: a checkmark and a line, or the reason it did not finish.
private struct OutcomeLabel: View {
    let outcome: OptimizeOutcome

    private var text: String {
        if outcome.status == .done, outcome.bytesFreed > 0, !outcome.message.contains(ByteFormat.string(outcome.bytesFreed)) {
            return "\(outcome.message) · \(ByteFormat.string(outcome.bytesFreed))"
        }
        return outcome.message
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            switch outcome.status {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: outcome)
                    .accessibilityLabel("Done")
            case .failed:
                // Informative, not alarming: orange, the Caution colour.
                Image(systemName: "exclamationmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Did not finish")
            case .skipped:
                EmptyView()
            }
        }
        .help(text)
        .transition(.opacity)
    }
}

private struct AdminBadge: View {
    var body: some View {
        Label("Admin", systemImage: "lock.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .help("Needs administrator rights")
            .accessibilityLabel("Needs administrator rights")
    }
}

/// The exact things a task would act on, shown before it runs.
private struct PreviewList: View {
    let items: [TaskCheck.PreviewItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: SweepMetric.grid) {
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .help(item.path ?? item.title)
                .contextMenu {
                    if let path = item.path {
                        Button("Reveal in Finder") { Finder.reveal(path) }
                    }
                }
            }
        }
    }
}

/// A text link with a chevron that turns when its content is open.
private struct PreviewDisclosureStyle: LabelStyle {
    let isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
                .font(.caption2)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
    }
}
