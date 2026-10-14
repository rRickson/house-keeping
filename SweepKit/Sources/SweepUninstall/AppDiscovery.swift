import Foundation
import SweepKit

/// Security and antivirus products Sweep lists but never removes.
public enum SecurityCatalog {
    private static func vendor(_ name: String, _ url: String) -> SecurityVendor {
        SecurityVendor(name: name, supportURL: URL(string: url) ?? URL(fileURLWithPath: "/"))
    }

    /// Lowercased bundle-identifier prefixes and the vendor behind each.
    static let prefixes: [(prefix: String, vendor: SecurityVendor)] = [
        ("com.malwarebytes.", vendor("Malwarebytes", "https://support.malwarebytes.com")),
        ("com.symantec.", vendor("Norton", "https://support.norton.com")),
        ("com.norton.", vendor("Norton", "https://support.norton.com")),
        ("com.mcafee.", vendor("McAfee", "https://www.mcafee.com/support")),
        ("com.sophos.", vendor("Sophos", "https://support.sophos.com")),
        ("com.bitdefender.", vendor("Bitdefender", "https://www.bitdefender.com/consumer/support/")),
        ("com.kaspersky.", vendor("Kaspersky", "https://support.kaspersky.com")),
        ("com.eset.", vendor("ESET", "https://support.eset.com")),
        ("com.avast.", vendor("Avast", "https://support.avast.com")),
        ("com.avg.", vendor("AVG", "https://support.avg.com")),
        ("com.avira.", vendor("Avira", "https://support.avira.com")),
        ("com.intego.", vendor("Intego", "https://www.intego.com/support")),
        ("com.trendmicro.", vendor("Trend Micro", "https://helpcenter.trendmicro.com")),
        ("com.crowdstrike.", vendor("CrowdStrike", "https://www.crowdstrike.com")),
        ("com.sentinelone.", vendor("SentinelOne", "https://www.sentinelone.com")),
        ("com.carbonblack.", vendor("Carbon Black", "https://www.broadcom.com/support")),
        ("com.vmware.carbonblack.", vendor("Carbon Black", "https://www.broadcom.com/support")),
        ("com.cylance.", vendor("Cylance", "https://www.blackberry.com/us/en/support")),
        ("com.paloaltonetworks.", vendor("Palo Alto Networks", "https://support.paloaltonetworks.com")),
        ("com.microsoft.wdav", vendor("Microsoft Defender", "https://learn.microsoft.com/defender-endpoint/mac-resources")),
        ("com.jamf.protect", vendor("Jamf Protect", "https://www.jamf.com/support/")),
        ("com.webroot.", vendor("Webroot", "https://www.webroot.com/us/en/support")),
        ("com.f-secure.", vendor("F-Secure", "https://www.f-secure.com/en/support")),
        ("com.withsecure.", vendor("WithSecure", "https://www.withsecure.com/en/support")),
        ("com.zscaler.", vendor("Zscaler", "https://help.zscaler.com")),
        ("com.netskope.", vendor("Netskope", "https://support.netskope.com")),
        ("com.huntress.", vendor("Huntress", "https://support.huntress.io")),
        ("com.pandasecurity.", vendor("Panda Security", "https://www.pandasecurity.com/en/support/")),
        ("com.drweb.", vendor("Dr.Web", "https://support.drweb.com")),
        ("com.clamxav.", vendor("ClamXAV", "https://www.clamxav.com/support")),
        ("at.obdev.littlesnitch", vendor("Little Snitch", "https://obdev.at/support")),
        ("com.objective-see.", vendor("Objective-See", "https://objective-see.org")),
    ]

    /// The vendor whose uninstaller must be used for this bundle identifier, if it is security software.
    public static func vendor(forBundleID bundleID: String) -> SecurityVendor? {
        let lower = bundleID.lowercased()
        return prefixes.first { lower.hasPrefix($0.prefix) }?.vendor
    }
}

/// Finds the apps in the applications folders.
struct AppDiscovery: Sendable {
    /// An app and, when it is not shown, why.
    struct Found: Sendable {
        var app: InstalledApp
        var hiddenReason: String?
    }

    let context: SweepContext
    let environment: UninstallEnvironment

    /// Apple apps that do not ship with macOS and can be removed like any other.
    private static let removableAppleApps: Set<String> = [
        "com.apple.dt.xcode", "com.apple.iwork.pages", "com.apple.iwork.numbers", "com.apple.iwork.keynote",
        "com.apple.garageband10", "com.apple.imovieapp", "com.apple.finalcut", "com.apple.logic10",
        "com.apple.motionapp", "com.apple.compressor", "com.apple.mainstage3", "com.apple.testflight",
        "com.apple.developer", "com.apple.transporterapp", "com.apple.configurator.ui", "com.apple.remotedesktop",
        "com.apple.sfsymbols", "com.apple.realitycomposerpro", "com.apple.appstoreconnect",
    ]

    /// Every app bundle in the applications folders and one level of subfolders.
    func bundlePaths() -> [String] {
        let manager = FileManager.default
        let home = SafetyGuard.realpath(context.home.path) ?? context.home.path
        var result: [String] = []
        var seen = Set<String>()

        func add(_ path: String) {
            if seen.insert(path).inserted { result.append(path) }
        }

        for folder in environment.applicationFolders {
            // A fixture run must never look at the real machine, whatever was injected.
            guard let written = PathText.clean(folder) else { continue }
            if context.isFixture, !SafetyGuard.isInside(written, home), !SafetyGuard.isInside(written, context.home.path) { continue }
            guard let root = SafetyGuard.realpath(written) else { continue }
            if context.isFixture, !SafetyGuard.isInside(root, home) { continue }
            let names = ((try? manager.contentsOfDirectory(atPath: root)) ?? []).sorted()
            for name in names where !name.hasPrefix(".") {
                let path = root + "/" + name
                if name.hasSuffix(".app") {
                    add(path)
                    continue
                }
                // Utilities, Setapp, vendor folders. Links are not followed.
                guard let print = Fingerprint(path: path), print.isDirectory, !print.isSymlink else { continue }
                let inner = ((try? manager.contentsOfDirectory(atPath: path)) ?? []).sorted()
                for child in inner where child.hasSuffix(".app") && !child.hasPrefix(".") {
                    add(path + "/" + child)
                }
            }
        }
        return result
    }

