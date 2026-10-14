import Foundation
import SweepKit

/// The Uninstall tool: finds apps, previews what removing one takes with it,
/// and removes it through the guarded remover, Homebrew or the admin helper.
///
/// Nothing here deletes a file itself. Every path goes through
/// `GuardedRemover` with the `.uninstall` scope and an allowlist that holds
/// exactly the previewed paths.
public final class AppUninstaller: Sendable {
    public let engine: SweepEngine
    public let privileged: any PrivilegedRunning
    public let environment: UninstallEnvironment

    /// The last discovery, hidden apps included.
    private let known = Locked<[AppDiscovery.Found]?>(nil)

    /// - Parameter environment: defaults to the real machine, or to a
    ///   fixture-only environment when the engine runs against a fixture home.
    public init(engine: SweepEngine, privileged: any PrivilegedRunning = NoPrivilegedRunner(), environment: UninstallEnvironment? = nil) {
        self.engine = engine
        self.privileged = privileged
        self.environment = environment ?? .standard(for: engine.context)
    }

    var context: SweepContext { engine.context }
    var realHome: String { engine.safety.home }
    private var casks: HomebrewCasks { HomebrewCasks(engine: engine, environment: environment) }

    // MARK: Discovery

    /// Apps the user can act on, sorted by name. System apps and Sweep itself are left out.
    public func installedApps() async -> [InstalledApp] {
        await inventory(refresh: true).filter { $0.hiddenReason == nil }.map(\.app)
    }

    func inventory(refresh: Bool) async -> [AppDiscovery.Found] {
        if !refresh, let cached = known.get() { return cached }
        let index = await casks.index()
        let discovery = AppDiscovery(context: context, environment: environment)
        let found = await Task.detached(priority: .userInitiated) { discovery.discover(casks: index) }.value
        known.set(found)
        return found
    }

    /// Allocated size of an app bundle.
    public func size(of app: InstalledApp) async -> Int64 {
        await size(ofPath: app.path)
    }

    /// Allocated size of any path, links not followed.
    public func size(ofPath path: String) async -> Int64 {
        (try? await engine.sizer.sizeAsync(of: [URL(fileURLWithPath: path)]))?.bytes ?? 0
    }

    public func isRunning(_ app: InstalledApp) -> Bool {
        AppDiscovery.isRunning(path: app.path, bundleID: app.bundleID, names: app.names, in: context.processes.runningProcesses())
    }

    // MARK: Preview

    /// Everything removing the app would take: the bundle, then each leftover.
    /// - Parameter measure: false returns at once with sizes still nil; fill them in with `size(ofPath:)`.
    public func plan(for app: InstalledApp, measure: Bool = true) async -> UninstallPlan {
        let others = await inventory(refresh: false).map(\.app).filter { $0.path != app.path }
        var sharedNames = Set<String>()
        for other in others where other.bundleID?.lowercased() != app.bundleID?.lowercased() {
            sharedNames.formUnion(other.names.map { $0.lowercased() })
        }
        let matcher = LeftoverMatcher(app: app, otherBundleIDs: others.compactMap(\.bundleID), sharedNames: sharedNames)

        var plan = UninstallPlan(app: app, items: [])
        var seen: Set<String> = [app.path]
        var bundle = makeItem(app.path, kind: .appBundle, evidence: .bundle)
        if app.caskToken != nil { bundle.route = .homebrew }
        plan.items.append(bundle)

        if app.removability.isRemovable {
            if let token = app.caskToken {
                let zap = await casks.zapPaths(token: token)
                // Homebrew deletes without asking Sweep's guard, so the guard is asked here.
                let refused = zap.filter { !isAcceptableZapPath($0) }
                if refused.isEmpty {
                    for path in zap where seen.insert(path).inserted {
                        var item = makeItem(path, kind: .leftover, location: location(of: path), evidence: .caskZap(token: token))
                        item.route = .homebrew
                        item.blockedReason = nil
                        item.isSelectedByDefault = true
                        plan.items.append(item)
                    }
                } else {
                    plan.usesZap = false
                    plan.notes.append("The cask's cleanup list names a protected location, so Homebrew removes the app only.")
                }
            }
            for item in leftovers(matching: matcher, appPath: app.path) where seen.insert(item.path).inserted {
                plan.items.append(item)
            }
            if app.caskToken == nil {
                let receipts = await PackageReceipts(engine: engine).receipts(for: app, matcher: matcher)
                plan.packageIDs = receipts.packages
                for extra in receipts.extras where seen.insert(extra.path).inserted {
                    plan.items.append(makeItem(
                        extra.path, kind: .leftover, location: location(of: extra.path),
                        evidence: .receipt(package: extra.package), selected: false))
                }
                if receipts.omitted > 0 {
                    plan.notes.append("\(receipts.omitted) more files from the installer are not listed.")
                }
            }
        }

        if measure {
            for index in plan.items.indices {
                plan.items[index].bytes = await size(ofPath: plan.items[index].path)
            }
        }
        return plan
    }

