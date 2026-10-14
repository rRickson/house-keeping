import Foundation
@testable import SweepAnalyze
import SweepKit
import SweepTestSupport
import Testing

@Suite struct TrashTests {
    let fixture: FixtureHome
    let engine: SweepEngine
    let service: AnalyzeService

    init() throws {
        fixture = try FixtureHome()
        try fixture.write("Downloads/installer.dmg", bytes: 800_000)
        try fixture.write("Downloads/keep.pdf", bytes: 50_000)
        try fixture.write("Developer/app/node_modules/lib/index.js", bytes: 120_000)
        try fixture.write("Developer/app/node_modules/lib/data.bin", bytes: 240_000)
        try fixture.write("Developer/app/src/main.swift", bytes: 8_000)
        try fixture.write("Developer/app/.git/HEAD", bytes: 100)
        engine = fixture.engine(items: [])
        service = AnalyzeService(engine: engine, scanner: detailedScanner())
    }

    var trashFolder: String { fixture.path(".Trash") }

    func trashContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: trashFolder)) ?? []
    }

    @Test func trashingAFileMovesItToTheFixtureTrashAndIsLogged() async throws {
        let path = fixture.path("Downloads/installer.dmg")
        let size = allocatedBytes(path)
        var tree = try await service.scan(fixture.url)
        let before = tree.totalBytes
        #expect(service.trashDenyReason(for: path) == nil)
        #expect(service.canTrash(path))

        let result = await service.trash(path)

        #expect(result.succeeded)
        #expect(result.outcome == .removed(bytes: size))
        #expect(result.bytes == size)
        #expect(result.reason == nil)
        #expect(!fixture.exists("Downloads/installer.dmg"))
        #expect(fixture.exists("Downloads/keep.pdf"))
        // It is in the fixture's Trash, not gone.
        #expect(trashContents().count == 1)
        let trashed = try #require(trashContents().first)
        #expect(trashed.hasSuffix("-installer.dmg"))
        #expect(allocatedBytes(trashFolder + "/" + trashed) == size)

        // The ledger has exactly this operation.
        let operations = engine.ledger.operations()
        #expect(operations.count == 1)
        #expect(operations[0].id == result.operation.id)
        #expect(operations[0].kind == .analyze)
        #expect(operations[0].source == "window")
        #expect(operations[0].bytesFreed == size)
        #expect(operations[0].entries.count == 1)
        #expect(operations[0].entries[0].target == path)
        #expect(operations[0].entries[0].result == .removed)
        #expect(operations[0].entries[0].mode == "trash")
        #expect(operations[0].entries[0].itemName == "installer.dmg")
        #expect(engine.ledger.fileURL.path.hasPrefix(fixture.home.path))

        // The tree is updated in place.
        #expect(tree.remove(path: result.path) == size)
        #expect(tree.totalBytes == before - size)
        #expect(tree.node(atPath: path) == nil)
        #expect(tree.bytes(atPath: fixture.path("Downloads")) == allocatedBytes(fixture.path("Downloads/keep.pdf")))
    }

    @Test func trashingAFolderTakesEverythingInsideAndUpdatesTheTree() async throws {
        let path = fixture.path("Developer/app/node_modules")
        let size = fixture.allocatedTotal("Developer/app/node_modules")
        var tree = try await service.scan(fixture.url)
        let before = tree.totalBytes
        let developerBefore = tree.categoryBytes(of: tree.root)[.developer]

        let result = await service.trash(path)

        #expect(result.outcome == .removed(bytes: size))
        #expect(!fixture.exists("Developer/app/node_modules"))
        #expect(fixture.exists("Developer/app/src/main.swift"))
        #expect(trashContents().count == 1)
        let trashed = try #require(trashContents().first)
        #expect(FileManager.default.fileExists(atPath: trashFolder + "/" + trashed + "/lib/data.bin"))

        tree.remove(path: result.path)
        #expect(tree.totalBytes == before - size)
        #expect(tree.bytes(atPath: fixture.path("Developer/app")) == fixture.allocatedTotal("Developer/app"))
        #expect(tree.categoryBytes(of: tree.root)[.developer] == developerBefore - size)
        // What the tree says now is what a fresh scan says.
        let rescanned = try detailedScanner().scanBlocking(URL(fileURLWithPath: fixture.path("Developer")))
        #expect(tree.bytes(atPath: fixture.path("Developer")) == rescanned.totalBytes)
    }

    @Test func theFixtureHomeItselfIsRefused() async throws {
        let home = fixture.home.path
        // The refusal itself is written to the ledger, inside the fixture's Library/Logs.
        func userFiles() -> Set<String> { fixture.files().filter { !$0.contains("/Library/Logs/Sweep/") } }
        let files = userFiles()
        #expect(service.trashDenyReason(for: home) != nil)

        let result = await service.trash(home)

        #expect(!result.succeeded)
        guard case .refused = result.outcome else {
            Issue.record("expected a refusal, got \(result.outcome)")
            return
        }
        #expect(result.bytes == 0)
        #expect(userFiles() == files)
        #expect(FileManager.default.fileExists(atPath: home))
        #expect(trashContents().isEmpty)
        // The refusal is on record.
        let entry = try #require(engine.ledger.operations().first?.entries.first)
        #expect(entry.result == .refused)
        #expect(entry.target == home)
        #expect(engine.ledger.operations()[0].bytesFreed == 0)
    }

    @Test func systemLocationsAreRefused() async throws {
        // Only the guard is asked here; nothing outside the fixture is touched.
        for path in ["/", "/Users", "/Applications", "/System", "/System/Library", "/usr", "/usr/bin/true", "/Library", "/private/var"] {
            #expect(service.trashDenyReason(for: path) != nil, "\(path) must never be trashable")
            #expect(!service.canTrash(path))
        }

        let result = await service.trash("/System")
        guard case .refused(let reason) = result.outcome else {
            Issue.record("expected a refusal, got \(result.outcome)")
            return
        }
        #expect(reason.contains("/System"))
        #expect(FileManager.default.fileExists(atPath: "/System/Library"))
        #expect(trashContents().isEmpty)
        #expect(engine.ledger.operations().first?.entries.first?.result == .refused)
    }

    @Test func protectedPlacesInsideHomeAreRefusedButTheirContentsAreNot() async throws {
        for relative in ["Documents", "Desktop", "Pictures", "Library", "Library/Caches", ".ssh", ".ssh/id_ed25519", "Downloads"] {
            #expect(service.trashDenyReason(for: fixture.path(relative)) != nil, "\(relative)")
        }
        // Anything inside a repository's .git folder, and the folder itself.
        #expect(service.trashDenyReason(for: fixture.path("Developer/app/.git")) != nil)
        #expect(service.trashDenyReason(for: fixture.path("Developer/app/.git/HEAD")) != nil)
        // A folder that contains a protected one would take it along.
        #expect(service.trashDenyReason(for: fixture.root.path) != nil)
        // Something that is not there.
        #expect(service.trashDenyReason(for: fixture.path("Downloads/ghost.zip")) != nil)

        // The user's own files and folders are theirs to trash by hand.
        #expect(service.trashDenyReason(for: fixture.path("Documents/thesis.txt")) == nil)
        #expect(service.trashDenyReason(for: fixture.path("Developer/app")) == nil)

        let refused = await service.trash(fixture.path("Documents"))
        #expect(!refused.succeeded)
        #expect(fixture.exists("Documents/thesis.txt"))
        let gone = await service.trash(fixture.path("Downloads/ghost.zip"))
        #expect(gone.outcome == .skipped("already gone"))
    }

    @Test func aSymlinkIsNeverTrashedOrFollowed() async throws {
        try fixture.symlink("Downloads/shortcut", to: fixture.path("Documents"))
        let link = fixture.path("Downloads/shortcut")
        #expect(service.trashDenyReason(for: link) != nil)

        let result = await service.trash(link)

        #expect(!result.succeeded)
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == fixture.path("Documents"))
        #expect(trashContents().isEmpty)
        // Nor a path that reaches a file through the link.
        let through = await service.trash(link + "/thesis.txt")
        #expect(!through.succeeded)
        #expect(fixture.exists("Documents/thesis.txt"))
    }

    @Test func anItemThatVanishedIsSkipped() async throws {
        // A path that disappeared between the menu and the click is skipped, not an error.
        let path = fixture.path("Downloads/keep.pdf")
        try FileManager.default.removeItem(atPath: path)
        let result = await service.trash(path)
        #expect(result.outcome == .skipped("already gone"))
        #expect(result.bytes == 0)
        #expect(engine.ledger.operations().first?.entries.first?.result == .skipped)
    }
}

