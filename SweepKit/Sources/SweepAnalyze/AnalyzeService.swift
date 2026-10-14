import Foundation
import SweepKit

/// What happened when a file or folder was sent to the Trash from Analyze.
public struct AnalyzeTrashResult: Sendable {
    public var path: String
    public var outcome: RemovalOutcome
    /// The operation as written to the ledger.
    public var operation: SweepOperation

    /// True when the item is now in the Trash.
    public var succeeded: Bool {
        if case .removed = outcome { return true }
        return false
    }

    /// Bytes that left the scanned folder.
    public var bytes: Int64 {
        switch outcome {
        case .removed(let bytes): bytes
        case .failed(_, let freed): freed
        case .dryRun, .skipped, .refused: 0
        }
    }

    /// Why nothing was moved, when nothing was.
    public var reason: String? {
        switch outcome {
        case .removed, .dryRun: nil
        case .skipped(let reason), .refused(let reason), .failed(let reason, _): reason
        }
    }
}

/// Everything the Analyze tool asks of the engine: scanning with the 24-hour
/// cache, moving an item to the Trash through the guard, and exclusions.
public struct AnalyzeService: Sendable {
    public let engine: SweepEngine
    public let cache: AnalyzeCache
    public var scanner: AnalyzeScanner

    public init(engine: SweepEngine, scanner: AnalyzeScanner = AnalyzeScanner(), cache: AnalyzeCache? = nil) {
        self.engine = engine
        self.scanner = scanner
        self.cache = cache ?? AnalyzeCache(context: engine.context)
    }

    // MARK: Scanning

    /// The path a scan of `url` is filed under: the folder itself, links resolved.
    public func resolvedPath(for url: URL) -> String {
        let standardized = url.standardizedFileURL.path
        return SafetyGuard.realpath(standardized) ?? standardized
    }

    /// The scan of `url` from the last 24 hours, if there is one.
    public func cachedTree(for url: URL, now: Date = Date()) -> AnalyzeTree? {
        cache.load(path: resolvedPath(for: url), now: now)
    }

    /// Walks `url` and remembers the result for the next 24 hours.
    public func scan(
        _ url: URL,
        now: Date = Date(),
        progress: (@Sendable (AnalyzeProgress) -> Void)? = nil
    ) async throws -> AnalyzeTree {
        let tree = try await scanner.scan(url, now: now, progress: progress)
        save(tree)
        return tree
    }

    /// Reads one folder of `tree` again (an unreadable one, usually) and
    /// returns the tree with that folder replaced and every size above it updated.
    public func retry(_ id: AnalyzeTree.NodeID, in tree: AnalyzeTree) async throws -> AnalyzeTree {
        guard tree.isValid(id), tree[id].isDirectory else { return tree }
        if id == tree.root { return try await scan(URL(fileURLWithPath: tree.rootPath)) }
        let subtree = try await scanner.scan(URL(fileURLWithPath: tree.path(of: id)))
        var updated = tree
        updated.graft(subtree, at: id)
        save(updated)
        return updated
    }

    /// Writes a tree back to the cache, for example after an item was trashed.
    /// A cache that cannot be written only costs a rescan next time.
    public func save(_ tree: AnalyzeTree) {
        try? cache.store(tree)
    }

    public func volumeSpace(for url: URL) async -> VolumeSpace {
        await VolumeInspector(runner: engine.context.runner).inspect(url)
    }

    // MARK: Trash

    /// Tidies a path without touching the disk: no doubled or trailing
    /// slashes and no `.` components. Tree paths are already real paths, and
    /// Foundation's own standardising would rewrite `/private/var` to `/var`.
    static func normalized(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return (path.hasPrefix("/") ? "/" : "") + components.joined(separator: "/")
    }

