import Foundation
import SweepKit

/// Builds the Clean tool's review list. Nothing here deletes anything: the
/// scanner lists folders, measures them and explains what it had to skip.
public struct JunkScanner: Sendable {
    public let engine: SweepEngine
    public let privileged: any PrivilegedRunning
    public var options: JunkOptions
    private let rules: JunkRules

    static let fullDiskAccessReason = "Needs Full Disk Access"

    public init(engine: SweepEngine, privileged: any PrivilegedRunning = NoPrivilegedRunner(), options: JunkOptions = JunkOptions()) {
        self.engine = engine
        self.privileged = privileged
        self.options = options
        self.rules = JunkRules(engine: engine)
    }

    // MARK: Full Disk Access

    /// Found by trying to read `~/Library/Safari`.
    public var fullDiskAccess: FullDiskAccess.Status { FullDiskAccess.status(home: URL(fileURLWithPath: rules.home)) }

    /// True when macOS refused the probe, which is when the banner is shown.
    public var isFullDiskAccessMissing: Bool { fullDiskAccess == .denied }

    /// The Full Disk Access pane of System Settings.
    public var fullDiskAccessSettingsURL: URL { FullDiskAccess.settingsURL }

    // MARK: Scan

    /// Scans every category. Entries are reported as soon as they are found
    /// (`isSizing` true) and again once measured, at most `maxConcurrent`
    /// measurements at a time. Cancelling the consuming task stops the scan.
    public func scan(maxConcurrent: Int = 4) -> AsyncStream<JunkScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await self.run(maxConcurrent: max(maxConcurrent, 1)) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Scans everything and returns the measured entries in review order:
    /// risk tier, then size descending, with the Trash last.
    public func scanCollected() async -> [JunkEntry] {
        var entries: [String: JunkEntry] = [:]
        for await event in scan() {
            switch event {
            case .entry(let entry): entries[entry.id] = entry
            case .dropped(let id): entries[id] = nil
            }
        }
        return entries.values.filter { !$0.isSizing }.reviewOrdered()
    }

