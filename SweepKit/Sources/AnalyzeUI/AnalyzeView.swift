import SweepAnalyze
import SweepDesign
import SweepKit
import SwiftUI

/// The Analyze tool of the main window: a treemap of any folder or volume,
/// coloured by file type, with drill-down and the lists of what is largest.
public struct AnalyzeView: View {
    @State private var model: AnalyzeModel
    @State private var hovered: AnalyzeTree.NodeID?

    public init(engine: SweepEngine) {
        _model = State(initialValue: AnalyzeModel(engine: engine))
    }

    /// For previews: a view over a model that already holds a tree.
    init(model: AnalyzeModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ToolHeader("Analyze", subtitle: subtitle) {
                HStack(spacing: 8) {
                    TargetMenu(model: model)
                    primaryButton
                }
            }
            content
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.load() }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingTrash
        ) { _ in
            Button("Move to Trash") { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = nil }
        } message: { item in
            Text("\(ByteFormat.string(item.bytes)) · \(model.context.abbreviate(item.path))\nYou can put it back from the Trash.")
        }
    }

    private var trashTitle: String {
        "Move “\(model.pendingTrash?.name ?? "")” to the Trash?"
    }

    private var subtitle: String {
        switch model.phase {
        case .idle:
            return "See what takes up space in any folder or volume."
        case .scanning:
            return "Reading \(model.context.abbreviate(model.target.path))…"
        case .ready:
            guard let tree = model.tree else { return "" }
            // Under a minute old reads better as "just now" than as a count of seconds.
            let age = Date().timeIntervalSince(tree.scannedAt) < 60 ? "just now" : tree.scannedAt.relativeDescription
            return "\(model.context.abbreviate(tree.rootPath)) · scanned \(age)"
        }
    }

    /// The one prominent action: scan, or scan again.
    @ViewBuilder private var primaryButton: some View {
        switch model.phase {
        case .idle:
            Button("Scan", systemImage: "square.split.2x2") { model.scan() }
                .prominentActionStyle()
                .keyboardShortcut(.defaultAction)
        case .scanning:
            Button("Cancel", role: .cancel) { model.cancelScan() }
                .secondaryActionStyle()
                .keyboardShortcut(.cancelAction)
        case .ready:
            Button("Rescan", systemImage: "arrow.clockwise") { model.scan() }
                .prominentActionStyle()
                .keyboardShortcut("r", modifiers: .command)
                .help("Results are kept for 24 hours. Rescan to read the folder again.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            AnalyzeIdleView(model: model)
        case .scanning:
            AnalyzeProgressView(model: model)
        case .ready:
            if let tree = model.tree {
                results(tree)
            }
        }
    }

    private func results(_ tree: AnalyzeTree) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                AnalyzeBreadcrumb(model: model, tree: tree, hovered: hovered)
                TreemapView(
                    tree: tree,
                    version: model.treeVersion,
                    focus: model.focus,
                    highlighted: model.highlightedTile,
                    retrying: model.retrying,
                    hovered: $hovered,
                    onOpen: { model.open($0) },
                    onRetry: { model.retry($0) }
                ) { node in
                    AnalyzeItemMenu(model: model, item: tree.item(for: node), isAggregate: tree[node].kind == .aggregate)
                }
                .padding(4)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: SweepMetric.cardRadius, style: .continuous))
                .overlay {
                    if tree[model.focus].bytes == 0, tree.unreadableFolders(under: model.focus).isEmpty {
                        ContentUnavailableView("Nothing here", systemImage: "square.dashed", description: Text("This folder takes up no space."))
                    }
                }
                AnalyzeLegend(categories: tree.categoryBytes(of: model.focus))
                AnalyzeFootnotes(model: model, tree: tree)
            }
            AnalyzeSidePanel(model: model)
                .frame(width: 300)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

// MARK: - Header controls

/// Picks the folder or volume to analyze.
private struct TargetMenu: View {
    let model: AnalyzeModel

    var body: some View {
        Menu {
            Button("Home", systemImage: "house") { model.choose(model.context.home) }
            let volumes = model.volumes
            if !volumes.isEmpty {
                Section("Volumes") {
                    ForEach(volumes, id: \.url) { volume in
                        Button(volume.name, systemImage: "internaldrive") { model.choose(volume.url) }
                    }
                }
            }
            Divider()
            Button("Choose Folder…", systemImage: "folder") { model.chooseWithPanel() }
        } label: {
            Label(model.targetName, systemImage: model.targetIsHome ? "house" : "folder")
        }
        .menuStyle(.button)
        .secondaryActionStyle()
        .fixedSize()
        .disabled(model.phase == .scanning)
        .help("Choose the folder or volume to analyze")
    }
}

// MARK: - Before and during a scan

private struct AnalyzeIdleView: View {
    let model: AnalyzeModel