    /// Reads every bundle. Hidden apps are returned too, so callers know what is installed.
    func discover(casks: CaskIndex = CaskIndex()) -> [Found] {
        let running = context.processes.runningProcesses()
        return bundlePaths().compactMap { path in
            read(path, running: running, casks: casks)
        }.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    func read(_ path: String, running: [RunningProcess], casks: CaskIndex) -> Found? {
        guard let print = Fingerprint(path: path) else { return nil }
        let fileName = (path as NSString).lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        let info = Self.infoDictionary(bundle: path)

        func string(_ key: String) -> String? {
            guard let value = info?[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let bundleID = string("CFBundleIdentifier")
        var names = [baseName]
        for key in ["CFBundleName", "CFBundleDisplayName"] {
            if let name = string(key), !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                names.append(name)
            }
        }

        var app = InstalledApp(
            path: path,
            name: baseName,
            bundleID: bundleID,
            version: string("CFBundleShortVersionString") ?? string("CFBundleVersion"),
            iconPath: Self.iconPath(bundle: path, info: info),
            lastOpened: environment.lastUsed.lastUsedDate(ofAppAt: path),
            isRunning: Self.isRunning(path: path, bundleID: bundleID, names: names, in: running),
            needsAdmin: environment.requiresAdmin(path),
            fingerprint: print,
            names: names
        )
        app.caskToken = casks.token(forAppAt: path)
        if let bundleID, let vendor = SecurityCatalog.vendor(forBundleID: bundleID) {
            app.removability = .vendorUninstaller(vendor)
        }
        return Found(app: app, hiddenReason: hiddenReason(for: app))
    }

    private func hiddenReason(for app: InstalledApp) -> String? {
        let real = SafetyGuard.realpath(app.path) ?? app.path
        if SafetyGuard.isSame(real, orInside: "/System") { return "part of macOS" }
        if let id = app.bundleID?.lowercased() {
            if environment.ownBundleIDs.contains(where: { $0.lowercased() == id }) { return "Sweep itself" }
            if BundleIdentifier.isApple(id), !Self.removableAppleApps.contains(id),
               Fingerprint(path: app.path + "/Contents/_MASReceipt/receipt") == nil {
                return "ships with macOS"
            }
        }
        if !context.isFixture, real == Bundle.main.bundlePath { return "Sweep itself" }
        return nil
    }

    // MARK: Bundle reading

    static func infoDictionary(bundle: String) -> [String: Any]? {
        var candidates = [bundle + "/Contents/Info.plist"]
        // iOS apps on Apple silicon keep the real bundle inside `Wrapper`.
        let wrapper = bundle + "/Wrapper"
        if let inner = try? FileManager.default.contentsOfDirectory(atPath: wrapper) {
            candidates += inner.filter { $0.hasSuffix(".app") }.sorted().map { wrapper + "/" + $0 + "/Info.plist" }
        }
        for candidate in candidates {
            guard let data = FileManager.default.contents(atPath: candidate),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            return plist
        }
        return nil
    }

    private static func iconPath(bundle: String, info: [String: Any]?) -> String? {
        guard let name = (info?["CFBundleIconFile"] as? String) ?? (info?["CFBundleIconName"] as? String), !name.isEmpty,
              !name.contains("/") else { return nil }
        let file = (name as NSString).pathExtension.isEmpty ? name + ".icns" : name
        let path = bundle + "/Contents/Resources/" + file
        return Fingerprint(path: path) != nil ? path : nil
    }

    static func isRunning(path: String, bundleID: String?, names: [String], in processes: [RunningProcess]) -> Bool {
        let inside = path + "/"
        return processes.contains { process in
            if process.path.hasPrefix(inside) { return true }
            if let bundleID, let running = process.bundleID, running.caseInsensitiveCompare(bundleID) == .orderedSame { return true }
            // A process list without paths (tests, fixture runs) is matched by name.
            if process.path.isEmpty {
                if let bundleID, process.name.caseInsensitiveCompare(bundleID) == .orderedSame { return true }
                return names.contains { process.name.caseInsensitiveCompare($0) == .orderedSame }
            }
            return false
        }
    }

    /// Bundle identifiers of the helpers, extensions and login items inside an app.
    static func embeddedBundleIDs(in bundle: String) -> [String] {
        let folders = [
            "Contents/Library/LoginItems", "Contents/Library/SystemExtensions", "Contents/Library/LaunchServices",
            "Contents/PlugIns", "Contents/Extensions", "Contents/XPCServices", "Contents/Helpers", "Contents/MacOS",
            "Contents/Frameworks", "Contents/Resources", "Contents/SharedSupport", "Contents/Applications",
        ]
        let extensions: Set<String> = ["app", "appex", "xpc", "systemextension", "bundle", "plugin"]
        var result: [String] = []
        for folder in folders {
            let directory = bundle + "/" + folder
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where extensions.contains((name as NSString).pathExtension.lowercased()) {
                if let id = infoDictionary(bundle: directory + "/" + name)?["CFBundleIdentifier"] as? String, !id.isEmpty {
                    result.append(id)
                }
            }
        }
        return result
    }
}
