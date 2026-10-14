import Foundation
import SweepKit
import os

/// What happened to one entry of the review list.
public struct JunkEntryResult: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable {
        /// Everything in the entry went.
        case cleaned
        /// Some paths went; others were skipped or failed.
        case partial
        /// Nothing was touched, for the reason given.
        case skipped
        case failed
        /// Nothing was touched; `bytes` is what a real run would remove.
        case dryRun
    }

    /// The entry's id.
    public var id: String
    public var name: String
    public var category: JunkCategory
    public var status: Status
    /// Bytes removed, or planned for a dry run.
    public var bytes: Int64
    /// True when the bytes went to the Trash and are not free yet.
    public var movedToTrash: Bool
    public var removedCount: Int
    /// Paths that were skipped, refused or failed.
    public var problemCount: Int
    /// The first reason something was skipped or failed.
    public var reason: String?

    /// True when something the user ticked is still there for a reason worth showing.
    public var hasProblem: Bool { problemCount > 0 }
}

/// The outcome of one clean.
public struct JunkCleanReport: Sendable {
    /// The operation as written to the ledger (dry runs are not written).
    public var operation: SweepOperation
    public var results: [JunkEntryResult]
    public var dryRun: Bool

    /// Bytes that are really gone: permanent deletes and helper work.
    public var bytesFreed: Int64 {
        results.filter { !$0.movedToTrash && $0.status != .dryRun }.reduce(0) { $0 + $1.bytes }
    }

    /// Bytes moved to the Trash; they are free once the Trash is emptied.
    public var bytesTrashed: Int64 {
        results.filter { $0.movedToTrash && $0.status != .dryRun }.reduce(0) { $0 + $1.bytes }
    }

    /// Bytes a dry run says it would remove.
    public var bytesPlanned: Int64 {
        results.filter { $0.status == .dryRun }.reduce(0) { $0 + $1.bytes }
    }

    public var problems: [JunkEntryResult] { results.filter(\.hasProblem) }
    public func result(for entryID: String) -> JunkEntryResult? { results.first { $0.id == entryID } }
}

public enum JunkCleanEvent: Sendable {
    case started(entryID: String)
    case finished(JunkEntryResult)
}

/// Removes the entries the user ticked. Every path goes through the engine's
/// guarded remover with the category's own folder as the allowlist; system
/// caches go to the privileged runner and are never deleted from here.
public struct JunkCleaner: Sendable {
    public let engine: SweepEngine
    public let privileged: any PrivilegedRunning
    public var options: JunkOptions
    private let rules: JunkRules
    private let log = Logger(subsystem: "com.rickson.sweep", category: "junk")

    public init(engine: SweepEngine, privileged: any PrivilegedRunning = NoPrivilegedRunner(), options: JunkOptions = JunkOptions()) {
        self.engine = engine
        self.privileged = privileged
        self.options = options
        self.rules = JunkRules(engine: engine)
    }

    /// Trash or permanent for a category, or nil when the helper does the work.
    public func deleteMode(for category: JunkCategory) -> DeleteMode? {
        switch category.removal {
        case .cacheSetting: engine.settings.cacheDeleteMode
        case .trash: .trash
        case .permanent: .permanent
        case .helper: nil
        }
    }

    /// Cleans the given entries one after another and keeps going after a failure.
    /// - Parameters:
    ///   - entries: the ticked rows of the review list. Nothing else is touched.
    ///   - dryRun: report what would go without touching anything.
    ///   - source: which front end asked, for the ledger.
    @discardableResult
    public func clean(
        _ entries: [JunkEntry],
        dryRun: Bool = false,
        source: String = "window",
        onEvent: (@Sendable (JunkCleanEvent) -> Void)? = nil
    ) async -> JunkCleanReport {
        var operation = SweepOperation(kind: .junk, source: source, dryRun: dryRun)
        var results: [JunkEntryResult] = []
        var seen = Set<String>()

        for entry in entries where seen.insert(entry.id).inserted {
            if Task.isCancelled { break }
            onEvent?(.started(entryID: entry.id))
            // Running apps are looked up again for every entry, right before it is cleaned.
            let processes = engine.context.processes.runningProcesses()
            let (result, ledgerEntries) = await clean(entry, processes: processes, dryRun: dryRun)
            operation.entries.append(contentsOf: ledgerEntries)
            results.append(result)
            onEvent?(.finished(result))
        }

        engine.ledger.append(operation)
        return JunkCleanReport(operation: operation, results: results, dryRun: dryRun)
    }

    // MARK: One entry

