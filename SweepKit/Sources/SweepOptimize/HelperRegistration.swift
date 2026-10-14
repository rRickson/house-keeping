import Foundation
import ServiceManagement

/// Where the helper stands with macOS.
public enum HelperStatus: Sendable, Equatable {
    /// Not installed; admin tasks ask for the password.
    case notRegistered
    /// Registered and allowed to run.
    case enabled
    /// Registered, waiting for the switch in System Settings → General → Login Items.
    case requiresApproval
    /// The helper or its property list is missing from the app bundle.
    case notFound

    public var title: String {
        switch self {
        case .notRegistered: "Not installed"
        case .enabled: "Installed"
        case .requiresApproval: "Waiting for approval in Login Items"
        case .notFound: "Not included in this build"
        }
    }
}

/// Registers the helper daemon with macOS. Abstracted so tests never touch
/// the real Service Management database.
public protocol HelperRegistering: Sendable {
    func status() -> HelperStatus
    func register() throws
    func unregister() async throws
}

/// `SMAppService.daemon` for the property list bundled at
/// `Contents/Library/LaunchDaemons/com.rickson.sweep.helper.plist`.
public struct HelperRegistration: HelperRegistering {
    private let plistName: String

    public init(plistName: String = HelperConstants.daemonPlistName) {
        self.plistName = plistName
    }

    private var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    public func status() -> HelperStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() async throws {
        try await service.unregister()
    }

    /// Opens System Settings → General → Login Items, where the helper is approved.
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// A helper that is never there. Used against fixture homes.
public struct NoHelperRegistration: HelperRegistering {
    public init() {}
    public func status() -> HelperStatus { .notFound }
    public func register() throws {}
    public func unregister() async throws {}
}
