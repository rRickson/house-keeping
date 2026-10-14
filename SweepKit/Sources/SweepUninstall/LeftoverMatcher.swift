import Foundation
import SweepKit

/// Plain-text path handling. `URL.standardizedFileURL` is avoided on purpose:
/// it rewrites `/private/var` to `/var`, which no longer equals the real path.
enum PathText {
    /// An absolute path without `.`, `..` or doubled slashes, or nil when the text is not one.
    static func clean(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ base: String, _ relative: String) -> String? {
        clean(base + "/" + relative)
    }
}

/// Helpers for reverse-DNS identifiers. Everything compares lowercased.
enum BundleIdentifier {
    static func components(_ id: String) -> [Substring] {
        id.split(separator: ".", omittingEmptySubsequences: false)
    }

    /// `com.apple.*` and Apple's group identifiers. Never matched, never proposed.
    static func isApple(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "com.apple" || lower.hasPrefix("com.apple.") || lower.contains(".com.apple.")
            || lower.hasSuffix(".com.apple") || lower.hasPrefix("systemgroup.com.apple")
    }

    /// True when `name` is `id` itself or `id` followed by a dot and more.
    static func isSame(_ name: String, orChildOf id: String) -> Bool {
        name == id || name.hasPrefix(id + ".")
    }

    /// True when the two identifiers are the same or one is nested under the other.
    static func areRelated(_ a: String, _ b: String) -> Bool {
        isSame(a, orChildOf: b) || isSame(b, orChildOf: a)
    }

    /// The first two components: `com.foo` for `com.foo.App`.
    static func vendor(_ id: String) -> String? {
        let parts = components(id)
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    /// Identifiers that many unrelated apps share because nobody changed a template.
    static let generic: Set<String> = [
        "com.github.electron", "com.electron.app", "com.github.atom", "org.python.python",
        "com.yourcompany.app", "com.mycompany.app", "com.example.app", "com.company.app",
        "org.qt-project.qt", "com.trolltech.qt", "org.gnu.emacs", "net.java.openjdk.java",
    ]

    /// Identifiers of command-line tools, runtimes and system services. They
    /// look like apps' but no app bundle ever answers to them.
    static let toolPrefixes = [
        "org.cups.", "org.swift.", "org.llvm.", "org.python.", "org.gnu.", "org.graalvm.", "org.openjdk.", "net.java.",
        "com.oracle.", "org.freedesktop.", "org.gradle.", "com.android.", "org.mozilla.nss", "org.x.", "org.xquartz.",
        "com.plausiblelabs.", "org.sparkle-project.", "com.github.", "io.sentry.",
    ]

    /// True for identifiers that belong to tools rather than apps: a known prefix or a `cli` ending.
    static func looksLikeTool(_ id: String) -> Bool {
        let lower = id.lowercased()
        if toolPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        guard let last = components(lower).last else { return false }
        return last == "cli" || last.hasSuffix("-cli") || last == "daemon" || last == "agent"
    }

    private static let topLevel: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "co", "me", "us", "uk", "de", "fr", "jp", "ch", "se", "nl", "it", "es",
        "ca", "au", "at", "be", "eu", "xyz", "tv", "ai", "im", "cc", "info", "edu", "gov", "sh", "so", "to", "fm", "pl",
        "cz", "ru", "no", "dk", "fi", "br", "in", "cn", "kr", "tw", "hk", "nz", "ie", "pt", "gr", "hu", "ro", "ua",
        "tech", "software", "tools", "studio", "cloud", "design", "page", "one", "pro", "biz", "mobi", "name", "ly",
    ]

    /// A name that can only be a bundle identifier: a known top-level domain
    /// first, then at least two more parts of letters, digits, `-` and `_`.
    static func looksReverseDNS(_ name: String) -> Bool {
        let parts = components(name.lowercased())
        guard parts.count >= 3, parts.count <= 8, let first = parts.first, topLevel.contains(String(first)) else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 63 else { return false }
            guard part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return false }
        }
        // The developer's part must be a word, not a version number.
        return parts[1].contains(where: \.isLetter) && parts[1].count >= 2
    }
}

/// Decides whether a file or folder name belongs to one app. Matching is
/// deliberately narrow: a missed leftover costs a few megabytes, a wrong match
/// costs somebody's data.
struct LeftoverMatcher: Sendable {
    /// Lowercased bundle identifier, or nil when it is unusable for matching.
    let bundleID: String?
    /// Identifiers with three or more parts may own `<id>.<anything>`; shorter
    /// ones only the exact name and a few well-known suffixes.
    private let allowsAnyChild: Bool
    /// Lowercased names that are distinctive enough to match on.
    let names: [String]
    /// Lowercased identifiers of the other installed apps.
    private let otherBundleIDs: [String]

    /// Suffixes macOS itself adds to a bundle identifier.
    static let systemSuffixes = [".plist.lockfile", ".plist", ".savedstate", ".binarycookies"]

