import Foundation
import SweepKit
import SweepTestSupport
import Testing
@testable import SweepUninstall

// Every test runs against a throwaway FixtureHome. Nothing here reads or
// changes the real applications folders, the real Dock or real tools.

@Suite struct DiscoveryTests {
    @Test func findsAppsWithTheirMetadata() async throws {
        let fixture = try FixtureHome()
        let foo = try fixture.app("Foo Editor", bundleID: "com.foo.App", version: "2.1", info: ["CFBundleIconFile": "AppIcon"])
        try fixture.write("Applications/Foo Editor.app/Contents/Resources/AppIcon.icns", bytes: 8192)
        try fixture.app("Bar", bundleID: "org.bar.Bar", in: "Applications/Utilities")
        try fixture.write("Applications/readme.txt")
        let opened = Date(timeIntervalSince1970: 1_700_000_000)

        let uninstaller = fixture.uninstaller(processes: ["Foo Editor"]) {
            $0.lastUsed = FixedLastUsed(dates: [foo: opened])
        }
        let apps = await uninstaller.installedApps()
        #expect(apps.map(\.name) == ["Bar", "Foo Editor"])

        let app = try #require(apps.last)
        #expect(app.path == foo)
        #expect(app.bundleID == "com.foo.App")
        #expect(app.version == "2.1")
        #expect(app.iconPath == foo + "/Contents/Resources/AppIcon.icns")
        #expect(app.lastOpened == opened)
        #expect(app.isRunning)
        #expect(app.removability == .removable)
        #expect(app.caskToken == nil)
        #expect(!app.needsAdmin)
        #expect(await uninstaller.size(of: app) >= 64 * 1024 + 8192)

        let bar = try #require(apps.first)
        #expect(bar.lastOpened == nil)
        #expect(!bar.isRunning)
        #expect(bar.path == fixture.path("Applications/Utilities/Bar.app"))
    }

    @Test func fixtureEngineNeverLooksAtTheRealMachine() async throws {
        let fixture = try FixtureHome()
        try fixture.app("Foo", bundleID: "com.foo.App")
        let engine = fixture.engine(items: [])

        let standard = UninstallEnvironment.standard(for: engine.context)
        #expect(standard.applicationFolders == [fixture.path("Applications")])
        #expect(standard.systemLibrary == nil)
        #expect(standard.caskrooms.isEmpty)
        #expect(standard.dock is NoDockEditor)
        #expect(standard.terminator is NoAppTerminator)

        // Even when real locations are injected by mistake, a fixture run skips them.
        let careless = fixture.uninstaller {
            $0.applicationFolders = ["/Applications", "/System/Applications", fixture.path("Applications")]
            $0.systemLibrary = "/Library"
        }
        let apps = await careless.installedApps()
        #expect(apps.map(\.path) == [fixture.path("Applications/Foo.app")])
        #expect(careless.scanDirectory(.systemLaunchDaemons) == nil)
        let plan = await careless.plan(for: try #require(apps.first))
        #expect(plan.items.allSatisfy { $0.path.hasPrefix(fixture.home.path + "/") })
    }

    @Test func hidesSystemAppsAndSweepItself() async throws {
        let fixture = try FixtureHome()
        try fixture.app("Safari", bundleID: "com.apple.Safari")
        try fixture.app("Calculator", bundleID: "com.apple.calculator")
        try fixture.app("Xcode", bundleID: "com.apple.dt.Xcode")
        try fixture.app("Store App", bundleID: "com.apple.SomeStoreApp")
        try fixture.write("Applications/Store App.app/Contents/_MASReceipt/receipt")
        try fixture.app("House Keeping", bundleID: "com.rickson.housekeeping")
        try fixture.app("Foo", bundleID: "com.foo.App")

        let uninstaller = fixture.uninstaller()
        let names = await uninstaller.installedApps().map(\.name)
        #expect(names == ["Foo", "Store App", "Xcode"])

        // Hidden apps are still known, so their leftovers are never called orphans.
        let all = await uninstaller.inventory(refresh: true)
        #expect(all.count == 6)
        #expect(all.first { $0.app.name == "Safari" }?.hiddenReason == "ships with macOS")
        #expect(all.first { $0.app.name == "House Keeping" }?.hiddenReason == "House Keeping itself")
    }

    @Test func securityAppsAreListedButNeverRemoved() async throws {
        let fixture = try FixtureHome()
        let path = try fixture.app("Malwarebytes", bundleID: "com.malwarebytes.mbam.frontend.application")
        try fixture.write("Library/Application Support/com.malwarebytes.mbam.frontend.application/db")
        try fixture.write("Library/Preferences/com.malwarebytes.mbam.frontend.application.plist")

        let uninstaller = fixture.uninstaller()
        let app = try #require(await uninstaller.app(named: "Malwarebytes"))
        guard case .vendorUninstaller(let vendor) = app.removability else {
            Issue.record("security app should not be removable")
            return
        }
        #expect(vendor.name == "Malwarebytes")
        #expect(vendor.supportURL.scheme == "https")

        let plan = await uninstaller.plan(for: app)
        #expect(plan.items.map(\.path) == [path])

        let before = fixture.userFiles()
        let report = await uninstaller.uninstall(plan, selecting: Set(plan.items.map(\.id)))
        #expect(report.stoppedReason != nil)
        #expect(report.operation.entries.isEmpty)
        #expect(fixture.userFiles() == before)
        #expect(fixture.trashed().isEmpty)
    }

    @Test func knownSecurityVendors() {
        #expect(SecurityCatalog.vendor(forBundleID: "com.crowdstrike.falcon.App")?.name == "CrowdStrike")
        #expect(SecurityCatalog.vendor(forBundleID: "com.microsoft.wdav")?.name == "Microsoft Defender")
        #expect(SecurityCatalog.vendor(forBundleID: "com.microsoft.Word") == nil)
        #expect(SecurityCatalog.vendor(forBundleID: "com.foo.App") == nil)
    }
}

@Suite struct LeftoverTests {
    /// A home with one app, every kind of leftover, and near misses that must be left alone.
    private func populated() throws -> (fixture: FixtureHome, expected: Set<String>, nearMisses: [String]) {
        let fixture = try FixtureHome()
        try fixture.app("Foo Editor", bundleID: "com.foo.App")
        try fixture.app("Foo Editor Pro", bundleID: "com.foo.App.Pro")

        let matches = [
            "Library/Application Support/com.foo.App/data.db",
            "Library/Application Support/Foo Editor/projects.json",
            "Library/Caches/com.foo.App/blob",
            "Library/Caches/com.foo.App.ShipIt/update.zip",
            "Library/Caches/foo editor/thumbs",
            "Library/Preferences/com.foo.App.plist",
            "Library/Preferences/com.foo.App.helper.plist",
            "Library/Preferences/ByHost/com.foo.App.43CA8902-DB90-5A35-B3C9-62F44D84A1E3.plist",
            "Library/Logs/Foo Editor/today.log",
            "Library/Logs/com.foo.App.log",
            "Library/Containers/com.foo.App/Data/file",
            "Library/Containers/com.foo.App.ShareExtension/Data/file",
            "Library/Group Containers/group.com.foo.App/shared.db",
            "Library/Group Containers/ABCDE12345.com.foo.App/shared.db",
            "Library/HTTPStorages/com.foo.App/httpstorages.sqlite",
            "Library/HTTPStorages/com.foo.App.binarycookies",
            "Library/WebKit/com.foo.App/WebsiteData/x",
            "Library/Saved Application State/com.foo.App.savedState/windows.plist",
            "Library/LaunchAgents/com.foo.App.agent.plist",
            "SystemLibrary/LaunchAgents/com.foo.App.plist",
            "SystemLibrary/LaunchDaemons/com.foo.App.daemon.plist",
            "SystemLibrary/PrivilegedHelperTools/com.foo.App.helper",
        ]
        let nearMisses = [
            "Library/Application Support/com.foo.AppOther/data.db",
            "Library/Application Support/com.foo/shared.db",
            "Library/Application Support/Foo/data",
            "Library/Application Support/Foo Editor 2/data",
            "Library/Application Support/Foo Editor Backup/data",
            "Library/Caches/com.foo.AppOther/blob",
            "Library/Caches/com.foo.App-nightly/blob",
            "Library/Caches/org.foo.App/blob",
            "Library/Preferences/com.foo.AppOther.plist",
            "Library/Preferences/com.foo.plist",
            "Library/Preferences/Foo Editor.plist",
            "Library/Preferences/xcom.foo.App.plist",
            // Belongs to the installed Pro edition, whose identifier is longer.
            "Library/Preferences/com.foo.App.Pro.plist",
            "Library/Caches/com.foo.App.Pro/blob",
            "Library/Containers/Foo Editor/Data/file",
            "Library/Group Containers/group.com.foo.App.shared/db",
            "Library/Group Containers/group.com.foo.AppOther/db",
            "Library/Group Containers/ABCDE12345.xcom.foo.App/db",
            "Library/Saved Application State/com.foo.AppOther.savedState/windows.plist",
            "Library/LaunchAgents/com.foo.AppOther.plist",
            "Library/WebKit/Databases/x",
            "SystemLibrary/LaunchDaemons/com.foo.AppOther.plist",
            "Library/Caches/com.apple.foo.App/blob",
            // Not one of the known locations.
            "Library/Application Scripts/com.foo.App/script",
            "Library/com.foo.App/file",
            "Documents/com.foo.App/file",
        ]
        for file in matches + nearMisses { try fixture.write(file) }

        // What is proposed is the direct child of a known location, never deeper, never the location.
        let expected = Set(matches.map { file -> String in
            let parts = file.split(separator: "/").map(String.init)
            let depth = file.hasPrefix("Library/Preferences/ByHost/") ? 4 : 3
            return fixture.path(parts.prefix(depth).joined(separator: "/"))
        })
        return (fixture, expected, nearMisses)
    }

