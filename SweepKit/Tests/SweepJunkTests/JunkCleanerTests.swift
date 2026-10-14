import Foundation
import SweepKit
import SweepTestSupport
import Testing
@testable import SweepJunk

@Suite struct JunkCleanerTests {
    /// Files that no clean may ever remove.
    private static let untouchable = [
        "Documents/thesis.txt", ".ssh/id_ed25519", "Library/Logs/House Keeping/operations.jsonl",
        "Library/Caches/Homebrew/downloads/bottle.tar.gz", "Library/Application Support/Google/Chrome/Default/Cookies",
        "Library/Safari/History.db", "Projects/app/README.md", "SystemCaches/com.apple.something/cache.bin",
    ]

    private func trashed(_ fixture: FixtureHome) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash"))) ?? []).sorted()
    }

    /// Every file in the fixture except the ledger a clean writes.
    private func withoutLedger(_ fixture: FixtureHome) -> Set<String> {
        fixture.files().subtracting([fixture.path("Library/Logs/House Keeping/operations.jsonl")])
    }

    @Test func cleaningRemovesOnlyTheTickedEntries() async throws {
        let fixture = try FixtureHome()
        try fixture.populateEverything()
        let entries = await fixture.scanner().scanCollected()
        let before = fixture.files()

        let spotify = try #require(entries.named("Spotify"))
        let report = await fixture.cleaner().clean([spotify])

        let after = fixture.files()
        #expect(before.subtracting(after) == [fixture.path("Library/Caches/com.spotify.client/Data/blob")])
        #expect(after.subtracting(before).isEmpty)
        #expect(!fixture.exists("Library/Caches/com.spotify.client"))
        #expect(fixture.exists("Library/Caches/com.example.editor/index"))

        #expect(report.results.count == 1)
        let result = try #require(report.result(for: spotify.id))
        #expect(result.status == .cleaned)
        #expect(result.bytes == 64 * 1024)
        #expect(!result.movedToTrash)
        #expect(result.removedCount == 1)
        #expect(result.problemCount == 0)
        #expect(report.bytesFreed == 64 * 1024)
        #expect(report.bytesTrashed == 0)
        #expect(report.problems.isEmpty)
    }

    @Test func theDefaultSelectionLeavesCautionAskAndTrashAlone() async throws {
        let fixture = try FixtureHome()
        try fixture.populateEverything()
        let options = JunkOptions(now: ninetyDaysAhead, systemCachesDirectory: fixture.path("SystemCaches"))
        let privileged = FakePrivileged()
        let entries = await fixture.scanner(privileged: privileged, options: options).scanCollected()

        let ticked = entries.filter(\.isSelectedByDefault)
        let report = await fixture.cleaner(privileged: privileged, options: options).clean(ticked)
        #expect(report.problems.isEmpty)
        #expect(report.results.count == ticked.count)
        #expect(privileged.calls.isEmpty)

        for gone in [
            "Library/Caches/com.spotify.client", "Library/Caches/com.example.editor", "Library/Caches/com.apple.Safari",
            "Library/Caches/Google/Chrome", "Library/Logs/SomeApp", "Library/Logs/install.log",
            "Library/Logs/DiagnosticReports/SomeApp-2026-01-01.ips", "Downloads/.DS_Store", "Projects/app/.DS_Store",
        ] {
            #expect(!fixture.exists(gone), "\(gone) should be gone")
        }
        for kept in Self.untouchable + [
            "Downloads/Old Installer.dmg", ".Trash/old-report.txt",
            "Library/Application Support/MobileSync/Backup/00008030-000A1B2C3D4E/Manifest.db",
            "Library/Containers/com.apple.mail/Data/Library/Mail Downloads/4F2A/invoice.pdf",
            "Library/Caches", "Library/Logs", "Library/Logs/DiagnosticReports", "Downloads",
        ] {
            #expect(fixture.exists(kept), "\(kept) should still be there")
        }
    }

    @Test func cleaningEverythingStaysInsideTheJunkFolders() async throws {
        let fixture = try FixtureHome()
        try fixture.populateEverything()
        let options = JunkOptions(now: ninetyDaysAhead, systemCachesDirectory: fixture.path("SystemCaches"))
        let privileged = FakePrivileged()
        let entries = await fixture.scanner(privileged: privileged, options: options).scanCollected()
        let before = fixture.files()

        let report = await fixture.cleaner(privileged: privileged, options: options).clean(entries)
        #expect(report.problems.isEmpty)
        #expect(privileged.calls == [.cleanSystemCaches])

        let allowed = [
            "Library/Caches/com.", "Library/Caches/Google/Chrome/", "Library/Logs/SomeApp/", "Library/Logs/install.log",
            "Library/Logs/DiagnosticReports/", "Library/Containers/com.apple.mail/Data/Library/Mail Downloads/",
            "Library/Application Support/MobileSync/Backup/", "Downloads/", "Projects/app/.DS_Store", ".Trash/",
        ].map(fixture.path)
        for removed in before.subtracting(fixture.files()) {
            #expect(allowed.contains { removed.hasPrefix($0) }, "\(removed) is outside every junk location")
        }
        for kept in Self.untouchable { #expect(fixture.exists(kept), "\(kept) should still be there") }
        // Installers, Mail downloads and the backup were moved to the Trash, not deleted; what was in the Trash is gone.
        #expect(trashed(fixture).map { String($0.dropFirst(9)) }.sorted() == ["00008030-000A1B2C3D4E", "4F2A", "Old Installer.dmg"])
        #expect(report.bytesTrashed > 0)
        #expect(report.bytesFreed > 0)
    }

    @Test func aDryRunTouchesNothing() async throws {
        let fixture = try FixtureHome()
        try fixture.populateEverything()
        let options = JunkOptions(now: ninetyDaysAhead, systemCachesDirectory: fixture.path("SystemCaches"))
        let privileged = FakePrivileged()
        let entries = await fixture.scanner(privileged: privileged, options: options).scanCollected()
        let before = fixture.files()
        let ledgerBefore = try Data(contentsOf: URL(fileURLWithPath: fixture.path("Library/Logs/House Keeping/operations.jsonl")))

        let cleaner = fixture.cleaner(privileged: privileged, options: options)
        let report = await cleaner.clean(entries, dryRun: true)

        #expect(fixture.files() == before)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path("Library/Logs/House Keeping/operations.jsonl"))) == ledgerBefore)
        #expect(privileged.calls.isEmpty)
        #expect(trashed(fixture) == ["old-report.txt"])

        #expect(report.dryRun)
        #expect(report.operation.dryRun)
        #expect(report.results.count == entries.count)
        #expect(report.results.allSatisfy { $0.status == .dryRun && !$0.movedToTrash })
        #expect(report.bytesFreed == 0)
        #expect(report.bytesTrashed == 0)
        #expect(report.bytesPlanned == entries.reduce(0) { $0 + $1.bytes })
        #expect(cleaner.engine.ledger.operations().isEmpty)
    }

    @Test func aCacheEntryLinkedToDocumentsIsRefused() async throws {
        let fixture = try FixtureHome()
        try fixture.symlink("Library/Caches/com.evil.cache", to: fixture.path("Documents"))
        let before = fixture.files()

        // The scanner never lists a link, so the entry is forged the way a stale list would hold it.
        #expect(await fixture.scanner().scanCollected().isEmpty)
        let path = fixture.path("Library/Caches/com.evil.cache")
        let forged = JunkEntry(id: "userCaches:\(path)", category: .userCaches, name: "Evil", targets: [JunkTarget(path: path)], bytes: 4096)

        let cleaner = fixture.cleaner()
        let report = await cleaner.clean([forged])

        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(fixture.exists("Library/Caches/com.evil.cache"))
        #expect(withoutLedger(fixture) == before)
        let result = try #require(report.results.first)
        #expect(result.status == .failed)
        #expect(result.reason == "is a symbolic link")
        #expect(result.bytes == 0)
        #expect(report.bytesFreed == 0)

        let logged = try #require(cleaner.engine.ledger.operations().first)
        #expect(logged.entries.map(\.result) == [.refused])
        #expect(logged.failures.count == 1)
    }

    @Test func aCacheSwappedForALinkAfterTheScanIsNotFollowed() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)
        try fixture.write("Library/Caches/com.example.other/blob", bytes: 8192)
        let entries = await fixture.scanner().scanCollected()
        #expect(entries.count == 2)

        // Between the scan and the clean, one cache becomes a link into Documents
        // and the other a different folder with the same name.
        try FileManager.default.removeItem(atPath: fixture.path("Library/Caches/com.example.app"))
        try fixture.symlink("Library/Caches/com.example.app", to: fixture.path("Documents"))
        try FileManager.default.moveItem(atPath: fixture.path("Library/Caches/com.example.other"), toPath: fixture.path("Library/Caches/moved"))
        try fixture.write("Library/Caches/com.example.other/new-data", bytes: 8192)
        let before = fixture.files()

        let report = await fixture.cleaner().clean(entries)
        #expect(withoutLedger(fixture) == before)
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(report.result(for: "userCaches:" + fixture.path("Library/Caches/com.example.app"))?.reason == "is a symbolic link")
        let other = try #require(report.result(for: "userCaches:" + fixture.path("Library/Caches/com.example.other")))
        #expect(other.status == .skipped)
        #expect(other.reason == "changed since the scan")
        #expect(report.bytesFreed == 0)
    }

    @Test func forgedEntriesCannotWidenACategory() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Documents/.DS_Store")
        try fixture.write(".ssh/.DS_Store")
        try fixture.write("Library/Logs/House Keeping/operations.jsonl")
        try fixture.write("Library/Caches/Homebrew/bottle")
        try fixture.write("Library/Application Support/Google/Chrome/Default/Cookies")
        try fixture.write("Projects/app/main.swift")
        try fixture.write("Downloads/taxes.pdf")
        let before = fixture.files()

        func forged(_ category: JunkCategory, _ relative: String) -> JunkEntry {
            let path = relative.hasPrefix("/") ? relative : fixture.path(relative)
            return JunkEntry(id: "\(category.rawValue):\(relative)", category: category, name: relative, targets: [JunkTarget(path: path)], bytes: 4096)
        }
        let entries = [
            forged(.userCaches, "Documents/thesis.txt"),
            forged(.userCaches, "Documents"),
            forged(.userCaches, "Library/Caches"),
            forged(.userCaches, "Library/Caches/Homebrew"),
            forged(.userCaches, fixture.path("Library/Caches") + "/../../Documents/thesis.txt"),
            forged(.browserCaches, "Library/Application Support/Google/Chrome/Default"),
            forged(.logs, "Library/Logs/House Keeping"),
            forged(.logs, "Library/Logs/House Keeping/operations.jsonl"),
            forged(.logs, "Library/Logs"),
            forged(.crashReports, "Documents/thesis.txt"),
            forged(.dsStore, "Documents/.DS_Store"),
            forged(.dsStore, ".ssh/.DS_Store"),
            forged(.dsStore, "Projects/app/main.swift"),
            forged(.mailDownloads, "Documents/thesis.txt"),
            forged(.installers, "Downloads/taxes.pdf"),
            forged(.installers, "Downloads"),
            forged(.deviceBackups, "Library/Application Support"),
            forged(.trash, ".ssh/id_ed25519"),
            forged(.trash, ".Trash"),
            forged(.trash, fixture.home.path),
            forged(.systemCaches, "Documents/thesis.txt"),
        ]

        let report = await fixture.cleaner(privileged: FakePrivileged()).clean(entries)
        #expect(fixture.files() == before)
        #expect(report.results.count == entries.count)
        #expect(report.results.allSatisfy { $0.status == .failed || $0.status == .skipped }, "\(report.results.filter { $0.status == .cleaned })")
        #expect(report.bytesFreed == 0)
        #expect(report.bytesTrashed == 0)
    }

    @Test func cleaningKeepsGoingAfterAFailure() async throws {
        let fixture = try FixtureHome()
        try fixture.symlink("Library/Caches/com.evil.cache", to: fixture.path("Documents"))
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)
        try fixture.write("Library/Logs/App/run.log", bytes: 8192)
        var entries = await fixture.scanner().scanCollected()
        let evil = fixture.path("Library/Caches/com.evil.cache")
        entries.insert(JunkEntry(id: "evil", category: .userCaches, name: "Evil", targets: [JunkTarget(path: evil)]), at: 1)

        let events = Locked<[String]>([])
        let report = await fixture.cleaner().clean(entries) { event in
            switch event {
            case .started(let id): events.mutate { $0.append("start \(id)") }
            case .finished(let result): events.mutate { $0.append("end \(result.id) \(result.status.rawValue)") }
            }
        }

        #expect(report.results.map(\.status) == [.cleaned, .failed, .cleaned])
        #expect(report.problems.map(\.id) == ["evil"])
        #expect(report.bytesFreed == 16384)
        #expect(!fixture.exists("Library/Caches/com.example.app"))
        #expect(!fixture.exists("Library/Logs/App"))
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(events.get() == entries.flatMap { ["start \($0.id)", "end \($0.id) \($0.id == "evil" ? "failed" : "cleaned")"] })
    }

    @Test func runningAppsAreCheckedAgainRightBeforeCleaning() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.spotify.client/blob", bytes: 8192)
        try fixture.write("Library/Caches/com.apple.Safari/Cache.db", bytes: 8192)
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)

        // Nothing was running when the list was drawn.
        let entries = await fixture.scanner().scanCollected()
        #expect(entries.allSatisfy { !$0.isBlocked })

        let report = await fixture.cleaner(processes: ["Spotify", "Safari"]).clean(entries)
        #expect(fixture.exists("Library/Caches/com.spotify.client/blob"))
        #expect(fixture.exists("Library/Caches/com.apple.Safari/Cache.db"))
        #expect(!fixture.exists("Library/Caches/com.example.app"))

        let spotify = try #require(report.results.first { $0.name == "Spotify" })
        #expect(spotify.status == .skipped)
        #expect(spotify.reason == "Spotify is running")
        #expect(report.results.first { $0.name == "Safari" }?.reason == "Safari is running")
        #expect(report.results.first { $0.name == "Example" }?.status == .cleaned)
    }

    @Test func entriesBlockedAtScanTimeAreSkipped() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.spotify.client/blob", bytes: 8192)
        let entries = await fixture.scanner(processes: ["Spotify"]).scanCollected()
        #expect(entries.first?.blockedReason == "Spotify is running")

        // Even if the app has quit since, a blocked row is only cleaned after a fresh scan.
        let report = await fixture.cleaner().clean(entries)
        #expect(report.results.map(\.status) == [.skipped])
        #expect(fixture.exists("Library/Caches/com.spotify.client/blob"))
    }

    @Test func installersAndBackupsGoToTheTrash() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Downloads/Old Installer.dmg", bytes: 128 * 1024)
        try fixture.writeBackup("0000-PHONE", deviceName: "Phone", product: "iPhone", date: Date())
        try fixture.write("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A/file.pdf")
        let entries = await fixture.scanner().scanCollected()
        #expect(entries.count == 3)

        // The cache setting is "permanent"; these three categories ignore it.
        let cleaner = fixture.cleaner()
        #expect(cleaner.engine.settings.cacheDeleteMode == .permanent)
        let report = await cleaner.clean(entries)

        #expect(!fixture.exists("Downloads/Old Installer.dmg"))
        #expect(!fixture.exists("Library/Application Support/MobileSync/Backup/0000-PHONE"))
        #expect(!fixture.exists("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A"))
        #expect(fixture.exists("Library/Application Support/MobileSync/Backup"))
        #expect(trashed(fixture).map { String($0.dropFirst(9)) }.sorted() == ["0000-PHONE", "A", "Old Installer.dmg"])

        #expect(report.results.allSatisfy { $0.status == .cleaned && $0.movedToTrash })
        #expect(report.bytesFreed == 0)
        #expect(report.bytesTrashed == entries.reduce(0) { $0 + $1.bytes })
        #expect(report.operation.entries.allSatisfy { $0.mode == "trash" && $0.result == .removed })
    }

    @Test func emptyingTheTrashIsPermanentAndKeepsTheFolder() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".Trash/a.txt", bytes: 8192)
        try fixture.write(".Trash/folder/b.txt", bytes: 8192)
        let entries = await fixture.scanner().scanCollected()

        // Even with caches set to go to the Trash, the Trash itself is emptied for good.
        var settings = SweepSettings()
        settings.cacheDeleteMode = .trash
        let report = await fixture.cleaner(settings: settings).clean(entries)

        #expect(fixture.exists(".Trash"))
        #expect(trashed(fixture).isEmpty)
        #expect(report.results.map(\.status) == [.cleaned])
        #expect(report.bytesFreed == 16384)
        #expect(report.results.first?.movedToTrash == false)
        #expect(report.results.first?.removedCount == 2)
        #expect(report.operation.entries.allSatisfy { $0.mode == "permanent" })
    }

    @Test func cachesFollowTheDeleteModeSetting() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)
        try fixture.write("Library/Logs/App/run.log", bytes: 8192)
        try fixture.write("Projects/.DS_Store")
        let entries = await fixture.scanner().scanCollected()
        #expect(entries.count == 3)

        var settings = SweepSettings()
        settings.cacheDeleteMode = .trash
        let cleaner = fixture.cleaner(settings: settings)
        #expect(cleaner.deleteMode(for: .userCaches) == .trash)
        #expect(cleaner.deleteMode(for: .installers) == .trash)
        #expect(cleaner.deleteMode(for: .trash) == .permanent)
        #expect(cleaner.deleteMode(for: .systemCaches) == nil)

        let report = await cleaner.clean(entries)
        #expect(!fixture.exists("Library/Caches/com.example.app"))
        #expect(trashed(fixture).map { String($0.dropFirst(9)) }.sorted() == [".DS_Store", "App", "com.example.app"])
        #expect(report.results.allSatisfy { $0.movedToTrash })
        #expect(report.operation.entries.allSatisfy { $0.mode == "trash" })
    }

    @Test func theLedgerRecordsTheOperation() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)
        try fixture.write("Library/Logs/DiagnosticReports/a.ips", bytes: 8192)
        try fixture.write("Library/Logs/DiagnosticReports/b.ips", bytes: 8192)
        let entries = await fixture.scanner().scanCollected()

        let cleaner = fixture.cleaner()
        let report = await cleaner.clean(entries)

        #expect(fixture.exists("Library/Logs/House Keeping/operations.jsonl"))
        let operations = cleaner.engine.ledger.operations()
        #expect(operations.count == 1)
        let logged = try #require(operations.first)
        #expect(logged.id == report.operation.id)
        #expect(logged.kind == .junk)
        #expect(logged.source == "window")
        #expect(!logged.dryRun)
        #expect(logged.bytesFreed == 3 * 8192)
        #expect(Set(logged.entries.map(\.target)) == [
            fixture.path("Library/Caches/com.example.app"),
            fixture.path("Library/Logs/DiagnosticReports/a.ips"),
            fixture.path("Library/Logs/DiagnosticReports/b.ips"),
        ])
        #expect(Set(logged.entries.map(\.itemID)) == ["junk.userCaches", "junk.crashReports"])
        #expect(logged.entries.allSatisfy { $0.mode == "permanent" && $0.result == .removed && $0.bytes == 8192 })
        #expect(logged.cleanedItemNames.sorted() == ["Crash reports", "Example"])

        // The ledger now lives in ~/Library/Logs and is still never offered for cleaning.
        let again = await fixture.scanner().scanCollected()
        #expect(again.isEmpty, "listed: \(again.allPaths)")
        #expect(cleaner.engine.ledger.operations().count == 1)
    }

    @Test func systemCachesGoToThePrivilegedRunner() async throws {
        let fixture = try FixtureHome()
        try fixture.write("SystemCaches/com.apple.something/cache.bin", bytes: 64 * 1024)
        let options = JunkOptions(now: ninetyDaysAhead, systemCachesDirectory: fixture.path("SystemCaches"))
        let privileged = FakePrivileged(.helper, bytesFreed: 40_000)
        let entries = await fixture.scanner(privileged: privileged, options: options).scanCollected()
        #expect(entries.map(\.category) == [.systemCaches])
        let listed = try #require(entries.first)
        #expect(listed.bytes == 64 * 1024)
        #expect(!listed.isSelectedByDefault)
        let before = fixture.files()

        let cleaner = fixture.cleaner(privileged: privileged, options: options)
        let report = await cleaner.clean(entries)

        #expect(privileged.calls == [.cleanSystemCaches])
        // House Keeping itself deleted nothing: the fake helper touches no files.
        #expect(withoutLedger(fixture) == before)
        let result = try #require(report.results.first)
        #expect(result.status == .cleaned)
        #expect(result.bytes == 40_000)
        #expect(!result.movedToTrash)
        #expect(report.bytesFreed == 40_000)

        let logged = try #require(cleaner.engine.ledger.operations().first)
        #expect(logged.entries.map(\.target) == ["helper: cleanSystemCaches"])
        #expect(logged.entries.map(\.mode) == ["command"])
        #expect(logged.entries.map(\.itemID) == ["junk.systemCaches"])
    }

    @Test func systemCachesAreNeverCleanedWithoutARunner() async throws {
        let fixture = try FixtureHome()
        try fixture.write("SystemCaches/blob", bytes: 8192)
        let override = JunkOptions(now: ninetyDaysAhead, systemCachesDirectory: fixture.path("SystemCaches"))
        let entry = JunkEntry(id: "systemCaches", category: .systemCaches, name: "System caches",
                              targets: [JunkTarget(path: fixture.path("SystemCaches"))], bytes: 8192)

        // Runner unavailable.
        let unavailable = FakePrivileged(.unavailable)
        var report = await fixture.cleaner(privileged: unavailable, options: override).clean([entry])
        #expect(report.results.map(\.status) == [.skipped])
        #expect(unavailable.calls.isEmpty)

        // A fixture home without the test override never reaches the real /Library/Caches.
        let available = FakePrivileged()
        report = await fixture.cleaner(privileged: available).clean([entry])
        #expect(report.results.map(\.status) == [.skipped])
        #expect(available.calls.isEmpty)

        // A dry run reports the size and asks the runner for nothing.
        report = await fixture.cleaner(privileged: available, options: override).clean([entry], dryRun: true)
        #expect(report.results.map(\.status) == [.dryRun])
        #expect(report.bytesPlanned == 8192)
        #expect(available.calls.isEmpty)

        // A helper that fails is reported, and nothing is deleted behind its back.
        let failing = FakePrivileged(.helper, succeeds: false)
        report = await fixture.cleaner(privileged: failing, options: override).clean([entry])
        #expect(report.results.map(\.status) == [.failed])
        #expect(report.results.first?.reason == "helper refused")
        #expect(failing.calls == [.cleanSystemCaches])
        #expect(fixture.exists("SystemCaches/blob"))
    }

    @Test func exclusionsAreHonouredWhenCleaning() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.keep.me/blob", bytes: 8192)
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)
        // The list was drawn before the exclusion was added in Settings.
        let entries = await fixture.scanner().scanCollected()
        #expect(entries.count == 2)

        var settings = SweepSettings()
        settings.exclusions = ["~/Library/Caches/com.keep.me"]
        let report = await fixture.cleaner(settings: settings).clean(entries)

        #expect(fixture.exists("Library/Caches/com.keep.me/blob"))
        #expect(!fixture.exists("Library/Caches/com.example.app"))
        let kept = try #require(report.results.first { $0.name == "Me" })
        #expect(kept.status == .skipped)
        #expect(kept.reason == "Excluded in Settings")
    }

    @Test func dsStoreCleaningRemovesOnlyThoseFiles() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Projects/app/.DS_Store")
        try fixture.write("Projects/app/main.swift")
        try fixture.write("Projects/.DS_Store")
        try fixture.write("Documents/.DS_Store")
        let entries = await fixture.scanner().scanCollected()
        let before = fixture.files()

        let report = await fixture.cleaner().clean(entries)
        #expect(before.subtracting(fixture.files()) == [fixture.path("Projects/app/.DS_Store"), fixture.path("Projects/.DS_Store")])
        #expect(report.results.map(\.status) == [.cleaned])
        #expect(report.results.first?.removedCount == 2)
        #expect(fixture.exists("Documents/.DS_Store"))
    }

    @Test func somethingAlreadyGoneIsNotAProblem() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Logs/DiagnosticReports/a.ips", bytes: 8192)
        try fixture.write("Library/Logs/DiagnosticReports/b.ips", bytes: 8192)
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)
        let entries = await fixture.scanner().scanCollected()

        // macOS tidied up between the scan and the clean.
        try FileManager.default.removeItem(atPath: fixture.path("Library/Logs/DiagnosticReports/a.ips"))
        try FileManager.default.removeItem(atPath: fixture.path("Library/Caches/com.example.app"))

        let report = await fixture.cleaner().clean(entries)
        let reports = try #require(report.results.first { $0.category == .crashReports })
        #expect(reports.status == .cleaned)
        #expect(reports.bytes == 8192)
        #expect(reports.problemCount == 0)
        let cache = try #require(report.results.first { $0.category == .userCaches })
        #expect(cache.status == .skipped)
        #expect(cache.reason == "already gone")
        #expect(report.bytesFreed == 8192)
    }

    @Test func duplicateEntriesAreCleanedOnce() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/com.example.app/blob", bytes: 8192)
        let entries = await fixture.scanner().scanCollected()
        let report = await fixture.cleaner().clean(entries + entries)
        #expect(report.results.count == 1)
        #expect(report.bytesFreed == 8192)
    }
}
