import Foundation
import SweepKit
import SweepTestSupport
@testable import SweepOptimize

/// Records the admin tasks it is asked to run and answers from a script.
final class FakePrivileged: PrivilegedRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [PrivilegedTask] = []
    let mode: PrivilegedAvailability
    let answer: @Sendable (PrivilegedTask) -> PrivilegedResult

    init(_ mode: PrivilegedAvailability = .helper, answer: @escaping @Sendable (PrivilegedTask) -> PrivilegedResult = { _ in PrivilegedResult(succeeded: true) }) {
        self.mode = mode
        self.answer = answer
    }

    var log: [PrivilegedTask] { lock.withLock { calls } }

    var availability: PrivilegedAvailability { get async { mode } }

    func run(_ task: PrivilegedTask, argument: String?) async -> PrivilegedResult {
        lock.withLock { calls.append(task) }
        return answer(task)
    }
}

/// The same, with one authorisation for several tasks.
final class FakeBatchPrivileged: BatchPrivilegedRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var single: [PrivilegedTask] = []
    private var batched: [[PrivilegedTask]] = []
    let mode: PrivilegedAvailability

    init(_ mode: PrivilegedAvailability = .passwordPrompt) { self.mode = mode }

    var singles: [PrivilegedTask] { lock.withLock { single } }
    var batches: [[PrivilegedTask]] { lock.withLock { batched } }

    var availability: PrivilegedAvailability { get async { mode } }

    func run(_ task: PrivilegedTask, argument: String?) async -> PrivilegedResult {
        lock.withLock { single.append(task) }
        return PrivilegedResult(succeeded: true)
    }

    func run(batch tasks: [PrivilegedTask]) async -> [PrivilegedTask: PrivilegedResult] {
        lock.withLock { batched.append(tasks) }
        return Dictionary(uniqueKeysWithValues: tasks.map { ($0, PrivilegedResult(succeeded: true)) })
    }
}

/// Records fixed commands instead of running them.
final class RecordingExecutor: FixedCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let exitCode: Int32

    init(exitCode: Int32 = 0) { self.exitCode = exitCode }

    var log: [[String]] { lock.withLock { calls } }

    func execute(_ command: FixedCommand, extraArguments: [String], timeout: TimeInterval) -> CommandResult {
        lock.withLock { calls.append(command.argv + extraArguments) }
        return CommandResult(exitCode: exitCode)
    }
}

struct FakeRegistration: HelperRegistering {
    var current: HelperStatus
    func status() -> HelperStatus { current }
    func register() throws {}
    func unregister() async throws {}
}

final class FakeTransport: HelperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String?]] = []
    let version: String?
    let reply: HelperReply

    init(version: String? = HelperConstants.protocolVersion, reply: HelperReply = .result(PrivilegedResult(succeeded: true, message: "helper"))) {
        self.version = version
        self.reply = reply
    }

    var log: [[String?]] { lock.withLock { calls } }

    func run(taskName: String, argument: String?, timeout: TimeInterval) async -> HelperReply {
        lock.withLock { calls.append([taskName, argument]) }
        return reply
    }

    func protocolVersion(timeout: TimeInterval) async -> String? { version }
}

extension FixtureHome {
    /// A folder that stands in for `/` when testing the root side.
    var systemRoot: URL { root.appendingPathComponent("system") }

    func systemPath(_ relative: String) -> String { systemRoot.appendingPathComponent(relative).path }

    @discardableResult
    func writeSystem(_ relative: String, bytes: Int = 4096) throws -> String {
        let target = systemPath(relative)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: target))
        return target
    }

    func mkdirSystem(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: systemPath(relative), withIntermediateDirectories: true)
    }

    func systemExists(_ relative: String) -> Bool {
        Fingerprint(path: systemPath(relative)) != nil
    }

    /// Creates a minimal app bundle with the given identifier.
    @discardableResult
    func makeApp(_ relative: String, bundleID: String) throws -> String {
        let bundle = systemPath(relative)
        try FileManager.default.createDirectory(atPath: bundle + "/Contents/MacOS", withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": (relative as NSString).lastPathComponent]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
        try Data(repeating: 0x42, count: 16_384).write(to: URL(fileURLWithPath: bundle + "/Contents/MacOS/app"))
        return bundle
    }

    /// Writes a launchd property list into the fixture home.
    @discardableResult
    func writeAgent(_ name: String, _ contents: [String: Any]) throws -> String {
        let target = path("Library/LaunchAgents/\(name)")
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: target))
        return target
    }

    /// A file that starts with the SQLite header, so it counts as a database.
    @discardableResult
    func writeDatabase(_ relative: String, bytes: Int = 8192) throws -> String {
        let target = path(relative)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data("SQLite format 3\0".utf8)
        data.append(Data(repeating: 0, count: max(bytes - data.count, 0)))
        try data.write(to: URL(fileURLWithPath: target))
        return target
    }

    /// A context that is not marked as a fixture but can still only reach the
    /// fake runner and this temporary home. Used to exercise the paths that a
    /// fixture context switches off.
    func unmarkedContext(runner: any CommandRunning, processes: [String] = []) -> SweepContext {
        SweepContext(
            home: home, environment: [:], runner: runner, processes: StaticProcessList(names: processes),
            trash: FolderTrash(directory: home.appendingPathComponent(".Trash")), isFixture: false
        )
    }
}

let shellMetacharacters: Set<Character> = [";", "|", "&", "$", "`", "<", ">", "\"", "'", "\\", "\n", "(", ")"]
