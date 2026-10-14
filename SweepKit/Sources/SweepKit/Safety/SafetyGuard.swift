import Darwin
import Foundation

/// What a path looked like when it was scanned. Compared again right before
/// deleting, so Sweep never removes something other than what was previewed.
public struct Fingerprint: Sendable, Hashable, Codable {
    public var device: Int32
    public var inode: UInt64
    public var owner: UInt32
    public var isDirectory: Bool
    public var isSymlink: Bool

    public init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = UInt64(info.st_ino)
        owner = info.st_uid
        isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        isSymlink = (info.st_mode & S_IFMT) == S_IFLNK
    }
}

/// The allowlist and deny list every delete passes through.
///
/// A path is deletable only when it sits under a root that a rule resolved to
/// (the allowlist) and is not protected (the deny list). Both checks run on
/// the path as written and again on its `realpath`.
public struct SafetyGuard: Sendable {
    public enum Scope: Sendable {
        /// Developer caches and system junk.
        case cache
        /// Build artifacts inside a project folder.
        case projectArtifact
        /// An app bundle and its leftovers; the only scope allowed inside `/Applications`.
        case uninstall
        /// A file or folder the user picked in Analyze. Trash only.
        case analyze
    }

    public struct Verdict: Sendable, Equatable {
        public var allowed: Bool
        public var reason: String?
        /// The path after symlink resolution.
        public var resolved: String

        public static func deny(_ reason: String, resolved: String) -> Verdict {
            Verdict(allowed: false, reason: reason, resolved: resolved)
        }
    }

    public let home: String

    public init(home: URL) {
        self.home = Self.realpath(home.path) ?? home.standardizedFileURL.path
    }

    // MARK: Deny list

    /// Nothing inside these is ever deleted, in any scope.
    private var systemSubtrees: [String] {
        [
            "/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", "/Library/Keychains",
            "\(home)/Library/Keychains", "\(home)/.ssh", "\(home)/.gnupg",
        ]
    }

    /// Media and iCloud Drive. Only Analyze, where the user picks a file by hand, may go inside.
    private var mediaFolders: [String] {
        ["\(home)/Pictures", "\(home)/Movies", "\(home)/Music", "\(home)/Library/Mobile Documents"]
    }

    /// Documents and Desktop: protected as subtrees for caches, see `denyReason`.
    private var userContentFolders: [String] {
        ["\(home)/Documents", "\(home)/Desktop"]
    }

    private var applicationFolders: [String] {
        ["/Applications", "\(home)/Applications"]
    }

    /// Containers that hold deletable things but must never go themselves.
    private var protectedExact: [String] {
        [
            "/", "/Users", "/Library", "/Library/Caches", "/Library/Application Support", "/Volumes", "/opt", "/opt/homebrew",
            "/usr/local", "/private", "/private/var", "/private/tmp", "/private/var/folders", "/cores",
            "/Applications", "\(home)/Applications",
            home, "\(home)/Library", "\(home)/Library/Caches", "\(home)/Library/Application Support",
            "\(home)/Library/Developer", "\(home)/Library/Developer/Xcode", "\(home)/Library/Developer/CoreSimulator",
            "\(home)/Library/Preferences", "\(home)/Library/Containers", "\(home)/Library/Group Containers",
            "\(home)/Library/Logs", "\(home)/.cache", "\(home)/.config", "\(home)/.local", "\(home)/.Trash",
            "\(home)/Downloads", "\(home)/Public",
        ]
    }

