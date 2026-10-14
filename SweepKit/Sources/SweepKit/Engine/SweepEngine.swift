import Foundation
import os

/// A value guarded by a lock, for the little shared state the engine has.
public final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    public func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    @discardableResult
    public func mutate<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// What the user chose to clean for one scanned item.
public struct CleanSelection: Sendable {
    public var result: ScanResult
    /// Nil cleans every target. Items the user picks from need an explicit set.
    public var targetIDs: Set<String>?

    public init(_ result: ScanResult, targetIDs: Set<String>? = nil) {
        self.result = result
        self.targetIDs = targetIDs
    }
}

public enum CleanEvent: Sendable {
    case started(itemID: String)
    case finished(itemID: String, bytesFreed: Int64, entries: [OperationEntry])
}

/// The pipeline every front end calls: Catalog → Resolver → Sizer → Guard → Executor → Ledger.
public final class SweepEngine: Sendable {
    public let context: SweepContext
    public let safety: SafetyGuard
    public let sizer = Sizer()
    public let resolver: Resolver
    public let remover: GuardedRemover
    public let ledger: Ledger
    public let settingsStore: SettingsStore
    /// Tool clean commands get this long before they are stopped.
    public let commandTimeout: TimeInterval

    private let memo = CommandMemo()
    private let catalogBox: Locked<Catalog>
    private let settingsBox: Locked<SweepSettings>
    private let log = Logger(subsystem: "com.rickson.housekeeping", category: "engine")

    public init(context: SweepContext = .live(), catalog: Catalog? = nil, settings: SweepSettings? = nil, commandTimeout: TimeInterval = 120) {
        self.context = context
        self.safety = SafetyGuard(home: context.home)
        self.resolver = Resolver(context: context, safety: safety)
        self.remover = GuardedRemover(context: context, safety: safety, sizer: sizer)
        self.ledger = Ledger(directory: context.logDirectory)
        self.settingsStore = SettingsStore(context: context)
        self.commandTimeout = commandTimeout
        self.catalogBox = Locked(catalog ?? Catalog.load(context: context))
        self.settingsBox = Locked(settings ?? settingsStore.load())
    }

    public var catalog: Catalog { catalogBox.get() }

    public func reloadCatalog() { catalogBox.set(Catalog.load(context: context)) }

    public var settings: SweepSettings { settingsBox.get() }

    /// Replaces the settings and writes them to disk.
    public func updateSettings(_ settings: SweepSettings) {
        settingsBox.set(settings)
        settingsStore.save(settings)
    }

    /// Runs a read-only command, sharing the answer between callers that ask within `reuseWithin` seconds.
    public func run(_ command: [String], timeout: TimeInterval, reuseWithin: TimeInterval) async -> CommandResult {
        await memo.run(command, runner: context.runner, timeout: timeout, reuseWithin: reuseWithin)
    }

    // MARK: Scan

