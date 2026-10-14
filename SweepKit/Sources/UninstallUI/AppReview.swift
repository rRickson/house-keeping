import SweepDesign
import SweepKit
import SweepUninstall
import SwiftUI

/// The review of one app: the bundle and every leftover, each with its size,
/// a checkbox and a way to see it in Finder. One action at the bottom.
struct AppReview: View {
    @Bindable var model: UninstallModel
    let app: InstalledApp

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if case .vendorUninstaller(let vendor) = app.removability {
                    VendorCard(app: app, vendor: vendor)
                } else if let plan = model.plan {
                    notices(for: plan)
                    ForEach(sections(of: plan), id: \.title) { section in
                        ItemSection(title: section.title, items: section.items, model: model)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for leftovers…").foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            // Room for the floating bar, so the last row is never hidden behind it.
            .padding(.bottom, 88)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            if app.removability.isRemovable, model.plan != nil {
                FloatingActionBar(
                    model.removesBundle || model.chosenItems.isEmpty ? "Uninstall" : "Remove Leftovers",
                    bytes: model.selectedBytes,
                    systemImage: "trash",
                    isBusy: model.isUninstalling,
                    isEnabled: model.canUninstall
                ) {
                    model.isConfirming = true
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIcon(path: app.path, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let bundleID = app.bundleID {
                    Text(bundleID)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(facts)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            PendingSize(bytes: model.sizes[app.id], font: .system(.title2, design: .rounded))
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let version = app.version { parts.append("Version \(version)") }
        if let opened = app.lastOpened {
            parts.append("Opened \(opened.relativeDescription)")
        } else {
            parts.append("Never opened")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func notices(for plan: UninstallPlan) -> some View {
        let lines = noticeLines(for: plan)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines, id: \.text) { line in
                    Label {
                        Text(line.text)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: line.symbol)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func noticeLines(for plan: UninstallPlan) -> [(symbol: String, text: String)] {
        var lines: [(symbol: String, text: String)] = []
        if app.isRunning {
            lines.append(("power", "\(app.name) is open. It is asked to quit first, and nothing is removed if it stays open."))
        }
        if let command = plan.command {
            lines.append(("shippingbox", "Installed with Homebrew, so Homebrew removes it: \(command.joined(separator: " "))"))
        }
        if plan.items.contains(where: { $0.needsAdmin && $0.route == .sweep }) {
            switch model.adminAvailability {
            case .unavailable:
                lines.append(("lock", "Some items belong to the system. They stay until House Keeping's helper is turned on in Settings."))
            case .passwordPrompt:
                lines.append(("lock", "Some items belong to the system. macOS asks for an administrator password to remove them."))
            case .helper, nil:
                lines.append(("lock", "Some items belong to the system and are removed by House Keeping's helper."))
            }
        }
        for note in plan.notes { lines.append(("info.circle", note)) }
        return lines
    }

    private func sections(of plan: UninstallPlan) -> [(title: String, items: [UninstallItem])] {
        var result: [(title: String, items: [UninstallItem])] = []
        let bundle = plan.items.filter { $0.kind == .appBundle }
        if !bundle.isEmpty { result.append(("Application", bundle)) }
        let leftovers = plan.items.filter { $0.kind == .leftover }
        var seen = Set<String>()
        for location in LeftoverLocation.allCases where seen.insert(location.title).inserted {
            let items = leftovers.filter { $0.location?.title == location.title }
            if !items.isEmpty { result.append((location.title, items)) }
        }
        let other = leftovers.filter { $0.location == nil }
        if !other.isEmpty { result.append(("Installed Files", other)) }
        return result
    }
}

/// One group of rows on a plain card.
private struct ItemSection: View {
    let title: String
    let items: [UninstallItem]
    @Bindable var model: UninstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                ForEach(items) { item in
                    ItemRow(item: item, model: model)
                }
            }
            .sweepCard(padding: 12)
        }
    }
}

private struct ItemRow: View {
    let item: UninstallItem
    @Bindable var model: UninstallModel

    var body: some View {
        HStack(spacing: 12) {
            Toggle(item.name, isOn: Binding(
                get: { model.isSelected(item) },
                set: { model.setSelected(item, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.isLocked(item) || model.isUninstalling)

            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(item.blockedReason == nil ? 1 : 0.6)

            Spacer(minLength: 12)
            PendingSize(bytes: item.bytes)

            Button {
                Finder.reveal(item.path)
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(item.name) in Finder")
        }
    }

    private var symbol: String {
        if item.kind == .appBundle { return "app" }
        return item.fingerprint?.isDirectory == true ? "folder" : "doc"
    }

    private var caption: String {
        let path = model.abbreviate((item.path as NSString).deletingLastPathComponent)
        if let reason = item.blockedReason { return "\(reason) · \(path)" }
        if item.route == .homebrew, item.kind != .appBundle { return "Removed by Homebrew · \(path)" }
        if item.needsAdmin, item.route == .sweep { return "Needs an administrator · \(path)" }
        if case .receipt(let package) = item.evidence { return "Installed by \(package) · \(path)" }
        return path
    }
}

/// Security software: no checkboxes, no action bar, a pointer to the vendor.
private struct VendorCard: View {
    let app: InstalledApp
    let vendor: SecurityVendor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Use \(vendor.name)'s uninstaller")
                    .font(.headline)
            } icon: {
                Image(systemName: "shield.lefthalf.filled")
                    .symbolRenderingMode(.hierarchical)
            }
            Text("\(app.name) is security software. It installs system extensions that only its own uninstaller removes cleanly, so House Keeping leaves it alone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link("Open \(vendor.name) Support", destination: vendor.supportURL)
                Button("Reveal in Finder") { Finder.reveal(app.path) }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sweepCard(padding: 16)
    }
}