    @Test func matchesByBundleIDAndExactNameOnly() async throws {
        let (fixture, expected, _) = try populated()
        let uninstaller = fixture.uninstaller { $0.systemLibrary = fixture.path("SystemLibrary") }
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        let plan = await uninstaller.plan(for: app)

        #expect(plan.items.first?.kind == .appBundle)
        #expect(plan.items.first?.path == fixture.path("Applications/Foo Editor.app"))
        let leftovers = plan.items.filter { $0.kind == .leftover }
        #expect(Set(leftovers.map(\.path)) == expected)
        #expect(leftovers.count == expected.count)

        // Every row has a size, a fingerprint and is ticked; nothing is a container folder.
        let containers = Set(LeftoverLocation.allCases.compactMap { uninstaller.scanDirectory($0) })
        for item in plan.items {
            #expect(item.bytes != nil && item.bytes! > 0, "\(item.path) has no size")
            #expect(item.fingerprint != nil)
            #expect(item.isSelectedByDefault)
            #expect(item.blockedReason == nil)
            #expect(!containers.contains(item.path))
            #expect(item.path != fixture.path("Library"))
        }
        #expect(plan.bytes() == plan.items.reduce(0) { $0 + ($1.bytes ?? 0) })

        let byName = leftovers.filter { $0.evidence == .appName }.map(\.path).sorted()
        #expect(byName == [
            fixture.path("Library/Application Support/Foo Editor"),
            fixture.path("Library/Caches/foo editor"),
            fixture.path("Library/Logs/Foo Editor"),
        ])
        #expect(leftovers.first { $0.path.hasSuffix("LaunchDaemons/com.foo.App.daemon.plist") }?.location == .systemLaunchDaemons)
    }

    @Test func uninstallLeavesNearMissesAlone() async throws {
        let (fixture, expected, nearMisses) = try populated()
        let dock = FakeDock()
        let uninstaller = fixture.uninstaller {
            $0.systemLibrary = fixture.path("SystemLibrary")
            $0.dock = dock
        }
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        let plan = await uninstaller.plan(for: app)
        let planned = plan.bytes()

        let report = await uninstaller.uninstall(plan)

        #expect(report.stoppedReason == nil)
        #expect(report.operation.failures.isEmpty)
        #expect(report.operation.skipped.isEmpty)
        #expect(report.operation.entries.count == expected.count + 1)
        #expect(report.operation.entries.allSatisfy { $0.result == .removed && $0.mode == "trash" })
        #expect(report.bytes == planned)
        #expect(report.dockEntryRemoved)
        #expect(dock.removed == [app.path])

        #expect(!fixture.exists("Applications/Foo Editor.app"))
        for path in expected { #expect(!FileManager.default.fileExists(atPath: path), "\(path) should be gone") }
        for file in nearMisses { #expect(fixture.exists(file), "\(file) must not be touched") }
        #expect(fixture.exists("Applications/Foo Editor Pro.app"))
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(fixture.exists(".ssh/id_ed25519"))

        // Trash, not deletion: everything is in the fixture Trash.
        let trashed = fixture.trashed()
        #expect(trashed.count == expected.count + 1)
        #expect(trashed.contains("Foo Editor.app"))
        #expect(trashed.contains("com.foo.App.savedState"))

        // The ledger has the operation.
        let logged = uninstaller.engine.ledger.operations()
        #expect(logged.count == 1)
        #expect(logged.first?.kind == .uninstall)
        #expect(logged.first?.source == "window")
        #expect(logged.first?.bytesFreed == planned)
        #expect(logged.first?.entries.first?.itemID == "com.foo.App")

        // The app is gone from the list.
        #expect(await uninstaller.app(named: "Foo Editor") == nil)
    }

    @Test func neverMatchesShortGenericOrAppleNames() async throws {
        let fixture = try FixtureHome()
        try fixture.app("Helper", bundleID: "helper")
        try fixture.app("Go", bundleID: "io.golang")
        try fixture.app("Xcode", bundleID: "com.apple.dt.Xcode")
        try fixture.app("Shell", bundleID: "com.github.Electron")
        for file in [
            "Library/Application Support/Helper/x", "Library/Caches/helper/x", "Library/Preferences/helper.plist",
            "Library/Application Support/Go/x", "Library/Caches/io.golang.sibling/x", "Library/Preferences/io.golang.other.plist",
            "Library/Application Support/Xcode/x", "Library/Caches/com.apple.dt.Xcode/x",
            "Library/Preferences/com.apple.dt.Xcode.plist", "Library/Logs/Xcode/x",
            "Library/Preferences/com.github.Electron.plist", "Library/Application Support/com.github.Electron/x",
            "Library/Application Support/Shell/x",
        ] { try fixture.write(file) }
        // The exact identifier and what macOS derives from it are all a two-part identifier may claim.
        try fixture.write("Library/Preferences/io.golang.plist")
        try fixture.write("Library/Caches/io.golang/x")

        let uninstaller = fixture.uninstaller()
        func leftovers(_ name: String) async throws -> [String] {
            let app = try #require(await uninstaller.app(named: name))
            return await uninstaller.plan(for: app).items.filter { $0.kind == .leftover }.map(\.path)
        }
        #expect(try await leftovers("Helper").isEmpty)
        #expect(try await leftovers("Xcode").isEmpty)
        #expect(try await leftovers("Go") == [fixture.path("Library/Caches/io.golang"), fixture.path("Library/Preferences/io.golang.plist")])
        // A template identifier is useless, but a distinctive name still counts.
        #expect(try await leftovers("Shell") == [fixture.path("Library/Application Support/Shell")])
    }

    @Test func matcherRules() {
        let app = InstalledApp(path: "/x/Foo Editor.app", name: "Foo Editor", bundleID: "com.foo.App")
        let matcher = LeftoverMatcher(app: app, otherBundleIDs: ["com.foo.App.Pro", "com.other.Thing"])
        #expect(matcher.evidence(for: "com.foo.App", in: .caches) == .bundleID)
        #expect(matcher.evidence(for: "COM.FOO.APP.plist", in: .preferences) == .bundleID)
        #expect(matcher.evidence(for: "com.foo.App.savedState", in: .savedState) == .bundleID)
        #expect(matcher.evidence(for: "com.foo.AppOther", in: .caches) == nil)
        #expect(matcher.evidence(for: "com.foo.AppOther.plist", in: .preferences) == nil)
        #expect(matcher.evidence(for: "com.foo.App.Pro.plist", in: .preferences) == nil)
        #expect(matcher.evidence(for: "com.foo", in: .applicationSupport) == nil)
        #expect(matcher.evidence(for: "Foo Editor", in: .applicationSupport) == .appName)
        #expect(matcher.evidence(for: "Foo Editor", in: .preferences) == nil)
        #expect(matcher.evidence(for: "Foo Editor", in: .containers) == nil)
        #expect(matcher.evidence(for: "Foo", in: .applicationSupport) == nil)
        #expect(matcher.evidence(for: "group.com.foo.App", in: .groupContainers) == .bundleID)
        #expect(matcher.evidence(for: "group.com.foo.App.more", in: .groupContainers) == nil)
        #expect(matcher.evidence(for: "com.apple.foo", in: .caches) == nil)
        #expect(matcher.evidence(for: ".com.foo.App", in: .caches) == nil)

        // A name two installed apps share says nothing about either.
        let shared = LeftoverMatcher(app: app, otherBundleIDs: [], sharedNames: ["foo editor"])
        #expect(shared.evidence(for: "Foo Editor", in: .applicationSupport) == nil)

        for name in ["Arc", "Data", "Helper", "Updater", "Google", "1234", "Cache"] {
            #expect(!LeftoverMatcher.isDistinctive(name), "\(name) is too short or generic")
        }
        #expect(LeftoverMatcher.isDistinctive("Foo Editor"))
    }

    @Test func aLongerIdentifierRegisteredToAnotherAppIsNotClaimed() async throws {
        let fixture = try FixtureHome()
        let path = try fixture.app("Foo Editor", bundleID: "com.foo.App")
        try fixture.write("Library/Preferences/com.foo.App.plist")
        try fixture.write("Library/Preferences/com.foo.App.helper.plist")
        try fixture.write("Library/Preferences/com.foo.App.Companion.plist")
        try fixture.write("Library/Caches/com.foo.App.Companion.ShipIt/update")

        // Launch Services knows a Companion app outside the applications folders,
        // and the editor's own login helper inside its bundle.
        let uninstaller = fixture.uninstaller {
            $0.registeredAppPaths = { id in
                switch id {
                case "com.foo.App.Companion": ["/opt/companion/Companion.app"]
                case "com.foo.App.helper": [path + "/Contents/Library/LoginItems/Helper.app"]
                default: []
                }
            }
        }
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        let leftovers = await uninstaller.plan(for: app).items.filter { $0.kind == .leftover }.map(\.name)
        #expect(leftovers == ["com.foo.App.helper.plist", "com.foo.App.plist"])

        let matcher = LeftoverMatcher(app: app, otherBundleIDs: [])
        #expect(matcher.longerIdentifiers(in: "com.foo.App.plist").isEmpty)
        #expect(matcher.longerIdentifiers(in: "com.foo.App.savedState").isEmpty)
        #expect(matcher.longerIdentifiers(in: "com.foo.App.Companion.ShipIt") == ["com.foo.App.Companion", "com.foo.App.Companion.ShipIt"])
        #expect(matcher.longerIdentifiers(in: "com.foo.App.43CA8902-DB90-5A35-B3C9-62F44D84A1E3.plist").isEmpty)
        #expect(matcher.longerIdentifiers(in: "com.other.Thing.plist").isEmpty)
    }

    @Test func symlinkLeftoverToDocumentsIsRefused() async throws {
        let fixture = try FixtureHome()
        try fixture.app("Foo Editor", bundleID: "com.foo.App")
        try fixture.write("Library/Preferences/com.foo.App.plist")
        // The trap: a "cache" that is really the user's Documents folder.
        try fixture.symlink("Library/Caches/com.foo.App", to: fixture.path("Documents"))
        // A whole location that is a link is not read at all.
        try fixture.write("Documents/com.foo.App/notes.txt")
        try fixture.symlink("Library/Logs", to: fixture.path("Documents"))

        let uninstaller = fixture.uninstaller()
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        let plan = await uninstaller.plan(for: app)

        let link = try #require(plan.items.first { $0.path == fixture.path("Library/Caches/com.foo.App") })
        #expect(link.blockedReason != nil)
        #expect(!link.isSelectedByDefault)
        #expect(!plan.defaultSelection.contains(link.id))
        #expect(!plan.items.contains { $0.path.contains("/Documents") || $0.path.contains("/Logs") })

        // Even when the caller insists, the guarded remover refuses.
        let report = await uninstaller.uninstall(plan, selecting: Set(plan.items.map(\.id)))
        let refused = try #require(report.operation.entries.first { $0.target == link.path })
        #expect(refused.result == .refused)
        #expect(refused.reason == "is a symbolic link")
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(fixture.exists("Documents/com.foo.App/notes.txt"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == fixture.path("Documents"))
        // The rest still went.
        #expect(!fixture.exists("Applications/Foo Editor.app"))
        #expect(!fixture.exists("Library/Preferences/com.foo.App.plist"))
        #expect(fixture.trashed() == ["Foo Editor.app", "com.foo.App.plist"])
    }
}

@Suite struct UninstallFlowTests {
    private func simple() throws -> FixtureHome {
        let fixture = try FixtureHome()
        try fixture.app("Foo Editor", bundleID: "com.foo.App")
        try fixture.write("Library/Application Support/com.foo.App/data.db", bytes: 32 * 1024)
        try fixture.write("Library/Preferences/com.foo.App.plist")
        try fixture.app("Other", bundleID: "com.other.App")
        try fixture.write("Library/Application Support/com.other.App/data.db")
        return fixture
    }

    @Test func dryRunTouchesNothing() async throws {
        let fixture = try simple()
        let dock = FakeDock()
        let terminator = FakeTerminator(quits: true)
        let privileged = FakePrivileged()
        let uninstaller = fixture.uninstaller(processes: ["Foo Editor"], privileged: privileged) {
            $0.dock = dock
            $0.terminator = terminator
        }
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        let plan = await uninstaller.plan(for: app)
        let before = fixture.userFiles()

        let report = await uninstaller.uninstall(plan, dryRun: true)

        #expect(fixture.userFiles() == before)
        #expect(fixture.trashed().isEmpty)
        #expect(report.dryRun)
        #expect(report.operation.entries.count == 3)
        #expect(report.operation.entries.allSatisfy { $0.result == .dryRun })
        #expect(report.bytes == plan.bytes())
        #expect(report.bytes >= 96 * 1024)
        #expect(report.operation.bytesFreed == 0)
        // No side effects either: nobody was asked to quit, the Dock was not edited, nothing was logged.
        #expect(terminator.asked.isEmpty)
        #expect(dock.removed.isEmpty)
        #expect(privileged.calls.isEmpty)
        #expect(uninstaller.engine.ledger.operations().isEmpty)
    }

    @Test func aRunningAppIsAskedToQuitAndNeverForced() async throws {
        let fixture = try simple()
        let stubborn = FakeTerminator(quits: false)
        let dock = FakeDock()
        var uninstaller = fixture.uninstaller(processes: ["Foo Editor"]) {
            $0.terminator = stubborn
            $0.dock = dock
        }
        var app = try #require(await uninstaller.app(named: "Foo Editor"))
        #expect(app.isRunning)
        var plan = await uninstaller.plan(for: app)
        let before = fixture.userFiles()

        var report = await uninstaller.uninstall(plan)
        #expect(stubborn.asked == ["Foo Editor"])
        #expect(report.stoppedReason == "Foo Editor is still running")
        #expect(report.operation.entries.allSatisfy { $0.result == .skipped })
        #expect(fixture.userFiles() == before)
        #expect(dock.removed.isEmpty)

        // The fixture default never quits anything, so a running app stays.
        uninstaller = fixture.uninstaller(processes: ["Foo Editor"])
        report = await uninstaller.uninstall(plan)
        #expect(report.stoppedReason == "Foo Editor is still running")
        #expect(fixture.userFiles() == before)

        let polite = FakeTerminator(quits: true)
        uninstaller = fixture.uninstaller(processes: ["Foo Editor"]) { $0.terminator = polite }
        app = try #require(await uninstaller.app(named: "Foo Editor"))
        plan = await uninstaller.plan(for: app)
        report = await uninstaller.uninstall(plan)
        #expect(polite.asked == ["Foo Editor"])
        #expect(report.didQuitApp)
        #expect(report.stoppedReason == nil)
        #expect(!fixture.exists("Applications/Foo Editor.app"))
        #expect(fixture.exists("Applications/Other.app"))
    }

    @Test func onlyTickedItemsAreRemovedAndModeFollowsSettings() async throws {
        let fixture = try simple()
        var settings = SweepSettings()
        #expect(settings.uninstallDeleteMode == .trash)
        settings.uninstallDeleteMode = .permanent
        let engine = fixture.engine(items: [], settings: settings)
        let uninstaller = AppUninstaller(engine: engine)
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        let plan = await uninstaller.plan(for: app)

        // Keep the preferences, remove the rest.
        let selection = plan.defaultSelection.subtracting([fixture.path("Library/Preferences/com.foo.App.plist")])
        let report = await uninstaller.uninstall(plan, selecting: selection, source: "cli")

        #expect(report.operation.entries.count == 2)
        #expect(report.operation.entries.allSatisfy { $0.result == .removed && $0.mode == "permanent" })
        #expect(report.operation.source == "cli")
        #expect(fixture.exists("Library/Preferences/com.foo.App.plist"))
        #expect(!fixture.exists("Applications/Foo Editor.app"))
        #expect(!fixture.exists("Library/Application Support/com.foo.App"))
        #expect(fixture.trashed().isEmpty)
        #expect(fixture.exists("Library/Application Support/com.other.App/data.db"))
    }

    @Test func aForgedPlanCannotRemoveSomethingElse() async throws {
        let fixture = try simple()
        try fixture.write("Projects/novel/chapter1.txt")
        let uninstaller = fixture.uninstaller()
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        var plan = await uninstaller.plan(for: app)
        let foreign = [
            fixture.path("Library/Application Support/com.other.App"),
            fixture.path("Applications/Other.app"),
            fixture.path("Projects/novel"),
            fixture.path("Documents"),
            fixture.path("Library/Caches"),
        ]
        for path in foreign {
            plan.items.append(UninstallItem(path: path, kind: .leftover, evidence: .bundleID, fingerprint: Fingerprint(path: path)))
        }

        let report = await uninstaller.uninstall(plan, selecting: Set(plan.items.map(\.id)))
        for path in foreign {
            let entry = try #require(report.operation.entries.first { $0.target == path })
            #expect(entry.result == .skipped)
            #expect(FileManager.default.fileExists(atPath: path))
        }
        #expect(fixture.exists("Projects/novel/chapter1.txt"))
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(!fixture.exists("Applications/Foo Editor.app"))

        // An "app" that is not an app in an applications folder is not uninstalled at all.
        let fake = InstalledApp(path: fixture.path("Documents"), name: "Documents", bundleID: "com.foo.Docs")
        let forged = UninstallPlan(app: fake, items: [
            UninstallItem(path: fake.path, kind: .appBundle, evidence: .bundle, fingerprint: Fingerprint(path: fake.path)),
        ])
        let refused = await uninstaller.uninstall(forged)
        #expect(refused.stoppedReason != nil)
        #expect(refused.operation.entries.isEmpty)
        #expect(fixture.exists("Documents/thesis.txt"))
    }

    @Test func somethingThatChangedSinceThePreviewIsSkipped() async throws {
        let fixture = try simple()
        let uninstaller = fixture.uninstaller()
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        let plan = await uninstaller.plan(for: app)

        // The preferences file is replaced after the preview.
        let prefs = fixture.path("Library/Preferences/com.foo.App.plist")
        try FileManager.default.removeItem(atPath: prefs)
        try fixture.write("Library/Preferences/com.foo.App.plist.tmp")
        try FileManager.default.moveItem(atPath: prefs + ".tmp", toPath: prefs)

        let report = await uninstaller.uninstall(plan)
        let entry = try #require(report.operation.entries.first { $0.target == prefs })
        #expect(entry.result == .skipped)
        #expect(entry.reason == "changed since the scan")
        #expect(FileManager.default.fileExists(atPath: prefs))
        #expect(!fixture.exists("Applications/Foo Editor.app"))
    }
}

@Suite struct HomebrewTests {
    private static let info = """
    {"formulae": [], "casks": [{"token": "tiled", "artifacts": [
      {"app": ["Tiled.app"]},
      {"zap": [{"trash": ["~/Library/Preferences/org.mapeditor.Tiled.plist", "~/Library/Application Support/Tiled Extras*", "~/Library/Missing"],
                "rmdir": "~/Library/Tiled"}]}
    ]}]}
    """

    private func fixtureWithCask(info: String = HomebrewTests.info, uninstallExit: Int32 = 0) throws -> (FixtureHome, FakeRunner) {
        let fixture = try FixtureHome()
        let app = try fixture.app("Tiled", bundleID: "org.mapeditor.Tiled")
        try fixture.app("Manual", bundleID: "com.manual.App")
        // Homebrew leaves a link to the installed app in its Caskroom.
        try fixture.symlink("homebrew/Caskroom/tiled/1.12.2/Tiled.app", to: app)
        try fixture.mkdir("homebrew/Caskroom/tiled/.metadata")
        try fixture.write("Library/Preferences/org.mapeditor.Tiled.plist")
        try fixture.write("Library/Application Support/Tiled Extras 1/file")
        try fixture.write("Library/Caches/org.mapeditor.Tiled/blob")

        let runner = FakeRunner()
        runner.on("brew") { arguments in
            switch arguments.first {
            case "list": CommandResult(exitCode: 0, stdout: "tiled\nxquartz\n")
            case "info": CommandResult(exitCode: 0, stdout: info)
            case "uninstall": CommandResult(exitCode: uninstallExit, stderr: uninstallExit == 0 ? "" : "Error: sudo needed")
            default: CommandResult(exitCode: 1)
            }
        }
        return (fixture, runner)
    }

    @Test func caskAppIsUninstalledByHomebrew() async throws {
        let (fixture, runner) = try fixtureWithCask()
        let uninstaller = fixture.uninstaller(runner: runner) { $0.caskrooms = [fixture.path("homebrew/Caskroom")] }

        let app = try #require(await uninstaller.app(named: "Tiled"))
        #expect(app.caskToken == "tiled")
        #expect(await uninstaller.app(named: "Manual")?.caskToken == nil)

        let plan = await uninstaller.plan(for: app)
        #expect(plan.command == ["brew", "uninstall", "--zap", "--cask", "tiled"])
        let homebrew = plan.items.filter { $0.route == .homebrew }.map(\.path)
        #expect(homebrew == [
            fixture.path("Applications/Tiled.app"),
            fixture.path("Library/Preferences/org.mapeditor.Tiled.plist"),
            fixture.path("Library/Application Support/Tiled Extras 1"),
        ])
        let own = plan.items.filter { $0.route == .sweep }.map(\.path)
        #expect(own == [fixture.path("Library/Caches/org.mapeditor.Tiled")])
        #expect(plan.items.allSatisfy { ($0.bytes ?? 0) > 0 })

        let report = await uninstaller.uninstall(plan)

        #expect(runner.ran(["brew", "uninstall", "--zap", "--cask", "tiled"]))
        let command = try #require(report.operation.entries.first { $0.mode == "command" })
        #expect(command.target == "brew uninstall --zap --cask tiled")
        #expect(command.result == .removed)
        // House Keeping did not delete what Homebrew owns: the fake brew removed nothing, so it is all still there.
        #expect(fixture.exists("Applications/Tiled.app"))
        #expect(fixture.exists("Library/Preferences/org.mapeditor.Tiled.plist"))
        #expect(fixture.exists("Library/Application Support/Tiled Extras 1/file"))
        #expect(command.bytes == 0)
        // The leftover Homebrew does not know about went to the Trash.
        #expect(!fixture.exists("Library/Caches/org.mapeditor.Tiled"))
        #expect(fixture.trashed() == ["org.mapeditor.Tiled"])
        #expect(uninstaller.engine.ledger.operations().count == 1)
    }

    @Test func dryRunNeverRunsBrewUninstall() async throws {
        let (fixture, runner) = try fixtureWithCask()
        let uninstaller = fixture.uninstaller(runner: runner) { $0.caskrooms = [fixture.path("homebrew/Caskroom")] }
        let app = try #require(await uninstaller.app(named: "Tiled"))
        let plan = await uninstaller.plan(for: app)
        let before = fixture.userFiles()

        let report = await uninstaller.uninstall(plan, dryRun: true)

        #expect(!runner.log.contains { $0.first == "brew" && $0.dropFirst().first == "uninstall" })
        #expect(fixture.userFiles() == before)
        #expect(report.operation.entries.allSatisfy { $0.result == .dryRun })
        #expect(report.bytes == plan.bytes())
    }

    @Test func whenHomebrewFailsNothingElseIsRemoved() async throws {
        let (fixture, runner) = try fixtureWithCask(uninstallExit: 1)
        let uninstaller = fixture.uninstaller(runner: runner) { $0.caskrooms = [fixture.path("homebrew/Caskroom")] }
        let app = try #require(await uninstaller.app(named: "Tiled"))
        let plan = await uninstaller.plan(for: app)
        let before = fixture.userFiles()

        let report = await uninstaller.uninstall(plan)

        #expect(report.stoppedReason == "Homebrew could not remove Tiled")
        #expect(report.operation.failures.count == 1)
        #expect(report.operation.failures.first?.reason == "command failed: Error: sudo needed")
        #expect(fixture.userFiles() == before)
        #expect(fixture.trashed().isEmpty)
    }

    @Test func zapIsDroppedWhenItNamesAProtectedPlace() async throws {
        let info = """
        {"casks": [{"token": "tiled", "artifacts": [{"zap": [{"trash": ["~/Documents", "~/Library/Preferences/org.mapeditor.Tiled.plist"]}]}]}]}
        """
        let (fixture, runner) = try fixtureWithCask(info: info)
        let uninstaller = fixture.uninstaller(runner: runner) { $0.caskrooms = [fixture.path("homebrew/Caskroom")] }
        let app = try #require(await uninstaller.app(named: "Tiled"))
        let plan = await uninstaller.plan(for: app)

        #expect(!plan.usesZap)
        #expect(plan.command == ["brew", "uninstall", "--cask", "tiled"])
        #expect(!plan.items.contains { $0.path == fixture.path("Documents") })
        _ = await uninstaller.uninstall(plan)
        #expect(runner.ran(["brew", "uninstall", "--cask", "tiled"]))
        #expect(!runner.log.contains { $0.contains("--zap") })
        #expect(fixture.exists("Documents/thesis.txt"))
    }

    @Test func caskTokensAndZapPatterns() throws {
        #expect(CaskIndex.normalize("Visual Studio Code") == "visual-studio-code")
        #expect(CaskIndex.normalize("XQuartz") == "xquartz")
        var index = CaskIndex()
        index.tokens = ["xquartz"]
        #expect(index.token(forAppAt: "/Applications/Utilities/XQuartz.app") == "xquartz")
        #expect(index.token(forAppAt: "/Applications/Other.app") == nil)

        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.x.one/a")
        try fixture.write("Library/Caches/com.x.two/a")
        let home = fixture.home.path
        #expect(HomebrewCasks.expand("~/Library/Caches/com.x.*", home: home) == [fixture.path("Library/Caches/com.x.one"), fixture.path("Library/Caches/com.x.two")])
        #expect(HomebrewCasks.expand("~/Library/*/com.x.one", home: home).isEmpty)
        #expect(HomebrewCasks.expand("~/Library/Caches/missing", home: home).isEmpty)
        #expect(HomebrewCasks.expand("relative/path", home: home).isEmpty)
        #expect(HomebrewCasks.expand("~", home: home).isEmpty)
    }
}

