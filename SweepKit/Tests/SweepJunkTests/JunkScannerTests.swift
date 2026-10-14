import Foundation
import SweepKit
import SweepTestSupport
import Testing
@testable import SweepJunk

@Suite struct JunkScannerTests {
    @Test func everyCategoryIsFound() async throws {
        let fixture = try FixtureHome()
        try fixture.populateEverything()
        let options = JunkOptions(now: ninetyDaysAhead, systemCachesDirectory: fixture.path("SystemCaches"))
        let entries = await fixture.scanner(privileged: FakePrivileged(), options: options).scanCollected()

        #expect(Set(entries.map(\.category)) == Set(JunkCategory.allCases))
        for entry in entries {
            #expect(!entry.isSizing)
            #expect(entry.bytes > 0, "\(entry.name) has no size")
            #expect(!entry.paths.isEmpty)
            #expect(entry.lastModified != nil, "\(entry.name) has no date")
        }

        let spotify = try #require(entries.named("Spotify"))
        #expect(spotify.category == .userCaches)
        #expect(spotify.detail == "com.spotify.client")
        #expect(spotify.paths == [fixture.path("Library/Caches/com.spotify.client")])
        #expect(spotify.bytes == 64 * 1024)
        #expect(spotify.risk == .safe)
        #expect(spotify.isSelectedByDefault)

        #expect(entries.of(.browserCaches).map(\.name).sorted() == ["Google Chrome", "Safari"])
        #expect(entries.of(.logs).map(\.name).sorted() == ["SomeApp", "install.log"])
        #expect(entries.of(.crashReports).first?.paths == [fixture.path("Library/Logs/DiagnosticReports/SomeApp-2026-01-01.ips")])
        #expect(entries.of(.mailDownloads).first?.paths
            == [fixture.path("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/4F2A")])
        #expect(entries.of(.installers).map(\.name) == ["Old Installer.dmg"])
        #expect(entries.of(.systemCaches).first?.paths == [fixture.path("SystemCaches")])
        #expect(entries.of(.trash).first?.paths == [fixture.path(".Trash/old-report.txt")])
    }

    @Test func tiersAndDefaultSelectionFollowTheSpec() async throws {
        let fixture = try FixtureHome()
        try fixture.populateEverything()
        let options = JunkOptions(now: ninetyDaysAhead, systemCachesDirectory: fixture.path("SystemCaches"))
        let entries = await fixture.scanner(privileged: FakePrivileged(), options: options).scanCollected()

        for entry in entries {
            switch entry.category {
            case .userCaches, .browserCaches, .logs, .crashReports, .dsStore:
                #expect(entry.risk == .safe)
                #expect(entry.isSelectedByDefault, "\(entry.name) should start ticked")
                #expect(!entry.needsConfirmation)
            case .mailDownloads, .installers, .systemCaches, .trash:
                #expect(entry.risk == .caution)
                #expect(!entry.isSelectedByDefault, "\(entry.name) must not start ticked")
                #expect(entry.needsConfirmation)
            case .deviceBackups:
                #expect(entry.risk == .ask)
                #expect(!entry.isSelectedByDefault)
                #expect(entry.needsConfirmation)
            }
        }
    }

    @Test func devCacheFoldersAreNotListed() async throws {
        let fixture = try FixtureHome()
        let devFolders = [
            "Homebrew", "pip", "Yarn", "node-gyp", "electron", "electron-builder", "ms-playwright", "Cypress",
            "pypoetry", "pipenv", "CocoaPods", "org.swift.swiftpm", "org.carthage.CarthageKit", "JetBrains",
            "Google/AndroidStudio2025.3", "go-build", "composer", "deno", "typescript",
        ]
        for folder in devFolders {
            try fixture.write("Library/Caches/\(folder)/payload", bytes: 8192)
        }
        // A tool added through the catalog is owned by Dev Caches as well.
        try fixture.write("Library/Caches/mytool/payload", bytes: 8192)
        try fixture.write("Library/Caches/com.example.app/payload", bytes: 8192)
        try fixture.write("Library/Caches/Google/GoogleUpdater/payload", bytes: 8192)

        let custom = CatalogItem.rule("mytool", paths: ["~/Library/Caches/mytool"])
        let entries = await fixture.scanner(items: [custom]).scanCollected()

        #expect(Set(entries.allPaths) == [
            fixture.path("Library/Caches/com.example.app"),
            fixture.path("Library/Caches/Google/GoogleUpdater"),
        ])
        #expect(entries.allSatisfy { $0.category == .userCaches })
    }

    @Test func theBundledCatalogOwnsItsCacheFolders() async throws {
        let fixture = try FixtureHome()
        let owned = Catalog.bundled().items
            .flatMap { $0.locate.flatMap { $0.paths ?? [] } + ($0.alsoPaths ?? []) }
            .filter { $0.hasPrefix("~/Library/Caches/") && !$0.contains("*") && !$0.contains("{") }
        #expect(owned.count > 10)
        for path in owned where path != "~/Library/Caches/Google" {
            try fixture.write(String(path.dropFirst(2)) + "/payload", bytes: 8192)
        }
        // No catalog is handed to the scanner: the built-in list must cover the bundled rules.
        let entries = await fixture.scanner().scanCollected()
        #expect(entries.isEmpty, "listed twice: \(entries.allPaths)")
    }

    @Test func cachesOfRunningAppsAreSkippedWithTheReason() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.spotify.client/blob", bytes: 8192)
        try fixture.write("Library/Caches/com.example.other/blob", bytes: 8192)
        try fixture.write("Library/Caches/com.apple.Safari/Cache.db", bytes: 8192)
        try fixture.write("Library/Caches/Firefox/Profiles/abc/cache2/entry", bytes: 8192)
        try fixture.write("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A/file.pdf")

        let entries = await fixture.scanner(processes: ["Spotify", "Safari", "Mail"]).scanCollected()

        let spotify = try #require(entries.named("Spotify"))
        #expect(spotify.blockedReason == "Spotify is running")
        #expect(!spotify.isSelectedByDefault)
        #expect(spotify.bytes == 8192)

        let other = try #require(entries.named("Other"))
        #expect(other.blockedReason == nil)
        #expect(other.isSelectedByDefault)

        #expect(entries.named("Safari")?.blockedReason == "Safari is running")
        #expect(entries.named("Firefox")?.blockedReason == nil)
        #expect(entries.named("Mail downloads")?.blockedReason == "Mail is running")
    }

    @Test func runningAppsAreMatchedByBundleIdentifier() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.tinyspeck.slackmacgap/blob", bytes: 8192)
        try fixture.write("Library/Caches/com.tinyspeck.slackmacgap.ShipIt/blob", bytes: 8192)
        try fixture.write("Library/Caches/com.example.quiet/blob", bytes: 8192)
        let processes = StaticProcessList([
            RunningProcess(pid: 42, name: "Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack", bundleID: "com.tinyspeck.slackmacgap"),
        ])
        let context = SweepContext.fixture(home: fixture.home, processes: processes)
        let engine = SweepEngine(context: context, catalog: Catalog(items: []), settings: SweepSettings())
        let entries = await JunkScanner(engine: engine).scanCollected()

        let blocked = entries.filter(\.isBlocked).flatMap(\.paths)
        #expect(Set(blocked) == [
            fixture.path("Library/Caches/com.tinyspeck.slackmacgap"),
            fixture.path("Library/Caches/com.tinyspeck.slackmacgap.ShipIt"),
        ])
    }

    @Test func oldInstallersAreListedAndRecentOnesAreNot() async throws {
        let fixture = try FixtureHome()
        for name in ["Old.dmg", "Old.pkg", "Old.xip", "Old.iso", "OLD-UPPER.DMG"] {
            try fixture.write("Downloads/\(name)", bytes: 8192)
        }
        for name in ["Recent.dmg", "Recent.pkg"] {
            try fixture.write("Downloads/\(name)", bytes: 8192)
            try fixture.touch("Downloads/\(name)", daysBeforeScan: 10)
        }
        // Old, but not installers.
        try fixture.write("Downloads/notes.txt", bytes: 8192)
        try fixture.write("Downloads/holiday.mov", bytes: 8192)
        // Only the top level of Downloads is looked at.
        try fixture.write("Downloads/Archive/Nested.dmg", bytes: 8192)
        // A link to an installer is not an installer.
        try fixture.symlink("Downloads/Linked.dmg", to: fixture.path("Documents/thesis.txt"))

        let entries = await fixture.scanner().scanCollected().of(.installers)
        #expect(entries.map(\.name).sorted() == ["OLD-UPPER.DMG", "Old.dmg", "Old.iso", "Old.pkg", "Old.xip"])
        #expect(entries.allSatisfy { $0.risk == .caution && !$0.isSelectedByDefault })
    }

    @Test func aBoundaryInstallerIsKeptUntilItIsThirtyDaysOld() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Downloads/Day29.dmg", bytes: 8192)
        try fixture.touch("Downloads/Day29.dmg", daysBeforeScan: 29)
        try fixture.write("Downloads/Day31.dmg", bytes: 8192)
        try fixture.touch("Downloads/Day31.dmg", daysBeforeScan: 31)

        let entries = await fixture.scanner().scanCollected().of(.installers)
        // The newer of "modified" and "added to Downloads" decides the age.
        #expect(entries.map(\.name) == ["Day31.dmg"])
    }

    @Test func aZipIsListedOnlyWhenItHoldsAnAppInstaller() async throws {
        let fixture = try FixtureHome()
        try fixture.writeZip("Downloads/App.zip", entries: [
            "MyApp.app/", "MyApp.app/Contents/", "MyApp.app/Contents/Info.plist", "MyApp.app/Contents/MacOS/MyApp",
            "__MACOSX/MyApp.app/._Contents",
        ])
        try fixture.writeZip("Downloads/Package.zip", entries: ["Installer.pkg"])
        try fixture.writeZip("Downloads/Photos.zip", entries: ["a.jpg", "b.jpg"])
        try fixture.writeZip("Downloads/Project.zip", entries: [
            "project/README.md", "project/build/MyApp.app/Contents/Info.plist",
        ])
        try fixture.writeZip("Downloads/AppAndNotes.zip", entries: ["MyApp.app/Contents/Info.plist", "tax-return.pdf"])
        try fixture.writeZip("Downloads/FakeApp.zip", entries: ["Thing.app/readme.txt"])
        try fixture.write("Downloads/Garbage.zip", bytes: 8192)
        try fixture.write("Downloads/Empty.zip", bytes: 0)

        let entries = await fixture.scanner().scanCollected().of(.installers)
        #expect(entries.map(\.name).sorted() == ["App.zip", "Package.zip"])
    }

    @Test func zipInspectorReadsEntryNames() throws {
        let fixture = try FixtureHome()
        try fixture.writeZip("a.zip", entries: ["One.app/Contents/Info.plist", "two.txt"])
        #expect(ZipInspector.entryNames(atPath: fixture.path("a.zip")) == ["One.app/Contents/Info.plist", "two.txt"])
        #expect(!ZipInspector.isAppInstaller(atPath: fixture.path("a.zip")))
        #expect(ZipInspector.entryNames(atPath: fixture.path("missing.zip")) == nil)
        try fixture.write("text.zip", bytes: 100)
        #expect(ZipInspector.entryNames(atPath: fixture.path("text.zip")) == nil)
    }

    @Test func sweepsOwnLogFolderIsNeverListed() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Logs/Sweep/operations.jsonl", bytes: 64 * 1024)
        try fixture.write("Library/Logs/Sweep/archive/2025.jsonl", bytes: 8192)
        try fixture.write("Library/Logs/OtherApp/run.log", bytes: 8192)

        let entries = await fixture.scanner().scanCollected()
        #expect(entries.allPaths == [fixture.path("Library/Logs/OtherApp")])
        #expect(!entries.allPaths.contains { $0.contains("/Library/Logs/Sweep") })
    }

    @Test func crashReportsAreOneEntryAndNotListedAsLogs() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Logs/DiagnosticReports/a.ips", bytes: 8192)
        try fixture.write("Library/Logs/DiagnosticReports/Retired/b.ips", bytes: 8192)

        let entries = await fixture.scanner().scanCollected()
        #expect(entries.count == 1)
        let reports = try #require(entries.first)
        #expect(reports.category == .crashReports)
        #expect(reports.bytes == 16384)
        #expect(Set(reports.paths) == [
            fixture.path("Library/Logs/DiagnosticReports/a.ips"),
            fixture.path("Library/Logs/DiagnosticReports/Retired"),
        ])
    }

    @Test func browserEntriesNameOnlyCacheFolders() async throws {
        let fixture = try FixtureHome()
        let caches = [
            "com.apple.Safari/Cache.db", "Google/Chrome/Default/Cache/data_0", "Arc/User Data/Default/Cache/data_0",
            "BraveSoftware/Brave-Browser/Default/Cache/data_0", "Firefox/Profiles/x.default/cache2/entries/1",
            "Microsoft Edge/Default/Cache/data_0", "com.google.Chrome.helper/blob", "com.apple.Safari.SafeBrowsing/blob",
        ]
        for cache in caches { try fixture.write("Library/Caches/\(cache)", bytes: 8192) }
        try fixture.write("Library/Containers/com.apple.Safari/Data/Library/Caches/WebKit/blob", bytes: 8192)
        let profiles = [
            "Library/Safari/History.db", "Library/Safari/Bookmarks.plist", "Library/Cookies/Cookies.binarycookies",
            "Library/Application Support/Google/Chrome/Default/Cookies", "Library/Application Support/Google/Chrome/Default/History",
            "Library/Application Support/Firefox/Profiles/x.default/places.sqlite",
            "Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks",
            "Library/Application Support/Microsoft Edge/Default/Login Data",
            "Library/Application Support/Arc/User Data/Default/History",
        ]
        for profile in profiles { try fixture.write(profile) }

        let entries = await fixture.scanner().scanCollected()
        // Browser helpers' caches are not listed as app caches either.
        #expect(entries.allSatisfy { $0.category == .browserCaches })
        #expect(entries.map(\.name).sorted() == ["Arc", "Brave", "Firefox", "Google Chrome", "Microsoft Edge", "Safari"])

        let cacheRoot = fixture.path("Library/Caches") + "/"
        let safariContainer = fixture.path("Library/Containers/com.apple.Safari/Data/Library/Caches") + "/"
        for path in entries.allPaths {
            #expect(path.hasPrefix(cacheRoot) || path.hasPrefix(safariContainer), "\(path) is not a cache folder")
        }
        #expect(entries.named("Safari")?.paths.count == 2)

        let report = await fixture.cleaner().clean(entries)
        #expect(report.problems.isEmpty)
        for profile in profiles { #expect(fixture.exists(profile), "\(profile) was removed") }
        for cache in caches.prefix(6) {
            #expect(!fixture.exists("Library/Caches/\(cache)"))
        }
        #expect(fixture.exists("Library/Containers/com.apple.Safari/Data/Library/Caches"))
        #expect(!fixture.exists("Library/Containers/com.apple.Safari/Data/Library/Caches/WebKit"))
    }

    @Test func dsStoreSearchSkipsWhatItShould() async throws {
        let fixture = try FixtureHome()
        let listed = [".DS_Store", "Downloads/.DS_Store", "Projects/app/.DS_Store", "Projects/app/Sources/.DS_Store"]
        let ignored = [
            "Library/.DS_Store", "Library/Caches/.DS_Store", "Documents/.DS_Store", "Desktop/.DS_Store", "Pictures/.DS_Store",
            ".config/.DS_Store", "Projects/app/node_modules/.DS_Store", "Projects/app/.git/.DS_Store",
            "Projects/app/node_modules/pkg/.DS_Store", "Applications/Tool.app/Contents/.DS_Store", "Projects/.hidden/.DS_Store",
        ]
        for path in listed + ignored { try fixture.write(path) }
        try fixture.write("Projects/app/main.swift")

        let entries = await fixture.scanner().scanCollected()
        #expect(entries.count == 1)
        let stores = try #require(entries.of(.dsStore).first)
        #expect(Set(stores.paths) == Set(listed.map(fixture.path)))
        #expect(stores.detail == "4 files")
        #expect(stores.isSelectedByDefault)
    }

    @Test func dsStoreSearchIsCappedInDepthAndCount() async throws {
        let fixture = try FixtureHome()
        try fixture.write("a/.DS_Store")
        try fixture.write("a/b/.DS_Store")
        try fixture.write("a/b/c/.DS_Store")
        try fixture.write("a/b/c/d/.DS_Store")

        var options = JunkOptions(now: ninetyDaysAhead, dsStoreMaxDepth: 2)
        var stores = await fixture.scanner(options: options).scanCollected().of(.dsStore)
        #expect(Set(stores.allPaths) == [fixture.path("a/.DS_Store"), fixture.path("a/b/.DS_Store")])

        options = JunkOptions(now: ninetyDaysAhead, dsStoreMaxCount: 3)
        stores = await fixture.scanner(options: options).scanCollected().of(.dsStore)
        // Breadth first, so the shallowest files are the ones kept.
        #expect(Set(stores.allPaths) == [fixture.path("a/.DS_Store"), fixture.path("a/b/.DS_Store"), fixture.path("a/b/c/.DS_Store")])

        options = JunkOptions(now: ninetyDaysAhead, dsStoreMaxFolders: 2)
        stores = await fixture.scanner(options: options).scanCollected().of(.dsStore)
        #expect(stores.allPaths == [fixture.path("a/.DS_Store")])
    }

    @Test func deviceBackupsShowTheDeviceAndItsBackupDate() async throws {
        let fixture = try FixtureHome()
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        try fixture.writeBackup("00008030-AAAA", deviceName: "Rickson's iPhone", product: "iPhone 15 Pro", date: date)
        try fixture.writeBackup("00008030-BBBB", deviceName: "Kitchen iPad", product: "iPad Air", date: date.addingTimeInterval(-86_400))
        // No readable Info.plist: still listed, by folder name.
        try fixture.write("Library/Application Support/MobileSync/Backup/00008030-CCCC/Manifest.db", bytes: 8192)

        let entries = await fixture.scanner().scanCollected()
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.category == .deviceBackups && $0.risk == .ask && !$0.isSelectedByDefault })

        let phone = try #require(entries.named("Rickson's iPhone"))
        #expect(phone.detail == "iPhone 15 Pro · iOS 18.2")
        #expect(phone.lastModified == date)
        #expect(phone.paths == [fixture.path("Library/Application Support/MobileSync/Backup/00008030-AAAA")])
        #expect(entries.named("Kitchen iPad")?.detail == "iPad Air · iPadOS 18.2")
        #expect(entries.named("Backup 00008030") != nil)
    }

    @Test func reviewOrderIsRiskThenSizeWithTrashLast() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.example.small/blob", bytes: 8 * 1024)
        try fixture.write("Library/Caches/com.example.large/blob", bytes: 512 * 1024)
        try fixture.write("Library/Logs/Medium/run.log", bytes: 64 * 1024)
        try fixture.write("Downloads/Small.dmg", bytes: 16 * 1024)
        try fixture.write("Downloads/Big.dmg", bytes: 2 * 1024 * 1024)
        try fixture.writeBackup("0000-ASK", deviceName: "Phone", product: "iPhone", date: Date(), bytes: 4 * 1024 * 1024)
        try fixture.write(".Trash/huge.bin", bytes: 8 * 1024 * 1024)
        try fixture.write("SystemCaches/blob", bytes: 256 * 1024)

        let options = JunkOptions(now: ninetyDaysAhead, systemCachesDirectory: fixture.path("SystemCaches"))
        let entries = await fixture.scanner(privileged: FakePrivileged(), options: options).scanCollected()

        #expect(entries.map(\.name) == ["Large", "Medium", "Small", "Big.dmg", "System caches", "Small.dmg", "Phone", "Trash"])
        #expect(entries.last?.category == .trash)

        let body = entries.dropLast()
        #expect(!body.contains { $0.category == .trash })
        for (a, b) in zip(body, body.dropFirst()) {
            #expect(a.risk <= b.risk, "\(a.name) before \(b.name)")
            if a.risk == b.risk { #expect(a.bytes >= b.bytes, "\(a.name) before \(b.name)") }
        }
        // The Trash is the largest entry and still comes after everything else.
        #expect(entries.last?.bytes == entries.map(\.bytes).max())
    }

    @Test func theTrashIsNeverPreselected() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".Trash/a.txt")
        try fixture.write(".Trash/folder/b.txt")
        try fixture.symlink(".Trash/link", to: fixture.path("Documents"))

        let entries = await fixture.scanner().scanCollected()
        let trash = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(trash.category == .trash)
        #expect(!trash.isSelectedByDefault)
        #expect(Set(trash.paths) == [fixture.path(".Trash/a.txt"), fixture.path(".Trash/folder")])
    }

    @Test func systemCachesNeedAnAdminRunnerAndAreHiddenForFixtures() async throws {
        let fixture = try FixtureHome()
        try fixture.write("SystemCaches/blob", bytes: 8192)
        let override = JunkOptions(now: ninetyDaysAhead, systemCachesDirectory: fixture.path("SystemCaches"))

        // No runner: nothing to offer.
        #expect(await fixture.scanner(options: override).scanCollected().isEmpty)
        #expect(await fixture.scanner(privileged: FakePrivileged(.unavailable), options: override).scanCollected().isEmpty)
        // A fixture home never shows the machine's real /Library/Caches.
        #expect(await fixture.scanner(privileged: FakePrivileged()).scanCollected().isEmpty)

        for state in [PrivilegedAvailability.helper, .passwordPrompt] {
            let entries = await fixture.scanner(privileged: FakePrivileged(state), options: override).scanCollected()
            #expect(entries.map(\.category) == [.systemCaches])
            #expect(entries.first?.risk == .caution)
            #expect(entries.first?.isSelectedByDefault == false)
        }
    }

    @Test func exclusionsFromSettingsAreNotListed() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.keep.me/blob", bytes: 8192)
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)
        try fixture.write("Projects/keep/.DS_Store")
        var settings = SweepSettings()
        settings.exclusions = ["~/Library/Caches/com.keep.me", "~/Projects"]

        let entries = await fixture.scanner(settings: settings).scanCollected()
        #expect(entries.allPaths == [fixture.path("Library/Caches/com.example.app")])
    }

    @Test func linksAndEmptyFoldersAreNotListed() async throws {
        let fixture = try FixtureHome()
        try fixture.symlink("Library/Caches/com.evil.cache", to: fixture.path("Documents"))
        try fixture.symlink("Library/Logs/evil.log", to: fixture.path("Documents/thesis.txt"))
        try fixture.mkdir("Library/Caches/com.example.empty")
        try fixture.write("Library/Caches/loose-file.db", bytes: 8192)

        #expect(await fixture.scanner().scanCollected().isEmpty)
    }

    @Test func aLinkedContainerIsIgnored() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Documents/Reports/q1.txt")
        try FileManager.default.removeItem(atPath: fixture.path("Library/Caches"))
        try fixture.symlink("Library/Caches", to: fixture.path("Documents"))
        try fixture.symlink("Library/Logs", to: fixture.path("Documents"))
        try fixture.symlink("Downloads", to: fixture.path("Documents"))
        try fixture.symlink(".Trash", to: fixture.path("Documents"))

        #expect(await fixture.scanner().scanCollected().isEmpty)
    }

    @Test func sizesArriveAfterTheEntryAppears() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)
        try fixture.mkdir("Library/Caches/com.example.empty")

        var seen: [String: [JunkEntry]] = [:]
        var dropped: [String] = []
        for await event in fixture.scanner().scan() {
            switch event {
            case .entry(let entry): seen[entry.id, default: []].append(entry)
            case .dropped(let id): dropped.append(id)
            }
        }
        let versions = try #require(seen["userCaches:" + fixture.path("Library/Caches/com.example.app")])
        #expect(versions.map(\.isSizing) == [true, false])
        #expect(versions.map(\.bytes) == [0, 8192])
        #expect(dropped == ["userCaches:" + fixture.path("Library/Caches/com.example.empty")])
    }

    @Test func fullDiskAccessIsDetectedByReadingSafari() async throws {
        let fixture = try FixtureHome()
        let scanner = fixture.scanner()
        #expect(scanner.fullDiskAccess == .unknown)
        #expect(!scanner.isFullDiskAccessMissing)

        try fixture.write("Library/Safari/History.db")
        #expect(scanner.fullDiskAccess == .granted)
        #expect(!scanner.isFullDiskAccessMissing)

        // An unreadable folder stands in for macOS refusing the read.
        chmod(fixture.path("Library/Safari"), 0)
        defer { chmod(fixture.path("Library/Safari"), 0o755) }
        #expect(scanner.fullDiskAccess == .denied)
        #expect(scanner.isFullDiskAccessMissing)
        #expect(FullDiskAccess.status(context: scanner.engine.context) == .denied)

        #expect(scanner.fullDiskAccessSettingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    @Test func unreadableLocationsExplainThemselves() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Safari/History.db")
        try fixture.write(".Trash/a.txt")
        try fixture.write("Library/Application Support/MobileSync/Backup/0000/Manifest.db")
        try fixture.write("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A/file.pdf")
        let locked = [
            "Library/Safari", ".Trash", "Library/Application Support/MobileSync/Backup",
            "Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        ]
        for folder in locked { chmod(fixture.path(folder), 0) }
        defer { for folder in locked { chmod(fixture.path(folder), 0o755) } }

        let entries = await fixture.scanner().scanCollected()
        #expect(Set(entries.map(\.category)) == [.trash, .deviceBackups, .mailDownloads])
        for entry in entries {
            #expect(entry.blockedReason == "Needs Full Disk Access")
            #expect(!entry.isSelectedByDefault)
            #expect(entry.bytes == 0)
        }
        #expect(entries.last?.category == .trash)
    }

    @Test func namesAreReadable() {
        #expect(JunkNaming.appName(fromFolder: "com.spotify.client") == "Spotify")
        #expect(JunkNaming.appName(fromFolder: "com.apple.Safari") == "Safari")
        #expect(JunkNaming.appName(fromFolder: "org.mozilla.firefox") == "Firefox")
        #expect(JunkNaming.appName(fromFolder: "com.microsoft.VSCode") == "VSCode")
        #expect(JunkNaming.appName(fromFolder: "us.zoom.xos") == "Zoom")
        #expect(JunkNaming.appName(fromFolder: "Microsoft Edge") == "Microsoft Edge")
        #expect(JunkNaming.appName(fromFolder: "SomeApp") == "SomeApp")
        #expect(JunkNaming.appName(fromFolder: "node-gyp") == "node-gyp")
        #expect(JunkNaming.appName(fromFolder: "archive.tar.gz") == "archive.tar.gz")
        #expect(JunkNaming.isBundleID("jp.co.example.app"))
        #expect(!JunkNaming.isBundleID("My App.v2.cache"))
    }
}