    /// Checks one path against the deny list only.
    public func denyReason(for path: String, scope: Scope) -> String? {
        if !path.hasPrefix("/") { return "path is not absolute" }
        let components = path.split(separator: "/")
        if components.contains(".git") { return "inside a .git folder" }
        if components.contains("..") { return "path is not normalised" }

        // `/usr/local` is the one place under `/usr` that is not system-owned.
        for subtree in systemSubtrees where Self.isSame(path, orInside: subtree) {
            if subtree == "/usr", Self.isInside(path, "/usr/local") { continue }
            return "inside protected location \(subtree)"
        }

        if scope != .uninstall, scope != .analyze {
            for folder in applicationFolders where Self.isSame(path, orInside: folder) {
                return "inside \(folder); apps are only removed through Uninstall"
            }
        }

        switch scope {
        case .cache, .uninstall:
            for folder in mediaFolders + userContentFolders where Self.isSame(path, orInside: folder) {
                return "inside protected location \(folder)"
            }
        case .projectArtifact:
            for folder in mediaFolders where Self.isSame(path, orInside: folder) {
                return "inside protected location \(folder)"
            }
            // Code often lives in ~/Documents. A build artifact there is only
            // deletable when it sits inside a project folder, never the user
            // folder itself or something directly in it.
            for folder in userContentFolders where Self.isSame(path, orInside: folder) {
                let depth = path.dropFirst(folder.count).split(separator: "/").count
                if depth < 2 { return "too close to protected location \(folder)" }
            }
        case .analyze:
            for folder in mediaFolders + userContentFolders where path == folder {
                return "protected location \(folder)"
            }
        }

        for exact in protectedExact where path == exact {
            return "protected location \(exact)"
        }
        // Deleting an ancestor of a protected location would delete it too.
        for protected in systemSubtrees + mediaFolders + userContentFolders + protectedExact where Self.isInside(protected, path) {
            return "contains protected location \(protected)"
        }
        return nil
    }

    // MARK: Checks

    /// Checks a location a rule resolved to. Returns the real path to use as an allowlist root.
    public func evaluateRoot(_ path: String, scope: Scope) -> Verdict {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let reason = denyReason(for: standardized, scope: scope) {
            return .deny(reason, resolved: standardized)
        }
        guard let real = Self.realpath(standardized) else {
            return .deny("does not exist", resolved: standardized)
        }
        if real != standardized, let reason = denyReason(for: real, scope: scope) {
            return .deny("resolves to \(real): \(reason)", resolved: real)
        }
        if let reason = repositoryReason(for: real, scope: scope) {
            return .deny(reason, resolved: real)
        }
        return Verdict(allowed: true, reason: nil, resolved: real)
    }

    /// A folder with `.git` directly inside is somebody's working tree, not a cache.
    /// Only Analyze, where the user picks the folder by hand, may trash one.
    private func repositoryReason(for path: String, scope: Scope) -> String? {
        guard scope != .analyze else { return nil }
        return Fingerprint(path: path + "/.git") != nil ? "a git repository" : nil
    }

    /// Checks a path that is about to be deleted.
    /// - Parameter allowedRoots: real paths of the locations a rule resolved to.
    public func evaluate(_ path: String, allowedRoots: [String], scope: Scope) -> Verdict {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let real = Self.realpath(standardized) else {
            return .deny("does not exist", resolved: standardized)
        }

        // A symlink is never a delete target: removing it is pointless and
        // following it is how a cache rule would escape into user data.
        if let print = Fingerprint(path: standardized), print.isSymlink {
            return .deny("is a symbolic link", resolved: real)
        }

        guard allowedRoots.contains(where: { Self.isSame(real, orInside: $0) }) else {
            return .deny("outside every location its rule names", resolved: real)
        }
        // The path as written must agree with where it really is, apart from
        // links in its ancestors that the root already accounts for.
        let parent = (standardized as NSString).deletingLastPathComponent
        let realParent = Self.realpath(parent) ?? parent
        let rebuilt = realParent == "/" ? "/" + (standardized as NSString).lastPathComponent
            : realParent + "/" + (standardized as NSString).lastPathComponent
        if rebuilt != real {
            return .deny("path changed while resolving links", resolved: real)
        }

        if let reason = denyReason(for: standardized, scope: scope) ?? denyReason(for: real, scope: scope)
            ?? repositoryReason(for: real, scope: scope) {
            return .deny(reason, resolved: real)
        }
        return Verdict(allowed: true, reason: nil, resolved: real)
    }

    /// True when the path is still the object that was scanned.
    public func stillMatches(_ path: String, fingerprint: Fingerprint) -> Bool {
        guard let now = Fingerprint(path: path) else { return false }
        return now == fingerprint
    }

    // MARK: Path helpers

    public static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `path` is strictly inside `ancestor`.
    public static func isInside(_ path: String, _ ancestor: String) -> Bool {
        if ancestor == "/" { return path != "/" && path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    public static func isSame(_ path: String, orInside ancestor: String) -> Bool {
        path == ancestor || isInside(path, ancestor)
    }
}
