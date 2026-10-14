import Foundation
import SweepKit

/// The kinds of system junk the Clean tool looks for.
public enum JunkCategory: String, CaseIterable, Sendable, Codable, Hashable {
    case userCaches
    case browserCaches
    case logs
    case crashReports
    case dsStore
    case mailDownloads
    case installers
    case systemCaches
    case deviceBackups
    case trash

    public var title: String {
        switch self {
        case .userCaches: "App caches"
        case .browserCaches: "Browser caches"
        case .logs: "Logs"
        case .crashReports: "Crash reports"
        case .dsStore: ".DS_Store files"
        case .mailDownloads: "Mail downloads"
        case .installers: "Old installers"
        case .systemCaches: "System caches"
        case .deviceBackups: "iOS device backups"
        case .trash: "Trash"
        }
    }

    /// SF Symbol for the category header.
    public var symbol: String {
        switch self {
        case .userCaches: "square.stack.3d.up"
        case .browserCaches: "globe"
        case .logs: "doc.text"
        case .crashReports: "exclamationmark.bubble"
        case .dsStore: "doc.badge.gearshape"
        case .mailDownloads: "envelope"
        case .installers: "shippingbox"
        case .systemCaches: "internaldrive"
        case .deviceBackups: "iphone"
        case .trash: "trash"
        }
    }

    public var risk: RiskTier {
        switch self {
        case .userCaches, .browserCaches, .logs, .crashReports, .dsStore: .safe
        case .mailDownloads, .installers, .systemCaches, .trash: .caution
        case .deviceBackups: .ask
        }
    }

    /// One line on what cleaning costs or how the content comes back.
    public var note: String {
        switch self {
        case .userCaches: "Rebuilt by each app the next time it needs them."
        case .browserCaches: "Pages load a little slower the first time. Profiles, cookies, history and bookmarks are never touched."
        case .logs: "Diagnostic text files that apps write as they run."
        case .crashReports: "Reports macOS keeps after an app quits unexpectedly."
        case .dsStore: "Finder's per-folder view settings. Finder writes them again when needed."
        case .mailDownloads: "Copies of attachments you opened from Mail. The originals stay in your mailboxes."
        case .installers: "Disk images, packages and app archives downloaded more than 30 days ago."
        case .systemCaches: "Caches shared by every user of this Mac. Cleaned by the helper as administrator."
        case .deviceBackups: "Local backups of an iPhone or iPad. A removed backup cannot be made again without the device."
        case .trash: "Everything in the Trash. Emptying it cannot be undone."
        }
    }

    /// How entries of this category are removed.
    public var removal: JunkRemoval {
        switch self {
        case .userCaches, .browserCaches, .logs, .crashReports, .dsStore: .cacheSetting
        case .mailDownloads, .installers, .deviceBackups: .trash
        case .trash: .permanent
        case .systemCaches: .helper
        }
    }

    /// True when macOS only lets an app with Full Disk Access read the location.
    public var needsFullDiskAccess: Bool {
        switch self {
        case .mailDownloads, .deviceBackups, .trash: true
        default: false
        }
    }

    /// Position in the review list when two categories share a tier and a size.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// How a category's entries leave the disk.
public enum JunkRemoval: Sendable, Hashable {
    /// Follows the "Delete mode for caches" setting.
    case cacheSetting
    /// Always moved to the Trash.
    case trash
    /// Always deleted for good (emptying the Trash).
    case permanent
    /// Cleaned by the privileged helper, never deleted by Sweep directly.
    case helper
}

/// One path an entry would remove.
public struct JunkTarget: Sendable, Hashable, Identifiable {
    public var path: String
    public var bytes: Int64
    public var lastModified: Date?
    /// Identity of the path at scan time, for the re-check before deleting.
    public var fingerprint: Fingerprint?

    public var id: String { path }

