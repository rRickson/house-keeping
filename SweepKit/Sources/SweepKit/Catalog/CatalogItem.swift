import Foundation

public enum CatalogGroup: String, Codable, CaseIterable, Sendable, Comparable {
    case javascript, python, apple, jvm, rustGo, containers, editors, aiAgents, system, other

    public var title: String {
        switch self {
        case .javascript: "JavaScript"
        case .python: "Python"
        case .apple: "Apple"
        case .jvm: "JVM"
        case .rustGo: "Rust/Go"
        case .containers: "Containers"
        case .editors: "Editors"
        case .aiAgents: "AI Agents"
        case .system: "System"
        case .other: "Other"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: CatalogGroup, b: CatalogGroup) -> Bool { a.order < b.order }
}

/// Decides what the one-click button may touch.
public enum RiskTier: String, Codable, CaseIterable, Sendable, Comparable {
    /// Rebuilt automatically; the only cost is re-download or rebuild time.
    case safe
    /// Rebuilt, but slowly, or breaks offline work until rebuilt.
    case caution
    /// May hold things the user chose or made. Never cleaned in one click.
    case ask

    public var title: String {
        switch self {
        case .safe: "Safe"
        case .caution: "Caution"
        case .ask: "Ask"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: RiskTier, b: RiskTier) -> Bool { a.order < b.order }
}

/// One way of finding where a cache lives. Steps are tried in order and the
/// first one that yields an existing location wins.
public struct LocateStep: Codable, Sendable, Hashable {
    /// Ask the tool: `["npm", "config", "get", "cache"]`.
    public var command: [String]?
    /// Read the location from a key of the command's JSON output instead of its last line.
    public var jsonKey: String?
    /// An environment variable that holds the location.
    public var env: String?
    /// Default locations. `~`, `*` and `{a,b}` are expanded.
    public var paths: [String]?
    /// Sub-paths appended to whatever the command or variable returned.
    public var append: [String]?

    public init(command: [String]? = nil, jsonKey: String? = nil, env: String? = nil, paths: [String]? = nil, append: [String]? = nil) {
        self.command = command
        self.jsonKey = jsonKey
        self.env = env
        self.paths = paths
        self.append = append
    }
}

/// How an item is cleaned once it has been located.
public struct CleanStrategy: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Delete each located folder.
        case delete
        /// Delete the entries inside each located folder, minus `exclude`.
        case deleteChildren
        /// Run the tool's own clean command.
        case command
        /// The user picks which entries inside the located folder go.
        case select
        /// Logic that does not fit a rule; implemented in code by name.
        case handler
    }

    public var type: Kind
    /// The clean command for `.command`.
    public var command: [String]?
    /// Commands run before cleaning, such as `gradle --stop`. Failures are ignored.
    public var before: [[String]]?
    /// Entry names that `.deleteChildren` and `.select` leave alone.
    public var exclude: [String]?
    /// Glob that entry names must match for `.select`.
    public var match: String?
    /// Handler name for `.handler`.
    public var handler: String?
    /// True when the clean command only removes what is unused (a "prune"), so
    /// the size shown is an upper bound on what it frees.
    public var partial: Bool?
    /// For `.deleteChildren` and `.select`: only entries in which nothing has
    /// changed for this many days. This is how leftovers of old sessions are
    /// told apart from a session that is still open.
    public var olderThanDays: Int?

    public init(type: Kind, command: [String]? = nil, before: [[String]]? = nil, exclude: [String]? = nil, match: String? = nil, handler: String? = nil, olderThanDays: Int? = nil) {
        self.olderThanDays = olderThanDays
        self.type = type
        self.command = command
        self.before = before
        self.exclude = exclude
        self.match = match
        self.handler = handler
    }

    public static let delete = CleanStrategy(type: .delete)
    public static func command(_ command: [String]) -> CleanStrategy { CleanStrategy(type: .command, command: command) }
}

/// Conditions that must hold before an item may be cleaned.
public struct ItemGuards: Codable, Sendable, Hashable {
    /// Process names, bundle identifiers or app names that must not be running.
    public var notRunning: [String]?
    /// What to tell the user when one of them is running. Defaults to "<first name> is running".
    public var runningReason: String?
    /// A command that must succeed, such as `docker info` for a running daemon.
    public var requires: [String]?
    /// What to tell the user when `requires` fails.
    public var requiresReason: String?

    public init(notRunning: [String]? = nil, runningReason: String? = nil, requires: [String]? = nil, requiresReason: String? = nil) {
        self.notRunning = notRunning
        self.runningReason = runningReason
        self.requires = requires
        self.requiresReason = requiresReason
    }
}

/// One declarative rule: a cache, an artifact store or a task.
public struct CatalogItem: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var group: CatalogGroup
    public var risk: RiskTier
    /// SF Symbol drawn on the item's icon tile when it has no monogram.
    public var symbol: String?
    /// Colour of the icon tile as a hex string, such as "#CB3837".
    public var tint: String?
    /// One to four letters drawn on the icon tile instead of the symbol, such as "npm".
    public var monogram: String?
    public var locate: [LocateStep]
    /// Extra locations that belong to the item wherever the steps above found it.
    public var alsoPaths: [String]?
    public var clean: CleanStrategy
    public var guards: ItemGuards?
    /// One line on what cleaning costs or how the content comes back.
    public var note: String?

    public init(
        id: String,
        name: String,
        group: CatalogGroup,
        risk: RiskTier,
        symbol: String? = nil,
        tint: String? = nil,
        monogram: String? = nil,
        locate: [LocateStep],
        alsoPaths: [String]? = nil,
        clean: CleanStrategy,
        guards: ItemGuards? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.risk = risk
        self.symbol = symbol
        self.tint = tint
        self.monogram = monogram
        self.locate = locate
        self.alsoPaths = alsoPaths
        self.clean = clean
        self.guards = guards
        self.note = note
    }
}