    /// For a name that starts with the app's identifier and continues, the
    /// longer identifiers it could stand for, shortest first: for
    /// `com.foo.App.Pro.helper.plist` and `com.foo.App`, `com.foo.App.Pro`
    /// and `com.foo.App.Pro.helper`. Empty when the name is the identifier itself.
    func longerIdentifiers(in name: String) -> [String] {
        guard let bundleID else { return [] }
        var text = name
        let lower = name.lowercased()
        if let suffix = Self.systemSuffixes.first(where: { lower.hasSuffix($0) }) { text.removeLast(suffix.count) }
        var parts = BundleIdentifier.components(text)
        if let last = parts.last, last.count == 36, UUID(uuidString: String(last)) != nil { parts.removeLast() }
        let own = BundleIdentifier.components(bundleID).count
        guard parts.count > own, parts.prefix(own).joined(separator: ".").lowercased() == bundleID else { return [] }
        return ((own + 1)...parts.count).map { parts.prefix($0).joined(separator: ".") }
    }

    /// Names too common to say anything about who owns a folder.
    static let genericNames: Set<String> = [
        "helper", "update", "updater", "updates", "install", "installer", "uninstall", "uninstaller", "data", "cache",
        "caches", "logs", "support", "library", "preferences", "settings", "config", "apple", "google", "microsoft",
        "adobe", "mozilla", "common", "shared", "default", "temp", "system", "user", "users", "application",
        "applications", "desktop", "documents", "downloads", "plugins", "extensions", "services", "backup", "backups",
        "crash", "crashes", "crashreporter", "diagnosticreports", "java", "python", "node", "electron", "launcher",
        "agent", "daemon", "service", "driver", "drivers", "fonts", "icons", "mail", "notes", "music", "photos",
        "calendar", "contacts", "messages", "terminal", "utilities", "tools", "test", "demo", "sample", "untitled",
        "games", "game", "steam", "sweep", "trash", "homebrew", "developer", "xcode", "docker", "containers",
    ]

    static func isDistinctive(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.count >= 4, trimmed.contains(where: \.isLetter) else { return false }
        guard !trimmed.hasPrefix("."), !trimmed.contains("/") else { return false }
        return !genericNames.contains(trimmed) && !BundleIdentifier.isApple(trimmed)
    }

    /// - Parameters:
    ///   - otherBundleIDs: identifiers of every other installed app, so that
    ///     `com.foo.App` never claims what belongs to an installed `com.foo.App.Pro`.
    ///   - sharedNames: lowercased names that more than one installed app uses.
    init(app: InstalledApp, otherBundleIDs: [String], sharedNames: Set<String> = []) {
        var usable: String?
        var anyChild = false
        if let id = app.bundleID?.lowercased(), !BundleIdentifier.isApple(id), !BundleIdentifier.generic.contains(id) {
            let parts = BundleIdentifier.components(id)
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }), id.count >= 6 {
                usable = id
                anyChild = parts.count >= 3
            }
        }
        bundleID = usable
        allowsAnyChild = anyChild
        // Apple's own apps keep their data where name matching would be a guess.
        let isAppleApp = app.bundleID.map(BundleIdentifier.isApple) ?? false
        var seen = Set<String>()
        names = isAppleApp ? [] : app.names.map { $0.lowercased() }.filter { name in
            Self.isDistinctive(name) && !sharedNames.contains(name) && seen.insert(name).inserted
        }
        self.otherBundleIDs = otherBundleIDs.map { $0.lowercased() }.filter { $0 != usable }
    }

    /// The evidence that `name`, found directly inside `location`, belongs to the app; nil when it does not.
    func evidence(for name: String, in location: LeftoverLocation) -> UninstallItem.Evidence? {
        let lower = name.lowercased()
        guard !lower.hasPrefix("."), !BundleIdentifier.isApple(lower) else { return nil }

        if let bundleID, Self.owns(bundleID, name: lower, in: location, anyChild: allowsAnyChild) {
            // A longer identifier of another installed app that also fits is the real owner.
            let claimedElsewhere = otherBundleIDs.contains { other in
                other.count > bundleID.count
                    && Self.owns(other, name: lower, in: location, anyChild: BundleIdentifier.components(other).count >= 3)
            }
            return claimedElsewhere ? nil : .bundleID
        }
        if location.allowsNameMatch, names.contains(lower) {
            return .appName
        }
        return nil
    }

    private static func owns(_ id: String, name: String, in location: LeftoverLocation, anyChild: Bool) -> Bool {
        if location == .groupContainers {
            // `group.com.foo.App`, `TEAMID.com.foo.App`: the identifier comes last.
            return name == id || name.hasSuffix("." + id)
        }
        if name == id { return true }
        if anyChild { return name.hasPrefix(id + ".") }
        return systemSuffixes.contains { name == id + $0 }
    }
}
