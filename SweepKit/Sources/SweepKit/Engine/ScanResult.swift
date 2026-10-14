import Foundation

/// One concrete thing a clean would do: delete a path or run a command.
public struct CleanTarget: Identifiable, Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case delete(path: String)
        case command([String])
    }

    public var id: String
    public var label: String
    public var action: Action
    public var bytes: Int64
    public var lastModified: Date?
    /// Identity of the path at scan time, for the re-check before deleting.
    public var fingerprint: Fingerprint?
    /// Extra context for the review list, such as "in use by 2 containers".
    public var detail: String?

    public init(id: String, label: String, action: Action, bytes: Int64, lastModified: Date? = nil, fingerprint: Fingerprint? = nil, detail: String? = nil) {
        self.id = id
        self.label = label
        self.action = action
        self.bytes = bytes
        self.lastModified = lastModified
        self.fingerprint = fingerprint
        self.detail = detail
    }

    public static func delete(_ path: String, label: String? = nil, bytes: Int64, lastModified: Date? = nil, detail: String? = nil) -> CleanTarget {
        CleanTarget(
            id: path,
            label: label ?? (path as NSString).lastPathComponent,
            action: .delete(path: path),
            bytes: bytes,
            lastModified: lastModified,
            fingerprint: Fingerprint(path: path),
            detail: detail
        )
    }

    public static func command(_ command: [String], label: String? = nil, bytes: Int64, lastModified: Date? = nil, detail: String? = nil) -> CleanTarget {
        let line = command.joined(separator: " ")
        return CleanTarget(id: "$ " + line, label: label ?? line, action: .command(command), bytes: bytes, lastModified: lastModified, detail: detail)
    }

    /// The path or command line, as written to the ledger.
    public var description: String {
        switch action {
        case .delete(let path): path
        case .command(let command): command.joined(separator: " ")
        }
    }
}

public enum ScanStatus: Sendable, Hashable {
    case ready
    /// Nothing was found: the tool is not installed or its cache does not exist.
    case missing
    /// A guard holds the item back; the reason is shown in place of the checkbox.
    case blocked(String)
    case permissionDenied

    public var isReady: Bool { self == .ready }

    public var reason: String? {
        switch self {
        case .ready: nil
        case .missing: "Not found"
        case .blocked(let reason): reason
        case .permissionDenied: "Permission denied"
        }
    }
}

public enum LocateSource: Sendable, Hashable {
    case tool([String])
    case environment(String)
    case defaultPath
    case handler
    case none

    public var description: String {
        switch self {
        case .tool(let command): "reported by `\(command.joined(separator: " "))`"
        case .environment(let name): "from $\(name)"
        case .defaultPath: "default location"
        case .handler: "reported by the tool"
        case .none: "not found"
        }
    }
}

/// What a scan learned about one catalog item.
public struct ScanResult: Identifiable, Sendable {
    public var item: CatalogItem
    public var id: String { item.id }
    /// Real paths of the locations the rule resolved to. This is the allowlist for deletes.
    public var roots: [String]
    public var targets: [CleanTarget]
    public var bytes: Int64
    public var fileCount: Int
    public var lastModified: Date?
    public var status: ScanStatus
    public var source: LocateSource
    /// True when the user picks targets one by one (Ask-tier lists).
    public var selectable: Bool
    /// The exact command or delete action, in words.
    public var actionDescription: String
    public var scannedAt: Date

    public init(
        item: CatalogItem,
        roots: [String] = [],
        targets: [CleanTarget] = [],
        bytes: Int64 = 0,
        fileCount: Int = 0,
        lastModified: Date? = nil,
        status: ScanStatus = .missing,
        source: LocateSource = .none,
        selectable: Bool = false,
        actionDescription: String = "",
        scannedAt: Date = Date()
    ) {
        self.item = item
        self.roots = roots
        self.targets = targets
        self.bytes = bytes
        self.fileCount = fileCount
        self.lastModified = lastModified
        self.status = status
        self.source = source
        self.selectable = selectable
        self.actionDescription = actionDescription
        self.scannedAt = scannedAt
    }

    /// True when `bytes` is the most a clean could free: the tool's own command
    /// decides what is unused, and usually keeps part of the cache.
    public var isUpperBound: Bool {
        guard item.clean.partial == true else { return false }
        return targets.contains { if case .command = $0.action { true } else { false } }
    }

    /// Bytes a clean of the given targets (all when nil) is expected to free.
    public func bytes(for targetIDs: Set<String>?) -> Int64 {
        guard let targetIDs else { return bytes }
        return targets.filter { targetIDs.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }
}
