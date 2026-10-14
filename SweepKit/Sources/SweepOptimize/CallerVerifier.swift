import Foundation
import Security

/// Code-signing requirements for the two ends of the helper connection.
public enum CodeRequirement {
    /// A requirement for code with this identifier, signed by this team with a
    /// certificate that chains to Apple. That holds for an Apple Development
    /// certificate from a personal team and for Developer ID alike.
    /// Returns nil when either value could not be a real identifier, so
    /// nothing odd can be spliced into the requirement text.
    public static func text(identifier: String, teamIdentifier: String) -> String? {
        guard isPlain(identifier, extra: [0x2E, 0x2D]), isPlain(teamIdentifier, extra: []) else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    private static func isPlain(_ text: String, extra: [UInt8]) -> Bool {
        !text.isEmpty && text.utf8.count <= 128 && text.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || extra.contains(byte)
        }
    }

    /// The team that signed the running process, or nil when it is unsigned or
    /// ad-hoc signed.
    public static func ownTeamIdentifier() -> String? {
        var current: SecCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(current, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Decides whether the process at the other end of an XPC connection is House Keeping.
///
/// The requirement is derived from the helper's own signature: the caller must
/// carry the app's identifier and be signed by the same team as the helper.
/// A helper that is unsigned or ad-hoc signed has no team to compare with and
/// therefore trusts nobody.
public struct CallerVerifier: Sendable {
    public let requirementText: String

    public init?(appIdentifier: String = HelperConstants.appIdentifier, teamIdentifier: String? = CodeRequirement.ownTeamIdentifier()) {
        guard let teamIdentifier, let text = CodeRequirement.text(identifier: appIdentifier, teamIdentifier: teamIdentifier) else { return nil }
        requirementText = text
    }

    /// Checks the peer of `connection`. The audit token is used when the
    /// system exposes it, because a process identifier can be reused between
    /// the connection and the check.
    public func isTrusted(_ connection: NSXPCConnection) -> Bool {
        if let token = Self.auditToken(of: connection) {
            return satisfies([kSecGuestAttributeAudit: token] as CFDictionary)
        }
        let pid = connection.processIdentifier
        guard pid > 0 else { return false }
        return isTrusted(processIdentifier: pid)
    }

    public func isTrusted(processIdentifier: pid_t) -> Bool {
        satisfies([kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary)
    }

    private func satisfies(_ attributes: CFDictionary) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// `NSXPCConnection` keeps its peer's audit token in a property that is
    /// not in the public headers. It is read only when it is there.
    private static func auditToken(of connection: NSXPCConnection) -> Data? {
        guard connection.responds(to: NSSelectorFromString("auditToken")),
              let value = connection.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        let size = MemoryLayout<audit_token_t>.size
        guard String(cString: value.objCType).hasPrefix("{"), sizeOfValue(value) == size else { return nil }
        value.getValue(&token, size: size)
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    private static func sizeOfValue(_ value: NSValue) -> Int {
        var size = 0
        NSGetSizeAndAlignment(value.objCType, &size, nil)
        return size
    }
}