    private func clean(_ entry: JunkEntry, processes: [RunningProcess], dryRun: Bool) async -> (JunkEntryResult, [OperationEntry]) {
        let itemID = "junk.\(entry.category.rawValue)"
        let mode = deleteMode(for: entry.category)
        let modeName = mode?.rawValue ?? "command"

        func ledger(_ target: String, _ bytes: Int64, _ outcome: OperationEntry.Result, _ reason: String? = nil) -> OperationEntry {
            OperationEntry(itemID: itemID, itemName: entry.name, target: target, bytes: bytes, mode: modeName, result: outcome, reason: reason)
        }
        func skipped(_ reason: String) -> (JunkEntryResult, [OperationEntry]) {
            let result = JunkEntryResult(
                id: entry.id, name: entry.name, category: entry.category, status: .skipped, bytes: 0,
                movedToTrash: false, removedCount: 0, problemCount: max(entry.targets.count, 1), reason: reason
            )
            return (result, [ledger(entry.targets.first?.path ?? entry.name, 0, .skipped, reason)])
        }

        if let reason = entry.blockedReason { return skipped(reason) }
        if let reason = rules.runningReason(for: entry, processes: processes) { return skipped(reason) }
        if entry.category == .systemCaches { return await cleanSystemCaches(entry, dryRun: dryRun) }
        guard let mode else { return skipped("cleaned by the helper only") }

        let roots = rules.allowedRoots(for: entry.category)
        guard !roots.isEmpty else { return skipped("its folder is not available") }

        let settings = engine.settings
        let context = engine.context
        let remover = engine.remover
        var entries: [OperationEntry] = []

        for target in entry.targets {
            if Task.isCancelled { break }
            let path = target.path
            // The path must belong to the category, whatever the entry claims.
            if let reason = rules.refusal(for: path, in: entry.category) {
                log.error("Refused junk delete \(path, privacy: .public): \(reason, privacy: .public)")
                entries.append(ledger(path, 0, .refused, reason))
                continue
            }
            if settings.isExcluded(path: path, context: context) {
                entries.append(ledger(path, 0, .skipped, "Excluded in Settings"))
                continue
            }
            guard let fingerprint = target.fingerprint else {
                entries.append(ledger(path, 0, .skipped, "already gone"))
                continue
            }
            let outcome = await Task.detached(priority: .utility) {
                remover.remove(path, allowedRoots: roots, scope: .cache, fingerprint: fingerprint, mode: mode, dryRun: dryRun)
            }.value
            switch outcome {
            case .removed(let bytes): entries.append(ledger(path, bytes, .removed))
            case .dryRun(let bytes): entries.append(ledger(path, bytes, .dryRun))
            case .skipped(let reason): entries.append(ledger(path, 0, .skipped, reason))
            case .refused(let reason):
                log.error("Refused junk delete \(path, privacy: .public): \(reason, privacy: .public)")
                entries.append(ledger(path, 0, .refused, reason))
            case .failed(let reason, let freed): entries.append(ledger(path, freed, .failed, reason))
            }
        }

        return (summarise(entry, entries: entries, movedToTrash: mode == .trash), entries)
    }

    private func summarise(_ entry: JunkEntry, entries: [OperationEntry], movedToTrash: Bool) -> JunkEntryResult {
        let removed = entries.filter { $0.result == .removed }
        let planned = entries.filter { $0.result == .dryRun }
        let failures = entries.filter(\.isFailure)
        // Something that vanished on its own is not a problem worth reporting.
        let skips = entries.filter { $0.result == .skipped && $0.reason != "already gone" }
        let problems = failures + skips
        let bytes = entries.filter { $0.result != .skipped && $0.result != .refused }.reduce(0) { $0 + $1.bytes }

        let status: JunkEntryResult.Status
        if !planned.isEmpty, removed.isEmpty {
            status = .dryRun
        } else if !removed.isEmpty {
            status = problems.isEmpty ? .cleaned : .partial
        } else if !failures.isEmpty {
            status = .failed
        } else {
            status = .skipped
        }

        var reason = problems.first?.reason
        if status == .skipped, reason == nil { reason = entries.isEmpty ? "nothing to clean" : "already gone" }
        return JunkEntryResult(
            id: entry.id, name: entry.name, category: entry.category, status: status, bytes: bytes,
            movedToTrash: movedToTrash && status != .dryRun, removedCount: removed.count,
            problemCount: problems.count, reason: reason
        )
    }

    // MARK: System caches

    /// `/Library/Caches` is emptied by the privileged runner, which accepts the
    /// task name and nothing else. Sweep never deletes there itself.
    private func cleanSystemCaches(_ entry: JunkEntry, dryRun: Bool) async -> (JunkEntryResult, [OperationEntry]) {
        let target = "helper: \(PrivilegedTask.cleanSystemCaches.rawValue)"
        func finish(_ status: JunkEntryResult.Status, _ outcome: OperationEntry.Result, bytes: Int64, reason: String? = nil) -> (JunkEntryResult, [OperationEntry]) {
            let result = JunkEntryResult(
                id: entry.id, name: entry.name, category: entry.category, status: status, bytes: bytes, movedToTrash: false,
                removedCount: outcome == .removed ? 1 : 0, problemCount: status == .skipped || status == .failed ? 1 : 0, reason: reason
            )
            let line = OperationEntry(itemID: "junk.systemCaches", itemName: entry.name, target: target, bytes: bytes, mode: "command", result: outcome, reason: reason)
            return (result, [line])
        }

        let directory: String
        if let override = options.systemCachesDirectory {
            directory = override
        } else if engine.context.isFixture {
            return finish(.skipped, .skipped, bytes: 0, reason: "not available against a fixture home")
        } else {
            directory = "/Library/Caches"
        }
        if await privileged.availability == .unavailable {
            return finish(.skipped, .skipped, bytes: 0, reason: "Admin tasks are not available")
        }

        let url = URL(fileURLWithPath: directory)
        let before = (try? await engine.sizer.sizeAsync(of: [url]))?.bytes ?? entry.bytes
        if dryRun { return finish(.dryRun, .dryRun, bytes: before) }

        let outcome = await privileged.run(.cleanSystemCaches, argument: nil)
        let after = (try? await engine.sizer.sizeAsync(of: [url]))?.bytes ?? before
        let freed = outcome.bytesFreed > 0 ? outcome.bytesFreed : max(before - after, 0)
        if outcome.succeeded { return finish(.cleaned, .removed, bytes: freed) }
        let reason = outcome.message.isEmpty ? "the helper could not clean them" : outcome.message
        return finish(.failed, .failed, bytes: freed, reason: reason)
    }
}