@Suite struct ReceiptTests {
    @Test func pkgutilReceiptsAddFilesForReview() async throws {
        let fixture = try FixtureHome()
        let app = try fixture.app("Foo Editor", bundleID: "com.foo.App")
        try fixture.write("Library/Extras/foo-tool")
        try fixture.write("Library/Extras/Foo.framework/Versions/A/Foo")
        try fixture.write("Library/Extras/unrelated-tool")
        try fixture.write("Documents/installed-by-pkg.txt")
        let home = fixture.home.path

        let runner = FakeRunner()
        runner.on("pkgutil") { arguments in
            switch arguments {
            case ["--pkgs"]:
                return CommandResult(exitCode: 0, stdout: "com.apple.pkg.Core\ncom.foo.pkg.App\ncom.foo.pkg.Unrelated\ncom.other.pkg\n")
            case ["--pkg-info", "com.foo.pkg.App"]:
                return CommandResult(exitCode: 0, stdout: "package-id: com.foo.pkg.App\nversion: 1.0\nvolume: \(home)\nlocation: \ninstall-time: 1700000000\n")
            case ["--files", "com.foo.pkg.App"]:
                return CommandResult(exitCode: 0, stdout: """
                Applications
                Applications/Foo Editor.app
                Applications/Foo Editor.app/Contents
                Applications/Foo Editor.app/Contents/MacOS/Foo Editor
                Library
                Library/Extras
                Library/Extras/foo-tool
                Library/Extras/Foo.framework
                Library/Extras/Foo.framework/Versions/A/Foo
                Library/Extras/never-installed
                Documents/installed-by-pkg.txt
                ../outside
                """)
            case ["--pkg-info", "com.foo.pkg.Unrelated"]:
                return CommandResult(exitCode: 0, stdout: "volume: \(home)\nlocation: Library/Extras\n")
            case ["--files", "com.foo.pkg.Unrelated"]:
                return CommandResult(exitCode: 0, stdout: "unrelated-tool\n")
            default:
                return CommandResult(exitCode: 1, stderr: "unexpected")
            }
        }

        let uninstaller = fixture.uninstaller(runner: runner)
        let installed = try #require(await uninstaller.app(named: "Foo Editor"))
        #expect(installed.path == app)
        let plan = await uninstaller.plan(for: installed)

        #expect(plan.packageIDs == ["com.foo.pkg.App"])
        let extras = plan.items.filter { if case .receipt = $0.evidence { true } else { false } }
        // A bundle-like folder is one row; shared folders, the app's own files and protected places are not listed.
        #expect(extras.map(\.path) == [fixture.path("Library/Extras/Foo.framework"), fixture.path("Library/Extras/foo-tool")])
        #expect(extras.allSatisfy { $0.evidence == .receipt(package: "com.foo.pkg.App") && !$0.isSelectedByDefault })

        // Only read-only pkgutil questions were asked, and only about this developer's receipts.
        let asked = runner.log.filter { $0.first == "pkgutil" }
        #expect(asked.allSatisfy { ["--pkgs", "--pkg-info", "--files"].contains($0[1]) })
        #expect(!asked.contains { $0.contains("com.other.pkg") || $0.contains("com.apple.pkg.Core") })

        // Unticked by default: a plain uninstall leaves them; ticking removes them.
        var report = await uninstaller.uninstall(plan, dryRun: true)
        #expect(!report.operation.entries.contains { $0.target.contains("/Extras/") })
        report = await uninstaller.uninstall(plan, selecting: Set(plan.items.map(\.id)))
        #expect(report.operation.failures.isEmpty)
        #expect(!fixture.exists("Library/Extras/foo-tool"))
        #expect(!fixture.exists("Library/Extras/Foo.framework"))
        #expect(fixture.exists("Library/Extras/unrelated-tool"))
        #expect(fixture.exists("Documents/installed-by-pkg.txt"))
    }
}

