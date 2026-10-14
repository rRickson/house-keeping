import SweepAnalyze
import SweepDesign
import SweepKit
import SwiftUI

/// The three lists beside the treemap: largest files, largest folders, and
/// files nobody has touched for a year. They cover the folder on screen.
struct AnalyzeSidePanel: View {
    @Bindable var model: AnalyzeModel

    private var items: [AnalyzeItem] {
        switch model.listKind {
        case .files: model.lists.largestFiles
        case .folders: model.lists.largestFolders
        case .untouched: model.lists.untouched
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("List", selection: $model.listKind) {
                ForEach(AnalyzeModel.ListKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Largest files, largest folders, and files not changed for a year")

            if items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, selection: $model.selection) { item in
                    AnalyzeItemRow(item: item, kind: model.listKind, context: model.context)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: AnalyzeItem.ID.self) { paths in
                    if let path = paths.first, let item = items.first(where: { $0.path == path }) {
                        AnalyzeItemMenu(model: model, item: item, showsMapAction: true)
                    }
                } primaryAction: { paths in
                    if let path = paths.first { model.reveal(path) }
                }
            }
        }
        .sweepCard(padding: 8)
        .sweepAnimation(value: model.listKind)
    }

    private var emptyTitle: String {
        switch model.listKind {
        case .files: "No files"
        case .folders: "No folders"
        case .untouched: "Nothing untouched"
        }
    }

    private var emptySymbol: String {
        switch model.listKind {
        case .files: "doc"
        case .folders: "folder"
        case .untouched: "clock"
        }
    }

    private var emptyDescription: String {
        switch model.listKind {
        case .files: "This folder has no files of its own."
        case .folders: "This folder has no folders inside it."
        case .untouched: "Every file here was changed within the last year."
        }
    }
}

private struct AnalyzeItemRow: View {
    let item: AnalyzeItem
    let kind: AnalyzeModel.ListKind
    let context: SweepContext

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder" : item.category.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.category.color)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            SizeText(item.bytes, font: .system(.callout, design: .rounded))
        }
        .padding(.vertical, 2)
        .help(context.abbreviate(item.path))
    }

    private var detail: String {
        switch kind {
        case .files: context.abbreviate(item.parentPath)
        case .folders: AnalyzeFormat.files(item.fileCount) + " · " + context.abbreviate(item.parentPath)
        case .untouched: AnalyzeFormat.lastChanged(item.modified)
        }
    }
}

/// The context menu of a tile or a list row: Move to Trash, Reveal in Finder, Add to Exclusions.
struct AnalyzeItemMenu: View {
    let model: AnalyzeModel
    let item: AnalyzeItem
    /// An aggregate ("312 other files") has no path of its own: only its folder can be revealed.
    var isAggregate = false
    var showsMapAction = false

    var body: some View {
        if isAggregate {
            Button("Reveal Folder in Finder", systemImage: "folder") { model.reveal(item.path) }
        } else {
            // The item is offered only when the guard would let it through.
            if model.trashDenyReason(item.path) == nil {
                Button("Move to Trash", systemImage: "trash") { model.requestTrash(item) }
            }
            Button("Reveal in Finder", systemImage: "magnifyingglass") { model.reveal(item.path) }
            if showsMapAction {
                Button("Show in Treemap", systemImage: "square.split.2x2") { model.showInMap(item.path) }
            }
            Divider()
            if model.isExcluded(item.path) {
                Button("Remove from Exclusions", systemImage: "eye") { model.toggleExclusion(item.path) }
            } else {
                Button("Add to Exclusions", systemImage: "eye.slash") { model.toggleExclusion(item.path) }
            }
        }
    }
}
