import Foundation
import SweepKit

/// Reads a bundle identifier out of a leftover's name.
enum OrphanName {
    /// The identifier a name stands for, in the name's own case, or nil when the name is not clearly one.
    static func bundleID(from name: String, in location: LeftoverLocation) -> String? {
        var id = name
        let lower = name.lowercased()
        guard !lower.hasPrefix("."), !BundleIdentifier.isApple(lower) else { return nil }
        if let suffix = LeftoverMatcher.systemSuffixes.first(where: { lower.hasSuffix($0) }) {
            id.removeLast(suffix.count)
        }
        if location == .preferencesByHost {
            // `com.foo.App.<host UUID>.plist`
            var parts = BundleIdentifier.components(id)
            if let last = parts.last, isUUID(last) { parts.removeLast() }
            id = parts.joined(separator: ".")
        }
        if location == .groupContainers {
            // `group.com.foo.App`, `TEAMID1234.com.foo.App`, `TEAMID1234.group.com.foo.App`
            var parts = BundleIdentifier.components(id)
            if let first = parts.first, isTeamID(first) { parts.removeFirst() }
            if let first = parts.first?.lowercased(), first == "group" || first == "groups" { parts.removeFirst() }
            id = parts.joined(separator: ".")
        }
        guard BundleIdentifier.looksReverseDNS(id), !BundleIdentifier.isApple(id) else { return nil }
        return id
    }

    private static func isUUID(_ text: Substring) -> Bool {
        text.count == 36 && UUID(uuidString: String(text)) != nil
    }

    private static func isTeamID(_ text: Substring) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }
}

extension AppUninstaller {
    /// Leftovers in `~/Library` named after a bundle identifier that nothing
    /// on this Mac answers to any more, biggest first, sizes included.
    ///
    /// Deliberately narrow. A leftover is listed only when all of this holds:
    /// its name is a reverse-DNS identifier; it is not Apple's or Sweep's; no
    /// installed app, embedded helper, registered app or running process has
    /// that identifier, a parent of it or a child of it; no installed app
    /// comes from the same developer (developers share data between their
    /// apps); it is not a known command-line tool or runtime; nothing inside
    /// it changed recently; and it is not a symbolic link.
    public func orphans() async -> [Orphan] {
        let candidates = await orphanCandidates()
        let measured = await withTaskGroup(of: Orphan?.self) { group -> [Orphan] in
            var result: [Orphan] = []
            var next = 0
            while next < min(4, candidates.count) {
                let candidate = candidates[next]
                group.addTask { await self.measuredIfUnused(candidate) }
                next += 1
            }
            while let orphan = await group.next() {
                if let orphan { result.append(orphan) }
                if next < candidates.count {
                    let candidate = candidates[next]
                    group.addTask { await self.measuredIfUnused(candidate) }
                    next += 1
                }
            }
            return result
        }
        return measured.sorted { ($0.bytes ?? 0, $1.path) > ($1.bytes ?? 0, $0.path) }
    }

    /// Every rule except the look inside for recent changes. Sizes are not filled in.
    func orphanCandidates() async -> [Orphan] {
        let found = await inventory(refresh: true)
        let environment = self.environment
        let safety = engine.safety
        let running = context.processes.runningProcesses()
        let directories: [(LeftoverLocation, String)] = LeftoverLocation.orphanLocations.compactMap { location in
            scanDirectory(location).map { (location, $0) }
        }

        return await Task.detached(priority: .utility) { () -> [Orphan] in
            var installed = Set(environment.ownBundleIDs.map { $0.lowercased() })
            for app in found.map(\.app) {
                if let id = app.bundleID { installed.insert(id.lowercased()) }
                for id in AppDiscovery.embeddedBundleIDs(in: app.path) { installed.insert(id.lowercased()) }
            }
            var runningNames = Set<String>()
            for process in running {
                // A running process counts like an installed app, wherever it was started from.
                if let id = process.bundleID { installed.insert(id.lowercased()) }
                runningNames.insert(process.name.lowercased())
            }
            let vendors = Set(installed.compactMap(BundleIdentifier.vendor))

            var result: [Orphan] = []
            var verdicts: [String: Bool] = [:]
            for (location, directory) in directories {
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
                for name in names {
                    guard let id = OrphanName.bundleID(from: name, in: location) else { continue }
                    let key = id.lowercased()
                    let isOrphan: Bool
                    if let known = verdicts[key] {
                        isOrphan = known
                    } else {
                        isOrphan = AppUninstaller.isUnclaimed(
                            id, installed: installed, vendors: vendors, runningNames: runningNames,
                            registeredAppPaths: environment.registeredAppPaths)
                        verdicts[key] = isOrphan
                    }
                    guard isOrphan else { continue }

                    let path = directory + "/" + name
                    guard let print = Fingerprint(path: path), !print.isSymlink,
                          safety.denyReason(for: path, scope: .uninstall) == nil else { continue }
                    result.append(Orphan(path: path, bundleID: id, location: location, fingerprint: print))
                }
            }
            return result
        }.value
    }

