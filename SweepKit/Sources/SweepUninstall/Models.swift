import Foundation
import SweepKit

/// The maker of a security product, and where its removal instructions live.
public struct SecurityVendor: Sendable, Hashable {
    public var name: String
    public var supportURL: URL

    public init(name: String, supportURL: URL) {
        self.name = name
        self.supportURL = supportURL
    }
}

public enum Removability: Sendable, Hashable {
    case removable
    /// Security and antivirus software installs system extensions and kernel
    /// hooks that only its own uninstaller removes cleanly. Sweep never touches it.
    case vendorUninstaller(SecurityVendor)

    public var isRemovable: Bool { self == .removable }
}

/// One app found in an applications folder.
public struct InstalledApp: Identifiable, Sendable, Hashable {
    public var id: String { path }
    /// The bundle, as a real path.
    public var path: String
    public var name: String
    public var bundleID: String?
    public var version: String?
    /// The `.icns` file named by the bundle, when there is one.
    public var iconPath: String?
    /// Spotlight's `kMDItemLastUsedDate`; nil when unknown.
    public var lastOpened: Date?
    public var isRunning: Bool
    public var removability: Removability
    /// The Homebrew cask that installed the app, if any.
    public var caskToken: String?
    /// True when the bundle belongs to another user (usually root).
    public var needsAdmin: Bool
    public var fingerprint: Fingerprint?
    /// Every name the bundle goes by: file name, `CFBundleName`, `CFBundleDisplayName`.
    public var names: [String]

    public init(
        path: String,
        name: String,
        bundleID: String? = nil,
        version: String? = nil,
        iconPath: String? = nil,
        lastOpened: Date? = nil,
        isRunning: Bool = false,
        removability: Removability = .removable,
        caskToken: String? = nil,
        needsAdmin: Bool = false,
        fingerprint: Fingerprint? = nil,
        names: [String]? = nil
    ) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.iconPath = iconPath
        self.lastOpened = lastOpened
        self.isRunning = isRunning
        self.removability = removability
        self.caskToken = caskToken
        self.needsAdmin = needsAdmin
        self.fingerprint = fingerprint
        self.names = names ?? [name]
    }
}

/// The places Sweep looks for what an app leaves behind. Only direct children
/// of these folders are ever proposed, never the folders themselves.
public enum LeftoverLocation: String, Sendable, CaseIterable, Hashable, Codable {
    case applicationSupport, caches, preferences, preferencesByHost, logs
    case containers, groupContainers, httpStorages, webKit, savedState, launchAgents
    case systemLaunchAgents, systemLaunchDaemons, privilegedHelperTools

    /// Path below a `Library` folder.
    public var relativePath: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .preferencesByHost: "Preferences/ByHost"
        case .logs: "Logs"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .httpStorages: "HTTPStorages"
        case .webKit: "WebKit"
        case .savedState: "Saved Application State"
        case .launchAgents, .systemLaunchAgents: "LaunchAgents"
        case .systemLaunchDaemons: "LaunchDaemons"
        case .privilegedHelperTools: "PrivilegedHelperTools"
        }
    }

    public var title: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .preferences, .preferencesByHost: "Preferences"
        case .logs: "Logs"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .httpStorages: "Web Storage"
        case .webKit: "WebKit"
        case .savedState: "Saved State"
        case .launchAgents: "Launch Agents"
        case .systemLaunchAgents: "System Launch Agents"
        case .systemLaunchDaemons: "Launch Daemons"
        case .privilegedHelperTools: "Privileged Helpers"
        }
    }

    /// True for `/Library`, false for `~/Library`.
    public var isSystem: Bool {
        switch self {
        case .systemLaunchAgents, .systemLaunchDaemons, .privilegedHelperTools: true
        default: false
        }
    }

    /// An exact app-name match counts only where apps keep a folder under their own name.
    var allowsNameMatch: Bool {
        switch self {
        case .applicationSupport, .caches, .logs: true
        default: false
        }
    }

    /// Places Sweep reads when it looks for orphans. Launch agents are left to
    /// Optimize, which checks whether the program they start still exists.
    static var orphanLocations: [LeftoverLocation] {
        allCases.filter { !$0.isSystem && $0 != .launchAgents }
    }
}

