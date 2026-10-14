import Foundation
import Observation
import SweepKit
import SweepUninstall

/// State of the Uninstall tool. All of it lives on the main actor; the engine does the work elsewhere.
@MainActor
@Observable
final class UninstallModel {
    enum Tab: String, CaseIterable, Identifiable {
        case apps = "Apps"
        case orphans = "Orphans"
        var id: String { rawValue }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case name = "Name"
        case size = "Size"
        case lastOpened = "Last Opened"
        var id: String { rawValue }
    }

    let uninstaller: AppUninstaller
    /// Nothing is removed; actions report what they would do.
    let dryRun: Bool

    var tab: Tab = .apps

    // Apps
    var apps: [InstalledApp] = []
    var sizes: [String: Int64] = [:]
    var isLoadingApps = false
    var search = ""
    var sort: SortKey = .name
    var selectedAppID: String?

    // Review
    var plan: UninstallPlan?
    var selection: Set<String> = []
    var isLoadingPlan = false
    var isConfirming = false
    var isUninstalling = false
    var lastReport: UninstallReport?
    var adminAvailability: PrivilegedAvailability?

    // Orphans
    var orphans: [Orphan] = []
    var isLoadingOrphans = false
    var pendingOrphan: Orphan?
    var removingOrphans: Set<String> = []
    var orphanBytesFreed: Int64 = 0
    var orphanNotice: String?

    @ObservationIgnored private var hasLoadedApps = false
    @ObservationIgnored private var hasLoadedOrphans = false
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var orphanTask: Task<Void, Never>?

    init(uninstaller: AppUninstaller, dryRun: Bool = false) {
        self.uninstaller = uninstaller
        self.dryRun = dryRun
    }

    var deleteMode: DeleteMode { uninstaller.engine.settings.uninstallDeleteMode }

    func abbreviate(_ path: String) -> String { uninstaller.engine.context.abbreviate(path) }

    // MARK: Apps

    var selectedApp: InstalledApp? {
        guard let selectedAppID else { return nil }
        return apps.first { $0.id == selectedAppID }
    }

