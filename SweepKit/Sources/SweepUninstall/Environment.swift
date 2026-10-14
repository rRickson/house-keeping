import Darwin
import Foundation
import SweepKit

/// Removes an app's tile from the Dock.
public protocol DockEditing: Sendable {
    /// Returns true when a tile was removed.
    func removeEntry(for app: InstalledApp) async -> Bool
}

/// Leaves the Dock alone. Used for fixture homes and tests.
public struct NoDockEditor: DockEditing {
    public init() {}
    public func removeEntry(for app: InstalledApp) async -> Bool { false }
}

/// Asks a running app to quit. Implementations never force-quit.
public protocol AppTerminating: Sendable {
    /// Returns true once the app is no longer running.
    func terminate(_ app: InstalledApp) async -> Bool
}

/// Quits nothing, so a running app is always left alone. Used for fixture homes.
public struct NoAppTerminator: AppTerminating {
    public init() {}
    public func terminate(_ app: InstalledApp) async -> Bool { false }
}

/// Reads when an app was last opened.
public protocol LastUsedProviding: Sendable {
    func lastUsedDate(ofAppAt path: String) -> Date?
}

public struct NoLastUsedDates: LastUsedProviding {
    public init() {}
    public func lastUsedDate(ofAppAt path: String) -> Date? { nil }
}

/// Everything the Uninstall tool knows about the machine beyond `SweepContext`.
/// Every part can be replaced, which is how tests keep away from the real one.
public struct UninstallEnvironment: Sendable {
    /// Folders that hold apps.
    public var applicationFolders: [String]
    /// `/Library`; nil skips the system-level leftover locations.
    public var systemLibrary: String?
    /// Homebrew's Caskroom folders.
    public var caskrooms: [String]
    public var dock: any DockEditing
    public var terminator: any AppTerminating
    public var lastUsed: any LastUsedProviding
    /// True when a path cannot be removed as the current user.
    public var requiresAdmin: @Sendable (String) -> Bool
    /// Where apps with this bundle identifier are installed, anywhere on the
    /// Mac and not just in the applications folders (Launch Services). Keeps
    /// leftovers of apps that live elsewhere from being claimed or called orphans.
    public var registeredAppPaths: @Sendable (String) -> [String]
    /// Sweep's own bundle identifiers; hidden from the list and never an orphan.
    public var ownBundleIDs: Set<String>
    /// A leftover changed more recently than this is still in use by something
    /// and is never called an orphan.
    public var orphanMinimumAge: TimeInterval

    public init(
        applicationFolders: [String],
        systemLibrary: String? = nil,
        caskrooms: [String] = [],
        dock: any DockEditing = NoDockEditor(),
        terminator: any AppTerminating = NoAppTerminator(),
        lastUsed: any LastUsedProviding = NoLastUsedDates(),
        requiresAdmin: @escaping @Sendable (String) -> Bool = { _ in false },
        registeredAppPaths: @escaping @Sendable (String) -> [String] = { _ in [] },
        ownBundleIDs: Set<String> = UninstallEnvironment.sweepBundleIDs,
        orphanMinimumAge: TimeInterval = 30 * 24 * 3600
    ) {
        self.applicationFolders = applicationFolders
        self.systemLibrary = systemLibrary
        self.caskrooms = caskrooms
        self.dock = dock
        self.terminator = terminator
        self.lastUsed = lastUsed
        self.requiresAdmin = requiresAdmin
        self.registeredAppPaths = registeredAppPaths
        self.ownBundleIDs = ownBundleIDs
        self.orphanMinimumAge = orphanMinimumAge
    }

    public static let sweepBundleIDs: Set<String> = ["com.rickson.sweep", "com.rickson.sweep.helper"]

    /// The environment for a context: the real machine, or, for a fixture home,
    /// only `<home>/Applications` with no Dock, no quitting and no system folders.
    public static func standard(for context: SweepContext) -> UninstallEnvironment {
        context.isFixture ? fixture(home: context.home) : live(context: context)
    }

    public static func fixture(home: URL) -> UninstallEnvironment {
        let real = SafetyGuard.realpath(home.path) ?? home.path
        return UninstallEnvironment(applicationFolders: [real + "/Applications"])
    }

    public static func live(context: SweepContext) -> UninstallEnvironment {
        var own = sweepBundleIDs
        if let main = Bundle.main.bundleIdentifier { own.insert(main) }
        let home = SafetyGuard.realpath(context.home.path) ?? context.home.path
        return UninstallEnvironment(
            applicationFolders: ["/Applications", home + "/Applications"],
            systemLibrary: "/Library",
            caskrooms: ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"],
            dock: SystemDockEditor(runner: context.runner),
            terminator: WorkspaceAppTerminator(processes: context.processes),
            lastUsed: SpotlightLastUsedDates(),
            requiresAdmin: { path in
                var info = stat()
                guard lstat(path, &info) == 0 else { return false }
                return info.st_uid != getuid()
            },
            registeredAppPaths: { LaunchServices.applicationPaths(bundleID: $0) },
            ownBundleIDs: own
        )
    }

    /// The folder a leftover location lives in, or nil when it is not looked at.
    func directory(for location: LeftoverLocation, home: URL) -> String? {
        if location.isSystem {
            guard let systemLibrary else { return nil }
            return systemLibrary + "/" + location.relativePath
        }
        return home.path + "/Library/" + location.relativePath
    }
}
