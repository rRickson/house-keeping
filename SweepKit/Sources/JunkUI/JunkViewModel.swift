import Foundation
import Observation
import SweepDesign
import SweepJunk
import SweepKit

/// One section of the review list.
struct JunkGroup: Identifiable {
    var category: JunkCategory
    var entries: [JunkEntry]
    var id: JunkCategory { category }

    /// Bytes of the rows that have been measured so far.
    var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    var isSizing: Bool { entries.contains(where: \.isSizing) }
}

/// What a row shows on its trailing edge.
enum JunkRowState: Equatable {
    case sizing
    case ready
    case waiting
    case cleaning
    case finished(JunkEntryResult)
}

@MainActor
@Observable
final class JunkViewModel {
    enum Phase: Equatable {
        case scanning
        case ready
        case cleaning
        /// The short pause after a clean, before the list is scanned again.
        case done
    }

    @ObservationIgnored let engine: SweepEngine
    @ObservationIgnored let privileged: any PrivilegedRunning
    @ObservationIgnored let options: JunkOptions

    private(set) var phase: Phase = .scanning
    private(set) var entries: [String: JunkEntry] = [:]
    private(set) var selected: Set<String> = []
    private(set) var fullDiskAccessMissing = false
    /// Entries of the running clean that have not finished yet.
    private(set) var waiting: Set<String> = []
    private(set) var cleaningID: String?
    private(set) var results: [String: JunkEntryResult] = [:]
    /// The last clean, shown as the "Freed X" result until the next scan the user asks for.
    private(set) var report: JunkCleanReport?
    /// Caution and Ask entries waiting for the confirmation sheet.
    var confirming: [JunkEntry] = []

    @ObservationIgnored private var hasAppeared = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cleanTask: Task<Void, Never>?

    init(engine: SweepEngine, privileged: any PrivilegedRunning, options: JunkOptions = JunkOptions()) {
        self.engine = engine
        self.privileged = privileged
        self.options = options
    }

    // MARK: Derived state

