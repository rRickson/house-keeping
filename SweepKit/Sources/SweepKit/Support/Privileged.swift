import Foundation

/// The complete list of things House Keeping may do as root. The helper accepts one of
/// these names and nothing else: no raw paths, no shell strings.
public enum PrivilegedTask: String, Codable, Sendable, CaseIterable {
    case flushDNS
    case reindexSpotlight
    case rebuildFontCaches
    case rebuildLaunchServices
    /// Empties `/Library/Caches`.
    case cleanSystemCaches
    /// Removes a root-owned app and its system-level leftovers. The argument is
    /// a bundle identifier; the helper finds and validates the paths itself.
    case removeApplication
    /// Empties the ARP table so stale address mappings are looked up again.
    case clearARPCache
}

public struct PrivilegedResult: Sendable, Equatable {
    public var succeeded: Bool
    public var message: String
    public var bytesFreed: Int64

    public init(succeeded: Bool, message: String = "", bytesFreed: Int64 = 0) {
        self.succeeded = succeeded
        self.message = message
        self.bytesFreed = bytesFreed
    }
}

public enum PrivilegedAvailability: Sendable, Equatable {
    /// The root helper is registered and answers.
    case helper
    /// No helper; macOS asks for the admin password on every run.
    case passwordPrompt
    case unavailable
}

/// Runs admin-only work. Tools that need it are handed one of these by the app.
public protocol PrivilegedRunning: Sendable {
    var availability: PrivilegedAvailability { get async }
    /// - Parameter argument: only for tasks that document one; validated by the helper.
    func run(_ task: PrivilegedTask, argument: String?) async -> PrivilegedResult
}

/// Stands in when admin work is not possible, such as against a fixture home.
public struct NoPrivilegedRunner: PrivilegedRunning {
    public init() {}
    public var availability: PrivilegedAvailability { get async { .unavailable } }
    public func run(_ task: PrivilegedTask, argument: String?) async -> PrivilegedResult {
        PrivilegedResult(succeeded: false, message: "Admin tasks are not available")
    }
}