    /// Why `path` cannot be moved to the Trash, or nil when it can. This is
    /// the guard's own answer, so a menu item can be hidden before it is tried.
    public func trashDenyReason(for path: String) -> String? {
        let standardized = Self.normalized(path)
        if let reason = engine.safety.denyReason(for: standardized, scope: .analyze) { return reason }
        if isExcluded(standardized) { return Self.excludedReason }
        let real = SafetyGuard.realpath(standardized) ?? standardized
        if real != standardized, Fingerprint(path: standardized) != nil { return Self.linkedReason }
        let verdict = engine.safety.evaluate(standardized, allowedRoots: [real], scope: .analyze)
        return verdict.allowed ? nil : (verdict.reason ?? "refused")
    }

    public func canTrash(_ path: String) -> Bool { trashDenyReason(for: path) == nil }

    /// Moves one file or folder to the Trash through the guarded remover and
    /// records it in the ledger. Nothing else in Analyze removes anything.
    public func trash(_ path: String) async -> AnalyzeTrashResult {
        await Task.detached(priority: .userInitiated) { trashBlocking(path) }.value
    }

    func trashBlocking(_ path: String) -> AnalyzeTrashResult {
        let standardized = Self.normalized(path)
        let real = SafetyGuard.realpath(standardized) ?? standardized
        let outcome: RemovalOutcome
        if isExcluded(standardized) {
            outcome = .refused(Self.excludedReason)
        } else if real != standardized, Fingerprint(path: standardized) != nil {
            // The scan never follows links, so a path through one did not come from the tree.
            outcome = .refused(Self.linkedReason)
        } else {
            // The user picked exactly this item, so it is its own allowlist root.
            outcome = engine.remover.remove(
                standardized,
                allowedRoots: [real],
                scope: .analyze,
                fingerprint: Fingerprint(path: standardized),
                mode: .trash,
                dryRun: false
            )
        }

        let result: OperationEntry.Result
        var bytes: Int64 = 0
        var reason: String?
        switch outcome {
        case .removed(let freed):
            result = .removed
            bytes = freed
        case .dryRun(let planned):
            result = .dryRun
            bytes = planned
        case .skipped(let why):
            result = .skipped
            reason = why
        case .refused(let why):
            result = .refused
            reason = why
        case .failed(let why, let freed):
            result = .failed
            bytes = freed
            reason = why
        }
        let entry = OperationEntry(
            itemID: "analyze",
            itemName: (standardized as NSString).lastPathComponent,
            target: standardized,
            bytes: bytes,
            mode: DeleteMode.trash.rawValue,
            result: result,
            reason: reason
        )
        let operation = SweepOperation(kind: .analyze, source: "window", entries: [entry])
        engine.ledger.append(operation)
        return AnalyzeTrashResult(path: standardized, outcome: outcome, operation: operation)
    }

    // MARK: Exclusions

    static let excludedReason = "excluded in Settings"
    static let linkedReason = "is, or is reached through, a symbolic link"

    /// True when the path, or a folder above it, is in the exclusions list.
    public func isExcluded(_ path: String) -> Bool {
        engine.settings.isExcluded(path: path, context: engine.context)
    }

    /// Adds the path to Settings → Exclusions. Returns false when it was already covered.
    @discardableResult
    public func addExclusion(_ path: String) -> Bool {
        let standardized = Self.normalized(path)
        var settings = engine.settings
        guard !settings.exclusions.contains(standardized) else { return false }
        settings.exclusions.append(standardized)
        engine.updateSettings(settings)
        return true
    }

    /// Takes the path itself back out of the exclusions list.
    @discardableResult
    public func removeExclusion(_ path: String) -> Bool {
        let standardized = Self.normalized(path)
        var settings = engine.settings
        guard settings.exclusions.contains(standardized) else { return false }
        settings.exclusions.removeAll { $0 == standardized }
        engine.updateSettings(settings)
        return true
    }

    /// True when the path is listed itself, as opposed to covered by a folder above it.
    public func isExcludedExactly(_ path: String) -> Bool {
        engine.settings.exclusions.contains(Self.normalized(path))
    }
}
