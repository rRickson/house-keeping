import SweepDesign
import SweepKit
import SweepUninstall
import SwiftUI

/// The last look before anything is removed: every path that goes, and its size.
struct UninstallConfirmation: View {
    @Bindable var model: UninstallModel

    var body: some View {
        let items = model.chosenItems
        VStack(alignment: .leading, spacing: 16) {
            if let app = model.plan?.app {
                HStack(spacing: 12) {
                    AppIcon(path: app.path, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.removesBundle ? "Uninstall \(app.name)?" : "Remove leftovers of \(app.name)?")
                            .font(.title3.weight(.semibold))
                        Text(summary(count: items.count))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Text(model.abbreviate(item.path))
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.path)
                            Spacer(minLength: 12)
                            PendingSize(bytes: item.bytes)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .sweepCard(padding: 12)

            if let footnote {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel) { model.isConfirming = false }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    Task { await model.uninstall() }
                }
                .prominentActionStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canUninstall)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func summary(count: Int) -> String {
        let noun = count == 1 ? "1 item" : "\(count) items"
        let size = ByteFormat.string(model.selectedBytes)
        switch model.deleteMode {
        case .trash: return "\(noun), \(size), will move to the Trash."
        case .permanent: return "\(noun), \(size), will be deleted. This cannot be undone."
        }
    }

    private var actionTitle: String {
        if model.dryRun { return "Dry Run" }
        if model.plan?.command != nil, model.removesBundle { return "Uninstall" }
        return model.deleteMode == .trash ? "Move to Trash" : "Delete"
    }

    private var footnote: String? {
        guard let plan = model.plan else { return nil }
        var parts: [String] = []
        if model.dryRun { parts.append("Dry run: nothing is removed, you only see what would happen.") }
        if plan.app.isRunning { parts.append("\(plan.app.name) is asked to quit first.") }
        if let command = plan.command, model.removesBundle {
            parts.append("Homebrew runs \(command.joined(separator: " ")).")
        }
        if model.chosenItems.contains(where: { $0.needsAdmin && $0.route == .sweep }) {
            parts.append("Items that belong to the system are removed by Sweep's helper.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// What the last uninstall did. Shown in place of the review until another app is chosen.
struct UninstallSummary: View {
    let report: UninstallReport
    @Bindable var model: UninstallModel
    @State private var bounce = 0

    var body: some View {
        let problems = report.operation.entries.filter { $0.result != .removed && $0.result != .dryRun }
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: succeeded ? "checkmark.circle" : "info.circle")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: bounce)
                    .accessibilityHidden(true)

                VStack(spacing: 4) {
                    if succeeded {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(report.dryRun ? "Would free" : "Freed").font(.system(.title2, design: .rounded).weight(.semibold))
                            SizeText(report.bytes, font: .system(.title2, design: .rounded).weight(.semibold))
                        }
                    } else {
                        Text("\(report.app.name) was not removed")
                            .font(.title3.weight(.semibold))
                    }
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Left in place")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(problems) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.abbreviate(entry.target))
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let reason = entry.reason {
                                        Text(reason)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sweepCard(padding: 12)
                    }
                    .frame(maxWidth: 440)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .onAppear {
            bounce += 1
            if succeeded, !report.dryRun { Haptics.done() }
        }
    }

    private var removedCount: Int {
        report.operation.entries.filter { $0.result == .removed || $0.result == .dryRun }.count
    }

    private var succeeded: Bool { removedCount > 0 && report.stoppedReason == nil }

    private var detail: String {
        if let reason = report.stoppedReason { return "\(reason). Nothing else was touched." }
        if removedCount == 0 { return "Nothing was removed." }
        let noun = removedCount == 1 ? "1 item" : "\(removedCount) items"
        if report.dryRun { return "Dry run for \(report.app.name): \(noun) would be removed. Nothing was touched." }
        let usedHomebrew = report.operation.entries.contains { $0.mode == "command" && $0.result == .removed }
        if usedHomebrew { return "\(report.app.name) was uninstalled with Homebrew." }
        switch model.deleteMode {
        case .trash: return "\(report.app.name): \(noun) moved to the Trash."
        case .permanent: return "\(report.app.name): \(noun) deleted."
        }
    }
}
