import Foundation
import SweepKit

/// Reads installer receipts with `pkgutil`. Nothing here changes the receipt database.
struct PackageReceipts: Sendable {
    struct Result: Sendable {
        /// Packages whose file list contains the app bundle.
        var packages: [String] = []
        /// Files those packages installed outside the bundle, with the package that owns each.
        var extras: [(path: String, package: String)] = []
        /// Files left out because the list was too long to review.
        var omitted = 0
    }

    let engine: SweepEngine

    /// A package installs thousands of files; only this many are offered for review.
    static let maxExtras = 200
    /// Receipts read per app. Each one costs two `pkgutil` runs.
    static let maxCandidates = 12

    /// Folder extensions that are one item to the user even though they are folders on disk.
    private static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "prefpane", "appex", "component", "saver", "qlgenerator",
        "mdimporter", "driver", "dext", "systemextension", "xpc", "service", "workflow", "action", "vst", "vst3",
    ]

    func receipts(for app: InstalledApp, matcher: LeftoverMatcher) async -> Result {
        var result = Result()
        guard let bundleID = matcher.bundleID, engine.context.runner.locate("pkgutil") != nil else { return result }
        let listed = await engine.run(["pkgutil", "--pkgs"], timeout: 20, reuseWithin: 300)
        guard listed.succeeded else { return result }

        // Only receipts from the same developer can be the app's installer.
        let vendor = BundleIdentifier.vendor(bundleID) ?? bundleID
        let candidates = listed.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { id in
                let lower = id.lowercased()
                return !BundleIdentifier.isApple(lower) && BundleIdentifier.isSame(lower, orChildOf: vendor)
            }
            .sorted { a, b in
                // Receipts named after the app first.
                let aClose = a.lowercased().contains(bundleID), bClose = b.lowercased().contains(bundleID)
                return aClose == bClose ? a < b : aClose
            }
            .prefix(Self.maxCandidates)

        let home = SafetyGuard.realpath(engine.context.home.path) ?? engine.context.home.path
        var extras: [String: String] = [:]
        for package in candidates {
            guard let files = await files(of: package), files.contains(app.path) else { continue }
            result.packages.append(package)
            for path in Self.reviewable(files, app: app, matcher: matcher) where extras[path] == nil {
                // A fixture run only ever sees its own home.
                if engine.context.isFixture, !SafetyGuard.isInside(path, home) { continue }
                if engine.safety.denyReason(for: path, scope: .uninstall) != nil { continue }
                extras[path] = package
            }
        }
        let sorted = extras.sorted { $0.key < $1.key }
        result.extras = sorted.prefix(Self.maxExtras).map { (path: $0.key, package: $0.value) }
        result.omitted = max(sorted.count - Self.maxExtras, 0)
        return result
    }

    /// Absolute paths of everything a package installed, or nil when the receipt cannot be read.
    private func files(of package: String) async -> Set<String>? {
        let info = await engine.run(["pkgutil", "--pkg-info", package], timeout: 20, reuseWithin: 300)
        guard info.succeeded else { return nil }
        var volume = "/"
        var location = ""
        for line in info.stdout.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("volume:") { volume = line.dropFirst("volume:".count).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("location:") { location = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces) }
        }
        guard let base = PathText.join(volume, location) else { return nil }

        let listed = await engine.run(["pkgutil", "--files", package], timeout: 30, reuseWithin: 300)
        guard listed.succeeded else { return nil }
        var result = Set<String>()
        for line in listed.stdout.split(whereSeparator: \.isNewline) {
            // Receipts hold relative paths; anything that climbs out of the install location is not trusted.
            guard !line.isEmpty, !line.hasPrefix("/"), let path = PathText.join(base, String(line)) else { continue }
            result.insert(path)
        }
        return result
    }

    /// The installed files worth showing: nothing inside the app, no shared
    /// folders, and bundle-like folders as one row instead of their contents.
    private static func reviewable(_ files: Set<String>, app: InstalledApp, matcher: LeftoverMatcher) -> [String] {
        var kept: [String] = []
        var collapsed: [String] = []
        for path in files.sorted() {
            if SafetyGuard.isSame(path, orInside: app.path) { continue }
            if collapsed.contains(where: { SafetyGuard.isInside(path, $0) }) { continue }
            guard let print = Fingerprint(path: path) else { continue }
            if print.isDirectory {
                // A plain folder may be shared with other software (`/usr/local/bin`, `/Library/Frameworks`).
                let name = (path as NSString).lastPathComponent
                let isBundle = bundleExtensions.contains((name as NSString).pathExtension.lowercased())
                let named = matcher.evidence(for: name, in: .applicationSupport) != nil
                guard isBundle || named else { continue }
                collapsed.append(path)
            }
            kept.append(path)
        }
        return kept
    }
}