@Suite struct PrivilegedTests {
    @Test func aRootOwnedAppGoesToTheHelperInsteadOfBeingDeleted() async throws {
        let fixture = try FixtureHome()
        let path = try fixture.app("Foo Editor", bundleID: "com.foo.App")
        try fixture.write("Library/Preferences/com.foo.App.plist")
        let helper = FakePrivileged()
        let uninstaller = fixture.uninstaller(privileged: helper) {
            $0.requiresAdmin = { $0 == path }
        }
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        #expect(app.needsAdmin)
        let plan = await uninstaller.plan(for: app)
        #expect(plan.bundle?.needsAdmin == true)
        let before = fixture.userFiles()

        // A dry run reports the path and does not call the helper.
        let preview = await uninstaller.uninstall(plan, dryRun: true)
        #expect(helper.calls.isEmpty)
        #expect(preview.operation.entries.first { $0.target == path }?.mode == "helper")
        #expect(preview.operation.entries.allSatisfy { $0.result == .dryRun })

        let report = await uninstaller.uninstall(plan)

        #expect(helper.calls == [FakePrivileged.Call(task: .removeApplication, argument: "com.foo.App")])
        #expect(report.privilegedResult == PrivilegedResult(succeeded: true, message: "removed", bytesFreed: 4242))
        let entry = try #require(report.operation.entries.first { $0.mode == "helper" && $0.result == .removed })
        #expect(entry.target == "removeApplication com.foo.App")
        #expect(entry.bytes == 4242)
        // House Keeping itself deleted nothing: the fake helper removes no files, so the bundle is untouched
        // and, because the app is still there, its leftovers were kept too.
        #expect(fixture.userFiles() == before)
        #expect(fixture.trashed().isEmpty)
        #expect(report.stoppedReason == "Foo Editor could not be removed")
        #expect(report.operation.entries.first { $0.target.hasSuffix("com.foo.App.plist") }?.result == .skipped)
    }