    /// Leftovers in the known locations whose name the matcher accepts.
    func leftovers(matching matcher: LeftoverMatcher, appPath: String) -> [UninstallItem] {
        guard matcher.bundleID != nil || !matcher.names.isEmpty else { return [] }
        var items: [UninstallItem] = []
        for location in LeftoverLocation.allCases {
            guard let directory = scanDirectory(location) else { continue }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
            for name in names {
                guard let evidence = matcher.evidence(for: name, in: location) else { continue }
                // `com.foo.App.Other` may be an app of its own that lives outside the applications folders.
                if evidence == .bundleID, location != .groupContainers, isClaimedByAnotherApp(name, matcher: matcher, appPath: appPath) { continue }
                items.append(makeItem(directory + "/" + name, kind: .leftover, location: location, evidence: evidence))
            }
        }
        return items
    }

    /// True when a longer identifier in the name is registered to an app that is not inside this one.
    private func isClaimedByAnotherApp(_ name: String, matcher: LeftoverMatcher, appPath: String) -> Bool {
        matcher.longerIdentifiers(in: name).contains { id in
            environment.registeredAppPaths(id).contains { !SafetyGuard.isSame($0, orInside: appPath) }
        }
    }

    /// The real folder of a location, or nil when it is missing, is itself a
    /// link, or (for a fixture home) lies outside the fixture.
    func scanDirectory(_ location: LeftoverLocation) -> String? {
        guard let expected = environment.directory(for: location, home: URL(fileURLWithPath: realHome)) else { return nil }
        guard let written = PathText.clean(expected) else { return nil }
        if context.isFixture, !SafetyGuard.isInside(written, realHome) { return nil }
        guard let real = SafetyGuard.realpath(written), real == written else { return nil }
        return real
    }

    private func location(of path: String) -> LeftoverLocation? {
        let parent = (path as NSString).deletingLastPathComponent
        return LeftoverLocation.allCases.first { scanDirectory($0) == parent }
    }

    private func makeItem(
        _ path: String,
        kind: UninstallItem.Kind,
        location: LeftoverLocation? = nil,
        evidence: UninstallItem.Evidence,
        selected: Bool = true
    ) -> UninstallItem {
        let print = Fingerprint(path: path)
        var blocked: String?
        if print?.isSymlink == true {
            blocked = "A symbolic link; left in place"
        } else if let reason = engine.safety.denyReason(for: path, scope: .uninstall) {
            blocked = "Protected: \(reason)"
        } else if let real = SafetyGuard.realpath(path), real != path {
            blocked = "Reached through a symbolic link; left in place"
        }
        return UninstallItem(
            path: path, kind: kind, location: location, evidence: evidence, fingerprint: print,
            needsAdmin: environment.requiresAdmin(path), blockedReason: blocked,
            isSelectedByDefault: selected && blocked == nil)
    }

    private func isAcceptableZapPath(_ path: String) -> Bool {
        if context.isFixture, !SafetyGuard.isInside(path, realHome) { return false }
        if engine.safety.denyReason(for: path, scope: .uninstall) != nil { return false }
        // A link is unlinked by Homebrew, never followed; anything else must be where it says it is.
        if let print = Fingerprint(path: path), !print.isSymlink, let real = SafetyGuard.realpath(path) {
            return engine.safety.denyReason(for: real, scope: .uninstall) == nil
        }
        return true
    }

