import SweepDesign
import SweepKit
import SwiftUI

/// The full version of the menu bar list: every catalog item, including the
/// Ask tier, whose entries are picked one by one.
struct DevCachesView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: CatalogGroup?
    @State private var expanded: Set<String> = []
    @State private var showConfirm = false
    @State private var showMissing = false
    @Namespace private var chipNamespace

    private var visibleGroups: [CatalogGroup] {
        CatalogGroup.allCases.filter { group in
            model.orderedResults.contains { $0.item.group == group && ($0.status != .missing || showMissing) }
        }
    }

    private func rows(in group: CatalogGroup) -> [ScanResult] {
        model.orderedResults.filter { $0.item.group == group && ($0.status != .missing || showMissing) }
    }

    /// Everything ticked: whole items plus the entries picked inside Ask-tier items.
    private var selections: [CleanSelection] {
        var result = model.checkedResults.map { CleanSelection($0) }
        for item in model.orderedResults where item.selectable && item.status.isReady {
            if let picked = model.pickedTargets[item.id], !picked.isEmpty {
                result.append(CleanSelection(item, targetIDs: picked))
            }
        }
        return result
    }

    private var selectedBytes: Int64 { selections.reduce(0) { $0 + $1.result.bytes(for: $1.targetIDs) } }

    private var needsConfirmation: Bool {
        selections.contains { $0.result.item.risk != .safe }
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader("Dev Caches", subtitle: subtitle) {
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
            }
            chips
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(filter.map { [$0] } ?? visibleGroups, id: \.self) { group in
                        groupSection(group)
                    }
                    Toggle("Show tools that were not found", isOn: $showMissing.animation(.sweep))
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 96)
            }
        }
        .overlay(alignment: .bottom) { actionBar }
        .sheet(isPresented: $showConfirm) {
            ReviewSheet(selections: selections) {
                model.clean(selections, source: "window")
            }
        }
    }

    private var subtitle: String {
        if model.isScanning { return "Scanning…" }
        return "\(ByteFormat.string(model.totalBytes)) across \(model.orderedResults.filter { $0.status != .missing && $0.bytes > 0 }.count) caches"
    }

    // MARK: Filter chips

    /// Group chips in one glass container; the selection pill slides between them.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 12) {
                HStack(spacing: 6) {
                    chip("All", group: nil)
                    ForEach(visibleGroups, id: \.self) { group in
                        chip(group.title, group: group)
                    }
                }
                .padding(4)
            }
        }
    }

    private func chip(_ title: String, group: CatalogGroup?) -> some View {
        let isSelected = filter == group
        return Button {
            withAnimation(.sweep) { filter = group }
        } label: {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.clear)
                            .glassOrMaterial(in: Capsule(), interactive: true)
                            .glassMorphID("selection", in: chipNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Groups and rows

    private func groupSection(_ group: CatalogGroup) -> some View {
        let rows = rows(in: group)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title).font(.headline)
                Spacer()
                SizeText(model.bytes(in: group), font: .system(.callout, design: .rounded))
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, result in
                    DevCacheRow(result: result, isExpanded: expanded.contains(result.id)) {
                        withAnimation(.sweep) {
                            if !expanded.insert(result.id).inserted { expanded.remove(result.id) }
                        }
                    }
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 40)
                    }
                }
            }
            .sweepCard(padding: 4)
        }
    }

    // MARK: Action bar

    @ViewBuilder
    private var actionBar: some View {
        if let cleaning = model.cleaning {
            FloatingActionBar("Cleaning", bytes: cleaning.freed, isBusy: true, action: {}) {
                Button("Cancel") { model.cancelClean() }
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
            }
        } else {
            let count = selections.count
            FloatingActionBar(
                count == 0 ? "Nothing selected" : "Clean \(count) item\(count == 1 ? "" : "s")",
                bytes: count == 0 ? nil : selectedBytes,
                isEnabled: count > 0
            ) {
                if needsConfirmation {
                    showConfirm = true
                } else {
                    model.clean(selections, source: "window")
                }
            }
        }
    }
}

/// A catalog item in the main window, with its paths and, for Ask-tier items, its entries.
struct DevCacheRow: View {
    @Environment(AppModel.self) private var model
    let result: ScanResult
    let isExpanded: Bool
    let toggle: () -> Void

