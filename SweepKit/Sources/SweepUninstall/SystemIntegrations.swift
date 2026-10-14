import AppKit
import CoreServices
import Foundation
import SweepKit

// The parts of Uninstall that talk to the real machine. None of them is used
// against a fixture home: `UninstallEnvironment.fixture` swaps in no-ops.

/// Pure editing of the Dock's `persistent-apps` list.
public enum DockTiles {
    /// The path a Dock tile points at, if it names one.
    public static func path(of tile: [String: Any]) -> String? {
        guard let data = tile["tile-data"] as? [String: Any],
              let file = data["file-data"] as? [String: Any],
              let string = file["_CFURLString"] as? String, !string.isEmpty else { return nil }
        let path: String
        if string.hasPrefix("file:") {
            guard let url = URL(string: string) else { return nil }
            path = url.path
        } else {
            path = string
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public static func bundleID(of tile: [String: Any]) -> String? {
        (tile["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
    }

    /// The tiles left after removing the app's. A tile is the app's when it
    /// points at the bundle; a tile without a path is matched by bundle identifier.
    public static func removing(appPath: String, bundleID: String?, from tiles: [[String: Any]]) -> [[String: Any]] {
        let target = URL(fileURLWithPath: appPath).standardizedFileURL.path
        return tiles.filter { tile in
            if let path = path(of: tile) { return path != target }
            if let bundleID, let tileID = self.bundleID(of: tile) {
                return tileID.caseInsensitiveCompare(bundleID) != .orderedSame
            }
            return true
        }
    }
}

/// Edits `com.apple.dock` and restarts the Dock so the tile disappears.
public struct SystemDockEditor: DockEditing {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func removeEntry(for app: InstalledApp) async -> Bool {
        guard Self.rewrite(appPath: app.path, bundleID: app.bundleID) else { return false }
        // The Dock only reads its preferences at launch; launchd restarts it at once.
        _ = await runner.run("killall", ["Dock"], timeout: 10)
        return true
    }

    private static func rewrite(appPath: String, bundleID: String?) -> Bool {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        var changed = false
        for key in ["persistent-apps", "recent-apps"] {
            guard let tiles = CFPreferencesCopyAppValue(key as CFString, domain) as? [[String: Any]] else { continue }
            let kept = DockTiles.removing(appPath: appPath, bundleID: bundleID, from: tiles)
            guard kept.count != tiles.count else { continue }
            CFPreferencesSetAppValue(key as CFString, kept as CFArray, domain)
            changed = true
        }
        return changed && CFPreferencesAppSynchronize(domain)
    }
}

/// Asks an app to quit the way the Dock's Quit item does, then waits.
public struct WorkspaceAppTerminator: AppTerminating {
    private let processes: any ProcessListing
    private let timeout: TimeInterval

    public init(processes: any ProcessListing = SystemProcessList(), timeout: TimeInterval = 15) {
        self.processes = processes
        self.timeout = timeout
    }

    public func terminate(_ app: InstalledApp) async -> Bool {
        let inside = app.path + "/"
        let pids = NSWorkspace.shared.runningApplications.filter { running in
            if let path = running.bundleURL?.standardizedFileURL.path, path == app.path || path.hasPrefix(inside) { return true }
            if let bundleID = app.bundleID, let id = running.bundleIdentifier {
                return id.caseInsensitiveCompare(bundleID) == .orderedSame
            }
            return false
        }.map { running -> pid_t in
            running.terminate()
            return running.processIdentifier
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let alive = pids.contains { pid in
                guard let running = NSRunningApplication(processIdentifier: pid) else { return false }
                return !running.isTerminated
            }
            // Helpers without a window are not apps to NSWorkspace; they must be gone too.
            if !alive, !processes.runningProcesses().contains(where: { $0.path.hasPrefix(inside) }) { return true }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return false }
        }
        return false
    }
}

/// Spotlight's record of when an app was last opened.
public struct SpotlightLastUsedDates: LastUsedProviding {
    public init() {}

    public func lastUsedDate(ofAppAt path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

enum LaunchServices {
    /// Where Launch Services knows apps with this bundle identifier to be, wherever they are installed.
    static func applicationPaths(bundleID: String) -> [String] {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return []
        }
        return urls.map(\.path)
    }
}
