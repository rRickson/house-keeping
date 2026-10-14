import Foundation
import SweepKit

/// A throwaway home folder in the temp directory.
public final class FixtureHome: @unchecked Sendable {
    public let root: URL
    public let home: URL

    public init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true)
        // Use the real path so expectations match what the guard resolves.
        root = URL(fileURLWithPath: SafetyGuard.realpath(base.path)!)
        home = root.appendingPathComponent("home")
        for folder in ["Documents", "Desktop", "Pictures", "Library/Caches", ".ssh"] {
            try mkdir(folder)
        }
        try write("Documents/thesis.txt")
        try write(".ssh/id_ed25519")
    }

    deinit {
        // Go-style read-only folders need their permissions back before removal.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in enumerator {
                chmod(root.path + "/" + path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    public func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }

    public func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    @discardableResult
    public func write(_ relative: String, bytes: Int = 4096) throws -> String {
        let target = path(relative)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: URL(fileURLWithPath: target))
        return target
    }

    public func symlink(_ relative: String, to destination: String) throws {
        let link = path(relative)
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: destination)
    }

    public func exists(_ relative: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path(relative))) != nil
    }

    /// Every regular file under the fixture, without following links.
    public func files() -> Set<String> {
        var result = Set<String>()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return result }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isRegularFile == true { result.insert(url.path) }
        }
        return result
    }

    public func engine(
        items: [CatalogItem],
        runner: any CommandRunning = NullCommandRunner(),
        processes: [String] = [],
        environment: [String: String] = [:],
        settings: SweepSettings = SweepSettings()
    ) -> SweepEngine {
        let context = SweepContext.fixture(home: home, runner: runner, processes: StaticProcessList(names: processes), environment: environment)
        return SweepEngine(context: context, catalog: Catalog(items: items), settings: settings)
    }
}

/// A scripted set of tools.
public final class FakeRunner: CommandRunning, @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> CommandResult
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var calls: [[String]] = []

    public init() {}

    public func on(_ tool: String, _ handler: @escaping Handler) {
        lock.lock()
        handlers[tool] = handler
        lock.unlock()
    }

    public var log: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }

    public func ran(_ command: [String]) -> Bool { log.contains(command) }

    public func locate(_ tool: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[tool] == nil ? nil : URL(fileURLWithPath: "/fake/bin/\(tool)")
    }

    public func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        let handler = lock.withLock { () -> Handler? in
            calls.append([tool] + arguments)
            return handlers[tool]
        }
        return handler?(arguments) ?? .notFound
    }
}

/// Runs the real git and nothing else.
public struct GitOnlyRunner: CommandRunning {
    public init() {}

    private let real = SystemCommandRunner(locator: ToolLocator(home: URL(fileURLWithPath: NSHomeDirectory()), queryLoginShell: false))

    public func locate(_ tool: String) -> URL? { tool == "git" ? real.locate(tool) : nil }

    public func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        guard tool == "git" else { return .notFound }
        return await real.run(tool, arguments, timeout: timeout)
    }

    @discardableResult
    public func git(_ arguments: String..., in directory: String) async -> CommandResult {
        await run("git", ["-C", directory, "-c", "user.name=House Keeping Tests", "-c", "user.email=tests@example.com",
                          "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments, timeout: 30)
    }
}

extension CatalogItem {
    public static func rule(
        _ id: String,
        paths: [String],
        clean: CleanStrategy = .delete,
        risk: RiskTier = .safe,
        guards: ItemGuards? = nil
    ) -> CatalogItem {
        CatalogItem(id: id, name: id, group: .other, risk: risk, locate: [LocateStep(paths: paths)], clean: clean, guards: guards)
    }
}

/// Deterministic random numbers so a failing property test can be replayed.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
