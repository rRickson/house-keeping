import Observation
import SweepMetrics
import SweepOptimize
import SweepDesign
import SweepKit
import SwiftUI

/// What happened to a row in the last clean.
enum RowOutcome: Equatable {
    case freed(Int64)
    case failed(String)
    case skipped(String)
}

/// A one-tap selection in the popover, like a lighting scene: it ticks the caches it covers and unticks the rest.
enum CleanPreset: String, CaseIterable, Identifiable {
    case safe, deep, javascript, apple, agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safe: "Safe"
        case .deep: "Deep"
        case .javascript: "JS"
        case .apple: "Apple"
        case .agents: "AI"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield"
        case .deep: "flame"
        case .javascript: "curlybraces"
        case .apple: "apple.logo"
        case .agents: "sparkles"
        }
    }

    /// Whether the preset ticks this cache. Ask-tier items are never part of a preset.
    func includes(_ item: CatalogItem) -> Bool {
        switch self {
        case .safe: item.risk == .safe
        case .deep: item.risk == .safe || item.risk == .caution
        case .javascript: item.group == .javascript && item.risk != .ask
        case .apple: item.group == .apple && item.risk != .ask
        case .agents: item.group == .aiAgents && item.risk != .ask
        }
    }
}

/// One line of the menu bar list. `result` is nil while the tool's first answer is still on its way.
struct QuickRow: Identifiable {
    var item: CatalogItem
    var result: ScanResult?
    var isLoading: Bool
    var id: String { item.id }
}

struct CleaningProgress: Equatable {
    var total: Int64
    var freed: Int64 = 0
    var itemIDs: [String]
    var active: Set<String> = []
    var finished: Set<String> = []

    var fraction: Double {
        guard !itemIDs.isEmpty else { return 0 }
        return Double(finished.count) / Double(itemIDs.count)
    }
}

struct FreedBanner: Equatable, Identifiable {
    let id = UUID()
    var bytes: Int64
    var count: Int
    var failures: Int
}

/// The one piece of shared state behind the menu bar, the main window and Settings.
@Observable
final class AppModel {
    static let shared = AppModel()

    let engine: SweepEngine
    /// Runs admin-only work: through the root helper when it is registered, otherwise with a password prompt.
    let privileged: HelperClient

    var settings: SweepSettings {
        didSet {
            guard settings != oldValue else { return }
            engine.updateSettings(settings)
            settingsChanged(from: oldValue)
        }
    }