    public init(path: String, bytes: Int64 = 0, lastModified: Date? = nil) {
        self.path = path
        self.bytes = bytes
        self.lastModified = lastModified
        self.fingerprint = Fingerprint(path: path)
    }
}

/// One row of the review list.
public struct JunkEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var category: JunkCategory
    /// A readable name: the app, the browser, the file or the device.
    public var name: String
    /// Extra context, such as the bundle identifier or the device model.
    public var detail: String?
    public var targets: [JunkTarget]
    public var bytes: Int64
    public var fileCount: Int
    public var lastModified: Date?
    /// Why the entry cannot be cleaned right now, such as "Safari is running".
    public var blockedReason: String?
    /// True until the scanner has measured the entry.
    public var isSizing: Bool

    public init(
        id: String,
        category: JunkCategory,
        name: String,
        detail: String? = nil,
        targets: [JunkTarget],
        bytes: Int64 = 0,
        fileCount: Int = 0,
        lastModified: Date? = nil,
        blockedReason: String? = nil,
        isSizing: Bool = false
    ) {
        self.id = id
        self.category = category
        self.name = name
        self.detail = detail
        self.targets = targets
        self.bytes = bytes
        self.fileCount = fileCount
        self.lastModified = lastModified
        self.blockedReason = blockedReason
        self.isSizing = isSizing
    }

    public var paths: [String] { targets.map(\.path) }
    public var risk: RiskTier { category.risk }
    public var isBlocked: Bool { blockedReason != nil }

    /// Safe entries are ticked when the list appears. Caution and Ask entries,
    /// the Trash and anything blocked never are.
    public var isSelectedByDefault: Bool {
        risk == .safe && category != .trash && blockedReason == nil
    }

    /// True when ticking the entry must be confirmed before cleaning.
    public var needsConfirmation: Bool { risk != .safe }

    /// Review order: risk tier, then size descending, with the Trash last.
    public static func inReviewOrder(_ a: JunkEntry, _ b: JunkEntry) -> Bool {
        let aTrash = a.category == .trash, bTrash = b.category == .trash
        if aTrash != bTrash { return bTrash }
        if a.risk != b.risk { return a.risk < b.risk }
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        if a.category != b.category { return a.category.order < b.category.order }
        let names = a.name.localizedStandardCompare(b.name)
        if names != .orderedSame { return names == .orderedAscending }
        return a.id < b.id
    }
}

extension Sequence where Element == JunkEntry {
    /// The entries in review order: risk tier, then size descending, Trash last.
    public func reviewOrdered() -> [JunkEntry] { sorted(by: JunkEntry.inReviewOrder) }
}

/// What a scan reports while it runs.
public enum JunkScanEvent: Sendable {
    /// A new entry, or a newer version of one already reported (same `id`).
    case entry(JunkEntry)
    /// An entry reported earlier turned out to be empty.
    case dropped(id: String)
}

/// Knobs that tests turn; the defaults are what the app uses.
public struct JunkOptions: Sendable {
    /// "Now" for the installer age check. Nil means the moment the scan runs.
    public var now: Date?
    public var installerAgeDays: Int
    public var dsStoreMaxDepth: Int
    public var dsStoreMaxCount: Int
    /// Folders the `.DS_Store` search opens before it gives up.
    public var dsStoreMaxFolders: Int
    /// The folder measured for the System caches entry. Nil means `/Library/Caches`
    /// on the real machine and no entry at all against a fixture home.
    public var systemCachesDirectory: String?

    public init(
        now: Date? = nil,
        installerAgeDays: Int = 30,
        dsStoreMaxDepth: Int = 6,
        dsStoreMaxCount: Int = 5000,
        dsStoreMaxFolders: Int = 40000,
        systemCachesDirectory: String? = nil
    ) {
        self.now = now
        self.installerAgeDays = installerAgeDays
        self.dsStoreMaxDepth = dsStoreMaxDepth
        self.dsStoreMaxCount = dsStoreMaxCount
        self.dsStoreMaxFolders = dsStoreMaxFolders
        self.systemCachesDirectory = systemCachesDirectory
    }
}