    /// Sections in review order: risk tier, then size, with the Trash last.
    /// While a scan runs the order stays fixed so rows do not jump about.
    var groups: [JunkGroup] {
        let settled = phase != .scanning
        var byCategory: [JunkCategory: [JunkEntry]] = [:]
        for entry in entries.values { byCategory[entry.category, default: []].append(entry) }

        let groups = byCategory.map { category, entries in
            JunkGroup(category: category, entries: settled ? entries.reviewOrdered() : entries.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        }
        let order = JunkCategory.allCases
        return groups.sorted { a, b in
            let aTrash = a.category == .trash, bTrash = b.category == .trash
            if aTrash != bTrash { return bTrash }
            if a.category.risk != b.category.risk { return a.category.risk < b.category.risk }
            if settled, a.bytes != b.bytes { return a.bytes > b.bytes }
            return (order.firstIndex(of: a.category) ?? 0) < (order.firstIndex(of: b.category) ?? 0)
        }
    }

    /// Ticked rows that can be cleaned right now, in review order.
    var selectedEntries: [JunkEntry] {
        entries.values.filter { selected.contains($0.id) && !$0.isBlocked && !$0.isSizing }.reviewOrdered()
    }

    var selectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes } }
    var isBusy: Bool { phase == .cleaning || phase == .done }

    var subtitle: String {
        switch phase {
        case .scanning:
            return entries.isEmpty ? "Looking for junk…" : "Looking for junk… \(ByteFormat.string(totalBytes)) so far"
        case .ready:
            if entries.isEmpty { return "Nothing to clean" }
            let count = entries.count
            return "\(count) \(count == 1 ? "item" : "items") found · \(ByteFormat.string(totalBytes))"
        case .cleaning:
            return "Cleaning…"
        case .done:
            return "Done"
        }
    }

    var actionTitle: String {
        if phase == .cleaning { return "Cleaning…" }
        let count = selectedEntries.count
        return count == 0 ? "Nothing selected" : "Clean \(count) \(count == 1 ? "item" : "items")"
    }

    func isSelected(_ entry: JunkEntry) -> Bool { selected.contains(entry.id) && !entry.isBlocked }

    func state(of entry: JunkEntry) -> JunkRowState {
        if cleaningID == entry.id { return .cleaning }
        if phase == .cleaning, waiting.contains(entry.id) { return .waiting }
        if isBusy, let result = results[entry.id] { return .finished(result) }
        return entry.isSizing ? .sizing : .ready
    }

    /// Why the last clean left a row behind, shown under its name.
    func problemNote(for entry: JunkEntry) -> String? {
        guard let result = results[entry.id], result.hasProblem, let reason = result.reason else { return nil }
        switch result.status {
        case .partial: return "Partly cleaned: \(reason)"
        case .failed: return "Not cleaned: \(reason)"
        default: return "Skipped: \(reason)"
        }
    }

    /// "Deleted permanently", "Moved to the Trash" or the helper, in words.
    func removalDescription(for category: JunkCategory) -> String {
        switch JunkCleaner(engine: engine, privileged: privileged, options: options).deleteMode(for: category) {
        case .permanent: "Deleted permanently"
        case .trash: "Moved to the Trash"
        case nil: "Cleaned by the helper as administrator"
        }
    }

    // MARK: Selection

    func setSelected(_ entry: JunkEntry, _ isOn: Bool) {
        guard !entry.isBlocked, !isBusy else { return }
        if isOn { selected.insert(entry.id) } else { selected.remove(entry.id) }
    }

    func setSelected(_ group: JunkGroup, _ isOn: Bool) {
        for entry in group.entries { setSelected(entry, isOn) }
    }

    func allSelected(in group: JunkGroup) -> Bool {
        let selectable = group.entries.filter { !$0.isBlocked }
        return !selectable.isEmpty && selectable.allSatisfy { selected.contains($0.id) }
    }

    // MARK: Scan

    func appear() {
        guard !hasAppeared else { return }
        hasAppeared = true
        scan(keepingProblems: false)
    }

    func disappear() {
        // A clean always runs to its end; a scan is cheap to start again.
        guard phase == .scanning else { return }
        scanTask?.cancel()
        scanTask = nil
        hasAppeared = false
    }

    /// The rescan the user asks for: starts from a clean slate.
    func rescan() {
        guard !isBusy else { return }
        report = nil
        scan(keepingProblems: false)
    }

    /// - Parameter keepingProblems: after a clean, rows that were skipped or
    ///   failed keep their reason.
    private func scan(keepingProblems: Bool) {
        scanTask?.cancel()
        phase = .scanning
        entries = [:]
        selected = []
        results = keepingProblems ? results.filter(\.value.hasProblem) : [:]
        let scanner = JunkScanner(engine: engine, privileged: privileged, options: options)
        scanTask = Task { [weak self] in
            let missing = await Task.detached(priority: .utility) { scanner.isFullDiskAccessMissing }.value
            guard !Task.isCancelled else { return }
            self?.fullDiskAccessMissing = missing
            for await event in scanner.scan() {
                guard !Task.isCancelled, let self else { return }
                self.apply(event)
            }
            guard !Task.isCancelled, let self, self.phase == .scanning else { return }
            self.phase = .ready
        }
    }

    private func apply(_ event: JunkScanEvent) {
        switch event {
        case .entry(let entry):
            // Safe entries start ticked; Caution, Ask and the Trash never do.
            if entries[entry.id] == nil, entry.isSelectedByDefault { selected.insert(entry.id) }
            if entry.isBlocked { selected.remove(entry.id) }
            entries[entry.id] = entry
        case .dropped(let id):
            entries[id] = nil
            selected.remove(id)
        }
    }

    // MARK: Clean

    /// The primary action. Safe entries clean at once; ticked Caution and Ask
    /// entries are listed in a sheet first.
    func requestClean() {
        guard phase == .ready || phase == .scanning, !selectedEntries.isEmpty else { return }
        let risky = selectedEntries.filter(\.needsConfirmation)
        if risky.isEmpty {
            startClean()
        } else {
            confirming = risky
        }
    }

    func cancelClean() {
        cleanTask?.cancel()
    }

    func startClean() {
        confirming = []
        let toClean = selectedEntries
        guard !toClean.isEmpty, !isBusy else { return }

        // Rows still being measured are left out of this clean.
        scanTask?.cancel()
        scanTask = nil
        for (id, entry) in entries where entry.isSizing { entries[id] = nil }

        phase = .cleaning
        report = nil
        results = [:]
        waiting = Set(toClean.map(\.id))
        cleaningID = nil

        let cleaner = JunkCleaner(engine: engine, privileged: privileged, options: options)
        cleanTask = Task { [weak self] in
            // A stream keeps the events in the order the cleaner produced them.
            let (events, continuation) = AsyncStream<JunkCleanEvent>.makeStream()
            let display = Task { [weak self] in
                for await event in events { self?.apply(event) }
            }
            let report = await cleaner.clean(toClean, source: "window") { continuation.yield($0) }
            continuation.finish()
            await display.value

            guard let self else { return }
            self.cleaningID = nil
            self.waiting = []
            self.report = report
            self.phase = .done
            Haptics.done()

            // Let the freed sizes be read, then show what is left.
            try? await Task.sleep(for: .milliseconds(1400))
            self.scan(keepingProblems: true)
        }
    }

    private func apply(_ event: JunkCleanEvent) {
        switch event {
        case .started(let id):
            cleaningID = id
        case .finished(let result):
            if cleaningID == result.id { cleaningID = nil }
            waiting.remove(result.id)
            results[result.id] = result
        }
    }
}