    /// Scans every item, at most `maxConcurrent` at a time, yielding results as they arrive.
    public func scanAll(_ items: [CatalogItem]? = nil, maxConcurrent: Int = 4) -> AsyncStream<ScanResult> {
        let items = items ?? catalog.items
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: ScanResult.self) { group in
                    var iterator = items.makeIterator()
                    for _ in 0..<max(maxConcurrent, 1) {
                        guard let item = iterator.next() else { break }
                        group.addTask { await self.scan(item) }
                    }
                    while let result = await group.next() {
                        continuation.yield(result)
                        if let item = iterator.next() {
                            group.addTask { await self.scan(item) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Scans every item and returns the results in catalog order.
    public func scanAllCollected(_ items: [CatalogItem]? = nil) async -> [ScanResult] {
        let items = items ?? catalog.items
        var byID: [String: ScanResult] = [:]
        for await result in scanAll(items) { byID[result.id] = result }
        return items.compactMap { byID[$0.id] }
    }

    public func scan(_ original: CatalogItem) async -> ScanResult {
        let item = effective(original)
        let settings = self.settings
        if settings.isExcluded(itemID: item.id) {
            return ScanResult(item: item, status: .blocked("Excluded in Settings"))
        }

        var result: ScanResult
        if item.clean.type == .handler {
            guard let name = item.clean.handler, let handler = Handlers.all[name] else {
                return ScanResult(item: item, status: .missing)
            }
            let scan = await handler.scan(item, engine: self)
            result = ScanResult(
                item: item,
                roots: scan.roots,
                targets: scan.targets,
                bytes: scan.bytes ?? scan.targets.reduce(0) { $0 + $1.bytes },
                lastModified: scan.targets.compactMap(\.lastModified).max(),
                status: scan.status,
                source: .handler,
                selectable: scan.selectable,
                actionDescription: scan.actionDescription
            )
        } else {
            result = await scanRule(item)
        }

        // Exclusions remove single targets; an item with nothing left is skipped.
        if !settings.exclusions.isEmpty {
            let before = result.targets.count
            result.targets.removeAll { target in
                if case .delete(let path) = target.action { return settings.isExcluded(path: path, context: context) }
                return false
            }
            if result.targets.count != before {
                result.bytes = result.targets.reduce(0) { $0 + $1.bytes }
                if result.targets.isEmpty { result.status = .blocked("Excluded in Settings") }
            }
            // A tool's clean command cannot skip part of its cache, so an excluded location holds back the whole item.
            let runsCommand = result.targets.contains { if case .command = $0.action { true } else { false } }
            if runsCommand, result.roots.contains(where: { settings.isExcluded(path: $0, context: context) }) {
                result.status = .blocked("Excluded in Settings")
            }
        }

        if result.status == .ready, let reason = await guardReason(for: item) {
            result.status = .blocked(reason)
        }
        return result
    }

    /// Settings that change how an item is cleaned.
    private func effective(_ item: CatalogItem) -> CatalogItem {
        var item = item
        if item.id == "uv", settings.uvFullClean, item.clean.type == .command {
            item.clean.command = ["uv", "cache", "clean"]
            item.clean.partial = false
        }
        // Agent history (Caution tier) uses the age from Settings; temp files keep their short rule ages.
        if item.group == .aiAgents, item.risk == .caution, item.clean.olderThanDays != nil {
            item.clean.olderThanDays = max(1, settings.oldSessionDays)
        }
        return item
    }

    private func scanRule(_ item: CatalogItem) async -> ScanResult {
        let resolution = await resolver.resolve(item)
        for refusal in resolution.refused {
            log.warning("Refused \(item.id, privacy: .public): \(refusal.path, privacy: .public) (\(refusal.reason, privacy: .public))")
        }
        var result = ScanResult(item: item, roots: resolution.roots, source: resolution.source)
        guard !resolution.roots.isEmpty else {
            if let refusal = resolution.refused.first {
                result.status = .blocked("Refused: \(context.abbreviate(refusal.path)) is \(refusal.reason)")
            }
            return result
        }

        var total = SizeResult()
        do {
            switch item.clean.type {
            case .delete:
                for root in resolution.roots {
                    let size = try await sizer.sizeAsync(of: [URL(fileURLWithPath: root)])
                    total.merge(size)
                    result.targets.append(.delete(root, label: context.abbreviate(root), bytes: size.bytes, lastModified: size.lastModified))
                }
                result.actionDescription = resolution.roots.count == 1 ? "Delete folder" : "Delete \(resolution.roots.count) folders"

            case .command:
                let command = item.clean.command ?? []
                total = try await sizer.sizeAsync(of: resolution.roots.map { URL(fileURLWithPath: $0) })
                if usesCommand(item, source: resolution.source) {
                    result.targets = [.command(command, bytes: total.bytes, lastModified: total.lastModified)]
                    result.actionDescription = command.joined(separator: " ")
                } else {
                    // The tool is gone but its cache is still here: delete it.
                    total = SizeResult()
                    for root in resolution.roots {
                        let size = try await sizer.sizeAsync(of: [URL(fileURLWithPath: root)])
                        total.merge(size)
                        result.targets.append(.delete(root, label: context.abbreviate(root), bytes: size.bytes, lastModified: size.lastModified))
                    }
                    result.actionDescription = "Delete folder (\(command.first ?? "tool") is not installed)"
                }

            case .deleteChildren, .select:
                let exclude = Set(item.clean.exclude ?? [])
                let cutoff = item.clean.olderThanDays.map { Date().addingTimeInterval(-TimeInterval($0) * 86_400) }
                // With several locations, the label says which one an entry is in.
                let labelsParent = resolution.roots.count > 1
                for root in resolution.roots {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
                    for name in names.sorted() where !exclude.contains(name) && name != ".DS_Store" {
                        if let pattern = item.clean.match, !Glob.matches(name, pattern: pattern) { continue }
                        let path = root + "/" + name
                        // A symbolic link is never a delete target, so it is not offered either.
                        if Fingerprint(path: path)?.isSymlink == true { continue }
                        let size = try await sizer.sizeAsync(of: [URL(fileURLWithPath: path)])
                        // Anything touched since the cutoff may belong to a session that is still open.
                        if let cutoff, (size.lastModified ?? Date()) > cutoff { continue }
                        total.merge(size)
                        let label = labelsParent ? (root as NSString).lastPathComponent + "/" + name : name
                        result.targets.append(.delete(path, label: label, bytes: size.bytes, lastModified: size.lastModified))
                    }
                }
                let age = item.clean.olderThanDays.map { " untouched for \($0) day\($0 == 1 ? "" : "s")" } ?? ""
                if item.clean.type == .select {
                    result.selectable = true
                    result.targets.sort { $0.bytes > $1.bytes }
                    result.actionDescription = "Delete the entries you select" + (age.isEmpty ? "" : ", from those" + age)
                } else {
                    result.actionDescription = age.isEmpty ? "Delete contents" : "Delete entries" + age
                }

            case .handler:
                break
            }
        } catch {
            // Cancelled mid-scan: report nothing rather than a partial size.
            return ScanResult(item: item, roots: resolution.roots, status: .missing, source: resolution.source)
        }

        result.bytes = total.bytes
        result.fileCount = total.files
        result.lastModified = total.lastModified
        result.status = (total.permissionDenied && total.bytes == 0) ? .permissionDenied : .ready
        return result
    }

    /// A clean command runs only when the tool is installed and it was the tool
    /// that reported the location. If the location is a leftover default path,
    /// the tool would clean somewhere else.
    private func usesCommand(_ item: CatalogItem, source: LocateSource) -> Bool {
        guard let tool = item.clean.command?.first, context.runner.locate(tool) != nil else { return false }
        let asksTool = item.locate.contains { $0.command != nil }
        if !asksTool { return true }
        if case .tool = source { return true }
        return false
    }

    /// The reason an item must not be cleaned right now, if any.
    public func guardReason(for item: CatalogItem) async -> String? {
        guard let guards = item.guards else { return nil }
        if let patterns = guards.notRunning, context.processes.firstRunning(of: patterns) != nil {
            return guards.runningReason ?? "\(patterns.first ?? "App") is running"
        }
        if let requires = guards.requires, !requires.isEmpty {
            let result = await context.runner.run(requires, timeout: 10)
            if !result.succeeded { return guards.requiresReason ?? "\(requires[0]) is not available" }
        }
        return nil
    }

    // MARK: Selection

    /// What the one-click button cleans: ready, non-empty items in the chosen
    /// tiers that are switched on. Items the user picks from are never included.
    public func oneClickSelection(from results: [ScanResult]) -> [CleanSelection] {
        let settings = self.settings
        return results.filter { result in
            result.status.isReady
                && result.bytes > 0
                && !result.selectable
                && result.item.risk != .ask
                && settings.oneClickTiers.contains(result.item.risk)
                && !settings.disabledItems.contains(result.id)
        }.map { CleanSelection($0) }
    }

    // MARK: Clean

    /// Cleans the selections one after another and records the operation.
    /// - Parameter mode: Trash or permanent; defaults to the cache setting.
    @discardableResult
    public func clean(
        _ selections: [CleanSelection],
        source: String,
        mode: DeleteMode? = nil,
        dryRun: Bool = false,
        onEvent: (@Sendable (CleanEvent) -> Void)? = nil
    ) async -> SweepOperation {
        let mode = mode ?? settings.cacheDeleteMode
        var operation = SweepOperation(kind: .devCaches, source: source, dryRun: dryRun)
        for selection in selections {
            if Task.isCancelled { break }
            onEvent?(.started(itemID: selection.result.id))
            let entries = await cleanItem(selection, mode: mode, dryRun: dryRun)
            operation.entries.append(contentsOf: entries)
            let freed = entries.filter { $0.result == .removed || $0.result == .dryRun }.reduce(0) { $0 + $1.bytes }
            onEvent?(.finished(itemID: selection.result.id, bytesFreed: freed, entries: entries))
        }
        ledger.append(operation)
        return operation
    }

    private func cleanItem(_ selection: CleanSelection, mode: DeleteMode, dryRun: Bool) async -> [OperationEntry] {
        let result = selection.result
        let item = result.item

        func entry(_ target: String, _ bytes: Int64, _ mode: String, _ outcome: OperationEntry.Result, _ reason: String? = nil) -> OperationEntry {
            OperationEntry(itemID: item.id, itemName: item.name, target: target, bytes: bytes, mode: mode, result: outcome, reason: reason)
        }
        let summaryTarget = result.targets.first?.description ?? item.name

        if let reason = result.status.reason {
            return [entry(summaryTarget, 0, mode.rawValue, .skipped, reason)]
        }
        if settings.isExcluded(itemID: item.id) {
            return [entry(summaryTarget, 0, mode.rawValue, .skipped, "Excluded in Settings")]
        }
        // Guards are checked again now, not just when the list was drawn.
        if let reason = await guardReason(for: item) {
            return [entry(summaryTarget, 0, mode.rawValue, .skipped, reason)]
        }
        if result.selectable, selection.targetIDs == nil {
            return [entry(summaryTarget, 0, mode.rawValue, .skipped, "nothing selected")]
        }

        let targets = result.targets.filter { selection.targetIDs?.contains($0.id) ?? true }
        guard !targets.isEmpty else { return [] }

        if !dryRun {
            for command in item.clean.before ?? [] where context.runner.locate(command[0]) != nil {
                _ = await context.runner.run(command, timeout: 30)
            }
        }

        var entries: [OperationEntry] = []
        for target in targets {
            if Task.isCancelled { break }
            switch target.action {
            case .delete(let path):
                if settings.isExcluded(path: path, context: context) {
                    entries.append(entry(path, 0, mode.rawValue, .skipped, "Excluded in Settings"))
                    continue
                }
                // An entry that qualified by age is checked again: a session may have been resumed since the scan.
                if let days = item.clean.olderThanDays {
                    let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
                    let newest = (try? await sizer.sizeAsync(of: [URL(fileURLWithPath: path)]))?.lastModified
                    if let newest, newest > cutoff {
                        entries.append(entry(path, 0, mode.rawValue, .skipped, "used since the scan"))
                        continue
                    }
                }
                let remover = self.remover
                let roots = result.roots
                let outcome = await Task.detached(priority: .utility) {
                    remover.remove(path, allowedRoots: roots, scope: .cache, fingerprint: target.fingerprint, mode: mode, dryRun: dryRun)
                }.value
                switch outcome {
                case .removed(let bytes): entries.append(entry(path, bytes, mode.rawValue, .removed))
                case .dryRun(let bytes): entries.append(entry(path, bytes, mode.rawValue, .dryRun))
                case .skipped(let reason): entries.append(entry(path, 0, mode.rawValue, .skipped, reason))
                case .refused(let reason):
                    log.error("Refused delete \(path, privacy: .public): \(reason, privacy: .public)")
                    entries.append(entry(path, 0, mode.rawValue, .refused, reason))
                case .failed(let reason, let freed): entries.append(entry(path, freed, mode.rawValue, .failed, reason))
                }

            case .command(let command):
                entries.append(await runClean(command, target: target, result: result, dryRun: dryRun))
            }
        }
        return entries
    }

    private func runClean(_ command: [String], target: CleanTarget, result: ScanResult, dryRun: Bool) async -> OperationEntry {
        let item = result.item
        let line = command.joined(separator: " ")
        func entry(_ bytes: Int64, _ outcome: OperationEntry.Result, _ reason: String? = nil) -> OperationEntry {
            OperationEntry(itemID: item.id, itemName: item.name, target: line, bytes: bytes, mode: "command", result: outcome, reason: reason)
        }
        if dryRun { return entry(target.bytes, .dryRun) }

        // The locations the tool is about to clean must still be what was scanned.
        for root in result.roots {
            let verdict = safety.evaluateRoot(root, scope: .cache)
            if !verdict.allowed || verdict.resolved != root {
                return entry(0, .refused, verdict.reason ?? "location changed since the scan")
            }
        }
        let rootURLs = result.roots.map { URL(fileURLWithPath: $0) }
        let before = rootURLs.isEmpty ? result.bytes : ((try? await sizer.sizeAsync(of: rootURLs))?.bytes ?? result.bytes)

        let outcome = await context.runner.run(command, timeout: commandTimeout)

        var freed: Int64
        if !rootURLs.isEmpty {
            let after = (try? await sizer.sizeAsync(of: rootURLs))?.bytes ?? 0
            freed = max(before - after, 0)
        } else if result.selectable {
            freed = outcome.succeeded ? target.bytes : 0
        } else if outcome.succeeded, let name = item.clean.handler, let handler = Handlers.all[name] {
            // No folder to measure: ask the tool again and compare.
            let after = await handler.scan(item, engine: self, fresh: true)
            let remaining = after.bytes ?? after.targets.reduce(0) { $0 + $1.bytes }
            freed = max(result.bytes - remaining, 0)
        } else {
            freed = 0
        }

        if outcome.succeeded { return entry(freed, .removed) }
        freed = max(freed, 0)
        return entry(freed, .failed, outcome.failureReason)
    }
}

/// Remembers the answers of slow read-only commands for a short while, and
/// lets concurrent callers wait for one run instead of starting their own.
actor CommandMemo {
    private var entries: [String: (started: Date, task: Task<CommandResult, Never>)] = [:]

    func run(_ command: [String], runner: any CommandRunning, timeout: TimeInterval, reuseWithin: TimeInterval) async -> CommandResult {
        let key = command.joined(separator: "\u{1F}")
        if reuseWithin > 0, let entry = entries[key], Date().timeIntervalSince(entry.started) < reuseWithin {
            return await entry.task.value
        }
        let task = Task { await runner.run(command, timeout: timeout) }
        entries[key] = (Date(), task)
        return await task.value
    }
}
