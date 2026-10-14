import Foundation
import SweepKit

/// An app's SQLite store that can be compacted while the app is closed.
public struct AppDatabase: Sendable, Hashable, Identifiable {
    /// The app that owns it, as shown to the user.
    public let app: String
    public let path: String
    public let bytes: Int64
    /// Set when the owning app is open; the database is then left alone.
    public let blockedBy: String?

    public var id: String { path }
}

/// Compacts the databases of apps that are not running.
///
/// `VACUUM` rewrites a database without changing what it holds. It only runs
/// when the owning app is closed, the file passes SQLite's integrity check and
/// there is free space worth reclaiming.
public struct DatabaseVacuum: Sendable {
    struct Store: Sendable {
        let app: String
        /// Home-relative glob patterns.
        let patterns: [String]
        /// Process names, bundle identifiers or app names that mean the app is open.
        let processes: [String]
    }

    static let stores: [Store] = [
        Store(app: "Mail", patterns: ["Library/Mail/V*/MailData/Envelope Index"], processes: ["Mail", "com.apple.mail"]),
        Store(app: "Safari", patterns: ["Library/Safari/History.db"], processes: ["Safari", "com.apple.Safari"]),
        Store(
            app: "Chrome",
            patterns: ["Library/Application Support/Google/Chrome/*/History", "Library/Application Support/Google/Chrome/*/Favicons"],
            processes: ["Google Chrome", "com.google.Chrome"]),
        Store(
            app: "Brave",
            patterns: ["Library/Application Support/BraveSoftware/Brave-Browser/*/History",
                       "Library/Application Support/BraveSoftware/Brave-Browser/*/Favicons"],
            processes: ["Brave Browser", "com.brave.Browser"]),
        Store(
            app: "Edge",
            patterns: ["Library/Application Support/Microsoft Edge/*/History", "Library/Application Support/Microsoft Edge/*/Favicons"],
            processes: ["Microsoft Edge", "com.microsoft.edgemac"]),
        Store(
            app: "Arc",
            patterns: ["Library/Application Support/Arc/User Data/*/History", "Library/Application Support/Arc/User Data/*/Favicons"],
            processes: ["Arc", "company.thebrowser.Browser"]),
        Store(
            app: "Firefox",
            patterns: ["Library/Application Support/Firefox/Profiles/*/places.sqlite",
                       "Library/Application Support/Firefox/Profiles/*/favicons.sqlite"],
            processes: ["firefox", "org.mozilla.firefox"]),
    ]

    /// Larger databases take too long to rewrite inside the command timeout.
    public static let maximumBytes: Int64 = 500_000_000
    /// Below this share of free pages there is nothing worth reclaiming.
    public static let minimumFreeFraction = 0.05

    private let context: SweepContext
    private let timeout: TimeInterval

    public init(context: SweepContext, timeout: TimeInterval = 120) {
        self.context = context
        self.timeout = timeout
    }

    /// Every known database that exists, with the app that blocks it when that app is open.
    public func candidates() -> [AppDatabase] {
        let running = context.processes.runningProcesses()
        var result: [AppDatabase] = []
        let home = SafetyGuard.realpath(context.home.path) ?? context.home.path
        for store in Self.stores {
            let blocked = store.processes.contains { pattern in running.contains { $0.matches(pattern) } }
            for pattern in store.patterns {
                for path in Glob.expand(home + "/" + pattern) {
                    guard let bytes = Self.databaseSize(path) else { continue }
                    result.append(AppDatabase(app: store.app, path: path, bytes: bytes, blockedBy: blocked ? "\(store.app) is open" : nil))
                }
            }
        }
        return result
    }

    public struct Summary: Sendable, Equatable {
        public var compacted = 0
        public var alreadyCompact = 0
        public var bytesFreed: Int64 = 0
        /// One line per database that was left alone or failed.
        public var skipped: [String] = []
        public var failed: [String] = []

        public var message: String {
            var parts: [String] = []
            if compacted > 0 {
                var text = "Compacted \(compacted) database\(compacted == 1 ? "" : "s")"
                if bytesFreed > 0 { text += ", freed \(ByteFormat.string(bytesFreed))" }
                parts.append(text)
            } else if failed.isEmpty {
                parts.append(alreadyCompact > 0 ? "Already compact" : "Nothing to compact")
            }
            if let first = failed.first { parts.append(first) }
            if let first = skipped.first { parts.append(skipped.count == 1 ? first : "\(first) and \(skipped.count - 1) more skipped") }
            return parts.joined(separator: " · ")
        }
    }

    /// Compacts every candidate whose app is closed.
    public func run() async -> Summary {
        var summary = Summary()
        var blockedApps: [String] = []
        for database in candidates() {
            if let reason = database.blockedBy {
                if !blockedApps.contains(reason) { blockedApps.append(reason) }
                continue
            }
            if Task.isCancelled { break }
            await compact(database, into: &summary)
        }
        summary.skipped.append(contentsOf: blockedApps)
        return summary
    }

    private func compact(_ database: AppDatabase, into summary: inout Summary) async {
        let name = "\(database.app) \((database.path as NSString).lastPathComponent)"
        if database.bytes > Self.maximumBytes {
            summary.skipped.append("\(name) is too large")
            return
        }

        let pages = await sqlite(["-batch", "-readonly", database.path, "PRAGMA page_count; PRAGMA freelist_count;"])
        let counts = pages.stdout.split(whereSeparator: \.isNewline).compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        guard pages.succeeded, counts.count >= 2, counts[0] > 0 else {
            summary.skipped.append("\(name) could not be read")
            return
        }
        if Double(counts[1]) / Double(counts[0]) < Self.minimumFreeFraction {
            summary.alreadyCompact += 1
            return
        }

        let check = await sqlite(["-batch", "-readonly", database.path, "PRAGMA integrity_check;"])
        let lines = check.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard check.succeeded, lines.contains("ok") else {
            summary.skipped.append("\(name) did not pass its integrity check")
            return
        }

        // The app may have been opened while the checks ran.
        let store = Self.stores.first { $0.app == database.app }
        if let store, context.processes.firstRunning(of: store.processes) != nil {
            summary.skipped.append("\(database.app) is open")
            return
        }

        let result = await sqlite(["-batch", database.path, "VACUUM;"])
        guard result.succeeded else {
            summary.failed.append("\(name): \(result.failureReason)")
            return
        }
        let after = Self.databaseSize(database.path) ?? database.bytes
        summary.compacted += 1
        summary.bytesFreed += max(database.bytes - after, 0)
    }

    private func sqlite(_ arguments: [String]) async -> CommandResult {
        await context.runner.run(SystemTool.sqlite3, arguments, timeout: timeout)
    }

    /// The size of a regular, writable file that starts with the SQLite header; nil for anything else.
    static func databaseSize(_ path: String) -> Int64? {
        guard let fingerprint = Fingerprint(path: path), !fingerprint.isSymlink, !fingerprint.isDirectory,
              FileManager.default.isWritableFile(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header == Data("SQLite format 3\0".utf8) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        return size
    }
}
