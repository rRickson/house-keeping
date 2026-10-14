import SweepDesign
import SweepJunk
import SweepKit
import SwiftUI

/// One category of the review list: a header and its rows on a plain card.
struct JunkGroupCard: View {
    let group: JunkGroup
    let model: JunkViewModel
    @Binding var expandedRows: Set<String>
    @Binding var showsAll: Bool

    /// Long categories start folded to their largest rows.
    private static let foldedCount = 6

    var body: some View {
        let visible = showsAll ? group.entries : Array(group.entries.prefix(Self.foldedCount))
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(alignment: .leading, spacing: 12) {
                ForEach(visible) { entry in
                    JunkRowView(
                        entry: entry,
                        model: model,
                        isExpanded: Binding(
                            get: { expandedRows.contains(entry.id) },
                            set: { if $0 { expandedRows.insert(entry.id) } else { expandedRows.remove(entry.id) } }
                        )
                    )
                    .transition(.opacity)
                }
            }
            if group.entries.count > Self.foldedCount {
                Button(showsAll ? "Show fewer" : "Show all \(group.entries.count)") {
                    showsAll.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .font(.callout)
            }
        }
        .sweepCard(padding: 16)
        .sweepAnimation(value: showsAll)
        .sweepAnimation(value: visible.map(\.id))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: group.category.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.category.title).font(.headline)
                Text(group.category.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if group.isSizing, group.bytes == 0 {
                    ProgressView().controlSize(.small)
                } else {
                    SizeText(group.bytes, font: .system(.title3, design: .rounded))
                }
                // Ask-tier entries are chosen one by one, never as a group.
                if group.category.risk != .ask, group.entries.count > 1, !model.isBusy {
                    let all = model.allSelected(in: group)
                    Button(all ? "Deselect all" : "Select all") {
                        model.setSelected(group, !all)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .font(.caption)
                }
            }
        }
    }
}

/// One entry: checkbox, risk dot, name, size and Reveal in Finder. Clicking
/// the row shows the paths it would remove.
struct JunkRowView: View {
    let entry: JunkEntry
    let model: JunkViewModel
    @Binding var isExpanded: Bool

    private static let shownPaths = 6

    var body: some View {
        let state = model.state(of: entry)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(entry.name, isOn: Binding(
                    get: { model.isSelected(entry) },
                    set: { model.setSelected(entry, $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(entry.isBlocked || model.isBusy)

                RiskDot(entry.risk)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                trailing(state)
                Button {
                    Finder.reveal(Array(entry.paths.prefix(10)))
                } label: {
                    Image(systemName: "magnifyingglass")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(entry.name) in Finder")

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            if isExpanded {
                details.transition(.opacity)
            }
        }
        .opacity(entry.isBlocked ? 0.7 : 1)
        .sweepAnimation(value: isExpanded)
        .sweepAnimation(value: state)
    }

    /// The line under the name: why the row is held back, else what it is.
    private var caption: String? {
        entry.blockedReason ?? model.problemNote(for: entry) ?? entry.detail
    }

    @ViewBuilder
    private func trailing(_ state: JunkRowState) -> some View {
        switch state {
        case .sizing, .cleaning:
            ProgressView().controlSize(.small)
        case .ready:
            if entry.bytes > 0 {
                SizeText(entry.bytes)
            }
        case .waiting:
            SizeText(entry.bytes).opacity(0.5)
        case .finished(let result):
            finished(result)
        }
    }

    @ViewBuilder
    private func finished(_ result: JunkEntryResult) -> some View {
        switch result.status {
        case .cleaned, .partial, .dryRun:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(result.movedToTrash ? "In Trash" : "Freed").foregroundStyle(.secondary)
                SizeText(result.bytes)
            }
        case .skipped, .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(result.status == .failed ? "Not cleaned" : "Skipped").foregroundStyle(.secondary)
            }
            .help(result.reason ?? "")
        }
    }

    private var details: some View {
        let paths = entry.paths
        let extra = paths.count - Self.shownPaths
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(paths.prefix(Self.shownPaths), id: \.self) { path in
                Text(model.engine.context.abbreviate(path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if extra > 0 {
                Text("and \(extra.formatted()) more")
            }
            Text(summary).padding(.top, 2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // Lines up with the name, past the checkbox and the risk dot.
        .padding(.leading, 40)
    }

    /// "Last changed 3 days ago · 1,204 files · Deleted permanently"
    private var summary: String {
        var parts: [String] = []
        if let date = entry.lastModified {
            let verb: String
            switch entry.category {
            case .installers: verb = "Downloaded"
            case .deviceBackups: verb = "Backed up"
            default: verb = "Last changed"
            }
            parts.append("\(verb) \(date.relativeDescription)")
        }
        if entry.fileCount > 1 {
            parts.append("\(entry.fileCount.formatted()) files")
        }
        parts.append(model.removalDescription(for: entry.category))
        return parts.joined(separator: " · ")
    }
}

/// Lists the Caution and Ask entries the user ticked before anything is cleaned.
struct JunkConfirmationSheet: View {
    let entries: [JunkEntry]
    let totalCount: Int
    let totalBytes: Int64
    let removal: (JunkCategory) -> String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Check these before cleaning").font(.title3.weight(.semibold))
                Text("They are not rebuilt automatically. Everything else you ticked is safe to remove.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            RiskDot(entry.risk)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                Text("\(entry.risk.title) · \(removal(entry.category))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // The category's note once, on its first row.
                                if index == 0 || entries[index - 1].category != entry.category {
                                    Text(entry.category.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            SizeText(entry.bytes)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: onConfirm) {
                    HStack(spacing: 6) {
                        Text("Clean \(totalCount) \(totalCount == 1 ? "item" : "items")")
                        Text("·").foregroundStyle(.secondary)
                        SizeText(totalBytes, font: .system(.body, design: .rounded).weight(.semibold))
                    }
                }
                .prominentActionStyle()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