    @Test func rootOwnedLeftoversGoToTheHelperAfterTheAppIsTrashed() async throws {
        let fixture = try FixtureHome()
        try fixture.app("Foo Editor", bundleID: "com.foo.App")
        try fixture.write("Library/Preferences/com.foo.App.plist")
        try fixture.write("SystemLibrary/LaunchDaemons/com.foo.App.daemon.plist")
        let daemon = fixture.path("SystemLibrary/LaunchDaemons/com.foo.App.daemon.plist")
        let helper = FakePrivileged()
        let uninstaller = fixture.uninstaller(privileged: helper) {
            $0.systemLibrary = fixture.path("SystemLibrary")
            $0.requiresAdmin = { $0 == daemon }
        }
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        let plan = await uninstaller.plan(for: app)
        #expect(plan.items.first { $0.path == daemon }?.needsAdmin == true)

        let report = await uninstaller.uninstall(plan)

        #expect(helper.calls == [FakePrivileged.Call(task: .removeApplication, argument: "com.foo.App")])
        #expect(report.stoppedReason == nil)
        #expect(fixture.trashed() == ["Foo Editor.app", "com.foo.App.plist"])
        // The daemon file was left to the helper, never deleted by House Keeping.
        #expect(FileManager.default.fileExists(atPath: daemon))
        #expect(report.operation.entries.first { $0.target == daemon }?.reason == "left in place by the admin helper")
    }

