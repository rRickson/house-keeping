import SweepDesign
import SweepKit
import SwiftUI

/// The menu bar popover: a dark panel with the witch over the moon, presets
/// to pick what goes, and every cache as a card you tap to select.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var filter: CatalogGroup?
    @State private var detailID: String?
    @State private var cautionToConfirm: [ScanResult] = []
    @State private var showCautionSheet = false

    /// Wider than a menu, so names fit and the selection summary has room.
    static let width: CGFloat = 430

    /// - Parameter detail: a catalog id to open straight on its detail (used for screenshots).
    init(detail: String? = nil) {
        _detailID = State(initialValue: detail)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                PopoverHero(isBusy: model.isBusy)
                    .frame(height: detailID == nil ? 158 : 200)
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }
            if let detailID {
                CacheDetailView(id: detailID) { withAnimation(.sweep) { self.detailID = nil } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                main
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            footer
        }
        .frame(width: Self.width)
        .background(Night.background)
        .environment(\.colorScheme, .dark)
        .overlay { ParticleSweep(trigger: model.banner?.id).tint(Night.badge) }
        .background {
            // Keyboard: Esc closes, ⌘R rescans, Return cleans what is selected.
            Group {
                Button("Close") { detailID == nil ? closePopover() : withAnimation(.sweep) { detailID = nil } }
                    .keyboardShortcut(.cancelAction)
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                Button("Clean") { cleanTapped() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(detailID != nil)
            }
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
        HStack(spacing: 10) {
            Image(systemName: "house")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Night.text)
                .frame(width: 36, height: 36)
                .background(Color(white: 0.22).opacity(0.9), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text("House Keeping")
                    .font(.headline)
                    .foregroundStyle(Night.text)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isBusy ? Night.badge : Night.green)
                        .frame(width: 6, height: 6)
                    statusLine
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            NightCircleButton(symbol: "slider.horizontal.3", size: 36) {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .help("Settings")
            NightCircleButton(symbol: "sparkles", size: 46, prominent: true,
                              progress: model.cleaning?.fraction,
                              isEnabled: model.cleaning == nil && !model.checkedResults.isEmpty) { cleanTapped() }
                .help(model.checkedResults.isEmpty ? "Nothing selected" : "Clean \(ByteFormat.string(model.checkedBytes))")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let cleaning = model.cleaning {
            Text("Cleaning").foregroundStyle(Night.text).fontWeight(.semibold)
            Text("· \(ByteFormat.string(cleaning.freed)) freed").foregroundStyle(Night.secondary)
        } else if let banner = model.banner {
            Text("Freed \(ByteFormat.string(banner.bytes))").foregroundStyle(Night.text).fontWeight(.semibold)
            Text("· \(banner.count) cache\(banner.count == 1 ? "" : "s")\(banner.failures > 0 ? ", \(banner.failures) failed" : "")")
                .foregroundStyle(Night.secondary)
        } else if let progress = model.scanProgress {
            Text("Scanning \(progress.done) of \(progress.total)").foregroundStyle(Night.secondary)
        } else {
            Text(ByteFormat.string(model.checkedBytes)).foregroundStyle(Night.text).fontWeight(.semibold)
            Text("to clean · \(ByteFormat.string(model.disk.free)) free").foregroundStyle(Night.secondary)
        }
    }

    // MARK: Main

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(CleanPreset.allCases) { preset in
                    PresetTile(preset: preset, isActive: model.activePreset == preset) {
                        withAnimation(.sweep) { model.apply(preset) }
                    }
                }
            }
            .disabled(model.cleaning != nil)

            SelectionSummary()

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
            .padding(.horizontal, -4)

            HStack(spacing: 6) {
                Text(filter?.title ?? "Everything")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Night.text)
                Text("· \(selectedInView) of \(checkableInView) selected")
                    .font(.callout)
                    .foregroundStyle(Night.secondary)
                Spacer()
                // Lit when they describe the selection: All when everything in view is selected, None when nothing is.
                NightCapsuleButton(title: "All", isOn: checkableInView > 0 && selectedInView == checkableInView) {
                    withAnimation(.sweep) { model.setAll(true, in: filter) }
                }
                NightCapsuleButton(title: "None", isOn: checkableInView > 0 && selectedInView == 0) {
                    withAnimation(.sweep) { model.setAll(false, in: filter) }
                }
            }
            .disabled(model.cleaning != nil)

            cards
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var groupsInView: [CatalogGroup] {
        CatalogGroup.allCases.filter { !model.quickRows(in: $0).isEmpty }
    }

    private var rowsInView: [QuickRow] {
        (filter.map { [$0] } ?? groupsInView).flatMap { model.quickRows(in: $0) }
    }

    private var checkableInView: Int {
        model.checkableResults.filter { filter == nil || $0.item.group == filter }.count
    }

    private var selectedInView: Int { model.checkedCount(in: filter) }

    /// The biggest cache in view gets the full-width card.
    private var featured: ScanResult? {
        rowsInView.compactMap(\.result)
            .filter { model.isCheckable($0) && !model.pending.contains($0.id) }
            .max { $0.bytes < $1.bytes }
    }

    private var cards: some View {
        let rows = rowsInView
        let featured = self.featured
        let largest = rows.compactMap(\.result?.bytes).max() ?? 0
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let featured {
                    FeaturedCacheCard(result: featured, open: { open(featured.id) }, erase: { model.quickErase(featured) })
                }
                ForEach(filter.map { [$0] } ?? groupsInView, id: \.self) { group in
                    let groupRows = model.quickRows(in: group).filter { $0.id != featured?.id }
                    if !groupRows.isEmpty {
                        NightSectionLabel(title: group.title)
                            .padding(.top, 6)
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(groupRows) { row in
                                CacheCard(row: row, largest: largest) { open(row.id) }
                                    .staggered(rowIndex(of: row.id))
                            }
                        }
                    }
                }
                if model.hiddenQuickRowCount > 0 || model.showEmpty {
                    @Bindable var model = model
                    Toggle("Show caches under 1 MB", isOn: $model.showEmpty.animation(.sweep))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .foregroundStyle(Night.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: 360)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func rowIndex(of id: String) -> Int {
        model.engine.catalog.items.firstIndex { $0.id == id } ?? 0
    }

    private func open(_ id: String) {
        withAnimation(.sweep) { detailID = id }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                openWindow(.projects)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.badge.gearshape")
                    Text(model.projectsScanned
                         ? "Projects · \(ByteFormat.string(model.projectsBytes))"
                         : "Projects")
                    Image(systemName: "arrow.right").font(.caption2)
                }
            }
            Spacer()
            Button("Open House Keeping") { openWindow(nil) }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(Night.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18))
    }

    // MARK: Actions

    private func cleanTapped() {
        guard model.cleaning == nil else { return }
        let (selections, caution) = model.quickSelection()
        guard !selections.isEmpty else { return }
        if caution.isEmpty {
            // Only Safe items: clean at once.
            model.clean(selections, source: "menubar")
        } else {
            cautionToConfirm = caution
            showCautionSheet = true
        }
    }

    private func openWindow(_ section: SidebarSection?) {
        if let section { model.requestedSection = section }
        model.openMainWindow?()
        closePopover()
    }

    private func closePopover() {
        // The popover belongs to the status item; closing its window is how it is dismissed.
        NSApp.keyWindow?.close()
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
