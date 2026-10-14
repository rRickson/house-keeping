import AppKit
import Foundation
import SweepKit

/// A browser whose cache folders the Clean tool knows.
struct JunkBrowser: Sendable {
    var id: String
    var name: String
    /// Process names and bundle identifiers that mean the browser is running.
    var processes: [String]
    var bundleIDs: [String]
    /// Cache folders, relative to `~/Library/Caches`. Never a profile folder.
    var cacheFolders: [String]

    static let all: [JunkBrowser] = [
        JunkBrowser(id: "safari", name: "Safari", processes: ["Safari", "com.apple.Safari"],
                    bundleIDs: ["com.apple.Safari"], cacheFolders: ["com.apple.Safari"]),
        JunkBrowser(id: "chrome", name: "Google Chrome", processes: ["Google Chrome", "com.google.Chrome"],
                    bundleIDs: ["com.google.Chrome"], cacheFolders: ["Google/Chrome", "com.google.Chrome"]),
        JunkBrowser(id: "arc", name: "Arc", processes: ["Arc", "company.thebrowser.Browser"],
                    bundleIDs: ["company.thebrowser.Browser"], cacheFolders: ["Arc", "company.thebrowser.Browser"]),
        JunkBrowser(id: "brave", name: "Brave", processes: ["Brave Browser", "com.brave.Browser"],
                    bundleIDs: ["com.brave.Browser"], cacheFolders: ["BraveSoftware/Brave-Browser", "com.brave.Browser"]),
        JunkBrowser(id: "firefox", name: "Firefox", processes: ["firefox", "Firefox", "org.mozilla.firefox"],
                    bundleIDs: ["org.mozilla.firefox"], cacheFolders: ["Firefox", "Mozilla", "org.mozilla.firefox"]),
        JunkBrowser(id: "edge", name: "Microsoft Edge", processes: ["Microsoft Edge", "com.microsoft.edgemac"],
                    bundleIDs: ["com.microsoft.edgemac"], cacheFolders: ["Microsoft Edge", "com.microsoft.edgemac"]),
    ]
}

/// Where each category lives and what belongs to it. The scanner uses this to
/// build the list; the cleaner uses it again to check every path it is handed,
/// so an entry can never widen what a category may delete.
struct JunkRules: Sendable {
    /// The real path of the home folder.
    let home: String
    private let context: SweepContext
    private let safety: SafetyGuard
    private let devOwned: Set<String>
    private let ledgerDirectory: String

    init(engine: SweepEngine) {
        home = engine.safety.home
        context = engine.context
        safety = engine.safety
        let log = engine.context.logDirectory.standardizedFileURL.path
        ledgerDirectory = SafetyGuard.realpath(log) ?? log

        var names = Self.devCacheFolders
        // Whatever the catalog places directly in ~/Library/Caches belongs to Dev Caches too.
        for item in engine.catalog.items {
            let patterns = item.locate.flatMap { $0.paths ?? [] } + (item.alsoPaths ?? [])
            for pattern in patterns {
                for prefix in ["~/Library/Caches/", home + "/Library/Caches/"] where pattern.hasPrefix(prefix) {
                    let first = pattern.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
                    if !first.isEmpty, !first.contains(where: { "*?{}[]".contains($0) }) { names.insert(first.lowercased()) }
                }
            }
        }
        names.remove("google")
        devOwned = names
    }

    // MARK: Locations

