import Foundation

public enum AutoCleanSchedule: String, Codable, Sendable, CaseIterable {
    case off, daily, weekly, lowDisk

    public var title: String {
        switch self {
        case .off: "Off"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .lowDisk: "When free disk is low"
        }
    }
}

public enum MenuBarDisplay: String, Codable, Sendable, CaseIterable {
    case iconOnly, iconAndReclaimable, iconAndFreeSpace

    public var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .iconAndReclaimable: "Icon and reclaimable space"
        case .iconAndFreeSpace: "Icon and free disk space"
        }
    }
}

/// A global hotkey as a virtual key code plus Carbon modifier flags.
public struct Hotkey: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// ⌃⌥⌘K. Carbon modifiers: cmd 0x100, option 0x800, control 0x1000.
    public static let `default` = Hotkey(keyCode: 40, modifiers: 0x0100 | 0x0800 | 0x1000, display: "⌃⌥⌘K")
}

/// Everything in the Settings window. Stored as JSON so the app and the CLI share it.
public struct SweepSettings: Codable, Sendable, Equatable {
    /// Tiers the one-click button pre-selects. Ask is never included.
    public var oneClickTiers: Set<RiskTier> = [.safe]
    /// Catalog ids switched off.
    public var disabledItems: Set<String> = []
    public var reclaimableNotifyBytes: Int64 = 5_000_000_000
    public var lowDiskNotifyFraction: Double = 0.10
    public var autoClean: AutoCleanSchedule = .off
    public var autoCleanPaused = false
    public var lastAutoClean: Date?
    public var cacheDeleteMode: DeleteMode = .permanent
    public var uninstallDeleteMode: DeleteMode = .trash
    public var projectDeleteMode: DeleteMode = .trash
    /// Nil means "the default folders that exist".
    public var projectRoots: [String]?
    public var recentProjectDays = 7
    public var staleProjectDays = 30
    /// Paths or catalog ids that are never touched.
    public var exclusions: [String] = []
    public var menuBarDisplay: MenuBarDisplay = .iconAndReclaimable
    public var hotkey: Hotkey = .default
    public var hotkeyEnabled = true
    public var launchAtLogin = true
    /// Run `uv cache clean` instead of `uv cache prune`.
    public var uvFullClean = false
    public var showMenuBarGraph = false
    /// How long an AI agent session must sit untouched before its history counts as old.
    public var oldSessionDays = 30
    /// Name of the accent colour: mint, teal, blue, indigo, purple, pink, orange or green.
    public var accent = "mint"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SweepSettings()
        oneClickTiers = try c.decodeIfPresent(Set<RiskTier>.self, forKey: .oneClickTiers) ?? d.oneClickTiers
        oneClickTiers.remove(.ask)
        disabledItems = try c.decodeIfPresent(Set<String>.self, forKey: .disabledItems) ?? d.disabledItems
        reclaimableNotifyBytes = try c.decodeIfPresent(Int64.self, forKey: .reclaimableNotifyBytes) ?? d.reclaimableNotifyBytes
        lowDiskNotifyFraction = try c.decodeIfPresent(Double.self, forKey: .lowDiskNotifyFraction) ?? d.lowDiskNotifyFraction
        autoClean = try c.decodeIfPresent(AutoCleanSchedule.self, forKey: .autoClean) ?? d.autoClean
        autoCleanPaused = try c.decodeIfPresent(Bool.self, forKey: .autoCleanPaused) ?? d.autoCleanPaused
        lastAutoClean = try c.decodeIfPresent(Date.self, forKey: .lastAutoClean)
        cacheDeleteMode = try c.decodeIfPresent(DeleteMode.self, forKey: .cacheDeleteMode) ?? d.cacheDeleteMode
        uninstallDeleteMode = try c.decodeIfPresent(DeleteMode.self, forKey: .uninstallDeleteMode) ?? d.uninstallDeleteMode
        projectDeleteMode = try c.decodeIfPresent(DeleteMode.self, forKey: .projectDeleteMode) ?? d.projectDeleteMode
        projectRoots = try c.decodeIfPresent([String].self, forKey: .projectRoots)
        recentProjectDays = try c.decodeIfPresent(Int.self, forKey: .recentProjectDays) ?? d.recentProjectDays
        staleProjectDays = try c.decodeIfPresent(Int.self, forKey: .staleProjectDays) ?? d.staleProjectDays
        exclusions = try c.decodeIfPresent([String].self, forKey: .exclusions) ?? d.exclusions
        menuBarDisplay = try c.decodeIfPresent(MenuBarDisplay.self, forKey: .menuBarDisplay) ?? d.menuBarDisplay
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? d.hotkey
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        uvFullClean = try c.decodeIfPresent(Bool.self, forKey: .uvFullClean) ?? d.uvFullClean
        showMenuBarGraph = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarGraph) ?? d.showMenuBarGraph
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? d.accent
        oldSessionDays = max(1, try c.decodeIfPresent(Int.self, forKey: .oldSessionDays) ?? d.oldSessionDays)
    }

    public static let defaultProjectRoots = ["~/Developer", "~/Projects", "~/code", "~/GitHub", "~/dev"]

    /// The scan roots in effect: the configured ones, or the defaults that exist.
    public func effectiveProjectRoots(context: SweepContext) -> [String] {
        let candidates = projectRoots ?? Self.defaultProjectRoots
        return candidates.map(context.expand).filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// True when a catalog id or a path falls under an exclusion.
    public func isExcluded(itemID: String) -> Bool {
        exclusions.contains(itemID)
    }

    public func isExcluded(path: String, context: SweepContext) -> Bool {
        exclusions.contains { exclusion in
            let expanded = context.expand(exclusion)
            guard expanded.hasPrefix("/") else { return false }
            let real = SafetyGuard.realpath(expanded) ?? expanded
            return SafetyGuard.isSame(path, orInside: expanded) || SafetyGuard.isSame(path, orInside: real)
        }
    }
}

/// Reads and writes `settings.json` in Sweep's Application Support folder.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(context: SweepContext) {
        fileURL = context.supportDirectory.appendingPathComponent("settings.json")
    }

    public func load() -> SweepSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return SweepSettings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SweepSettings.self, from: data)) ?? SweepSettings()
    }

    public func save(_ settings: SweepSettings) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