    // Scan
    private(set) var results: [String: ScanResult] = [:]
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var disk: DiskSpace
    private var scanTask: Task<Void, Never>?
    /// Catalog ids whose cache is still being measured.
    private(set) var pending: Set<String> = []
    private var scanTotal = 0
    /// Tools that had something on the last scan; only these get a loading row next time.
    private var knownPresent: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "scan.presentIDs") ?? [])

    // Selection
    /// Rows the user ticked or unticked by hand, by catalog id.
    var overrides: [String: Bool] = [:]
    /// Entries picked inside Ask-tier items, by catalog id.
    var pickedTargets: [String: Set<String>] = [:]
    var showEmpty = false

    // Clean
    private(set) var cleaning: CleaningProgress?
    private(set) var outcomes: [String: RowOutcome] = [:]
    private(set) var banner: FreedBanner?
    private var cleanTask: Task<Void, Never>?
    /// Catalog ids clicked in the quick-erase strip while another clean was running.
    private(set) var eraseQueue: [String] = []

    // Projects
    private(set) var projects: [Project] = []
    private(set) var isScanningProjects = false
    private(set) var projectsScanned = false
    private(set) var projectScanStatus = ""

    // History
    private(set) var history: [SweepOperation] = []

    // Menu bar icon
    private(set) var iconFrame = 0
    private(set) var iconWiggle = 0
    private var iconTimer: Timer?
    private var wasOverThreshold = false

    /// Set by a view that can open windows, so services can ask for the main window.
    var openMainWindow: (() -> Void)?
    var requestedSection: SidebarSection?

    init(engine: SweepEngine = SweepEngine()) {
        self.engine = engine
        self.privileged = HelperClient(context: engine.context)
        self.settings = engine.settings
        self.disk = DiskSpace.of(engine.context.home)
        self.history = engine.ledger.operations(limit: 200)
    }

    var context: SweepContext { engine.context }

    /// The name of the volume that holds the home folder, as Finder shows it.
    let volumeName: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (try? home.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Startup Disk"
    }()
    var accent: Color { SweepAccent(name: settings.accent).color }
    var isBusy: Bool { isScanning || cleaning != nil }

    // MARK: Rows

    var orderedResults: [ScanResult] {
        engine.catalog.items.compactMap { results[$0.id] }
    }

    /// Whether a row is ticked for the one-click clean.
    func isChecked(_ result: ScanResult) -> Bool {
        guard isCheckable(result) else { return false }
        return overrides[result.id] ?? settings.oneClickTiers.contains(result.item.risk)
    }

    /// Rows that can be part of a one-click clean at all: ready, non-empty, and not a pick-list.
    func isCheckable(_ result: ScanResult) -> Bool {
        result.status.isReady && result.bytes > 0 && !result.selectable && result.item.risk != .ask
            && !settings.disabledItems.contains(result.id)
    }

    func setChecked(_ result: ScanResult, _ checked: Bool) {
        overrides[result.id] = checked
    }

    /// Rows of the menu bar list: Safe and Caution only, grouped, with tiny ones hidden.
    /// While a scan runs, a tool that has not answered yet still gets a row, so
    /// each one shows its own loading state.
    func quickRows(in group: CatalogGroup) -> [QuickRow] {
        engine.catalog.items(in: group).compactMap { item in
            guard item.risk != .ask, !settings.disabledItems.contains(item.id) else { return nil }
            let loading = pending.contains(item.id)
            guard let result = results[item.id] else {
                // Nothing known yet: show the tool if it was there last time, or if this is the first scan.
                guard loading, knownPresent.isEmpty || knownPresent.contains(item.id) else { return nil }
                return QuickRow(item: item, result: nil, isLoading: true)
            }
            guard !result.selectable, result.status != .missing else { return nil }
            let visible = showEmpty || result.bytes >= 1_000_000 || cleaning?.itemIDs.contains(item.id) == true || outcomes[item.id] != nil
            return visible ? QuickRow(item: item, result: result, isLoading: loading) : nil
        }
    }

    /// Caches that are good to erase with one click: Safe tier, ready and worth the click.
    /// A cache stays in the strip while it is being erased and until its "done" mark clears.
    var quickEraseItems: [ScanResult] {
        orderedResults.filter { result in
            guard result.item.risk == .safe, !result.selectable, !settings.disabledItems.contains(result.id) else { return false }
            if cleaning?.itemIDs.contains(result.id) == true || eraseQueue.contains(result.id) { return true }
            if case .freed = outcomes[result.id] { return true }
            return result.status.isReady && result.bytes >= 1_000_000
        }
    }

    func isQueuedForErase(_ id: String) -> Bool {
        eraseQueue.contains(id) || (cleaning.map { $0.itemIDs.contains(id) && !$0.active.contains(id) && !$0.finished.contains(id) } ?? false)
    }

    /// Erases one cache now, or right after the clean that is already running.
    func quickErase(_ result: ScanResult) {
        guard result.item.risk == .safe, isCheckable(result) else { return }
        if cleaning == nil {
            clean([CleanSelection(result)], source: "menubar")
        } else if !eraseQueue.contains(result.id), cleaning?.itemIDs.contains(result.id) != true {
            eraseQueue.append(result.id)
        }
    }

    /// Starts the caches queued by `quickErase` once the running clean has finished.
    private func drainEraseQueue() {
        guard cleaning == nil, !eraseQueue.isEmpty else { return }
        let ids = eraseQueue
        eraseQueue.removeAll()
        let selections = ids.compactMap { results[$0] }
            .filter { $0.item.risk == .safe && isCheckable($0) }
            .map { CleanSelection($0) }
        clean(selections, source: "menubar")
    }

    // MARK: Presets and selection

    /// Every cache that can be ticked right now.
    var checkableResults: [ScanResult] { orderedResults.filter(isCheckable) }

    func apply(_ preset: CleanPreset) {
        for result in checkableResults { overrides[result.id] = preset.includes(result.item) }
    }

    /// The preset whose selection matches what is ticked, if any.
    var activePreset: CleanPreset? {
        let checkable = checkableResults
        guard !checkable.isEmpty else { return nil }
        return CleanPreset.allCases.first { preset in
            checkable.allSatisfy { isChecked($0) == preset.includes($0.item) }
        }
    }

    func setAll(_ checked: Bool, in group: CatalogGroup?) {
        for result in checkableResults where group == nil || result.item.group == group {
            overrides[result.id] = checked
        }
    }

    /// How many caches in a group are ticked, for the badges on the group pills.
    func checkedCount(in group: CatalogGroup?) -> Int {
        checkedResults.filter { group == nil || $0.item.group == group }.count
    }

    /// How far the running scan is, for the header.
    var scanProgress: (done: Int, total: Int)? {
        guard isScanning, scanTotal > 0 else { return nil }
        return (scanTotal - pending.count, scanTotal)
    }

    var hiddenQuickRowCount: Int {
        orderedResults.filter { result in
            result.item.risk != .ask && !result.selectable && !settings.disabledItems.contains(result.id)
                && result.status != .missing && result.bytes < 1_000_000
        }.count
    }

    var checkedResults: [ScanResult] { orderedResults.filter(isChecked) }
    var checkedBytes: Int64 { checkedResults.reduce(0) { $0 + $1.bytes } }

    /// Reclaimable space in Safe-tier dev caches, used for the badge and notifications.
    var reclaimableBytes: Int64 {
        engine.oneClickSelection(from: orderedResults).reduce(0) { $0 + $1.result.bytes }
    }

    var totalBytes: Int64 { orderedResults.reduce(0) { $0 + $1.bytes } }

    func bytes(in group: CatalogGroup) -> Int64 {
        orderedResults.filter { $0.item.group == group }.reduce(0) { $0 + $1.bytes }
    }

    // MARK: Scan

    func rescan() {
        guard !isScanning, cleaning == nil else { return }
        isScanning = true
        outcomes.removeAll()
        let items = engine.catalog.items
        pending = Set(items.map(\.id))
        scanTotal = items.count
        updateIconAnimation()
        scanTask = Task {
            for await result in engine.scanAll(items) {
                withAnimation(.sweep) {
                    results[result.id] = result
                    pending.remove(result.id)
                }
            }
            withAnimation(.sweep) { pending.removeAll() }
            isScanning = false
            lastScan = Date()
            rememberPresentTools()
            refreshDisk()
            updateIconAnimation()
            evaluateThresholds()
        }
    }

    private func rememberPresentTools() {
        knownPresent = Set(results.values.filter { $0.status != .missing }.map(\.id))
        // A fixture run must not change what the real app expects to find.
        if !context.isFixture { UserDefaults.standard.set(knownPresent.sorted(), forKey: "scan.presentIDs") }
    }

    /// Opening the popover rescans when the last scan is older than ten minutes.
    func rescanIfStale(maxAge: TimeInterval = 600) {
        guard let lastScan else { return rescan() }
        if Date().timeIntervalSince(lastScan) > maxAge { rescan() }
    }

    private func rescan(items ids: [String]) async {
        pending.formUnion(ids)
        for id in ids {
            if let item = engine.catalog.item(id) {
                let result = await engine.scan(item)
                withAnimation(.sweep) { results[id] = result }
            }
            pending.remove(id)
        }
        lastScan = Date()
    }

    #if DEBUG
    /// Puts the list into a mid-scan state for snapshots: some tools measured, some still loading.
    func debugSimulateScanning(loading ids: [String], unknown: [String]) {
        isScanning = true
        scanTotal = engine.catalog.items.count
        pending = Set(ids + unknown)
        knownPresent = []
        for id in unknown { results[id] = nil }
    }

    func debugEndSimulatedScan() {
        isScanning = false
        pending = []
    }
    #endif

    func refreshDisk() {
        withAnimation(.sweep) { disk = DiskSpace.of(context.home) }
    }

    // MARK: Clean

    /// The ticked rows as selections; Caution rows are returned separately so the caller can confirm them first.
    func quickSelection() -> (selections: [CleanSelection], caution: [ScanResult]) {
        let checked = checkedResults
        return (checked.map { CleanSelection($0) }, checked.filter { $0.item.risk == .caution })
    }

    /// Cleans the Safe tier only. Used by the hotkey, the schedule, Shortcuts and the right-click menu.
    @discardableResult
    func cleanSafe(source: String) async -> SweepOperation? {
        if lastScan == nil || Date().timeIntervalSince(lastScan ?? .distantPast) > 600 {
            rescan()
            await scanTask?.value
        }
        let selections = engine.oneClickSelection(from: orderedResults).filter { $0.result.item.risk == .safe }
        guard !selections.isEmpty, cleaning == nil else { return nil }
        return await runClean(selections, source: source)
    }

    func clean(_ selections: [CleanSelection], source: String) {
        guard cleaning == nil, !selections.isEmpty else { return }
        // Marked busy before the task starts, so two clicks in a row cannot start two cleans.
        let total = selections.reduce(Int64(0)) { $0 + $1.result.bytes(for: $1.targetIDs) }
        cleaning = CleaningProgress(total: total, itemIDs: selections.map(\.result.id))
        cleanTask = Task { _ = await runClean(selections, source: source) }
    }

    func cancelClean() {
        cleanTask?.cancel()
    }

    private func runClean(_ selections: [CleanSelection], source: String) async -> SweepOperation {
        let ids = selections.map(\.result.id)
        let total = selections.reduce(Int64(0)) { $0 + $1.result.bytes(for: $1.targetIDs) }
        outcomes.removeAll()
        banner = nil
        withAnimation(.sweep) { cleaning = CleaningProgress(total: total, itemIDs: ids) }
        updateIconAnimation()
        await Notifier.requestAuthorizationIfNeeded(context: context)

        let operation = await engine.clean(selections, source: source) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Let the last row event land before the summary replaces the progress bar.
        await Task.yield()

        withAnimation(.sweep) {
            cleaning = nil
            banner = FreedBanner(bytes: operation.bytesFreed, count: operation.cleanedItemNames.count, failures: operation.failures.count)
        }
        updateIconAnimation()
        history = engine.ledger.operations(limit: 200)
        refreshDisk()
        Haptics.done()
        if operation.bytesFreed > 0 {
            Notifier.post(title: "House Keeping", body: operation.summary(), context: context)
        }
        for id in ids { pickedTargets[id] = nil }
        await rescan(items: ids)
        drainEraseQueue()

        let shown = banner?.id
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard banner?.id == shown else { return }
            // Back to Ready: the banner goes and the cleaned rows collapse. Failures stay until the next scan.
            withAnimation(.sweep) {
                banner = nil
                outcomes = outcomes.filter { if case .freed = $0.value { false } else { true } }
            }
        }
        return operation
    }

    private func handle(_ event: CleanEvent) {
        switch event {
        case .started(let id):
            cleaning?.active.insert(id)
        case .finished(let id, let freed, let entries):
            withAnimation(.sweep) {
                cleaning?.active.remove(id)
                cleaning?.finished.insert(id)
                cleaning?.freed += freed
                if let failure = entries.first(where: \.isFailure) {
                    outcomes[id] = .failed(failure.reason ?? "failed")
                } else if freed == 0, let skipped = entries.first(where: { $0.result == .skipped }) {
                    outcomes[id] = .skipped(skipped.reason ?? "skipped")
                } else {
                    outcomes[id] = .freed(freed)
                }
                // The row's size drains by what was freed; the rescan afterwards sets the true value.
                if var result = results[id] {
                    result.bytes = max(result.bytes - freed, 0)
                    results[id] = result
                }
            }
        }
    }

    // MARK: Projects

    func scanProjects() {
        guard !isScanningProjects else { return }
        isScanningProjects = true
        projectScanStatus = ""
        Task {
            let scanner = ProjectScanner(engine: engine)
            let found = await scanner.scan { [weak self] path in
                Task { @MainActor in self?.projectScanStatus = path }
            }
            withAnimation(.sweep) { projects = found }
            isScanningProjects = false
            projectsScanned = true
        }
    }

    var projectsBytes: Int64 { projects.reduce(0) { $0 + $1.bytes } }

    func purge(_ artifacts: [ProjectArtifact]) async -> SweepOperation {
        let operation = await ProjectScanner(engine: engine).purge(artifacts, source: "window")
        let removed = Set(operation.entries.filter { $0.result == .removed }.map(\.target))
        withAnimation(.sweep) {
            projects = projects.compactMap { project in
                var project = project
                project.artifacts.removeAll { removed.contains($0.path) }
                return project.artifacts.isEmpty ? nil : project
            }
        }
        history = engine.ledger.operations(limit: 200)
        refreshDisk()
        if operation.bytesFreed > 0 { Haptics.done() }
        return operation
    }

    func reloadHistory() {
        history = engine.ledger.operations(limit: 200)
    }

    // MARK: Settings side effects

    private func settingsChanged(from old: SweepSettings) {
        if old.hotkey != settings.hotkey || old.hotkeyEnabled != settings.hotkeyEnabled {
            AppServices.shared.applyHotkey()
        }
        if old.launchAtLogin != settings.launchAtLogin {
            LoginItem.apply(enabled: settings.launchAtLogin, context: context)
        }
        if old.autoClean != settings.autoClean {
            AutoClean.applyLaunchAgent(schedule: settings.autoClean, context: context)
        }
        if old.oneClickTiers != settings.oneClickTiers || old.disabledItems != settings.disabledItems {
            overrides.removeAll()
        }
        if old.projectRoots != settings.projectRoots {
            projectsScanned = false
        }
        if old.oldSessionDays != settings.oldSessionDays || old.uvFullClean != settings.uvFullClean {
            rescan()
        }
        if old.showMenuBarGraph != settings.showMenuBarGraph {
            applyMenuBarGraph()
        }
    }

    private var isSamplingForMenuBar = false

    /// The menu bar graph samples CPU and memory only while it is switched on.
    func applyMenuBarGraph() {
        guard settings.showMenuBarGraph != isSamplingForMenuBar else { return }
        isSamplingForMenuBar = settings.showMenuBarGraph
        if isSamplingForMenuBar {
            MetricsSampler.shared.start(.glance)
        } else {
            MetricsSampler.shared.stop(.glance)
        }
    }

    // MARK: Menu bar icon

    /// The icon cycles its three dust dots while scanning or cleaning.
    private func updateIconAnimation() {
        if isBusy {
            guard iconTimer == nil else { return }
            iconTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.iconFrame += 1 }
            }
        } else {
            iconTimer?.invalidate()
            iconTimer = nil
            iconFrame = 0
        }
    }

    var isOverThreshold: Bool { reclaimableBytes >= settings.reclaimableNotifyBytes }

    /// One wiggle and one notification when reclaimable space crosses the threshold.
    private func evaluateThresholds() {
        let over = isOverThreshold
        if over, !wasOverThreshold {
            iconWiggle += 1
            Notifier.postOncePerDay(
                key: "reclaimable",
                title: "House Keeping",
                body: "\(ByteFormat.string(reclaimableBytes)) of developer caches can be reclaimed.",
                context: context
            )
        }
        wasOverThreshold = over
        if disk.total > 0, disk.freeFraction < settings.lowDiskNotifyFraction {
            Notifier.postOncePerDay(
                key: "lowdisk",
                title: "House Keeping",
                body: "Only \(ByteFormat.string(disk.free)) of disk space is free.",
                context: context
            )
        }
    }
}