    var caches: String { home + "/Library/Caches" }
    var logs: String { home + "/Library/Logs" }
    var crashReports: String { logs + "/DiagnosticReports" }
    var mailDownloads: String { home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads" }
    var safariContainerCaches: String { home + "/Library/Containers/com.apple.Safari/Data/Library/Caches" }
    var downloads: String { home + "/Downloads" }
    var backups: String { home + "/Library/Application Support/MobileSync/Backup" }
    var trash: String { home + "/.Trash" }
    var sweepLogs: String { logs + "/House Keeping" }

    /// The folders whose contents a category may delete.
    func containers(for category: JunkCategory) -> [String] {
        switch category {
        case .userCaches: [caches]
        case .browserCaches: [caches, safariContainerCaches]
        case .logs: [logs]
        case .crashReports: [crashReports]
        case .dsStore: [home]
        case .mailDownloads: [mailDownloads]
        case .installers: [downloads]
        case .deviceBackups: [backups]
        case .trash: [trash]
        case .systemCaches: []
        }
    }

    /// A container counts only when it is a real folder reached without any
    /// symbolic link: a `~/Library/Caches` that points somewhere else is ignored.
    func isUsable(_ container: String) -> Bool {
        guard SafetyGuard.realpath(container) == container, let print = Fingerprint(path: container) else { return false }
        return print.isDirectory
    }

    /// The allowlist handed to the remover for a category.
    func allowedRoots(for category: JunkCategory) -> [String] {
        containers(for: category).filter(isUsable)
    }

    // MARK: Ownership

    /// Folders in `~/Library/Caches` that House Keeping's Dev Caches tool cleans.
    static let devCacheFolders: Set<String> = [
        "homebrew", "pip", "yarn", "node-gyp", "electron", "electron-builder", "ms-playwright", "cypress", "claude-cli-nodejs",
        "pypoetry", "pipenv", "cocoapods", "org.swift.swiftpm", "org.carthage.carthagekit", "jetbrains",
        "go-build", "composer", "deno", "typescript", "pnpm", "bun", "uv", "puppeteer", "pre-commit",
    ]

    /// Caches macOS guards itself; listing them would only produce refusals.
    static let systemManagedFolders: Set<String> = [
        "cloudkit", "familycircle", "com.apple.homekit", "com.apple.homed", "com.apple.containermanagerd",
        "com.apple.ap.adprivacyd", "com.apple.bird", "com.apple.cloudd", "com.apple.findmy.fmipcore",
        "com.apple.findmy.fmfcore",
    ]

    /// House Keeping never lists its own cache.
    static let ownFolders: Set<String> = {
        var names: Set<String> = ["com.rickson.housekeeping", "house keeping", "housekeeping", "sweep"]
        if let id = Bundle.main.bundleIdentifier { names.insert(id.lowercased()) }
        return names
    }()

    func isDevOwned(_ folder: String) -> Bool { devOwned.contains(folder.lowercased()) }

    /// True for a top-level folder of `~/Library/Caches` that belongs to one of the known browsers.
    func isBrowserOwned(_ folder: String) -> Bool {
        let name = folder.lowercased()
        for browser in JunkBrowser.all {
            for cacheFolder in browser.cacheFolders {
                let first = cacheFolder.split(separator: "/").first.map { $0.lowercased() } ?? ""
                // "Google" is shared with other Google apps and handled one level down.
                if first != "google", first == name { return true }
            }
            for bundleID in browser.bundleIDs where name == bundleID.lowercased() || name.hasPrefix(bundleID.lowercased() + ".") {
                return true
            }
        }
        return false
    }

    /// Why a folder of `~/Library/Caches` is not an app cache the Clean tool lists.
    func userCacheExclusion(folder: String, insideGoogle: Bool = false) -> String? {
        if folder.hasPrefix(".") { return "hidden" }
        let name = folder.lowercased()
        if insideGoogle {
            if name.hasPrefix("androidstudio") { return "cleaned by Dev Caches" }
            if name.hasPrefix("chrome") { return "a browser cache" }
            return nil
        }
        if name == "google" { return "a shared vendor folder" }
        if isDevOwned(folder) { return "cleaned by Dev Caches" }
        if isBrowserOwned(folder) { return "a browser cache" }
        if Self.systemManagedFolders.contains(name) { return "managed by macOS" }
        if Self.ownFolders.contains(name) { return "House Keeping's own cache" }
        return nil
    }

    /// The browser a cache path belongs to, if it is one of the known cache folders.
    func browser(owning path: String) -> JunkBrowser? {
        for browser in JunkBrowser.all {
            for folder in browser.cacheFolders where path == caches + "/" + folder {
                return browser
            }
        }
        if Self.parent(of: path) == safariContainerCaches { return JunkBrowser.all.first { $0.id == "safari" } }
        return nil
    }

    /// True for anything that is, holds or sits inside the folder with House Keeping's ledger.
    func touchesLedger(_ path: String) -> Bool {
        for protected in Set([sweepLogs, ledgerDirectory]) {
            if SafetyGuard.isSame(path, orInside: protected) || SafetyGuard.isInside(protected, path) { return true }
        }
        return false
    }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso", "zip"]

    // MARK: Cleaner checks

    /// The reason a path does not belong to its category, or nil when it does.
    /// Runs in the cleaner on every path, whatever the entry claims.
    func refusal(for path: String, in category: JunkCategory) -> String? {
        // Checked as text: no empty, "." or ".." parts and no trailing slash.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return "path is not normalised"
        }
        let parent = Self.parent(of: path)
        let name = (path as NSString).lastPathComponent
        let outside = "not part of \(category.title)"

        switch category {
        case .userCaches:
            if parent == caches { return userCacheExclusion(folder: name) }
            if parent == caches + "/Google" { return userCacheExclusion(folder: name, insideGoogle: true) }
            return outside
        case .browserCaches:
            return browser(owning: path) == nil ? outside : nil
        case .logs:
            guard parent == logs else { return outside }
            if name == "DiagnosticReports" { return "listed under Crash reports" }
            if touchesLedger(path) { return "holds House Keeping's own history" }
            return nil
        case .crashReports:
            return parent == crashReports ? nil : outside
        case .dsStore:
            guard name == ".DS_Store", SafetyGuard.isInside(path, home) else { return outside }
            guard let print = Fingerprint(path: path) else { return nil }
            return print.isDirectory || print.isSymlink ? "not a .DS_Store file" : nil
        case .mailDownloads:
            return parent == mailDownloads ? nil : outside
        case .installers:
            guard parent == downloads else { return outside }
            return Self.installerExtensions.contains((name as NSString).pathExtension.lowercased()) ? nil : "not an installer"
        case .deviceBackups:
            return parent == backups ? nil : outside
        case .trash:
            return parent == trash ? nil : outside
        case .systemCaches:
            return "cleaned by the helper only"
        }
    }