    @Test func withoutAHelperARootOwnedAppStaysWithItsLeftovers() async throws {
        let fixture = try FixtureHome()
        let path = try fixture.app("Foo Editor", bundleID: "com.foo.App")
        try fixture.write("Library/Preferences/com.foo.App.plist")
        let uninstaller = fixture.uninstaller(privileged: NoPrivilegedRunner()) { $0.requiresAdmin = { $0 == path } }
        let app = try #require(await uninstaller.app(named: "Foo Editor"))
        let plan = await uninstaller.plan(for: app)
        let before = fixture.userFiles()

        let report = await uninstaller.uninstall(plan)

        #expect(report.privilegedResult?.succeeded == false)
        #expect(report.operation.failures.first?.reason == "Admin tasks are not available")
        #expect(report.stoppedReason == "Foo Editor could not be removed")
        #expect(fixture.userFiles() == before)
    }
}

@Suite struct OrphanTests {
    private func populated() throws -> FixtureHome {
        let fixture = try FixtureHome()
        try fixture.app("Foo Editor", bundleID: "com.foo.App")
        // A login item inside the app has its own identifier.
        try fixture.app("Login Helper", bundleID: "com.fooco.LoginHelper", in: "Applications/Foo Editor.app/Contents/Library/LoginItems")
        try fixture.app("Safari", bundleID: "com.apple.Safari")

        for file in [
            // Orphans.
            "Library/Application Support/com.gone.OldApp/data.db",
            "Library/Preferences/com.gone.OldApp.plist",
            "Library/Preferences/ByHost/com.gone.OldApp.43CA8902-DB90-5A35-B3C9-62F44D84A1E3.plist",
            "Library/Saved Application State/com.gone.OldApp.savedState/windows.plist",
            "Library/Group Containers/group.com.gone.OldApp/db",
            "Library/Group Containers/ABCDE12345.com.gone.OldApp/db",
            // Installed, part of something installed, or from a developer who still has an app here.
            "Library/Caches/com.foo.Sibling/blob",
            "Library/Preferences/com.foo.shared.plist",
            "Library/Caches/com.foo.App/blob",
            "Library/Caches/com.foo.App.helper/blob",
            "Library/Preferences/com.fooco.LoginHelper.plist",
            "Library/Group Containers/ABCDE12345.com.foo.shared/db",
            // Apple's.
            "Library/Caches/com.apple.Something/blob",
            "Library/Preferences/com.apple.Safari.plist",
            "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/db",
            // Not a bundle identifier.
            "Library/Application Support/Some Folder/x",
            "Library/Caches/pip/x",
            "Library/Caches/Homebrew/x",
            "Library/Preferences/loginwindow.plist",
            "Library/Application Support/1.2.3/x",
            "Library/Caches/foo.bar.baz/x",
            // In use, registered elsewhere, or House Keeping's own.
            "Library/Caches/com.running.Daemon/blob",
            "Library/Application Support/com.busy.tool/x",
            "Library/Containers/com.registered.Tool/Data/x",
            "Library/Containers/com.registered.Tool.Extension/Data/x",
            "Library/Preferences/com.rickson.housekeeping.plist",
            "Library/Preferences/com.github.Electron.plist",
            // Command-line tools, runtimes and system services.
            "Library/Caches/org.swift.swiftpm/x",
            "Library/Application Support/com.vercel.cli/auth.json",
            "Library/Preferences/org.cups.PrintingPrefs.plist",
            "Library/Preferences/com.android.Emulator.plist",
            // Launch agents are not orphan candidates.
            "Library/LaunchAgents/com.gone.OldApp.plist",
            // Not a known location.
            "Library/com.gone.OldApp/x",
        ] { try fixture.write(file) }
        try fixture.symlink("Library/Caches/com.gone.Link", to: fixture.path("Documents"))
        return fixture
    }

