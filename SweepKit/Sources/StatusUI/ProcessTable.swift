import SweepDesign
import SweepKit
import SweepMetrics
import SwiftUI

/// The process list: sortable, with pinned rows on top.
///
/// Drawn with plain stacks rather than SwiftUI's `Table`. `Table` sits on
/// `NSTableView`, which logs "reentrant operation in its NSTableView delegate"
/// (soon an assert) when every row moves once a second, as they do here.
struct ProcessTable: View {
    @Bindable var model: StatusModel
    /// Already filtered and sorted, pinned rows first.
    let rows: [ProcessSample]

    private enum Column {
        static let pin: CGFloat = 16
        static let cpu: CGFloat = 72
        static let memory: CGFloat = 92
        static let pid: CGFloat = 64
        static let user: CGFloat = 112
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, process in
                        row(process, isAlternate: index.isMultiple(of: 2))
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Column.pin, height: 1)
            sortHeader("Process", key: .name, comparator: KeyPathComparator(\.name), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("CPU %", key: .cpu, comparator: KeyPathComparator(\.cpuSortValue, order: .reverse), alignment: .trailing)
                .frame(width: Column.cpu, alignment: .trailing)
            sortHeader("Memory", key: .memory, comparator: KeyPathComparator(\.memorySortValue, order: .reverse), alignment: .trailing)
                .frame(width: Column.memory, alignment: .trailing)
            sortHeader("PID", key: .pid, comparator: KeyPathComparator(\.pid), alignment: .trailing)
                .frame(width: Column.pid, alignment: .trailing)
            sortHeader("User", key: .user, comparator: KeyPathComparator(\.userSortValue), alignment: .leading)
                .frame(width: Column.user, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// A column title that sorts by its column; clicking the active one flips the direction.
    private func sortHeader(_ title: String, key: ProcessSortKey, comparator: KeyPathComparator<ProcessSample>, alignment: Alignment) -> some View {
        let sort = model.sort
        let isActive = sort.key == key
        return Button {
            if isActive, var current = model.sortOrder.first {
                current.order = current.order == .forward ? .reverse : .forward
                model.sortOrder = [current]
            } else {
                model.sortOrder = [comparator]
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if isActive {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title)")
    }

    // MARK: Rows

    private func row(_ process: ProcessSample, isAlternate: Bool) -> some View {
        let isSelected = model.selection == process.id
        return HStack(spacing: 8) {
            PinMark(isPinned: model.isPinned(process)) { model.togglePin(process) }
                .frame(width: Column.pin)
            HStack(spacing: 6) {
                ProcessIcon(image: model.icon(for: process))
                Text(process.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NumberCell(text: StatusFormat.processCPU(process.cpuPercent))
                .frame(width: Column.cpu)
            NumberCell(text: process.residentBytes.map(StatusFormat.memory) ?? "—")
                .frame(width: Column.memory)
            NumberCell(text: String(process.pid))
                .foregroundStyle(.secondary)
                .frame(width: Column.pid)
            Text(process.ownerName ?? String(process.ownerUID))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Column.user, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            isSelected ? AnyShapeStyle(.tint.opacity(0.22))
                : isAlternate ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary.opacity(0.35))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selection = isSelected ? nil : process.id }
        .contextMenu {
            Button(model.isPinned(process) ? "Unpin" : "Pin to Top") { model.togglePin(process) }
            if let path = process.executablePath {
                Button("Reveal in Finder") { Finder.reveal(process.bundlePath ?? path) }
            }
            Divider()
            Button("Quit Process…") { model.askToQuit(process) }
                .disabled(model.quitRefusal(for: process) != nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A filled pin on pinned rows; clicking it unpins. Unpinned rows stay empty.
private struct PinMark: View {
    let isPinned: Bool
    let toggle: () -> Void

    var body: some View {
        if isPinned {
            Button(action: toggle) {
                Image(systemName: "pin.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Unpin")
            .accessibilityLabel("Pinned")
        }
    }
}

struct ProcessIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "gearshape")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// Right-aligned digits that do not shift as they change.
private struct NumberCell: View {
    let text: String

    var body: some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
