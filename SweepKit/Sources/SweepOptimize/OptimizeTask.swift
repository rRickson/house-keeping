import Foundation
import SweepKit

/// Absolute locations of the system tools Optimize runs. Nothing is looked up
/// on `PATH`, so a tool of the same name installed elsewhere is never used.
public enum SystemTool {
    public static let dscacheutil = "/usr/bin/dscacheutil"
    public static let killall = "/usr/bin/killall"
    public static let mdutil = "/usr/bin/mdutil"
    public static let atsutil = "/usr/bin/atsutil"
    public static let qlmanage = "/usr/bin/qlmanage"
    public static let sqlite3 = "/usr/bin/sqlite3"
    public static let pmset = "/usr/bin/pmset"
    public static let scutil = "/usr/sbin/scutil"
    public static let netstat = "/usr/sbin/netstat"
    public static let arp = "/usr/sbin/arp"
    public static let launchctl = "/bin/launchctl"
    public static let osascript = "/usr/bin/osascript"
    public static let find = "/usr/bin/find"
    public static let rm = "/bin/rm"
    public static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
}

/// One maintenance task in the Optimize list.
public struct OptimizeTask: Identifiable, Sendable, Hashable {
    /// A command run as the current user: a fixed argument array, never a shell string.
    public struct Step: Sendable, Hashable {
        public let argv: [String]
        /// A step that is not required may fail without failing the task.
        public let required: Bool

        public init(_ argv: [String], required: Bool = true) {
            self.argv = argv
            self.required = required
        }
    }

    public enum Action: Sendable, Hashable {
        /// An optional admin step followed by commands run as the user.
        case commands(privileged: PrivilegedTask?, user: [Step])
        case vacuumDatabases
        case pruneNotifications
        case removeBrokenLaunchAgents
    }

    public let id: String
    public let title: String
    /// One line that says what the task does and what it costs.
    public let summary: String
    /// SF Symbol name.
    public let symbol: String
    /// Conditions checked right before the task runs.
    public let gates: [SafetyGate]
    /// Quick, harmless tasks are ticked when the list opens; slow or disruptive ones are not.
    public let selectedByDefault: Bool
    public let action: Action

    public var privilegedTask: PrivilegedTask? {
        if case .commands(let privileged, _) = action { return privileged }
        return nil
    }

    public var needsAdmin: Bool { privilegedTask != nil }

    public var userSteps: [Step] {
        if case .commands(_, let steps) = action { return steps }
        return []
    }
}

/// The fixed list of maintenance tasks. Mole's optimize tasks are the
/// reference for what is sensible; anything that edits user data, changes a
/// system setting or "boosts" memory is left out on purpose.
public enum OptimizeCatalog {
    public static let flushDNS = OptimizeTask(
        id: "flush-dns",
        title: "Flush DNS cache",
        summary: "Forgets cached lookups, so sites that moved resolve correctly.",
        symbol: "network",
        gates: [.vpnInactive],
        selectedByDefault: true,
        action: .commands(privileged: .flushDNS, user: [])
    )

    public static let rebuildLaunchServices = OptimizeTask(
        id: "rebuild-launch-services",
        title: "Rebuild Launch Services",
        summary: "Fixes duplicate or missing apps in Open With menus.",
        symbol: "arrow.triangle.2.circlepath",
        gates: [],
        selectedByDefault: true,
        action: .commands(privileged: nil, user: [
            OptimizeTask.Step([SystemTool.lsregister, "-f", "-all", "system,local,user"]),
            OptimizeTask.Step([SystemTool.lsregister, "-gc"], required: false),
        ])
    )

    public static let resetQuickLook = OptimizeTask(
        id: "reset-quick-look",
        title: "Reset Quick Look",
        summary: "Reloads preview generators and clears stale thumbnails.",
        symbol: "eye",
        gates: [],
        selectedByDefault: true,
        action: .commands(privileged: nil, user: [
            OptimizeTask.Step([SystemTool.qlmanage, "-r"]),
            OptimizeTask.Step([SystemTool.qlmanage, "-r", "cache"]),
        ])
    )

    public static let rebuildFontCaches = OptimizeTask(
        id: "rebuild-font-caches",
        title: "Rebuild font caches",
        summary: "Fixes garbled or missing fonts. Takes effect after you log out or restart.",
        symbol: "textformat",
        gates: [.browsersClosed],
        selectedByDefault: false,
        action: .commands(privileged: .rebuildFontCaches, user: [
            OptimizeTask.Step([SystemTool.atsutil, "databases", "-removeUser"]),
        ])
    )

    public static let reindexSpotlight = OptimizeTask(
        id: "reindex-spotlight",
        title: "Reindex Spotlight",
        summary: "Rebuilds the search index. Search is incomplete until indexing finishes.",
        symbol: "magnifyingglass",
        gates: [.onACPower],
        selectedByDefault: false,
        action: .commands(privileged: .reindexSpotlight, user: [])
    )

    public static let vacuumDatabases = OptimizeTask(
        id: "vacuum-databases",
        title: "Compact app databases",
        summary: "Vacuums the Mail and browser databases of apps that are closed.",
        symbol: "cylinder.split.1x2",
        gates: [],
        selectedByDefault: true,
        action: .vacuumDatabases
    )

    public static let pruneNotifications = OptimizeTask(
        id: "prune-notifications",
        title: "Prune notification history",
        summary: "Removes delivered notifications older than \(NotificationHistory.retentionDays) days.",
        symbol: "bell",
        gates: [],
        selectedByDefault: true,
        action: .pruneNotifications
    )

    public static let removeBrokenLaunchAgents = OptimizeTask(
        id: "broken-launch-agents",
        title: "Remove broken launch agents",
        summary: "Moves launch agents whose program no longer exists to the Trash.",
        symbol: "powerplug",
        gates: [],
        selectedByDefault: true,
        action: .removeBrokenLaunchAgents
    )

    public static let clearARPCache = OptimizeTask(
        id: "clear-arp-cache",
        title: "Clear ARP cache",
        summary: "Forgets stale address mappings for devices on the local network.",
        symbol: "point.3.connected.trianglepath.dotted",
        gates: [.vpnInactive],
        selectedByDefault: false,
        action: .commands(privileged: .clearARPCache, user: [])
    )

    public static let restartDock = OptimizeTask(
        id: "restart-dock",
        title: "Restart the Dock",
        summary: "Clears stuck icons and badges. The Dock disappears for a moment.",
        symbol: "dock.rectangle",
        gates: [],
        selectedByDefault: false,
        action: .commands(privileged: nil, user: [
            OptimizeTask.Step([SystemTool.killall, "Dock"]),
        ])
    )

    /// Every task, in the order the list shows them.
    public static let all: [OptimizeTask] = [
        flushDNS, rebuildLaunchServices, resetQuickLook, vacuumDatabases, pruneNotifications,
        removeBrokenLaunchAgents, rebuildFontCaches, reindexSpotlight, clearARPCache, restartDock,
    ]

    public static func task(id: String) -> OptimizeTask? {
        all.first { $0.id == id }
    }
}