    private func uninstaller(_ fixture: FixtureHome, minimumAge: TimeInterval = 0) -> AppUninstaller {
        let engine = fixture.engine(items: [])
        var context = engine.context
        context.processes = StaticProcessList([
            RunningProcess(pid: 1, name: "com.running.Daemon"),
            RunningProcess(pid: 2, name: "helperd", path: "/opt/busy/helperd", bundleID: "com.busy.tool.agent"),
        ])
        var environment = UninstallEnvironment.fixture(home: fixture.home)
        environment.registeredAppPaths = { $0 == "com.registered.Tool" ? ["/opt/tools/Tool.app"] : [] }
        environment.orphanMinimumAge = minimumAge
        return AppUninstaller(engine: SweepEngine(context: context, catalog: Catalog(items: [])), environment: environment)
    }

    @Test func findsOnlyUnclaimedReverseDNSLeftovers() async throws {
        let fixture = try populated()
        let orphans = await uninstaller(fixture).orphans()

        #expect(Set(orphans.map(\.path)) == Set([
            "Library/Application Support/com.gone.OldApp",
            "Library/Preferences/com.gone.OldApp.plist",
            "Library/Preferences/ByHost/com.gone.OldApp.43CA8902-DB90-5A35-B3C9-62F44D84A1E3.plist",
            "Library/Saved Application State/com.gone.OldApp.savedState",
            "Library/Group Containers/group.com.gone.OldApp",
            "Library/Group Containers/ABCDE12345.com.gone.OldApp",
        ].map(fixture.path)))
        #expect(orphans.allSatisfy { ($0.bytes ?? 0) > 0 && $0.lastModified != nil && $0.fingerprint != nil })
        #expect(orphans.allSatisfy { $0.bundleID == "com.gone.OldApp" })
        #expect(orphans.count == 6)
        // Biggest first.
        #expect(orphans.map { $0.bytes ?? 0 } == orphans.map { $0.bytes ?? 0 }.sorted(by: >))
        #expect(orphans.first { $0.path.contains("ByHost") }?.location == .preferencesByHost)
    }

    @Test func orphansAreRemovedOneAtATimeToTheTrash() async throws {
        let fixture = try populated()
        let uninstaller = uninstaller(fixture)
        let orphans = await uninstaller.orphans()
        let target = try #require(orphans.first { $0.path == fixture.path("Library/Application Support/com.gone.OldApp") })
        let before = fixture.userFiles()

        let preview = await uninstaller.removeOrphan(target, dryRun: true)
        #expect(preview.entries.first?.result == .dryRun)
        #expect(fixture.userFiles() == before)
        #expect(uninstaller.engine.ledger.operations().isEmpty)

        let operation = await uninstaller.removeOrphan(target)
        #expect(operation.kind == .uninstall)
        #expect(operation.entries.count == 1)
        #expect(operation.entries.first?.result == .removed)
        #expect(operation.entries.first?.mode == "trash")
        #expect(operation.bytesFreed == target.bytes)
        #expect(fixture.trashed() == ["com.gone.OldApp"])
        // Only that one went.
        #expect(!fixture.exists("Library/Application Support/com.gone.OldApp"))
        #expect(fixture.userFiles().count == before.count)
        #expect(fixture.exists("Library/Preferences/com.gone.OldApp.plist"))
        #expect(await uninstaller.orphans().count == orphans.count - 1)
        #expect(uninstaller.engine.ledger.operations().count == 1)
    }

    @Test func anythingChangedRecentlyIsStillInUse() async throws {
        let fixture = try FixtureHome()
        try fixture.app("Foo Editor", bundleID: "com.foo.App")
        try fixture.write("Library/Caches/com.gone.OldApp/blob")
        try fixture.write("Library/Preferences/com.gone.OldApp.plist")
        try fixture.write("Library/Application Support/com.gone.Active/state.db")
        try fixture.write("Library/Application Support/com.gone.Deep/a/b/old.db")
        try fixture.write("Library/Application Support/com.gone.Deep/a/b/written-today.db")
        // Three months old, except what is named otherwise.
        let old = Date().addingTimeInterval(-90 * 24 * 3600)
        for relative in ["Library/Caches/com.gone.OldApp", "Library/Preferences/com.gone.OldApp.plist", "Library/Application Support/com.gone.Deep"] {
            let root = fixture.path(relative)
            let inside = FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String } ?? []
            for path in [root] + inside.map({ root + "/" + $0 }) where !path.hasSuffix("written-today.db") {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
            }
        }

        // The default: untouched for 30 days or it is not an orphan.
        let uninstaller = uninstaller(fixture, minimumAge: UninstallEnvironment.fixture(home: fixture.home).orphanMinimumAge)
        #expect(uninstaller.environment.orphanMinimumAge == 30 * 24 * 3600)
        let orphans = await uninstaller.orphans()
        #expect(orphans.map(\.path).sorted() == [
            fixture.path("Library/Caches/com.gone.OldApp"), fixture.path("Library/Preferences/com.gone.OldApp.plist"),
        ])

        // Asking for the removal of something that is in use changes nothing.
        let active = fixture.path("Library/Application Support/com.gone.Deep")
        let operation = await uninstaller.removeOrphan(Orphan(
            path: active, bundleID: "com.gone.Deep", location: .applicationSupport, fingerprint: Fingerprint(path: active)))
        #expect(operation.entries.first?.result == .skipped)
        #expect(fixture.exists("Library/Application Support/com.gone.Deep/a/b/old.db"))
        #expect(fixture.trashed().isEmpty)
    }

    @Test func aForgedOrphanIsNotRemoved() async throws {
        let fixture = try populated()
        let uninstaller = uninstaller(fixture)
        for path in ["Documents", "Library/Caches/com.foo.App", "Library/Caches/com.gone.Link", "Applications/Foo Editor.app", "Library/Caches"] {
            let full = fixture.path(path)
            let forged = Orphan(path: full, bundleID: "com.gone.OldApp", location: .caches, fingerprint: Fingerprint(path: full))
            let operation = await uninstaller.removeOrphan(forged)
            #expect(operation.entries.first?.result == .skipped)
            #expect(operation.entries.first?.reason == "no longer an orphan")
        }
        #expect(fixture.trashed().isEmpty)
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(fixture.exists("Library/Caches/com.foo.App/blob"))
    }

    @Test func orphanNames() {
        #expect(OrphanName.bundleID(from: "com.foo.App.plist", in: .preferences) == "com.foo.App")
        #expect(OrphanName.bundleID(from: "com.foo.App.savedState", in: .savedState) == "com.foo.App")
        #expect(OrphanName.bundleID(from: "com.foo.App.43CA8902-DB90-5A35-B3C9-62F44D84A1E3.plist", in: .preferencesByHost) == "com.foo.App")
        #expect(OrphanName.bundleID(from: "ABCDE12345.group.com.foo.App", in: .groupContainers) == "com.foo.App")
        #expect(OrphanName.bundleID(from: "group.com.foo.App", in: .groupContainers) == "com.foo.App")
        #expect(OrphanName.bundleID(from: "UBF8T346G9.Office", in: .groupContainers) == nil)
        #expect(OrphanName.bundleID(from: "com.apple.Music", in: .webKit) == nil)
        #expect(OrphanName.bundleID(from: "com.foo", in: .caches) == nil)
        #expect(OrphanName.bundleID(from: "Google", in: .applicationSupport) == nil)
        #expect(OrphanName.bundleID(from: "my app.data.cache", in: .caches) == nil)
        #expect(OrphanName.bundleID(from: ".com.foo.App", in: .caches) == nil)

        for tool in ["org.swift.swiftpm", "com.vercel.cli", "org.cups.PrintingPrefs", "com.android.Emulator", "com.acme.sync-daemon.agent"] {
            #expect(BundleIdentifier.looksLikeTool(tool), "\(tool) is a tool, not an app")
        }
        #expect(!BundleIdentifier.looksLikeTool("com.gone.OldApp"))
    }
}