    private func run(maxConcurrent: Int, emit: @escaping @Sendable (JunkScanEvent) -> Void) async {
        let processes = engine.context.processes.runningProcesses()
        let accessDenied = isFullDiskAccessMissing

        // Listing folders is quick, so the whole list appears before any size.
        var found: [JunkEntry] = []
        found += userCaches(processes: processes)
        found += browserCaches(processes: processes)
        found += logs()
        found += crashReports()
        found += mailDownloads(processes: processes)
        found += installers()
        found += deviceBackups()
        found += trash()
        for entry in found { emit(.entry(entry)) }

        var jobs: [@Sendable () async -> Void] = []
        for entry in found where entry.isSizing {
            jobs.append {
                guard let measured = self.measure(entry, accessDenied: accessDenied) else { return }
                emit(measured.isEmpty ? .dropped(id: entry.id) : .entry(measured))
            }
        }
        jobs.append {
            guard let entry = self.dsStores(), let measured = self.measure(entry, accessDenied: accessDenied), !measured.isEmpty else { return }
            emit(.entry(measured))
        }
        jobs.append {
            guard let entry = await self.systemCaches() else { return }
            emit(.entry(entry))
            guard let measured = self.measure(entry, accessDenied: false) else { return }
            emit(measured.isEmpty ? .dropped(id: entry.id) : .entry(measured))
        }

        await withTaskGroup(of: Void.self) { group in
            var iterator = jobs.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let job = iterator.next() else { break }
                group.addTask(priority: .utility) { await job() }
            }
            while await group.next() != nil {
                if Task.isCancelled { break }
                if let job = iterator.next() {
                    group.addTask(priority: .utility) { await job() }
                }
            }
        }
    }

    // MARK: Measuring

    /// Fills in sizes. Returns nil when the scan was cancelled.
    private func measure(_ original: JunkEntry, accessDenied: Bool) -> JunkEntry? {
        var entry = original
        var total = SizeResult()
        for index in entry.targets.indices {
            guard let size = try? engine.sizer.size(of: URL(fileURLWithPath: entry.targets[index].path)) else { return nil }
            entry.targets[index].bytes = size.bytes
            if entry.targets[index].lastModified == nil { entry.targets[index].lastModified = size.lastModified }
            total.merge(size)
        }
        entry.bytes = total.bytes
        entry.fileCount = total.files
        // Installers and backups already carry the date that matters.
        if entry.lastModified == nil { entry.lastModified = total.lastModified }
        entry.isSizing = false
        if total.bytes == 0, total.permissionDenied, accessDenied, entry.blockedReason == nil {
            entry.blockedReason = Self.fullDiskAccessReason
        }
        return entry
    }

    // MARK: Listing

    private enum Listing {
        case missing
        case denied
        case entries([DirectoryEntry])
    }

    /// The contents of a container, sorted by name. A container reached
    /// through a symbolic link counts as missing.
    private func list(_ directory: String) -> Listing {
        guard rules.isUsable(directory) else { return .missing }
        var entries: [DirectoryEntry] = []
        do {
            try DirectoryReader.read(directory) { entries.append($0) }
        } catch {
            return error.isPermissionDenied ? .denied : .missing
        }
        return .entries(entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private func isExcluded(_ path: String) -> Bool {
        engine.settings.isExcluded(path: path, context: engine.context)
    }

    /// A placeholder row for a location macOS will not let House Keeping read.
    private func accessPlaceholder(_ category: JunkCategory, name: String, path: String) -> JunkEntry {
        JunkEntry(
            id: "\(category.rawValue):access",
            category: category,
            name: name,
            targets: [JunkTarget(path: path)],
            blockedReason: Self.fullDiskAccessReason
        )
    }

    // MARK: Categories

    private func userCaches(processes: [RunningProcess]) -> [JunkEntry] {
        guard case .entries(let children) = list(rules.caches) else { return [] }
        let lookUp = !engine.context.isFixture
        var result: [JunkEntry] = []

        func add(_ path: String, folder: String, name: String) {
            guard rules.refusal(for: path, in: .userCaches) == nil, !isExcluded(path) else { return }
            var entry = JunkEntry(
                id: "userCaches:\(path)",
                category: .userCaches,
                name: name,
                detail: name == folder ? nil : folder,
                targets: [JunkTarget(path: path)],
                isSizing: true
            )
            entry.blockedReason = rules.runningReason(for: entry, processes: processes)
            result.append(entry)
        }

        for child in children where child.kind == .directory {
            let path = rules.caches + "/" + child.name
            if child.name == "Google" {
                // Shared by Chrome (a browser cache), Android Studio (Dev Caches) and other Google apps.
                guard case .entries(let inner) = list(path) else { continue }
                for item in inner where item.kind == .directory {
                    let name = item.name.hasPrefix("Google") ? item.name : "Google \(item.name)"
                    add(path + "/" + item.name, folder: item.name, name: name)
                }
            } else {
                add(path, folder: child.name, name: JunkNaming.displayName(forFolder: child.name, lookUpInstalledApps: lookUp))
            }
        }
        return result
    }

    private func browserCaches(processes: [RunningProcess]) -> [JunkEntry] {
        guard rules.isUsable(rules.caches) else { return [] }
        var result: [JunkEntry] = []
        for browser in JunkBrowser.all {
            var targets: [JunkTarget] = []
            for folder in browser.cacheFolders {
                let path = rules.caches + "/" + folder
                // A real folder, reached without links; never a link to a profile.
                guard SafetyGuard.realpath(path) == path, let print = Fingerprint(path: path), print.isDirectory,
                      !isExcluded(path) else { continue }
                targets.append(JunkTarget(path: path))
            }
            var containerDenied = false
            if browser.id == "safari" {
                switch list(rules.safariContainerCaches) {
                case .entries(let children):
                    for child in children where child.kind != .symlink {
                        let path = rules.safariContainerCaches + "/" + child.name
                        if !isExcluded(path) { targets.append(JunkTarget(path: path)) }
                    }
                case .denied: containerDenied = true
                case .missing: break
                }
            }
            if targets.isEmpty {
                if containerDenied {
                    var placeholder = accessPlaceholder(.browserCaches, name: browser.name, path: rules.safariContainerCaches)
                    placeholder.id = "browserCaches:\(browser.id)"
                    result.append(placeholder)
                }
                continue
            }
            var entry = JunkEntry(id: "browserCaches:\(browser.id)", category: .browserCaches, name: browser.name, targets: targets, isSizing: true)
            entry.blockedReason = rules.runningReason(for: entry, processes: processes)
            result.append(entry)
        }
        return result
    }

    private func logs() -> [JunkEntry] {
        guard case .entries(let children) = list(rules.logs) else { return [] }
        let lookUp = !engine.context.isFixture
        var result: [JunkEntry] = []
        for child in children where child.kind == .directory || child.kind == .file {
            if child.name.hasPrefix(".") { continue }
            let path = rules.logs + "/" + child.name
            // Never `~/Library/Logs/House Keeping` (the ledger) and not the crash reports listed on their own.
            guard rules.refusal(for: path, in: .logs) == nil, !isExcluded(path) else { continue }
            let name = child.kind == .directory ? JunkNaming.displayName(forFolder: child.name, lookUpInstalledApps: lookUp) : child.name
            result.append(JunkEntry(
                id: "logs:\(path)",
                category: .logs,
                name: name,
                detail: name == child.name ? nil : child.name,
                targets: [JunkTarget(path: path)],
                isSizing: true
            ))
        }
        return result
    }

    private func crashReports() -> [JunkEntry] {
        guard case .entries(let children) = list(rules.crashReports) else { return [] }
        let targets = children
            .filter { $0.kind != .symlink && !$0.name.hasPrefix(".") }
            .map { rules.crashReports + "/" + $0.name }
            .filter { !isExcluded($0) }
            .map { JunkTarget(path: $0) }
        guard !targets.isEmpty else { return [] }
        return [JunkEntry(id: "crashReports", category: .crashReports, name: "Crash reports", targets: targets, isSizing: true)]
    }

    private func mailDownloads(processes: [RunningProcess]) -> [JunkEntry] {
        switch list(rules.mailDownloads) {
        case .missing:
            return []
        case .denied:
            return [accessPlaceholder(.mailDownloads, name: "Mail downloads", path: rules.mailDownloads)]
        case .entries(let children):
            let targets = children
                .filter { $0.kind != .symlink && !$0.name.hasPrefix(".") }
                .map { rules.mailDownloads + "/" + $0.name }
                .filter { !isExcluded($0) }
                .map { JunkTarget(path: $0) }
            guard !targets.isEmpty else { return [] }
            var entry = JunkEntry(id: "mailDownloads", category: .mailDownloads, name: "Mail downloads", targets: targets, isSizing: true)
            entry.blockedReason = rules.runningReason(for: entry, processes: processes)
            return [entry]
        }
    }

    private func installers() -> [JunkEntry] {
        guard case .entries(let children) = list(rules.downloads) else { return [] }
        let cutoff = (options.now ?? Date()).addingTimeInterval(-Double(options.installerAgeDays) * 86_400)
        var result: [JunkEntry] = []
        for child in children {
            let ext = (child.name as NSString).pathExtension.lowercased()
            guard JunkRules.installerExtensions.contains(ext), !child.name.hasPrefix(".") else { continue }
            // Old-style packages are folders; everything else must be a plain file.
            let isPackageFolder = child.kind == .directory && (ext == "pkg" || ext == "mpkg")
            guard child.kind == .file || isPackageFolder else { continue }

            let path = rules.downloads + "/" + child.name
            guard rules.refusal(for: path, in: .installers) == nil, !isExcluded(path) else { continue }

            // The newer of "modified" and "added to Downloads": a download keeps
            // the date its author built it, which says nothing about its age here.
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey])
            let modified = values?.contentModificationDate ?? Date(timeIntervalSince1970: child.modified)
            let newest = max(modified, values?.addedToDirectoryDate ?? modified)
            guard newest < cutoff else { continue }

            // A zip is listed only when its contents are clearly an app installer.
            if ext == "zip", !ZipInspector.isAppInstaller(atPath: path) { continue }

            result.append(JunkEntry(
                id: "installers:\(path)",
                category: .installers,
                name: child.name,
                targets: [JunkTarget(path: path, lastModified: newest)],
                lastModified: newest,
                isSizing: true
            ))
        }
        return result
    }

    private func deviceBackups() -> [JunkEntry] {
        switch list(rules.backups) {
        case .missing:
            return []
        case .denied:
            return [accessPlaceholder(.deviceBackups, name: "iOS device backups", path: rules.backups)]
        case .entries(let children):
            var result: [JunkEntry] = []
            for child in children where child.kind == .directory && !child.name.hasPrefix(".") {
                let path = rules.backups + "/" + child.name
                guard !isExcluded(path) else { continue }
                let info = BackupInfo(backupPath: path)
                result.append(JunkEntry(
                    id: "deviceBackups:\(path)",
                    category: .deviceBackups,
                    name: info?.deviceName ?? "Backup \(child.name.prefix(8))",
                    detail: info?.summary,
                    targets: [JunkTarget(path: path)],
                    lastModified: info?.lastBackup,
                    isSizing: true
                ))
            }
            return result
        }
    }

    private func trash() -> [JunkEntry] {
        switch list(rules.trash) {
        case .missing:
            return []
        case .denied:
            return [accessPlaceholder(.trash, name: "Trash", path: rules.trash)]
        case .entries(let children):
            // Links are left alone: the remover never deletes one.
            let targets = children
                .filter { $0.kind != .symlink }
                .map { rules.trash + "/" + $0.name }
                .filter { !isExcluded($0) }
                .map { JunkTarget(path: $0) }
            guard !targets.isEmpty else { return [] }
            return [JunkEntry(id: "trash", category: .trash, name: "Trash", targets: targets, isSizing: true)]
        }
    }

    /// Hidden against a fixture home and when no admin runner is available.
    private func systemCaches() async -> JunkEntry? {
        let directory: String
        if let override = options.systemCachesDirectory {
            directory = override
        } else if engine.context.isFixture {
            return nil
        } else {
            directory = "/Library/Caches"
        }
        guard await privileged.availability != .unavailable, Fingerprint(path: directory)?.isDirectory == true else { return nil }
        return JunkEntry(id: "systemCaches", category: .systemCaches, name: "System caches", targets: [JunkTarget(path: directory)], isSizing: true)
    }

    // MARK: .DS_Store

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "logicx", "band", "xcarchive", "sparsebundle", "backupdb", "lproj", "xcodeproj", "xcworkspace",
    ]

    private static func skipsFolder(_ name: String, atHomeLevel: Bool) -> Bool {
        if name.hasPrefix(".") { return true }
        if atHomeLevel, name == "Library" { return true }
        if name == "node_modules" { return true }
        return packageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A bounded, breadth-first search of the home folder. Skips `Library`,
    /// hidden folders, `node_modules`, packages, other volumes and everything
    /// the safety guard protects (Documents, Desktop, Pictures and so on).
    private func dsStores() -> JunkEntry? {
        guard rules.isUsable(rules.home), let homePrint = Fingerprint(path: rules.home) else { return nil }
        let settings = engine.settings
        let context = engine.context
        var found: [String] = []
        var queue: [(path: String, depth: Int)] = [(rules.home, 0)]
        var next = 0

        search: while next < queue.count, next < options.dsStoreMaxFolders {
            if Task.isCancelled { return nil }
            let (directory, depth) = queue[next]
            next += 1

            var folders: [String] = []
            var hasStore = false
            _ = try? DirectoryReader.read(directory) { entry in
                switch entry.kind {
                case .file:
                    if entry.name == ".DS_Store" { hasStore = true }
                case .directory:
                    // Stay on the volume the home folder lives on.
                    if entry.device == homePrint.device, !Self.skipsFolder(entry.name, atHomeLevel: depth == 0) {
                        folders.append(entry.name)
                    }
                case .symlink, .other:
                    break
                }
            }

            if hasStore {
                let path = directory + "/.DS_Store"
                if engine.safety.denyReason(for: path, scope: .cache) == nil, !settings.isExcluded(path: path, context: context) {
                    found.append(path)
                    if found.count >= options.dsStoreMaxCount { break search }
                }
            }
            guard depth < options.dsStoreMaxDepth else { continue }
            for name in folders.sorted() {
                let child = directory + "/" + name
                if engine.safety.denyReason(for: child + "/.DS_Store", scope: .cache) != nil { continue }
                if settings.isExcluded(path: child, context: context) { continue }
                queue.append((child, depth + 1))
            }
        }

        guard !found.isEmpty else { return nil }
        return JunkEntry(
            id: "dsStore",
            category: .dsStore,
            name: ".DS_Store files",
            detail: found.count == 1 ? "1 file" : "\(found.count) files",
            targets: found.map { JunkTarget(path: $0) },
            isSizing: true
        )
    }
}

