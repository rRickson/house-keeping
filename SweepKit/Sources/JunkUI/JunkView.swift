import SweepDesign
import SweepJunk
import SweepKit
import SwiftUI

/// The Clean tool of the main window: a review list of system junk with one
/// primary action. Scans when it appears; nothing is removed until the user
/// presses Clean, and Caution or Ask entries are confirmed in a sheet first.
public struct JunkView: View {
    @State private var model: JunkViewModel
    @State private var expandedRows: Set<String> = []
    @State private var expandedGroups: Set<JunkCategory> = []
    @Environment(\.openURL) private var openURL

    public init(engine: SweepEngine, privileged: any PrivilegedRunning) {
        _model = State(initialValue: JunkViewModel(engine: engine, privileged: privileged))
    }

    /// For previews and off-screen rendering: a model built elsewhere, with some rows already open.
    init(model: JunkViewModel, expandedRows: Set<String> = [], expandedGroups: Set<JunkCategory> = []) {
        _model = State(initialValue: model)
        _expandedRows = State(initialValue: expandedRows)
        _expandedGroups = State(initialValue: expandedGroups)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ToolHeader("Clean", subtitle: model.subtitle) {
                HStack(spacing: 8) {
                    if model.phase == .scanning {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        model.rescan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy)
                    .help("Scan again")
                }
            }
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { actionBar }
        .sheet(isPresented: isConfirming) {
            JunkConfirmationSheet(
                entries: model.confirming,
                totalCount: model.selectedEntries.count,
                totalBytes: model.selectedBytes,
                removal: model.removalDescription(for:),
                onCancel: { model.confirming = [] },
                onConfirm: { model.startClean() }
            )
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { !model.confirming.isEmpty }, set: { if !$0 { model.confirming = [] } })
    }

    // MARK: List

    private var list: some View {
        let groups = model.groups
        return ScrollView {
            VStack(spacing: 16) {
                if let report = model.report {
                    JunkResultBanner(report: report)
                        .transition(.opacity)
                }
                if model.fullDiskAccessMissing {
                    fullDiskAccessBanner
                }
                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups) { group in
                        JunkGroupCard(
                            group: group,
                            model: model,
                            expandedRows: $expandedRows,
                            showsAll: Binding(
                                get: { expandedGroups.contains(group.category) },
                                set: { if $0 { expandedGroups.insert(group.category) } else { expandedGroups.remove(group.category) } }
                            )
                        )
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            // Room for the floating action bar.
            .padding(.bottom, 96)
            .sweepAnimation(value: model.phase)
            .sweepAnimation(value: groups.map(\.category))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.phase == .scanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking for junk…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 96)
        } else {
            ContentUnavailableView {
                Label("Nothing to clean", systemImage: "sparkles")
                    .symbolRenderingMode(.hierarchical)
            } description: {
                Text("No caches, logs or old installers worth removing.")
            }
            .padding(.vertical, 64)
        }
    }

    private var fullDiskAccessBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .symbolRenderingMode(.hierarchical)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access is off").font(.headline)
                Text("Without it, House Keeping can't look at Safari, Mail, iOS backups or the Trash. Everything else works as usual.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") {
                    openURL(FullDiskAccess.settingsURL)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .sweepCard(padding: 16)
    }

    // MARK: Action bar

    @ViewBuilder
    private var actionBar: some View {
        if !model.entries.isEmpty, model.phase != .done {
            let isCleaning = model.phase == .cleaning
            let hasSelection = !model.selectedEntries.isEmpty
            FloatingActionBar(
                model.actionTitle,
                bytes: isCleaning || !hasSelection ? nil : model.selectedBytes,
                isBusy: isCleaning,
                isEnabled: hasSelection,
                action: { model.requestClean() }
            ) {
                if isCleaning {
                    Button("Cancel") { model.cancelClean() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The calm result of a clean: "Freed 8.2 GB".
struct JunkResultBanner: View {
    let report: JunkCleanReport
    @State private var bounce = 0

    var body: some View {
        let freed = report.bytesFreed
        let trashed = report.bytesTrashed
        let nothing = freed == 0 && trashed == 0
        HStack(spacing: 12) {
            Image(systemName: nothing ? "info.circle.fill" : "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.title)
                .foregroundStyle(nothing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                .symbolEffect(.bounce, value: bounce)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if nothing {
                        Text("Nothing was removed").font(.title3.weight(.semibold))
                    } else if freed > 0 {
                        Text("Freed").font(.title3.weight(.semibold))
                        SizeText(freed, font: .system(.title3, design: .rounded).weight(.semibold))
                    } else {
                        Text("Moved to the Trash").font(.title3.weight(.semibold))
                        SizeText(trashed, font: .system(.title3, design: .rounded).weight(.semibold))
                    }
                }
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .sweepCard(padding: 16)
        .onAppear { bounce += 1 }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        var parts: [String] = []
        if report.bytesFreed > 0, report.bytesTrashed > 0 {
            parts.append("\(ByteFormat.string(report.bytesTrashed)) moved to the Trash")
        }
        let problems = report.problems.count
        if problems > 0 {
            parts.append("\(problems) \(problems == 1 ? "item was" : "items were") left in place")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
