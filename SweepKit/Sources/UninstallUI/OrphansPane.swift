import SweepDesign
import SweepKit
import SweepUninstall
import SwiftUI

/// Leftovers of apps that are gone. Each one is reviewed and removed on its own.
struct OrphansPane: View {
    @Bindable var model: UninstallModel

    var body: some View {
        Group {
            if model.orphans.isEmpty {
                if model.isLoadingOrphans {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading your Library…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if model.orphanBytesFreed > 0 {
                    ContentUnavailableView(
                        "All clear",
                        systemImage: "checkmark.circle",
                        description: Text("Freed \(ByteFormat.string(model.orphanBytesFreed)). No other leftovers were found."))
                } else {
                    ContentUnavailableView(
                        "No orphaned leftovers",
                        systemImage: "checkmark.circle",
                        description: Text("Everything in your Library belongs to an app that is still installed."))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(intro)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let notice = model.orphanNotice {
                            Label(notice, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .symbolRenderingMode(.hierarchical)
                        }
                        ForEach(groups, id: \.bundleID) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.bundleID)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                VStack(spacing: 12) {
                                    ForEach(group.orphans) { orphan in
                                        OrphanRow(orphan: orphan, model: model)
                                    }
                                }
                                .sweepCard(padding: 12)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .sweepAnimation(value: model.orphans.count)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            model.pendingOrphan.map { "Move “\($0.name)” to the Trash?" } ?? "",
            isPresented: Binding(get: { model.pendingOrphan != nil }, set: { if !$0 { model.pendingOrphan = nil } }),
            presenting: model.pendingOrphan
        ) { orphan in
            Button("Move to Trash") {
                Task { await model.remove(orphan) }
            }
            Button("Cancel", role: .cancel) { model.pendingOrphan = nil }
        } message: { orphan in
            Text("\(model.abbreviate(orphan.path))\nNo installed app uses the identifier \(orphan.bundleID). You can put it back from the Trash.")
        }
    }

    private var intro: String {
        var text = "These files and folders are named after apps that are no longer installed. Look at each one before moving it to the Trash."
        if model.orphanBytesFreed > 0 { text += " Freed so far: \(ByteFormat.string(model.orphanBytesFreed))." }
        return text
    }

    /// Orphans of one identifier together, the biggest group first.
    private var groups: [(bundleID: String, orphans: [Orphan])] {
        var order: [String] = []
        var byID: [String: [Orphan]] = [:]
        for orphan in model.orphans {
            let key = orphan.bundleID.lowercased()
            if byID[key] == nil { order.append(key) }
            byID[key, default: []].append(orphan)
        }
        return order.compactMap { key in
            guard let orphans = byID[key], let first = orphans.first else { return nil }
            return (first.bundleID, orphans)
        }
    }
}

private struct OrphanRow: View {
    let orphan: Orphan
    @Bindable var model: UninstallModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: orphan.fingerprint?.isDirectory == true ? "folder" : "doc")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(orphan.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)
            PendingSize(bytes: orphan.bytes)

            Button {
                Finder.reveal(orphan.path)
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(orphan.name) in Finder")

            if model.removingOrphans.contains(orphan.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    model.pendingOrphan = orphan
                } label: {
                    Image(systemName: "trash")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .help("Move to Trash…")
                .accessibilityLabel("Move \(orphan.name) to the Trash")
            }
        }
    }

    private var caption: String {
        var parts = [orphan.location.title]
        if let modified = orphan.lastModified { parts.append("Last changed \(modified.relativeDescription)") }
        parts.append(model.abbreviate((orphan.path as NSString).deletingLastPathComponent))
        return parts.joined(separator: " · ")
    }
}
