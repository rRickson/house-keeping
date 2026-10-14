import Foundation
import SweepKit

/// Names shared by the app, the helper and its launchd property list.
public enum HelperConstants {
    /// Bundle identifier of the app; the only caller the helper accepts.
    public static let appIdentifier = "com.rickson.sweep"
    /// The helper's code-signing identifier and launchd label.
    public static let helperIdentifier = "com.rickson.sweep.helper"
    public static let machServiceName = "com.rickson.sweep.helper"
    /// File name inside the app's `Contents/Library/LaunchDaemons`.
    public static let daemonPlistName = "com.rickson.sweep.helper.plist"
    /// Bumped when the protocol changes, so the app can tell an old helper apart.
    public static let protocolVersion = "1"
}

/// Everything the helper can be asked over XPC.
///
/// The only inputs are a task NAME (a `PrivilegedTask` raw value) and, for the
/// one task that documents it, an argument string that the helper validates
/// itself. There is no way to send a path or a command.
@objc(SweepHelperProtocol)
public protocol HelperXPCProtocol {
    /// - Parameter reply: succeeded, a message for the user, bytes freed.
    func runTask(_ name: String, argument: String?, reply: @escaping @Sendable (Bool, String, Int64) -> Void)
    func protocolVersion(reply: @escaping @Sendable (String) -> Void)
}