    var filteredApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? apps : apps.filter { app in
            app.name.localizedCaseInsensitiveContains(query) || (app.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
        switch sort {
        case .name:
            return matching
        case .size:
            return matching.sorted { (sizes[$0.id] ?? -1, $1.name) > (sizes[$1.id] ?? -1, $0.name) }
        case .lastOpened:
            // Least recently used first: those are the ones worth removing.
            return matching.sorted { ($0.lastOpened ?? .distantPast, $0.name) < ($1.lastOpened ?? .distantPast, $1.name) }
        }
    }

    var subtitle: String {
        switch tab {
        case .apps:
            if apps.isEmpty { return isLoadingApps ? "Looking for apps…" : "No apps found" }
            let total = sizes.values.reduce(0, +)
            let count = apps.count == 1 ? "1 app" : "\(apps.count) apps"
            return sizes.isEmpty ? count : "\(count) · \(ByteFormat.string(total))"
        case .orphans:
            if orphans.isEmpty { return isLoadingOrphans ? "Looking for leftovers…" : "Leftovers of apps that are no longer installed" }
            let total = orphans.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
            let count = orphans.count == 1 ? "1 leftover" : "\(orphans.count) leftovers"
            return "\(count) of apps that are no longer installed · \(ByteFormat.string(total))"
        }
    }

    func loadIfNeeded() async {
        if !hasLoadedApps { await loadApps() }
    }

    func tabChanged() {
        if tab == .orphans, !hasLoadedOrphans { loadOrphans() }
    }

    func refresh() async {
        switch tab {
        case .apps: await loadApps()
        case .orphans: loadOrphans()
        }
    }

    func loadApps() async {
        hasLoadedApps = true
        isLoadingApps = true
        let found = await uninstaller.installedApps()
        apps = found
        isLoadingApps = false
        let known = Set(found.map(\.id))
        sizes = sizes.filter { known.contains($0.key) }
        if let selectedAppID, !known.contains(selectedAppID) {
            self.selectedAppID = nil
            plan = nil
            selection = []
        }
        measureApps(found)
    }

    private func measureApps(_ apps: [InstalledApp]) {
        sizeTask?.cancel()
        sizeTask = Task { [uninstaller] in
            await Self.measure(apps, work: { app in (app.id, await uninstaller.size(of: app)) }) { id, bytes in
                if Task.isCancelled { return false }
                self.sizes[id] = bytes
                return true
            }
        }
    }

    /// Measures items at most four at a time, handing each result back on the
    /// main actor as it arrives. `receive` returns false to stop early.
    private static func measure<Item: Sendable, Value: Sendable>(
        _ items: [Item],
        work: @escaping @Sendable (Item) async -> (String, Value),
        receive: (String, Value) -> Bool
    ) async {
        await withTaskGroup(of: (String, Value).self) { group in
            var next = 0
            while next < min(4, items.count) {
                let item = items[next]
                group.addTask { await work(item) }
                next += 1
            }
            while let (id, value) = await group.next() {
                guard receive(id, value) else {
                    group.cancelAll()
                    break
                }
                if next < items.count {
                    let item = items[next]
                    group.addTask { await work(item) }
                    next += 1
                }
            }
        }
    }

    // MARK: Review

    func selectionChanged() {
        planTask?.cancel()
        plan = nil
        selection = []
        isLoadingPlan = false
        guard let app = selectedApp else { return }
        lastReport = nil
        isLoadingPlan = true
        let id = app.id
        planTask = Task { [uninstaller] in
            var plan = await uninstaller.plan(for: app, measure: false)
            guard !Task.isCancelled, self.selectedAppID == id else { return }
            if let known = self.sizes[id], let index = plan.items.firstIndex(where: { $0.kind == .appBundle }) {
                plan.items[index].bytes = known
            }
            self.plan = plan
            self.selection = plan.defaultSelection
            self.isLoadingPlan = false
            if plan.items.contains(where: \.needsAdmin) {
                self.adminAvailability = await uninstaller.privileged.availability
            }
            let unmeasured = plan.items.filter { $0.bytes == nil }
            await Self.measure(unmeasured, work: { item in (item.id, await uninstaller.size(ofPath: item.path)) }) { path, bytes in
                guard !Task.isCancelled, self.selectedAppID == id else { return false }
                if let index = self.plan?.items.firstIndex(where: { $0.id == path }) {
                    self.plan?.items[index].bytes = bytes
                }
                return true
            }
        }
    }

    /// What the current ticks remove, in preview order.
    var chosenItems: [UninstallItem] {
        plan?.effectiveItems(selecting: selection).filter { $0.blockedReason == nil } ?? []
    }

    var selectedBytes: Int64 { plan?.bytes(selecting: selection) ?? 0 }

    var removesBundle: Bool { chosenItems.contains { $0.kind == .appBundle } }

    var canUninstall: Bool {
        guard let plan, plan.app.removability.isRemovable else { return false }
        return !chosenItems.isEmpty && !isUninstalling
    }

    /// A row can be unticked unless the safety model blocks it or Homebrew decides for it.
    func isLocked(_ item: UninstallItem) -> Bool {
        item.blockedReason != nil || (item.route == .homebrew && item.kind != .appBundle)
    }

    func isSelected(_ item: UninstallItem) -> Bool {
        if item.blockedReason != nil { return false }
        if item.route == .homebrew, item.kind != .appBundle, let bundle = plan?.bundle { return selection.contains(bundle.id) }
        return selection.contains(item.id)
    }

    func setSelected(_ item: UninstallItem, _ isOn: Bool) {
        guard !isLocked(item) else { return }
        if isOn { selection.insert(item.id) } else { selection.remove(item.id) }
    }

    func uninstall() async {
        guard let plan, canUninstall else { return }
        isConfirming = false
        isUninstalling = true
        let report = await uninstaller.uninstall(plan, selecting: selection, source: "window", dryRun: dryRun)
        isUninstalling = false
        lastReport = report
        self.plan = nil
        selection = []
        selectedAppID = nil
        hasLoadedOrphans = false
        await loadApps()
    }

    // MARK: Orphans

    func loadOrphans() {
        hasLoadedOrphans = true
        orphanTask?.cancel()
        isLoadingOrphans = true
        orphanTask = Task { [uninstaller] in
            // Sizes come with the list: a leftover is only an orphan once its
            // contents have been read and found untouched for a while.
            let found = await uninstaller.orphans()
            guard !Task.isCancelled else { return }
            self.orphans = found
            self.isLoadingOrphans = false
        }
    }

    func remove(_ orphan: Orphan) async {
        pendingOrphan = nil
        removingOrphans.insert(orphan.id)
        let operation = await uninstaller.removeOrphan(orphan, source: "window", dryRun: dryRun)
        removingOrphans.remove(orphan.id)
        if let entry = operation.entries.first, entry.result == .dryRun {
            orphanNotice = "Dry run: \(orphan.name) would move to the Trash and free \(ByteFormat.string(entry.bytes))."
        } else if let entry = operation.entries.first, entry.result == .removed {
            orphanBytesFreed += entry.bytes
            orphanNotice = nil
            orphans.removeAll { $0.id == orphan.id }
        } else {
            let reason = operation.entries.first?.reason ?? "it could not be moved"
            orphanNotice = "\(orphan.name) was left in place: \(reason)."
        }
    }
}
