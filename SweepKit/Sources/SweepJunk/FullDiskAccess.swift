import Darwin
import Foundation
import SweepKit

/// Full Disk Access is optional. Without it macOS hides Safari, Mail, iOS
/// backups, the Trash and some app containers from House Keeping.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        /// macOS refused the read: the banner with the Settings link is shown.
        case denied
        /// `~/Library/Safari` does not exist, so there is nothing to probe.
        case unknown
    }

    /// Privacy & Security → Full Disk Access in System Settings.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Detects access by trying to read `~/Library/Safari`, which macOS only
    /// lets an app with Full Disk Access list.
    public static func status(home: URL) -> Status {
        let probe = home.appendingPathComponent("Library/Safari").path
        let descriptor = open(probe, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        switch errno {
        case EPERM, EACCES: return .denied
        default: return .unknown
        }
    }

    public static func status(context: SweepContext) -> Status { status(home: context.home) }
}
