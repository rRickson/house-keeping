import SweepDesign
import SweepKit
import SwiftUI

/// Disk bar, reclaimable totals per tool, one "Clean all Safe" button, and the last five operations.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let open: (SidebarSection) -> Void

    private var safeSelection: [CleanSelection] {
        model.engine.oneClickSelection(from: model.orderedResults).filter { $0.result.item.risk == .safe }
    }

    private var safeBytes: Int64 { safeSelection.reduce(0) { $0 + $1.result.bytes } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                reclaimable
                recent
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
            }
        }
    }

    // MARK: Disk and primary action

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.volumeName).font(.title2.weight(.semibold))
                    Text("\(ByteFormat.string(model.disk.used)) used of \(ByteFormat.string(model.disk.total))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    SizeText(model.disk.free, font: .system(size: 34, weight: .semibold, design: .rounded),
                             unitFont: .system(.title3, design: .rounded))
                    Text("free").font(.callout).foregroundStyle(.secondary)
                }
            }
            DiskBar(model.disk, height: 10)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        SizeText(safeBytes, font: .system(.title, design: .rounded).weight(.semibold),
                                 unitFont: .system(.title3, design: .rounded))
                        Text("in safe developer caches").foregroundStyle(.secondary)
                    }
                    Text(heroDetail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let cleaning = model.cleaning {
                    ProgressView(value: cleaning.fraction).frame(width: 140)
                    Button("Cancel") { model.cancelClean() }
                } else {
                    Button {
                        model.clean(safeSelection, source: "window")
                    } label: {
                        Label("Clean All Safe", systemImage: "sparkles")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                    .prominentActionStyle()
                    .controlSize(.large)
                    .disabled(safeSelection.isEmpty)
                }
            }
        }
        .sweepCard(padding: 20)
    }

    private var heroDetail: String {
        if model.isScanning { return "Scanning…" }
        if let banner = model.banner { return "Freed \(ByteFormat.string(banner.bytes)) from \(banner.count) cache\(banner.count == 1 ? "" : "s")" }
        let count = safeSelection.count
        return count == 0 ? "Nothing to clean right now" : "\(count) cache\(count == 1 ? "" : "s"), rebuilt automatically when needed"
    }

    // MARK: Reclaimable per tool

    private struct ToolTotal: Identifiable {
        var id: String
        var name: String
        var bytes: Int64
        var risk: RiskTier
    }

    private var toolTotals: [ToolTotal] {
        model.orderedResults
            .filter { $0.bytes >= 50_000_000 }
            .sorted { $0.bytes > $1.bytes }
            .prefix(10)
            .map { ToolTotal(id: $0.id, name: $0.item.name, bytes: $0.bytes, risk: $0.item.risk) }
    }

    private var reclaimable: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reclaimable by tool").font(.headline)
                Spacer()
                ForEach(RiskTier.allCases, id: \.self) { tier in
                    HStack(spacing: 4) {
                        RiskDot(tier)
                        Text(tier.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Show All") { open(.devCaches) }
                    .buttonStyle(.link)
                    .padding(.leading, 8)
            }
            if toolTotals.isEmpty {
                Text(model.isScanning ? "Scanning…" : "No developer caches larger than 50 MB.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                let largest = Double(toolTotals.first?.bytes ?? 1)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(toolTotals) { tool in
                        GridRow {
                            Text(tool.name).lineLimit(1)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(tool.risk.color.gradient)
                                    .frame(width: max(6, proxy.size.width * Double(tool.bytes) / largest))
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 8)
                            SizeText(tool.bytes, font: .system(.callout, design: .rounded))
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .sweepAnimation(value: toolTotals.map(\.bytes))
            }
        }
        .sweepCard(padding: 20)
    }

    // MARK: Recent operations

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                Button("History") { open(.history) }
                    .buttonStyle(.link)
            }
            if model.history.isEmpty {
                Text("Nothing has been cleaned yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.history.prefix(5)) { operation in
                        OperationRow(operation: operation)
                    }
                }
            }
        }
        .sweepCard(padding: 20)
    }
}

/// One line of history: when, what, how much.
struct OperationRow: View {
    let operation: SweepOperation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if operation.kind != .optimize {
                SizeText(operation.bytesFreed, font: .system(.callout, design: .rounded))
            }
        }
    }

    private var symbol: String {
        switch operation.kind {
        case .devCaches: "hammer"
        case .projects: "folder.badge.gearshape"
        case .junk: "sparkles"
        case .uninstall: "trash"
        case .optimize: "bolt"
        case .analyze: "square.split.2x2"
        }
    }

    private var title: String {
        let names = operation.cleanedItemNames
        if names.isEmpty { return operation.kind.title }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }

    private var subtitle: String {
        var text = "\(operation.kind.title) · \(operation.date.formatted(date: .abbreviated, time: .shortened))"
        if !operation.failures.isEmpty { text += " · \(operation.failures.count) failed" }
        return text
    }
}