    /// True when nothing installed, registered or running answers to the identifier.
    static func isUnclaimed(
        _ id: String,
        installed: Set<String>,
        vendors: Set<String>,
        runningNames: Set<String>,
        registeredAppPaths: @Sendable (String) -> [String]
    ) -> Bool {
        let lower = id.lowercased()
        if BundleIdentifier.generic.contains(lower) || BundleIdentifier.looksLikeTool(lower) { return false }
        if installed.contains(where: { BundleIdentifier.areRelated(lower, $0) }) { return false }
        // Updaters, shared settings and licence files carry the developer's prefix, not one app's.
        if let vendor = BundleIdentifier.vendor(lower), vendors.contains(vendor) { return false }
        if runningNames.contains(lower) { return false }
        if let last = BundleIdentifier.components(lower).last, last.count >= 4, runningNames.contains(String(last)) { return false }
        // The app may live outside the applications folders: ask Launch Services
        // for the identifier and its parents, in the identifier's own case.
        let parts = BundleIdentifier.components(id)
        var count = parts.count
        while count >= 3 {
            if !registeredAppPaths(parts.prefix(count).joined(separator: ".")).isEmpty { return false }
            count -= 1
        }
        return true
    }

    /// The candidate with its size and newest change, or nil when something
    /// inside it changed within `orphanMinimumAge`: whatever wrote to it is still around.
    func measuredIfUnused(_ orphan: Orphan) async -> Orphan? {
        guard let size = try? await engine.sizer.sizeAsync(of: [URL(fileURLWithPath: orphan.path)]) else { return nil }
        if environment.orphanMinimumAge > 0, let changed = size.lastModified,
           changed > Date().addingTimeInterval(-environment.orphanMinimumAge) {
            return nil
        }
        var orphan = orphan
        orphan.bytes = size.bytes
        orphan.lastModified = size.lastModified
        return orphan
    }

    /// Moves one orphan to the Trash. Orphans are removed one at a time, after review.
    @discardableResult
    public func removeOrphan(_ orphan: Orphan, source: String = "window", dryRun: Bool = false) async -> SweepOperation {
        var operation = SweepOperation(kind: .uninstall, source: source, dryRun: dryRun)
        let mode = DeleteMode.trash
        func record(_ bytes: Int64, _ result: OperationEntry.Result, _ reason: String? = nil) {
            operation.entries.append(OperationEntry(
                itemID: orphan.bundleID, itemName: orphan.name, target: orphan.path, bytes: bytes, mode: mode.rawValue,
                result: result, reason: reason))
        }

        // Look again: the path must still be an orphan Sweep itself would list.
        var stillOrphan = false
        if let current = await orphanCandidates().first(where: { $0.path == orphan.path }) {
            stillOrphan = await measuredIfUnused(current) != nil
        }
        guard stillOrphan else {
            record(0, .skipped, "no longer an orphan")
            engine.ledger.append(operation)
            return operation
        }
        let remover = engine.remover
        let outcome = await Task.detached(priority: .userInitiated) {
            remover.remove(
                orphan.path, allowedRoots: [orphan.path], scope: .uninstall, fingerprint: orphan.fingerprint,
                mode: mode, dryRun: dryRun)
        }.value
        switch outcome {
        case .removed(let bytes): record(bytes, .removed)
        case .dryRun(let bytes): record(bytes, .dryRun)
        case .skipped(let reason): record(0, .skipped, reason)
        case .refused(let reason): record(0, .refused, reason)
        case .failed(let reason, let freed): record(freed, .failed, reason)
        }
        engine.ledger.append(operation)
        return operation
    }
}