@Suite struct ExclusionTests {
    let fixture: FixtureHome
    let engine: SweepEngine
    let service: AnalyzeService

    init() throws {
        fixture = try FixtureHome()
        try fixture.write("Projects/keep/data.bin", bytes: 30_000)
        try fixture.write("Projects/other/data.bin", bytes: 30_000)
        engine = fixture.engine(items: [])
        service = AnalyzeService(engine: engine, scanner: detailedScanner())
    }

    @Test func addingAnExclusionChangesTheSettingsOnDisk() {
        let path = fixture.path("Projects/keep")
        #expect(engine.settings.exclusions.isEmpty)
        #expect(!service.isExcluded(path))

        #expect(service.addExclusion(path))

        #expect(engine.settings.exclusions == [path])
        #expect(service.isExcluded(path))
        #expect(service.isExcludedExactly(path))
        // Saved, so the menu bar, the CLI and the next launch see it.
        #expect(engine.settingsStore.load().exclusions == [path])
        #expect(engine.settingsStore.fileURL.path.hasPrefix(fixture.home.path))
        // Other settings are left alone.
        var expected = SweepSettings()
        expected.exclusions = [path]
        #expect(engine.settings == expected)
    }

    @Test func exclusionsAreNotDuplicatedAndCanBeRemoved() {
        let path = fixture.path("Projects/keep")
        #expect(service.addExclusion(path))
        #expect(!service.addExclusion(path))
        #expect(!service.addExclusion(path + "/"))
        #expect(!service.addExclusion(fixture.path("Projects/./keep")))
        #expect(service.addExclusion(fixture.path("Projects/other")))
        #expect(engine.settings.exclusions == [path, fixture.path("Projects/other")])

        #expect(service.removeExclusion(path))
        #expect(!service.removeExclusion(path))
        #expect(engine.settingsStore.load().exclusions == [fixture.path("Projects/other")])
        #expect(!service.isExcluded(path))
    }

