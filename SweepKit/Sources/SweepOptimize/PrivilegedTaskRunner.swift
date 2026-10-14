import Darwin
import Foundation
import SweepKit

/// Runs one fixed command. The helper's real one uses `Process`; tests record instead.
public protocol FixedCommandExecuting: Sendable {
    func execute(_ command: FixedCommand, extraArguments: [String], timeout: TimeInterval) -> CommandResult
}

/// Launches the executable directly with an argument array and a bare
/// environment. No shell is involved at any point.
public struct ProcessCommandExecutor: FixedCommandExecuting {
    public init() {}

    public func execute(_ command: FixedCommand, extraArguments: [String], timeout: TimeInterval) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: command.executable) else { return .notFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments + extraArguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: 126, stderr: error.localizedDescription, launched: false)
        }

        let output = Locked(Data())
        let errors = Locked(Data())
        let readers = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        DispatchQueue.global().async(group: readers) { output.set(outHandle.readDataToEndOfFile()) }
        DispatchQueue.global().async(group: readers) { errors.set(errHandle.readDataToEndOfFile()) }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        _ = readers.wait(timeout: .now() + 3)
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: output.get(), as: UTF8.self),
            stderr: String(decoding: errors.get(), as: UTF8.self),
            timedOut: timedOut,
            launched: true
        )
    }
}

/// What `removeApplication` will delete for one bundle identifier. Every path
/// in it was found by the runner; none came from the caller.
public struct ApplicationRemovalPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let path: String
        let fingerprint: Fingerprint
        /// A launch daemon's label, when the item is its property list.
        let daemonLabel: String?
    }

    public let bundleIdentifier: BundleIdentifier
    public let application: Item
    public let leftovers: [Item]

    public var items: [Item] { [application] + leftovers }
    public var paths: [String] { items.map(\.path) }
}

/// Why a removal was refused.
public struct RemovalRefusal: Error, Sendable, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// The root side of the helper: turns a task name into fixed work.
///
/// This is the whole of what House Keeping can do as root. A task is one of
/// `PrivilegedTask`'s names; the only argument any task takes is a bundle
/// identifier, which is validated and then used to *look for* files, never as
/// a path. `root` is `/` in the helper and a temporary folder in tests.
public struct PrivilegedTaskRunner: Sendable {
    public let root: String
    private let executor: any FixedCommandExecuting
    private let isInUse: @Sendable (String) -> Bool
    private let isRunning: @Sendable (String) -> Bool
    private let commandTimeout: TimeInterval

    public init(
        root: URL = URL(fileURLWithPath: "/"),
        executor: any FixedCommandExecuting = ProcessCommandExecutor(),
        commandTimeout: TimeInterval = 120,
        isInUse: @escaping @Sendable (String) -> Bool = { OpenFiles.isInUse($0) },
        isRunning: @escaping @Sendable (String) -> Bool = { OpenFiles.hasProcess(inside: $0) }
    ) {
        self.root = Self.normalizedRoot(root)
        self.executor = executor
        self.commandTimeout = commandTimeout
        self.isInUse = isInUse
        self.isRunning = isRunning
    }

    func systemPath(_ path: String) -> String { root + path }

