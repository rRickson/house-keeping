import Foundation

public enum DeleteMode: String, Codable, Sendable, CaseIterable {
    case trash, permanent

    public var title: String {
        switch self {
        case .trash: "Move to Trash"
        case .permanent: "Delete permanently"
        }
    }
}

/// One line of an operation: a single path or command and what happened to it.
public struct OperationEntry: Codable, Sendable, Identifiable, Hashable {
    public enum Result: String, Codable, Sendable {
        /// The path was deleted or the command succeeded.
        case removed
        /// A guard or re-check held it back.
        case skipped
        /// The safety model refused the path outright.
        case refused
        case failed
        /// Nothing was touched; this is what would have happened.
        case dryRun
    }

    public var id: UUID
    public var itemID: String
    public var itemName: String
    /// The path or the command line.
    public var target: String
    public var bytes: Int64
    /// "trash", "permanent", "command" (a tool's own clean command) or "helper" (the admin helper).
    public var mode: String
    public var result: Result
    public var reason: String?

    public init(itemID: String, itemName: String, target: String, bytes: Int64, mode: String, result: Result, reason: String? = nil) {
        self.id = UUID()
        self.itemID = itemID
        self.itemName = itemName
        self.target = target
        self.bytes = bytes
        self.mode = mode
        self.result = result
        self.reason = reason
    }

    public var isFailure: Bool { result == .failed || result == .refused }
}

/// A clean, purge, uninstall or optimise run, as written to the ledger.
public struct SweepOperation: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case devCaches, projects, junk, uninstall, optimize, analyze

        public var title: String {
            switch self {
            case .devCaches: "Dev caches"
            case .projects: "Projects"
            case .junk: "System junk"
            case .uninstall: "Uninstall"
            case .optimize: "Optimize"
            case .analyze: "Analyze"
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    /// Which front end started it: "menubar", "window", "cli", "hotkey", "schedule", "shortcut".
    public var source: String
    public var dryRun: Bool
    public var entries: [OperationEntry]

    public init(kind: Kind, source: String, dryRun: Bool = false, entries: [OperationEntry] = [], date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.kind = kind
        self.source = source
        self.dryRun = dryRun
        self.entries = entries
    }

    public var bytesFreed: Int64 {
        entries.filter { $0.result == .removed }.reduce(0) { $0 + $1.bytes }
    }

    /// Bytes a dry run reports it would free.
    public var bytesPlanned: Int64 {
        entries.filter { $0.result == .dryRun }.reduce(0) { $0 + $1.bytes }
    }

    public var failures: [OperationEntry] { entries.filter(\.isFailure) }
    public var skipped: [OperationEntry] { entries.filter { $0.result == .skipped } }

    /// Names of the items that had something removed.
    public var cleanedItemNames: [String] {
        var seen = Set<String>()
        return entries.filter { $0.result == .removed }.compactMap { seen.insert($0.itemID).inserted ? $0.itemName : nil }
    }

    /// "Freed 18.4 GB from 9 caches"
    public func summary(noun: String = "cache") -> String {
        let count = cleanedItemNames.count
        let plural = count == 1 ? noun : noun + "s"
        return "Freed \(ByteFormat.string(bytesFreed)) from \(count) \(plural)"
    }
}