    @Test func anExclusionCoversEverythingInsideIt() {
        service.addExclusion(fixture.path("Projects/keep"))
        #expect(service.isExcluded(fixture.path("Projects/keep/data.bin")))
        #expect(!service.isExcludedExactly(fixture.path("Projects/keep/data.bin")))
        #expect(!service.isExcluded(fixture.path("Projects/other/data.bin")))
        #expect(!service.isExcluded(fixture.path("Projects/keeper")))
    }

    @Test func excludedItemsAreNeverTrashed() async {
        let path = fixture.path("Projects/keep/data.bin")
        #expect(service.canTrash(path))
        service.addExclusion(fixture.path("Projects/keep"))
        #expect(service.trashDenyReason(for: path) == "excluded in Settings")
        #expect(service.trashDenyReason(for: fixture.path("Projects/keep")) == "excluded in Settings")

        let result = await service.trash(path)

        #expect(result.outcome == .refused("excluded in Settings"))
        #expect(fixture.exists("Projects/keep/data.bin"))
        #expect(engine.ledger.operations().first?.entries.first?.result == .refused)
        // Its neighbour is not affected.
        #expect(service.canTrash(fixture.path("Projects/other/data.bin")))
    }
}

@Suite struct VolumeSpaceTests {
    static let listing = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-10-13-101530.local
        com.apple.TimeMachine.2026-10-12-090000.local
        com.apple.os.update-3F2A9B1C4D5E
        """

    var utc: TimeZone { TimeZone(identifier: "UTC")! }

    @Test func snapshotListingIsParsed() throws {
        let snapshots = VolumeInspector.parseSnapshots(Self.listing, timeZone: utc)
        #expect(snapshots.map(\.name) == [
            "com.apple.os.update-3F2A9B1C4D5E",
            "com.apple.TimeMachine.2026-10-12-090000.local",
            "com.apple.TimeMachine.2026-10-13-101530.local",
        ])
        #expect(snapshots[0].date == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let newest = try #require(snapshots[2].date)
        #expect(calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: newest)
            == DateComponents(year: 2026, month: 10, day: 13, hour: 10, minute: 15, second: 30))
        let older = try #require(snapshots[1].date)
        #expect(older < newest)
    }

    @Test func outputWithoutSnapshotsGivesNone() {
        #expect(VolumeInspector.parseSnapshots("").isEmpty)
        #expect(VolumeInspector.parseSnapshots("Snapshots for volume group containing disk /:\n").isEmpty)
        #expect(VolumeInspector.parseSnapshots("Snapshots for disk /:\n\n   \n").isEmpty)
        #expect(VolumeInspector.parseSnapshots("tmutil: unable to list snapshots\n").isEmpty)
        // Repeated lines and odd stamps do not break it.
        let odd = VolumeInspector.parseSnapshots("com.apple.TimeMachine.2026-13-40-999999.local\ncom.apple.TimeMachine.2026-13-40-999999.local\n")
        #expect(odd.count == 1)
        #expect(odd[0].date == nil)
    }

    @Test func snapshotsAreAskedThroughTheEnginesRunner() async throws {
        let fixture = try FixtureHome()
        let runner = FakeRunner()
        runner.on("tmutil") { arguments in
            arguments.first == "listlocalsnapshots" ? CommandResult(exitCode: 0, stdout: Self.listing) : CommandResult(exitCode: 1)
        }
        let service = AnalyzeService(engine: fixture.engine(items: [], runner: runner))

        let space = await service.volumeSpace(for: fixture.home)

        #expect(space.snapshots.count == 3)
        #expect(space.hasHiddenSpace)
        #expect(runner.log == [["tmutil", "listlocalsnapshots", space.mountPoint]])
        #expect(space.mountPoint.hasPrefix("/"))
        #expect(space.total > 0)
        #expect(space.available > 0)
        #expect(space.availableForImportantUsage >= space.available)
        #expect(space.purgeable == space.availableForImportantUsage - space.available)
        #expect(space.used == space.total - space.available)
    }

    @Test func aMissingOrFailingToolMeansNoSnapshots() async throws {
        let fixture = try FixtureHome()
        // The fixture engine knows no tools at all.
        let none = await AnalyzeService(engine: fixture.engine(items: [])).volumeSpace(for: fixture.home)
        #expect(none.snapshots.isEmpty)
        #expect(none.total > 0)

        let runner = FakeRunner()
        runner.on("tmutil") { _ in CommandResult(exitCode: 1, stdout: "com.apple.TimeMachine.2026-10-13-101530.local", stderr: "failed") }
        let failed = await VolumeInspector(runner: runner).snapshots(mountPoint: "/")
        #expect(failed.isEmpty)
    }

    @Test func purgeableSpaceIsTheGapBetweenTheTwoFreeNumbers() {
        var space = VolumeSpace(mountPoint: "/", total: 1_000, available: 200, availableForImportantUsage: 350)
        #expect(space.purgeable == 150)
        #expect(space.used == 800)
        #expect(space.hasHiddenSpace)
        #expect(space.unaccounted(scannedBytes: 700) == 100)
        #expect(space.unaccounted(scannedBytes: 900) == 0)

        // Never negative, and nothing to explain when the numbers agree.
        space.availableForImportantUsage = 150
        #expect(space.purgeable == 0)
        #expect(!space.hasHiddenSpace)
        space.snapshots = [LocalSnapshot(name: "com.apple.TimeMachine.2026-10-13-101530.local")]
        #expect(space.hasHiddenSpace)
    }
}
