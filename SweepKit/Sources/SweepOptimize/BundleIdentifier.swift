import Foundation

/// A bundle identifier that is safe to build file names from.
///
/// Only reverse-DNS characters pass: ASCII letters, digits, hyphens and dots,
/// in at least two non-empty parts. That rules out path separators, `..`,
/// spaces, quotes and every shell metacharacter. Apple's own identifiers are
/// refused outright.
public struct BundleIdentifier: Sendable, Hashable, CustomStringConvertible {
    public let value: String

    public init?(_ raw: String) {
        guard !raw.isEmpty, raw.utf8.count <= 155 else { return nil }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        for part in parts {
            guard !part.isEmpty, part.first != "-", part.last != "-" else { return nil }
            guard part.utf8.allSatisfy(Self.isAllowed) else { return nil }
        }
        let lowered = raw.lowercased()
        guard lowered != "com.apple", !lowered.hasPrefix("com.apple.") else { return nil }
        value = raw
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
    }

    public var description: String { value }

    var partCount: Int { value.split(separator: ".").count }

    /// True when `name` (a file name without its extension) belongs to this
    /// identifier: the identifier itself, or the identifier followed by a dot
    /// and more. `com.acme.app` owns `com.acme.app.helper` but not
    /// `com.acme.apple`. A two-part identifier such as `com.acme` names a whole
    /// vendor, so it only ever matches exactly.
    public func owns(_ name: String) -> Bool {
        if name == value { return true }
        return partCount >= 3 && name.hasPrefix(value + ".")
    }
}