    // MARK: Running apps

    /// "Safari is running" when the app an entry belongs to is open, else nil.
    func runningReason(for entry: JunkEntry, processes: [RunningProcess]) -> String? {
        switch entry.category {
        case .userCaches:
            for target in entry.targets {
                let folder = (target.path as NSString).lastPathComponent
                if isRunning(cacheFolder: folder, processes: processes) { return "\(entry.name) is running" }
            }
            return nil
        case .browserCaches:
            for target in entry.targets {
                guard let browser = browser(owning: target.path) else { continue }
                if processes.contains(where: { process in browser.processes.contains { process.matches($0) } }) {
                    return "\(browser.name) is running"
                }
            }
            return nil
        case .mailDownloads:
            return processes.contains { $0.matches("Mail") || $0.matches("com.apple.mail") } ? "Mail is running" : nil
        default:
            return nil
        }
    }

    /// True when the app that owns a cache folder is running. Matches the folder
    /// name as a bundle identifier, an app name or a process name.
    func isRunning(cacheFolder folder: String, processes: [RunningProcess]) -> Bool {
        let pretty = JunkNaming.appName(fromFolder: folder)
        let lowered = folder.lowercased()
        for process in processes {
            if process.matches(folder) || process.matches(pretty) { return true }
            // "com.example.App.helper-cache" belongs to the running "com.example.App".
            if let bundleID = process.bundleID?.lowercased(), bundleID.split(separator: ".").count >= 3,
               lowered.hasPrefix(bundleID + ".") {
                return true
            }
        }
        return false
    }

    // MARK: Helpers

    static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}

/// Turns cache and log folder names into something a person would recognise.
enum JunkNaming {
    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "co", "me", "us", "uk", "de", "fr", "jp", "ch", "se", "nl",
        "it", "es", "at", "au", "ca", "cn", "ru", "pl", "tv", "ai", "edu", "gov", "info", "company", "is", "fm",
    ]

    /// Trailing bundle-identifier parts that say nothing about which app it is.
    private static let genericParts: Set<String> = [
        "client", "app", "mac", "macos", "osx", "desktop", "helper", "agent", "daemon", "main", "macapp",
        "application", "launcher", "updater", "xos",
    ]

    /// True for names shaped like `com.example.App`.
    static func isBundleID(_ name: String) -> Bool {
        guard !name.contains(" ") else { return false }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts.contains(where: \.isEmpty), let first = parts.first else { return false }
        // Two-letter country codes ("jp.co.example") count from three parts up.
        if parts.count >= 3, first.count == 2 { return true }
        return topLevelDomains.contains(first.lowercased())
    }

    /// A readable name derived from the folder name alone: `com.spotify.client` → "Spotify".
    static func appName(fromFolder folder: String) -> String {
        guard isBundleID(folder) else { return folder }
        var parts = folder.split(separator: ".").map(String.init)
        parts.removeFirst()
        while parts.count > 1, let last = parts.last, genericParts.contains(last.lowercased()) {
            parts.removeLast()
        }
        guard let last = parts.last, !last.isEmpty else { return folder }
        // "apple.Safari" → "Safari"; keep the capitals an app chose for itself.
        if last == last.lowercased() { return last.prefix(1).uppercased() + last.dropFirst() }
        return last
    }

    /// The installed app's own name when the folder is the bundle identifier of
    /// an app on this Mac; otherwise the name derived from the folder.
    static func displayName(forFolder folder: String, lookUpInstalledApps: Bool) -> String {
        if lookUpInstalledApps, isBundleID(folder),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folder) {
            let name = url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        return appName(fromFolder: folder)
    }
}
