import Foundation
import SweepKit
import SweepTestSupport
@testable import SweepUninstall

extension FixtureHome {
    /// Writes a fake `.app` bundle with an Info.plist and a small executable.
    @discardableResult
    func app(
        _ name: String,
        bundleID: String?,
        version: String = "1.0",
        in folder: String = "Applications",
        info extra: [String: Any] = [:]
    ) throws -> String {
        let bundle = "\(folder)/\(name).app"
        var info: [String: Any] = ["CFBundleName": name, "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        info.merge(extra) { _, new in new }
        try mkdir(bundle + "/Contents/MacOS")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path(bundle + "/Contents/Info.plist")))
        try write(bundle + "/Contents/MacOS/\(name)", bytes: 64 * 1024)
        return path(bundle)
    }

    /// Names of what is in the fixture Trash, without the unique prefix `FolderTrash` adds.
    func trashed() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path(".Trash"))) ?? []
        return names.map { String($0.dropFirst(9)) }.sorted()
    }

    /// Every file except House Keeping's own operations log, which records skipped and failed runs too.
    func userFiles() -> Set<String> {
        files().filter { !$0.hasPrefix(path("Library/Logs/House Keeping/")) }
    }

    func uninstaller(
        runner: any CommandRunning = NullCommandRunner(),
        processes: [String] = [],
        privileged: any PrivilegedRunning = NoPrivilegedRunner(),
        configure: (inout UninstallEnvironment) -> Void = { _ in }
    ) -> AppUninstaller {
        let engine = engine(items: [], runner: runner, processes: processes)
        var environment = UninstallEnvironment.fixture(home: home)
        configure(&environment)
        return AppUninstaller(engine: engine, privileged: privileged, environment: environment)
    }
}

extension AppUninstaller {
    func app(named name: String) async -> InstalledApp? {
        await installedApps().first { $0.name == name }
    }
}

final class FakeDock: DockEditing, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var removed: [String] { lock.withLock { paths } }
    func removeEntry(for app: InstalledApp) async -> Bool {
        lock.withLock { paths.append(app.path) }
        return true
    }
}

final class FakeTerminator: AppTerminating, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    let quits: Bool
    init(quits: Bool) { self.quits = quits }
    var asked: [String] { lock.withLock { names } }
    func terminate(_ app: InstalledApp) async -> Bool {
        lock.withLock { names.append(app.name) }
        return quits
    }
}

final class FakePrivileged: PrivilegedRunning, @unchecked Sendable {
    struct Call: Equatable {
        var task: PrivilegedTask
        var argument: String?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    let result: PrivilegedResult
    init(result: PrivilegedResult = PrivilegedResult(succeeded: true, message: "removed", bytesFreed: 4242)) { self.result = result }
    var calls: [Call] { lock.withLock { recorded } }
    var availability: PrivilegedAvailability { get async { .helper } }
    func run(_ task: PrivilegedTask, argument: String?) async -> PrivilegedResult {
        lock.withLock { recorded.append(Call(task: task, argument: argument)) }
        return result
    }
}

struct FixedLastUsed: LastUsedProviding {
    var dates: [String: Date]
    func lastUsedDate(ofAppAt path: String) -> Date? { dates[path] }
}