extension JunkEntry {
    /// Measured and nothing in it: not worth a row. Rows that explain a
    /// missing permission stay.
    var isEmpty: Bool { !isSizing && bytes == 0 && blockedReason != JunkScanner.fullDiskAccessReason }
}

/// What an iOS backup's `Info.plist` says about the device.
struct BackupInfo {
    var deviceName: String?
    var productName: String?
    var systemVersion: String?
    var lastBackup: Date?

    init?(backupPath: String) {
        let url = URL(fileURLWithPath: backupPath + "/Info.plist")
        // The file can carry app icons; anything huge is not worth reading for a name.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        deviceName = (plist["Device Name"] as? String) ?? (plist["Display Name"] as? String)
        productName = (plist["Product Name"] as? String) ?? (plist["Product Type"] as? String)
        systemVersion = plist["Product Version"] as? String
        lastBackup = plist["Last Backup Date"] as? Date
        if deviceName == nil, productName == nil, lastBackup == nil { return nil }
    }

    /// "iPhone 15 Pro · iOS 18.2"
    var summary: String? {
        var parts: [String] = []
        if let productName { parts.append(productName) }
        if let systemVersion {
            let system = (productName ?? "").contains("iPad") ? "iPadOS" : "iOS"
            parts.append("\(system) \(systemVersion)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
