import SweepDesign
import SweepKit
import SwiftUI

/// The menu bar popover: open it, read one number, press one button.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var expanded: String?
    @State private var cautionToConfirm: [ScanResult] = []
    @State private var showCautionSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            primaryAction
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            QuickEraseBar()
            list
            projectsLine
            footer
        }
        .frame(width: SweepMetric.popoverWidth)
        .overlay { ParticleSweep(trigger: model.banner?.id) }
        .background {
            // Esc closes the popover.
            Button("Close") { closePopover() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .onAppear { model.rescanIfStale() }
        .sheet(isPresented: $showCautionSheet) {
            CautionSheet(items: cautionToConfirm) {
                model.clean(model.quickSelection().selections, source: "menubar")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.volumeName).font(.headline)
                Spacer()
                Text(scanStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Button {
                    model.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.pulse, isActive: model.isScanning)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r")
                .disabled(model.isBusy)
                .help("Rescan (⌘R)")
            }
            DiskBar(model.disk)
            HStack {
                Text("\(ByteFormat.string(model.disk.used)) used")
                Spacer()
                Text("\(ByteFormat.string(model.disk.free)) free")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(16)
    }

    private var scanStatus: String {
        if let progress = model.scanProgress { return "Scanning \(progress.done) of \(progress.total)" }
        if model.isScanning { return "Scanning…" }
        guard let lastScan = model.lastScan else { return "" }
        if Date().timeIntervalSince(lastScan) < 60 { return "Scanned just now" }
        return "Scanned \(lastScan.relativeDescription)"
    }

    // MARK: Primary action

    @ViewBuilder
    private var primaryAction: some View {
        if let cleaning = model.cleaning {
            VStack(spacing: 8) {
                ProgressView(value: cleaning.fraction)
                HStack {
                    Text("Cleaning")
                    SizeText(cleaning.freed, font: .system(.callout, design: .rounded).weight(.semibold))
                    Text("of \(ByteFormat.string(cleaning.total))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelClean() }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
            }
            .frame(height: 44)
            .transition(.opacity)
        } else if let banner = model.banner {
            HStack(spacing: 8) {
                Image(systemName: banner.bytes > 0 ? "checkmark.circle.fill" : "circle.slash")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: banner.id)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text("Freed")
                        SizeText(banner.bytes, font: .system(.headline, design: .rounded))
                    }
                    .font(.headline)
                    Text(bannerDetail(banner)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 44)
            .transition(.opacity)
        } else {
            Button(action: cleanTapped) {
                HStack(spacing: 6) {
                    Text(buttonTitle)
                    if model.checkedBytes > 0 {
                        Text("·").opacity(0.7)
                        SizeText(model.checkedBytes, font: .system(.body, design: .rounded).weight(.semibold),
                                 unitFont: .system(.body, design: .rounded))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .prominentActionStyle()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.checkedResults.isEmpty)
            .frame(height: 44)
            .transition(.opacity)
        }
    }

    private var buttonTitle: String {
        let tiers = Set(model.checkedResults.map(\.item.risk))
        if model.checkedResults.isEmpty { return model.isScanning ? "Scanning caches" : "Nothing to clean" }
        return tiers == [.safe] ? "Clean safe caches" : "Clean selected caches"
    }

    private func bannerDetail(_ banner: FreedBanner) -> String {
        var text = "from \(banner.count) cache\(banner.count == 1 ? "" : "s")"
        if banner.failures > 0 { text += ", \(banner.failures) failed" }
        return text
    }

    private func cleanTapped() {
        let (selections, caution) = model.quickSelection()
        if caution.isEmpty {
            // Only Safe items: clean at once.
            model.clean(selections, source: "menubar")
        } else {
            cautionToConfirm = caution
            showCautionSheet = true
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(CatalogGroup.allCases, id: \.self) { group in
                    let rows = model.quickRows(in: group)
                    if !rows.isEmpty {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(rows) { row in
                            if let result = row.result {
                                CacheRow(result: result, isLoading: row.isLoading, isExpanded: expanded == row.id) {
                                    withAnimation(.sweep) { expanded = expanded == row.id ? nil : row.id }
                                }
                                .staggered(rowIndex(of: row.id))
                            } else {
                                LoadingRow(item: row.item)
                                    .staggered(rowIndex(of: row.id))
                            }
                        }
                    }
                }
                if model.hiddenQuickRowCount > 0 || model.showEmpty {
                    @Bindable var model = model
                    Toggle("Show empty", isOn: $model.showEmpty.animation(.sweep))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: 280)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func rowIndex(of id: String) -> Int {
        model.engine.catalog.items.firstIndex { $0.id == id } ?? 0
    }

    // MARK: Projects and footer

    @ViewBuilder
    private var projectsLine: some View {
        Button {
            open(.projects)
        } label: {
            HStack {
                Image(systemName: "folder.badge.gearshape").symbolRenderingMode(.hierarchical)
                if model.projectsScanned {
                    Text("Build artifacts: \(ByteFormat.string(model.projectsBytes)) in \(model.projects.count) project\(model.projects.count == 1 ? "" : "s")")
                } else {
                    Text("Build artifacts in projects")
                }
                Spacer()
                Image(systemName: "arrow.right").font(.caption)
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("Open House Keeping") { open(nil) }
            Button("Settings") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func open(_ section: SidebarSection?) {
        if let section { model.requestedSection = section }
        model.openMainWindow?()
        closePopover()
    }

    private func closePopover() {
        // The popover belongs to the status item; closing its window is how it is dismissed.
        NSApp.keyWindow?.close()
    }
}

/// One cache in the menu bar list.
struct CacheRow: View {
    @Environment(AppModel.self) private var model
    let result: ScanResult
    /// The tool is being measured again; the size shown is the previous one.
    var isLoading = false
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    @State private var confirmCaution = false

    private var isCleaning: Bool { model.cleaning?.active.contains(result.id) == true }
    private var isQueued: Bool {
        guard let cleaning = model.cleaning else { return false }
        return cleaning.itemIDs.contains(result.id) && !cleaning.finished.contains(result.id) && !isCleaning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ToolGlyph(item: result.item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.item.name).lineLimit(1)
                    if let detail {
                        Text(detail.text)
                            .font(.caption)
                            .foregroundStyle(detail.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if isExpanded {
                details
                    .padding(.leading, 48)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isExpanded ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .confirmationDialog("Clean \(result.item.name)?", isPresented: $confirmCaution) {
            Button("Clean \(ByteFormat.string(result.bytes))") { model.clean([CleanSelection(result)], source: "menubar") }
        } message: {
            Text(result.item.note ?? RiskTier.caution.explanation)
        }
    }

    private var detail: (text: String, isError: Bool)? {
        switch model.outcomes[result.id] {
        case .failed(let reason): return (reason, true)
        case .skipped(let reason): return (reason, false)
        case .freed, nil: break
        }
        // A guard holds this row back: say why, in place of the checkbox.
        if let reason = result.status.reason { return (reason, false) }
        return nil
    }

    @ViewBuilder
    private var trailing: some View {
        if isCleaning {
            ProgressView().controlSize(.small)
        } else if case .freed(let bytes) = model.outcomes[result.id], bytes > 0 {
            Label("\(ByteFormat.string(bytes)) freed", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(.tint)
        } else {
            SizeText(result.bytes, font: .system(.callout, design: .rounded))
                .opacity(isQueued || isLoading ? 0.5 : 1)
            if isLoading {
                ProgressView().controlSize(.mini).frame(width: 7)
            } else {
                RiskDot(result.item.risk)
            }
            if model.isCheckable(result) {
                Toggle("", isOn: Binding(
                    get: { model.isChecked(result) },
                    set: { model.setChecked(result, $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.cleaning != nil)
            } else {
                Image(systemName: result.status.isReady ? "minus" : "lock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(result.roots, id: \.self) { root in
                Text(model.context.abbreviate(root))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let modified = result.lastModified {
                Text("Last changed \(modified.relativeDescription)").font(.caption).foregroundStyle(.secondary)
            }
            if !result.actionDescription.isEmpty {
                Text(result.actionDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let note = result.item.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if result.isUpperBound {
                Text("Frees up to this much: the tool keeps what is still in use.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let root = result.roots.first {
                    Button("Reveal in Finder") { Finder.reveal(root) }
                }
                Spacer()
                Button("Clean") {
                    if result.item.risk == .caution {
                        confirmCaution = true
                    } else {
                        model.clean([CleanSelection(result)], source: "menubar")
                    }
                }
                .disabled(!result.status.isReady || result.bytes == 0 || model.cleaning != nil)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }
}

/// A tool whose cache is still being measured: its icon, its name and a spinner where the size will be.
struct LoadingRow: View {
    let item: CatalogItem

    var body: some View {
        HStack(spacing: 10) {
            ToolGlyph(item: item)
            Text(item.name).lineLimit(1)
            Spacer(minLength: 8)
            Text("Measuring")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ProgressView().controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), measuring")
    }
}

/// Lists the Caution items in a clean before anything is removed.
struct CautionSheet: View {
    let items: [ScanResult]
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("These rebuild slowly").font(.headline)
            Text("They come back, but only after a long download or rebuild, and offline work may fail until then.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        RiskDot(.caution)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.item.name)
                            if let note = item.item.note {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        SizeText(item.bytes, font: .system(.callout, design: .rounded))
                    }
                }
            }
            .sweepCard()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clean All") {
                    dismiss()
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