    /// The prefix to put in front of `/Library/…`: empty for `/`, otherwise the folder's real path.
    static func normalizedRoot(_ root: URL) -> String {
        let path = SafetyGuard.realpath(root.path) ?? root.path
        return path == "/" ? "" : (path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    // MARK: Entry points

    /// The entry point for requests that arrive as text. An unknown name is rejected.
    public func run(taskName: String, argument: String?) -> PrivilegedResult {
        guard let task = PrivilegedTask(rawValue: taskName) else {
            return PrivilegedResult(succeeded: false, message: "Unknown task")
        }
        return run(task, argument: argument)
    }

    public func run(_ task: PrivilegedTask, argument: String?) -> PrivilegedResult {
        let argument = argument.flatMap { $0.isEmpty ? nil : $0 }
        if !PrivilegedCommandTable.takesArgument(task), argument != nil {
            return PrivilegedResult(succeeded: false, message: "This task takes no argument")
        }
        switch task {
        case .flushDNS, .reindexSpotlight, .rebuildFontCaches, .rebuildLaunchServices, .clearARPCache:
            return runCommands(for: task)
        case .cleanSystemCaches:
            return cleanSystemCaches()
        case .removeApplication:
            guard let argument else { return PrivilegedResult(succeeded: false, message: "A bundle identifier is required") }
            return removeApplication(bundleIdentifier: argument)
        }
    }

    private func runCommands(for task: PrivilegedTask) -> PrivilegedResult {
        for command in PrivilegedCommandTable.commands(for: task) {
            let result = executor.execute(command, extraArguments: [], timeout: commandTimeout)
            if !result.succeeded, !command.allowFailure {
                return PrivilegedResult(succeeded: false, message: result.failureReason)
            }
        }
        return PrivilegedResult(succeeded: true)
    }

    // MARK: System caches

    /// Removes what is inside `/Library/Caches`, never the folder itself.
    ///
    /// Links are left where they are and never followed. Entries protected by
    /// System Integrity Protection and entries a process has open are skipped.
    /// Apple's own folders are emptied but kept, because the daemons that own
    /// them cannot always create them again.
    public func cleanSystemCaches() -> PrivilegedResult {
        let caches = systemPath("/Library/Caches")
        let descriptor = open(caches, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return PrivilegedResult(succeeded: false, message: "\(caches) could not be opened")
        }
        defer { close(descriptor) }
        var folder = stat()
        guard fstat(descriptor, &folder) == 0 else {
            return PrivilegedResult(succeeded: false, message: "\(caches) could not be read")
        }

        var tally = SecureRemover.Tally()
        var cleaned = 0
        var skipped = 0
        for name in SecureRemover.entries(of: descriptor) {
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            let text = String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let isApple = text.lowercased().hasPrefix("com.apple.")
            if kind == S_IFLNK || info.st_dev != folder.st_dev || SecureRemover.isRestricted(info) || isInUse(caches + "/" + text) {
                skipped += 1
                continue
            }
            let before = tally
            SecureRemover.remove(name, in: descriptor, keepDirectory: isApple && kind == S_IFDIR, device: folder.st_dev, tally: &tally)
            if tally.removed > before.removed {
                cleaned += 1
            } else if tally.failed > before.failed {
                skipped += 1
            }
        }
        var message = "Cleaned \(cleaned) \(cleaned == 1 ? "entry" : "entries")"
        if skipped > 0 { message += ", left \(skipped) that \(skipped == 1 ? "is" : "are") protected or in use" }
        return PrivilegedResult(succeeded: true, message: message, bytesFreed: tally.bytes)
    }

    // MARK: Application removal

    /// Finds the app with this bundle identifier in `/Applications` and the
    /// system-level files named after it. Nothing is deleted here.
    public func removalPlan(for identifier: BundleIdentifier) -> Result<ApplicationRemovalPlan, RemovalRefusal> {
        let applications = systemPath("/Applications")
        var matches: [(path: String, fingerprint: Fingerprint)] = []
        for bundle in Self.applicationBundles(in: applications) {
            guard Self.bundleIdentifier(ofApp: bundle) == identifier.value, let fingerprint = Fingerprint(path: bundle) else { continue }
            matches.append((bundle, fingerprint))
        }
        guard let match = matches.first else { return .failure(RemovalRefusal("No app with that identifier is installed in Applications")) }
        guard matches.count == 1 else { return .failure(RemovalRefusal("More than one app has that identifier")) }

        var info = stat()
        guard lstat(match.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(RemovalRefusal("The app is not a regular bundle"))
        }
        if SecureRemover.isRestricted(info) { return .failure(RemovalRefusal("The app is protected by macOS")) }
        if isRunning(match.path) { return .failure(RemovalRefusal("The app is running")) }

        var leftovers: [ApplicationRemovalPlan.Item] = []
        for (folder, suffix, isDaemon) in [
            ("/Library/LaunchDaemons", ".plist", true),
            ("/Library/LaunchAgents", ".plist", false),
            ("/Library/PrivilegedHelperTools", "", false),
        ] {
            let directory = systemPath(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names.sorted() where name.hasSuffix(suffix) {
                let stem = String(name.dropLast(suffix.count))
                guard identifier.owns(stem) else { continue }
                let path = directory + "/" + name
                guard let fingerprint = Fingerprint(path: path), !fingerprint.isSymlink else { continue }
                // Property lists are files; a folder with that name is something else.
                if !suffix.isEmpty, fingerprint.isDirectory { continue }
                leftovers.append(.init(path: path, fingerprint: fingerprint, daemonLabel: isDaemon ? stem : nil))
            }
        }
        return .success(ApplicationRemovalPlan(
            bundleIdentifier: identifier,
            application: .init(path: match.path, fingerprint: match.fingerprint, daemonLabel: nil),
            leftovers: leftovers
        ))
    }

    public func removeApplication(bundleIdentifier raw: String) -> PrivilegedResult {
        guard let identifier = BundleIdentifier(raw) else {
            return PrivilegedResult(succeeded: false, message: "Not a valid bundle identifier")
        }
        let plan: ApplicationRemovalPlan
        switch removalPlan(for: identifier) {
        case .success(let found): plan = found
        case .failure(let refusal): return PrivilegedResult(succeeded: false, message: refusal.reason)
        }

        var tally = SecureRemover.Tally()
        let appGone = Self.remove(plan.application, tally: &tally)
        guard appGone else {
            return PrivilegedResult(succeeded: false, message: "The app could not be removed completely", bytesFreed: tally.bytes)
        }
        var left = 0
        for item in plan.leftovers {
            if let label = item.daemonLabel, BrokenLaunchAgents.isPlainLabel(label) {
                // Stop the daemon before its files go. It may not be loaded; that is fine.
                _ = executor.execute(FixedCommand(SystemTool.launchctl, ["bootout"], allowFailure: true),
                                     extraArguments: ["system/\(label)"], timeout: 15)
            }
            if !Self.remove(item, tally: &tally) { left += 1 }
        }
        var message = "Removed \((plan.application.path as NSString).lastPathComponent)"
        let removedLeftovers = plan.leftovers.count - left
        if removedLeftovers > 0 { message += " and \(removedLeftovers) system file\(removedLeftovers == 1 ? "" : "s")" }
        if left > 0 { message += "; \(left) could not be removed" }
        return PrivilegedResult(succeeded: true, message: message, bytesFreed: tally.bytes)
    }

    private static func remove(_ item: ApplicationRemovalPlan.Item, tally: inout SecureRemover.Tally) -> Bool {
        let directory = (item.path as NSString).deletingLastPathComponent
        let name = (item.path as NSString).lastPathComponent
        return SecureRemover.remove(name: name, inDirectory: directory, expected: item.fingerprint, tally: &tally)
    }

    /// App bundles directly in `folder` and one level down (vendor folders, Utilities). Links are not followed.
    static func applicationBundles(in folder: String) -> [String] {
        func isRealDirectory(_ path: String) -> Bool {
            guard let fingerprint = Fingerprint(path: path) else { return false }
            return fingerprint.isDirectory && !fingerprint.isSymlink
        }
        var bundles: [String] = []
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() {
            let path = folder + "/" + name
            guard isRealDirectory(path) else { continue }
            if name.hasSuffix(".app") {
                bundles.append(path)
                continue
            }
            for inner in ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted() where inner.hasSuffix(".app") {
                let innerPath = path + "/" + inner
                if isRealDirectory(innerPath) { bundles.append(innerPath) }
            }
        }
        return bundles
    }

    /// Reads `CFBundleIdentifier` from the bundle's own Info.plist.
    static func bundleIdentifier(ofApp bundle: String) -> String? {
        let plist = bundle + "/Contents/Info.plist"
        guard let fingerprint = Fingerprint(path: plist), !fingerprint.isSymlink, !fingerprint.isDirectory,
              let size = (try? FileManager.default.attributesOfItem(atPath: plist)[.size] as? NSNumber)?.intValue, size <= 8_388_608,
              let data = FileManager.default.contents(atPath: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return values["CFBundleIdentifier"] as? String
    }
}
