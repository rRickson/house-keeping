import Foundation

/// Moves items to the Trash.
public protocol Trashing: Sendable {
    func trash(_ url: URL) throws
}

public struct SystemTrash: Trashing {
    public init() {}
    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// A Trash that is just a folder. Used for fixture homes and tests.
public struct FolderTrash: Trashing {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func trash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
    }
}

/// Everything the engine knows about the machine it runs on. Front ends build
/// one with `live()`; tests build one that points at a temporary home.
public struct SweepContext: Sendable {
    public var home: URL
    public var environment: [String: String]
    public var runner: any CommandRunning
    public var processes: any ProcessListing
    public var trash: any Trashing
    /// `~/Library/Application Support/Sweep`
    public var supportDirectory: URL
    /// `~/Library/Logs/Sweep`
    public var logDirectory: URL
    /// True when the context points at a fixture home instead of the real one.
    public var isFixture: Bool

    public init(
        home: URL,
        environment: [String: String],
        runner: any CommandRunning,
        processes: any ProcessListing,
        trash: any Trashing,
        supportDirectory: URL? = nil,
        logDirectory: URL? = nil,
        isFixture: Bool = false
    ) {
        self.home = home.standardizedFileURL
        self.environment = environment
        self.runner = runner
        self.processes = processes
        self.trash = trash
        self.supportDirectory = supportDirectory ?? home.appendingPathComponent("Library/Application Support/Sweep")
        self.logDirectory = logDirectory ?? home.appendingPathComponent("Library/Logs/Sweep")
        self.isFixture = isFixture
    }

    /// The context for the real machine. Setting `SWEEP_HOME` switches to a
    /// fixture home with no tools, which is how Sweep is exercised safely.
    public static func live() -> SweepContext {
        let environment = ProcessInfo.processInfo.environment
        if let fixture = environment["SWEEP_HOME"], !fixture.isEmpty {
            return .fixture(home: URL(fileURLWithPath: fixture))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locator = ToolLocator(home: home, environment: environment)
        return SweepContext(
            home: home,
            environment: environment,
            runner: SystemCommandRunner(locator: locator, environment: environment),
            processes: SystemProcessList(),
            trash: SystemTrash()
        )
    }

    /// A context rooted at `home` that runs no tools and sees no processes.
    public static func fixture(
        home: URL,
        runner: any CommandRunning = NullCommandRunner(),
        processes: any ProcessListing = StaticProcessList(),
        environment: [String: String] = [:]
    ) -> SweepContext {
        SweepContext(
            home: home,
            environment: environment,
            runner: runner,
            processes: processes,
            trash: FolderTrash(directory: home.appendingPathComponent(".Trash")),
            isFixture: true
        )
    }

    /// Expands a leading `~` against this context's home.
    public func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
        return path
    }

    /// Shortens a path under home to `~/…` for display.
    public func abbreviate(_ path: String) -> String {
        for h in Set([home.path, SafetyGuard.realpath(home.path) ?? home.path]) {
            if path == h { return "~" }
            if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        }
        return path
    }
}