    private var picked: Set<String> { model.pickedTargets[result.id] ?? [] }
    private var isCleaning: Bool { model.cleaning?.active.contains(result.id) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                ToolGlyph(item: result.item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.item.name)
                    Text(caption.text)
                        .font(.caption)
                        .foregroundStyle(caption.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if isCleaning {
                    ProgressView().controlSize(.small)
                } else if case .freed(let bytes) = model.outcomes[result.id], bytes > 0 {
                    Label("\(ByteFormat.string(bytes)) freed", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.tint)
                } else {
                    if result.selectable, !picked.isEmpty {
                        Text("\(picked.count) picked").font(.caption).foregroundStyle(.secondary)
                    }
                    SizeText(result.bytes, font: .system(.body, design: .rounded))
                    RiskBadge(result.item.risk).frame(width: 62, alignment: .trailing)
                    checkbox.frame(width: 20)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if isExpanded {
                details
                    .padding(.leading, 62)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }

    private var caption: (text: String, isError: Bool) {
        switch model.outcomes[result.id] {
        case .failed(let reason): return (reason, true)
        case .skipped(let reason): return (reason, false)
        case .freed, nil: break
        }
        if let reason = result.status.reason { return (reason, false) }
        return (result.actionDescription, false)
    }

    @ViewBuilder
    private var checkbox: some View {
        if model.isCheckable(result) {
            Toggle("", isOn: Binding(get: { model.isChecked(result) }, set: { model.setChecked(result, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.cleaning != nil)
        } else if result.selectable, result.status.isReady {
            Image(systemName: "list.bullet").font(.caption).foregroundStyle(.tertiary).help("Pick entries inside")
        } else {
            Image(systemName: result.status.isReady ? "minus" : "lock").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = result.item.note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if result.isUpperBound {
                Text("Frees up to this much: the tool keeps what is still in use.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(result.roots, id: \.self) { root in
                HStack(spacing: 6) {
                    Text(model.context.abbreviate(root))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        Finder.reveal(root)
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                }
            }
            HStack(spacing: 12) {
                if result.source != .none {
                    Text("Location \(result.source.description)").font(.caption).foregroundStyle(.tertiary)
                }
                if let modified = result.lastModified {
                    Text("Last changed \(modified.relativeDescription)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if result.selectable || result.targets.count > 1 {
                entries
            }
        }
    }

    /// The file list of the item. For Ask-tier items each entry has its own checkbox.
    private var entries: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(result.targets.prefix(60)) { target in
                HStack(spacing: 8) {
                    if result.selectable {
                        Toggle("", isOn: Binding(
                            get: { picked.contains(target.id) },
                            set: { isOn in
                                var set = picked
                                if isOn { set.insert(target.id) } else { set.remove(target.id) }
                                model.pickedTargets[result.id] = set
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(!result.status.isReady || model.cleaning != nil)
                    }
                    Text(target.label).lineLimit(1).truncationMode(.middle)
                    if let detail = target.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let modified = target.lastModified {
                        Text(modified.relativeDescription).font(.caption).foregroundStyle(.tertiary)
                    }
                    SizeText(target.bytes, font: .system(.callout, design: .rounded))
                }
                .font(.callout)
            }
            if result.targets.count > 60 {
                Text("and \(result.targets.count - 60) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

/// The preview shown before anything outside the Safe tier is removed: what goes, and how much.
struct ReviewSheet: View {
    let selections: [CleanSelection]
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var total: Int64 { selections.reduce(0) { $0 + $1.result.bytes(for: $1.targetIDs) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review before cleaning").font(.headline)
            Text("Caution items rebuild slowly. Ask items may hold things you chose or made and do not come back on their own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(selections.sorted { $0.result.item.risk > $1.result.item.risk }, id: \.result.id) { selection in
                        let result = selection.result
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(result.item.name)
                                RiskBadge(result.item.risk)
                                Spacer()
                                SizeText(result.bytes(for: selection.targetIDs), font: .system(.callout, design: .rounded))
                            }
                            if let ids = selection.targetIDs {
                                ForEach(result.targets.filter { ids.contains($0.id) }) { target in
                                    Text(target.label)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            } else {
                                Text(result.actionDescription).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            .sweepCard()
            HStack {
                Text("Total").foregroundStyle(.secondary)
                SizeText(total, font: .system(.body, design: .rounded).weight(.semibold))
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clean") {
                    dismiss()
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