@Suite struct DockTests {
    private func tile(_ url: String?, bundleID: String) -> [String: Any] {
        var data: [String: Any] = ["bundle-identifier": bundleID, "file-label": "x"]
        if let url { data["file-data"] = ["_CFURLString": url, "_CFURLStringType": 15] }
        return ["tile-type": "file-tile", "tile-data": data]
    }

    @Test func removesOnlyTheAppsOwnTile() {
        let tiles = [
            tile("file:///Applications/Foo%20Editor.app/", bundleID: "com.foo.App"),
            tile("file:///Applications/Other.app/", bundleID: "com.other.App"),
            // Another copy of the same app elsewhere keeps its tile.
            tile("file:///Users/me/Applications/Foo%20Editor.app/", bundleID: "com.foo.App"),
            tile(nil, bundleID: "com.foo.App"),
            tile("/Applications/Plain.app", bundleID: "com.plain.App"),
        ]
        let kept = DockTiles.removing(appPath: "/Applications/Foo Editor.app", bundleID: "com.foo.App", from: tiles)
        #expect(kept.compactMap { DockTiles.path(of: $0) } == [
            "/Applications/Other.app", "/Users/me/Applications/Foo Editor.app", "/Applications/Plain.app",
        ])
        #expect(kept.count == 3)

        let untouched = DockTiles.removing(appPath: "/Applications/Missing.app", bundleID: nil, from: tiles)
        #expect(untouched.count == tiles.count)
        #expect(DockTiles.removing(appPath: "/Applications/Plain.app", bundleID: nil, from: tiles).count == 4)
    }
}
