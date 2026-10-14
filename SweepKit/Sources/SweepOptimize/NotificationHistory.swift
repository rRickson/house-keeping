import Darwin
import Foundation
import SweepKit

/// Trims delivered notifications that are older than a month from
/// Notification Center's own database.
public struct NotificationHistory: Sendable {
    public static let retentionDays = 30

    public enum State: Sendable, Equatable {
        case ready(path: String)
        /// The database exists but macOS will not let Sweep read it.
        case needsFullDiskAccess
        case notFound
    }

    private let context: SweepContext
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval

    public init(context: SweepContext, timeout: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.context = context
        self.timeout = timeout
        self.now = now
    }

    /// Where the database may live: the group container on macOS 15 and later,
    /// the per-user Darwin folder before that.
    func candidatePaths() -> [String] {
        let home = SafetyGuard.realpath(context.home.path) ?? context.home.path
        var paths = [home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"]
        if !context.isFixture, let userDirectory = Self.darwinUserDirectory() {
            paths.append(userDirectory + "com.apple.notificationcenter/db2/db")
        }
        return paths
    }

    public func state() -> State {
        var denied = false
        for path in candidatePaths() {
            if FileManager.default.isReadableFile(atPath: path), FileManager.default.isWritableFile(atPath: path) {
                return .ready(path: path)
            }
            // The container itself is visible even when its contents are not.
            let container = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            var info = stat()
            if lstat(container, &info) == 0 || errno == EPERM || errno == EACCES { denied = true }
        }
        return denied ? .needsFullDiskAccess : .notFound
    }

    /// Seconds since 2001, which is how the database stores `delivered_date`.
    func cutoff() -> Int {
        Int(now().addingTimeInterval(-Double(Self.retentionDays) * 86_400).timeIntervalSinceReferenceDate)
    }

    /// The statement that counts what would go. It doubles as a check that the
    /// table still has the shape Sweep expects before anything is deleted.
    func countStatement() -> String {
        "SELECT count(*) FROM record WHERE delivered_date IS NOT NULL AND delivered_date > 0 AND delivered_date < \(cutoff());"
    }

    func deleteStatement() -> String {
        "DELETE FROM record WHERE delivered_date IS NOT NULL AND delivered_date > 0 AND delivered_date < \(cutoff());"
    }

    public func prune() async -> OptimizeOutcome {
        guard case .ready(let path) = state() else {
            return state() == .needsFullDiskAccess
                ? .failed("Needs Full Disk Access")
                : .skipped("No notification history found")
        }
        let count = await context.runner.run(SystemTool.sqlite3, ["-batch", "-readonly", path, countStatement()], timeout: timeout)
        let numbers = count.stdout.split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard count.succeeded, let old = numbers.last else {
            return .failed(count.succeeded ? "Notification history has an unexpected format" : count.failureReason)
        }
        guard old > 0 else { return .done("Nothing older than \(Self.retentionDays) days") }

        let delete = await context.runner.run(SystemTool.sqlite3, ["-batch", path, deleteStatement()], timeout: timeout)
        guard delete.succeeded else { return .failed(delete.failureReason) }
        // Notification Center reloads its list when it starts again; launchd restarts it at once.
        _ = await context.runner.run(SystemTool.killall, ["NotificationCenter"], timeout: 10)
        return .done("Removed \(old) old notification\(old == 1 ? "" : "s")")
    }

    static func darwinUserDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
        guard length > 1, length <= buffer.count else { return nil }
        // `length` counts the terminating zero.
        let path = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.hasSuffix("/") ? path : path + "/"
    }
}