/// One path in an uninstall preview.
public struct UninstallItem: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case appBundle
        case leftover
    }

    /// Why Sweep believes the path belongs to the app.
    public enum Evidence: Sendable, Hashable {
        case bundle
        /// The name is the bundle identifier, or starts with it and a dot.
        case bundleID
        /// The name is exactly the app's name.
        case appName
        /// A package receipt lists the file.
        case receipt(package: String)
        /// The Homebrew cask names it in its zap stanza.
        case caskZap(token: String)
    }

    /// Who removes the path.
    public enum Route: Sendable, Hashable {
        /// Sweep's guarded remover.
        case sweep
        /// `brew uninstall --zap`; follows the app bundle and cannot be unticked on its own.
        case homebrew
    }

    public var id: String { path }
    public var path: String
    public var kind: Kind
    public var location: LeftoverLocation?
    public var evidence: Evidence
    public var route: Route
    /// Nil until measured.
    public var bytes: Int64?
    public var fingerprint: Fingerprint?
    /// Owned by another user; goes through the admin helper.
    public var needsAdmin: Bool
    /// Set when the safety model will not remove the path (a symbolic link, a protected place).
    public var blockedReason: String?
    public var isSelectedByDefault: Bool

    public init(
        path: String,
        kind: Kind,
        location: LeftoverLocation? = nil,
        evidence: Evidence,
        route: Route = .sweep,
        bytes: Int64? = nil,
        fingerprint: Fingerprint? = nil,
        needsAdmin: Bool = false,
        blockedReason: String? = nil,
        isSelectedByDefault: Bool = true
    ) {
        self.path = path
        self.kind = kind
        self.location = location
        self.evidence = evidence
        self.route = route
        self.bytes = bytes
        self.fingerprint = fingerprint
        self.needsAdmin = needsAdmin
        self.blockedReason = blockedReason
        self.isSelectedByDefault = isSelectedByDefault
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Everything an uninstall would remove, for review before anything happens.
public struct UninstallPlan: Sendable, Hashable {
    public var app: InstalledApp
    /// The app bundle first, then leftovers.
    public var items: [UninstallItem]
    /// Package receipts that list the app.
    public var packageIDs: [String]
    /// Things worth telling the user that are not paths.
    public var notes: [String]
    /// False when the cask's zap stanza names a place Sweep protects; Homebrew then removes the app only.
    public var usesZap = true

    public init(app: InstalledApp, items: [UninstallItem], packageIDs: [String] = [], notes: [String] = []) {
        self.app = app
        self.items = items
        self.packageIDs = packageIDs
        self.notes = notes
    }

    public var caskToken: String? { app.caskToken }

    /// The command Homebrew runs for a cask-installed app.
    public var command: [String]? {
        caskToken.map { usesZap ? ["brew", "uninstall", "--zap", "--cask", $0] : ["brew", "uninstall", "--cask", $0] }
    }

    public var bundle: UninstallItem? { items.first { $0.kind == .appBundle } }

    public var defaultSelection: Set<String> {
        Set(items.filter(\.isSelectedByDefault).map(\.id))
    }

    /// The items a selection really removes. Paths Homebrew handles follow the
    /// app bundle; blocked paths never count.
    public func effectiveItems(selecting selection: Set<String>? = nil) -> [UninstallItem] {
        let selection = selection ?? defaultSelection
        let bundleSelected = bundle.map { selection.contains($0.id) } ?? false
        return items.filter { item in
            if item.route == .homebrew, item.kind != .appBundle { return bundleSelected }
            return selection.contains(item.id)
        }
    }

    /// Measured bytes of a selection.
    public func bytes(selecting selection: Set<String>? = nil) -> Int64 {
        effectiveItems(selecting: selection).filter { $0.blockedReason == nil }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }
}

/// What an uninstall did.
public struct UninstallReport: Sendable {
    public var app: InstalledApp
    public var operation: SweepOperation
    /// Set when the uninstall stopped early, such as an app that would not quit.
    public var stoppedReason: String?
    /// The app was running and quit when asked.
    public var didQuitApp = false
    public var dockEntryRemoved = false
    /// The admin helper's answer, when it was called.
    public var privilegedResult: PrivilegedResult?

    public init(app: InstalledApp, operation: SweepOperation) {
        self.app = app
        self.operation = operation
    }

    public var dryRun: Bool { operation.dryRun }

    /// Bytes freed, or the bytes a dry run would free.
    public var bytes: Int64 { operation.dryRun ? operation.bytesPlanned : operation.bytesFreed }

    public var removedPaths: [String] {
        operation.entries.filter { $0.result == .removed && $0.mode != "command" && $0.mode != "helper" }.map(\.target)
    }
}

/// A leftover whose bundle identifier matches no installed app.
public struct Orphan: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    /// The bundle identifier read from the name.
    public var bundleID: String
    public var location: LeftoverLocation
    public var bytes: Int64?
    public var lastModified: Date?
    public var fingerprint: Fingerprint?

    public init(
        path: String,
        bundleID: String,
        location: LeftoverLocation,
        bytes: Int64? = nil,
        lastModified: Date? = nil,
        fingerprint: Fingerprint? = nil
    ) {
        self.path = path
        self.bundleID = bundleID
        self.location = location
        self.bytes = bytes
        self.lastModified = lastModified
        self.fingerprint = fingerprint
    }

    public var name: String { (path as NSString).lastPathComponent }
}