    // MARK: Uninstall

    /// Removes the app and the selected leftovers.
    ///
    /// Order: ask the app to quit, remove its Dock tile, remove the bundle,
    /// then the leftovers. If the bundle cannot be removed, the leftovers stay.
    /// - Parameters:
    ///   - selection: ids of the items to remove; nil takes the plan's default selection.
    ///   - dryRun: touches nothing and reports what would happen.
    public func uninstall(
        _ plan: UninstallPlan,
        selecting selection: Set<String>? = nil,
        source: String = "window",
        dryRun: Bool = false
    ) async -> UninstallReport {
        let app = plan.app
        let mode = engine.settings.uninstallDeleteMode
        var report = UninstallReport(app: app, operation: SweepOperation(kind: .uninstall, source: source, dryRun: dryRun))

        func record(_ target: String, _ bytes: Int64, _ mode: String, _ result: OperationEntry.Result, _ reason: String? = nil) {
            report.operation.entries.append(OperationEntry(
                itemID: app.bundleID ?? app.path, itemName: app.name, target: target, bytes: bytes, mode: mode, result: result, reason: reason))
        }
        func finish() -> UninstallReport {
            engine.ledger.append(report.operation)
            known.set(nil)
            return report
        }

        // The plan is a preview, not an instruction: only what a fresh look at
        // the machine still attributes to this app is eligible.
        guard let current = await currentApp(at: app.path), current.bundleID == app.bundleID else {
            report.stoppedReason = "\(app.name) is no longer where it was"
            return report
        }
        guard current.removability.isRemovable else {
            report.stoppedReason = "\(app.name) must be removed with its own uninstaller"
            return report
        }
        let fresh = await self.plan(for: current, measure: false)
        let freshByPath = Dictionary(fresh.items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        var chosen: [UninstallItem] = []
        for item in plan.effectiveItems(selecting: selection) {
            guard let now = freshByPath[item.path] else {
                record(item.path, 0, mode.rawValue, .skipped, "no longer matches \(app.name)")
                continue
            }
            var item = item
            item.route = now.route
            item.needsAdmin = now.needsAdmin
            item.blockedReason = now.blockedReason
            chosen.append(item)
        }
        guard !chosen.isEmpty else { return finish() }
        let removesBundle = chosen.contains { $0.kind == .appBundle }

        // 1. Quit. A running app is asked, never forced.
        if isRunning(current), !dryRun {
            report.didQuitApp = await environment.terminator.terminate(current)
            if !report.didQuitApp {
                report.stoppedReason = "\(app.name) is still running"
                for item in chosen { record(item.path, 0, mode.rawValue, .skipped, "\(app.name) is still running") }
                return finish()
            }
        }

        // 2. Dock tile.
        if removesBundle, !dryRun {
            report.dockEntryRemoved = await environment.dock.removeEntry(for: current)
        }

        // 3. Remove. The allowlist is exactly the chosen paths, as real paths.
        let roots = chosen.filter { $0.route == .sweep && $0.fingerprint?.isSymlink != true }
            .map(\.path).filter { SafetyGuard.realpath($0) == $0 }
        var remaining = chosen
        var stop: String?

        func removeWithGuard(_ item: UninstallItem) async {
            let remover = engine.remover
            let outcome = await Task.detached(priority: .userInitiated) {
                remover.remove(item.path, allowedRoots: roots, scope: .uninstall, fingerprint: item.fingerprint, mode: mode, dryRun: dryRun)
            }.value
            switch outcome {
            case .removed(let bytes): record(item.path, bytes, mode.rawValue, .removed)
            case .dryRun(let bytes): record(item.path, bytes, mode.rawValue, .dryRun)
            case .skipped(let reason): record(item.path, 0, mode.rawValue, .skipped, reason)
            case .refused(let reason): record(item.path, 0, mode.rawValue, .refused, reason)
            case .failed(let reason, let freed): record(item.path, freed, mode.rawValue, .failed, reason)
            }
            if item.kind == .appBundle {
                switch outcome {
                case .removed, .dryRun: break
                default: stop = "\(app.name) could not be removed"
                }
            }
        }

        // 3a. Homebrew casks: brew removes the bundle and what its zap stanza names.
        if let token = current.caskToken, removesBundle {
            let handled = remaining.filter { $0.route == .homebrew }
            remaining.removeAll { $0.route == .homebrew }
            let command = fresh.command ?? ["brew", "uninstall", "--cask", token]
            let line = command.joined(separator: " ")
            var before: [String: Int64] = [:]
            for item in handled { before[item.path] = await size(ofPath: item.path) }
            if dryRun {
                record(line, before.values.reduce(0, +), "command", .dryRun)
            } else {
                let result = await context.runner.run(command, timeout: engine.commandTimeout)
                let freed = handled.filter { Fingerprint(path: $0.path) == nil }.reduce(Int64(0)) { $0 + (before[$1.path] ?? 0) }
                if result.succeeded {
                    record(line, freed, "command", .removed)
                } else {
                    record(line, freed, "command", .failed, result.failureReason)
                    if Fingerprint(path: current.path) != nil { stop = "Homebrew could not remove \(app.name)" }
                }
            }
        } else {
            remaining.removeAll { $0.route == .homebrew && $0.kind != .appBundle }
        }

        // 3b. The bundle, when the current user owns it.
        if let bundle = remaining.first(where: { $0.kind == .appBundle && !$0.needsAdmin }) {
            remaining.removeAll { $0.id == bundle.id }
            await removeWithGuard(bundle)
        }

        // 3c. Root-owned paths go to the helper, which takes a bundle identifier and nothing else.
        let admin = remaining.filter { $0.needsAdmin && $0.blockedReason == nil }
        remaining.removeAll { item in admin.contains { $0.id == item.id } }
        if !admin.isEmpty {
            if let stop {
                for item in admin { record(item.path, 0, "helper", .skipped, stop) }
            } else if dryRun {
                for item in admin {
                    let bytes = await size(ofPath: item.path)
                    record(item.path, bytes, "helper", .dryRun)
                }
            } else if let bundleID = current.bundleID {
                var before: [String: Int64] = [:]
                for item in admin { before[item.path] = await size(ofPath: item.path) }
                let result = await privileged.run(.removeApplication, argument: bundleID)
                report.privilegedResult = result
                let left = admin.filter { Fingerprint(path: $0.path) != nil }
                let measured = admin.filter { Fingerprint(path: $0.path) == nil }.reduce(Int64(0)) { $0 + (before[$1.path] ?? 0) }
                let target = "\(PrivilegedTask.removeApplication.rawValue) \(bundleID)"
                if result.succeeded {
                    record(target, result.bytesFreed > 0 ? result.bytesFreed : measured, "helper", .removed)
                    for item in left { record(item.path, 0, "helper", .skipped, "left in place by the admin helper") }
                } else {
                    record(target, measured, "helper", .failed, result.message.isEmpty ? "the admin helper failed" : result.message)
                }
                if left.contains(where: { $0.kind == .appBundle }) { stop = "\(app.name) could not be removed" }
            } else {
                for item in admin { record(item.path, 0, "helper", .skipped, "needs an administrator and has no bundle identifier") }
                if admin.contains(where: { $0.kind == .appBundle }) { stop = "\(app.name) could not be removed" }
            }
        }

        // 3d. Leftovers.
        for item in remaining {
            if let stop {
                record(item.path, 0, mode.rawValue, .skipped, stop)
            } else {
                await removeWithGuard(item)
            }
        }
        report.stoppedReason = stop
        return finish()
    }

    /// The app as it is on disk right now; nil when it is gone, hidden, or not in an applications folder.
    private func currentApp(at path: String) async -> InstalledApp? {
        await inventory(refresh: true).first { $0.app.path == path && $0.hiddenReason == nil }?.app
    }
}
