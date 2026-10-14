import SweepDesign
import SweepKit
import SwiftUI

/// Every catalog item as a card, with the same presets and filters as the
/// popover. Ask-tier items open a detail where their entries are picked.
struct DevCachesView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: CatalogGroup?
    @State private var detailID: String?
    @State private var showMissing = false
    @State private var showConfirm = false

    private var groupsInView: [CatalogGroup] {
        CatalogGroup.allCases.filter { !rows(in: $0).isEmpty }
    }

    /// All items of a group, Ask tier included; tools that were not found only on request.
    private func rows(in group: CatalogGroup) -> [QuickRow] {
        model.engine.catalog.items(in: group).compactMap { item in
            guard !model.settings.disabledItems.contains(item.id) else { return nil }
            let loading = model.pending.contains(item.id)
            guard let result = model.results[item.id] else {
                return loading ? QuickRow(item: item, result: nil, isLoading: true) : nil
            }
            if result.status == .missing && !showMissing { return nil }
            return QuickRow(item: item, result: result, isLoading: loading)
        }
    }

    /// Everything selected: ticked items plus the entries picked inside Ask-tier items.
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
    private var needsConfirmation: Bool { selections.contains { $0.result.item.risk != .safe } }
    private var checkableInView: Int { model.checkableResults.filter { filter == nil || $0.item.group == filter }.count }
    private var selectedInView: Int { model.checkedCount(in: filter) }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader("Dev Caches", subtitle: subtitle) {
                NightCircleButton(symbol: "arrow.clockwise", size: 34, isEnabled: !model.isBusy) { model.rescan() }
                    .help("Rescan")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                ForEach(CleanPreset.allCases) { preset in
                                    PresetTile(preset: preset, isActive: model.activePreset == preset) {
                                        withAnimation(.sweep) { model.apply(preset) }
                                    }
                                }
                            }
                            .disabled(model.cleaning != nil)
                        }
                        .frame(maxWidth: 420)
                        SelectionSummary(legendCount: 6)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            GroupPill(title: "All", count: 0, isSelected: filter == nil) { withAnimation(.sweep) { filter = nil } }
                            ForEach(groupsInView, id: \.self) { group in
                                GroupPill(title: group.title, count: model.checkedCount(in: group), isSelected: filter == group) {
                                    withAnimation(.sweep) { filter = group }
                                }
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Text(filter?.title ?? "Everything").font(.callout.weight(.semibold)).foregroundStyle(Night.text)
                        Text("· \(selectedInView) of \(checkableInView) selected").font(.callout).foregroundStyle(Night.secondary)
                        Spacer()
                        Toggle("Show tools that were not found", isOn: $showMissing.animation(.sweep))
                            .toggleStyle(.checkbox)
                            .font(.callout)
                            .foregroundStyle(Night.secondary)
                            .padding(.trailing, 8)
                        NightCapsuleButton(title: "All", isOn: checkableInView > 0 && selectedInView == checkableInView) {
                            withAnimation(.sweep) { model.setAll(true, in: filter) }
                        }
                        NightCapsuleButton(title: "None", isOn: checkableInView > 0 && selectedInView == 0) {
                            withAnimation(.sweep) { model.setAll(false, in: filter) }
                        }
                    }
                    .disabled(model.cleaning != nil)

                    ForEach(filter.map { [$0] } ?? groupsInView, id: \.self) { group in
                        let groupRows = rows(in: group)
                        let largest = groupRows.compactMap(\.result?.bytes).max() ?? 0
                        if !groupRows.isEmpty {
                            HStack {
                                NightSectionLabel(title: group.title)
                                SizeText(model.bytes(in: group), font: .system(.caption, design: .rounded))
                                    .foregroundStyle(Night.tertiary)
                            }
                            .padding(.top, 6)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                                ForEach(groupRows) { row in
                                    CacheCard(row: row, largest: largest) { open(row.id) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 96)
            }
        }
        .overlay(alignment: .bottom) { actionBar }
        .inspector(isPresented: Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } })) {
            ScrollView {
                if let detailID {
                    CacheDetailView(id: detailID) { withAnimation(.sweep) { self.detailID = nil } }
                        .padding(.top, 12)
                        .id(detailID)
                }
            }
            .background(Night.background)
            .inspectorColumnWidth(min: 340, ideal: 380, max: 460)
        }
        .sheet(isPresented: $showConfirm) {
            ReviewSheet(selections: selections) { model.clean(selections, source: "window") }
        }
    }

    private var subtitle: String {
        if let progress = model.scanProgress { return "Scanning \(progress.done) of \(progress.total)" }
        return "\(ByteFormat.string(model.totalBytes)) across \(model.orderedResults.filter { $0.status != .missing && $0.bytes > 0 }.count) caches"
    }

    private func open(_ id: String) {
        withAnimation(.sweep) { detailID = id }
    }

    @ViewBuilder
    private var actionBar: some View {
        if let cleaning = model.cleaning {
            FloatingActionBar("Cleaning", bytes: cleaning.freed, isBusy: true, action: {}) {
                Button("Cancel") { model.cancelClean() }
                    .buttonStyle(NightSecondaryButtonStyle())
            }
        } else {
            let count = selections.count
            FloatingActionBar(
                count == 0 ? "Nothing selected" : "Clean \(count) item\(count == 1 ? "" : "s")",
                bytes: count == 0 ? nil : selectedBytes,
                isEnabled: count > 0
            ) {
                if needsConfirmation { showConfirm = true } else { model.clean(selections, source: "window") }
            }
        }
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