    var body: some View {
        ContentUnavailableView {
            Label("Nothing scanned yet", systemImage: "square.split.2x2")
                .symbolRenderingMode(.hierarchical)
        } description: {
            VStack(spacing: 4) {
                Text("Scan “\(model.targetName)” to see its folders and files as a map, sized by the space they take.")
                if let failure = model.failure {
                    Text(failure)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AnalyzeProgressView: View {
    let model: AnalyzeModel

    var body: some View {
        let progress = model.progress
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 240)
            SizeText(progress.bytes, font: .system(size: 40, weight: .semibold, design: .rounded), unitFont: .system(.title2, design: .rounded))
            Text("\(AnalyzeFormat.files(progress.files)) in \(AnalyzeFormat.folders(progress.directories))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(progress.files)))
            Text(model.context.abbreviate(progress.currentPath))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
        }
        .sweepAnimation(value: progress.files)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Around the treemap

/// The path from the scanned folder to the one on screen. Each step is a button.
private struct AnalyzeBreadcrumb: View {
    let model: AnalyzeModel
    let tree: AnalyzeTree
    let hovered: AnalyzeTree.NodeID?

    var body: some View {
        let chain = tree.ancestors(of: model.focus)
        // What the trailing numbers describe: the hovered tile, else the folder on screen.
        let subject = hovered.flatMap { tree.isValid($0) ? $0 : nil } ?? model.focus
        HStack(spacing: 8) {
            Button("Enclosing Folder", systemImage: "chevron.up") { model.goUp() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(chain.count < 2)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Go to the enclosing folder")
            HStack(spacing: 4) {
                ForEach(Array(steps(chain).enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    if let node = step {
                        let isCurrent = node == model.focus
                        Button(name(of: node)) { model.open(node) }
                            .buttonStyle(.plain)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .allowsHitTesting(!isCurrent)
                    } else {
                        Text("…").foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if subject != model.focus {
                    Text(tree.displayName(of: subject))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
                SizeText(tree[subject].bytes, font: .system(.body, design: .rounded).weight(.semibold))
                Text(AnalyzeFormat.files(tree[subject].fileCount))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .layoutPriority(1)
        }
    }

    /// The chain to show: all of it when short, otherwise the scanned folder,
    /// an ellipsis, and the last three folders. Nil stands for the ellipsis.
    private func steps(_ chain: [AnalyzeTree.NodeID]) -> [AnalyzeTree.NodeID?] {
        guard chain.count > 5 else { return chain }
        return [chain[0], nil] + chain.suffix(3)
    }

    private func name(of node: AnalyzeTree.NodeID) -> String {
        guard node == tree.root else { return tree.displayName(of: node) }
        if tree.rootPath == model.context.home.path { return "Home" }
        return tree.rootPath == "/" ? (model.volume?.name ?? "Startup Disk") : tree.displayName(of: node)
    }
}

/// What the colours mean, with how much of the folder on screen each type holds.
private struct AnalyzeLegend: View {
    let categories: CategoryBytes
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FlowLayout(spacing: 16, lineSpacing: 6) {
                ForEach(categories.ranked, id: \.category) { entry in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(entry.category.tint(scheme))
                            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(entry.category.color.opacity(0.6), lineWidth: 0.5))
                            .frame(width: 11, height: 11)
                        Text(entry.category.title)
                            .font(.callout)
                        SizeText(entry.bytes, font: .system(.callout, design: .rounded))
                    }
                    .accessibilityElement(children: .combine)
                }
        }
        .sweepAnimation(value: categories)
    }
}

/// Lays views out left to right and wraps to a new line when the row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + lineHeight))
    }
}

/// The quiet lines under the map: the result of the last action, folders that
/// could not be read, and the space no file accounts for.
private struct AnalyzeFootnotes: View {
    let model: AnalyzeModel
    let tree: AnalyzeTree

    var body: some View {
        let unreadable = tree.unreadableFolders(under: model.focus)
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.notice {
                HStack(spacing: 6) {
                    Image(systemName: notice.succeeded ? "checkmark.circle" : "info.circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(notice.succeeded ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .symbolEffect(.bounce, value: notice.id)
                    Text(notice.text)
                    if let bytes = notice.bytes {
                        SizeText(bytes, font: .system(.callout, design: .rounded))
                    }
                }
                .font(.callout)
                .transition(.opacity)
            }
            if !unreadable.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                    Text("\(AnalyzeFormat.folders(unreadable.count)) could not be read, so \(unreadable.count == 1 ? "its" : "their") size is missing.")
                        .foregroundStyle(.secondary)
                    Button("Retry") { model.retryAllUnreadable() }
                        .buttonStyle(.link)
                        .disabled(!model.retrying.isEmpty)
                    if unreadable.contains(where: { tree[$0].flags.contains(.permissionDenied) }) {
                        Button("Full Disk Access…") { model.openFullDiskAccessSettings() }
                            .buttonStyle(.link)
                            .help("Folders of other apps need Full Disk Access. This opens the pane in System Settings.")
                    }
                }
                .font(.callout)
            }
            if let volume = model.volume, volume.hasHiddenSpace {
                HiddenSpaceNote(volume: volume)
            }
        }
        .sweepAnimation(value: model.notice)
    }
}

/// Explains space that is used but is not a file: purgeable space and APFS local snapshots.
private struct HiddenSpaceNote: View {
    let volume: VolumeSpace

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            if volume.purgeable > 0 {
                SizeText(volume.purgeable, font: .system(.callout, design: .rounded))
            }
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .help(volume.snapshots.map(\.name).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        let name = volume.name ?? "this volume"
        let count = volume.snapshots.count
        var snapshots = ""
        if count > 0 {
            snapshots = count == 1 ? "1 local snapshot" : "\(count) local snapshots"
            if let newest = volume.snapshots.compactMap(\.date).max() {
                snapshots += " (newest \(newest.relativeDescription))"
            }
        }
        switch (volume.purgeable > 0, count > 0) {
        case (true, true):
            return "purgeable on \(name), plus \(snapshots). macOS frees both by itself when space is needed, so no file on the map accounts for them."
        case (true, false):
            return "purgeable on \(name). macOS frees it by itself when space is needed, so no file on the map accounts for it."
        case (false, true):
            return "\(name) has \(snapshots). They hold space no file on the map accounts for; macOS removes them by itself."
        case (false, false):
            return ""
        }
    }
}
