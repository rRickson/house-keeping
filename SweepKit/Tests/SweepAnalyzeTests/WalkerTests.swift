import Darwin
import Foundation
import SweepAnalyze
import SweepKit
import SweepTestSupport
import Testing

@Suite struct WalkerTests {
    let fixture: FixtureHome

    init() throws {
        fixture = try FixtureHome()
    }

    @Test func totalsMatchTheFilesOnDisk() throws {
        try fixture.write("Projects/app/main.swift", bytes: 10_000)
        try fixture.write("Projects/app/assets/logo.png", bytes: 300_000)
        try fixture.write("Projects/app/assets/intro.mov", bytes: 1_200_000)
        try fixture.write("Downloads/archive.zip", bytes: 700_000)
        try fixture.write("Downloads/empty.txt", bytes: 0)

        let tree = try detailedScanner().scanBlocking(fixture.url)

        #expect(tree.rootPath == fixture.home.path)
        #expect(tree.totalBytes == fixture.allocatedTotal())
        #expect(tree.totalBytes == (try Sizer().size(of: fixture.home)).bytes)
        #expect(tree.totalFiles == fixture.files().count)

        // Every folder is the sum of what is inside it.
        #expect(tree.bytes(atPath: fixture.path("Projects/app/assets")) == fixture.allocatedTotal("Projects/app/assets"))
        #expect(tree.bytes(atPath: fixture.path("Projects")) == fixture.allocatedTotal("Projects"))
        #expect(tree.bytes(atPath: fixture.path("Downloads/archive.zip")) == allocatedBytes(fixture.path("Downloads/archive.zip")))
        #expect(tree.bytes(atPath: fixture.path("Projects/app/assets/intro.mov")) ?? 0 >= 1_200_000)
    }

    @Test func everyFolderEqualsTheSumOfItsChildren() throws {
        var generator = SeededGenerator(seed: 7)
        for index in 0..<120 {
            let depth = Int.random(in: 1...4, using: &generator)
            let folders = (0..<depth).map { _ in "d\(Int.random(in: 0..<4, using: &generator))" }
            try fixture.write("tree/" + folders.joined(separator: "/") + "/f\(index).bin", bytes: Int.random(in: 0...60_000, using: &generator))
        }
        let tree = try detailedScanner { $0.detailDepth = 2; $0.maxFilesPerDirectory = 3; $0.individualFileThreshold = 20_000 }
            .scanBlocking(fixture.url)

        #expect(tree.totalBytes == fixture.allocatedTotal())
        for id in 0..<tree.nodeCount where tree[id].isDirectory {
            let children = tree.children(of: id)
            #expect(children.reduce(0) { $0 + tree[$1].bytes } == tree[id].bytes, "folder \(tree.path(of: id))")
            #expect(children.reduce(0) { $0 + tree[$1].fileCount } <= tree[id].fileCount)
            #expect(tree.categoryBytes(of: id).total == tree[id].bytes)
            // Largest first.
            let sizes = children.map { tree[$0].bytes }
            #expect(sizes == sizes.sorted(by: >))
            for child in children { #expect(tree.parent(of: child) == id) }
        }
    }

    @Test func hardlinksAreCountedOnce() throws {
        let original = try fixture.write("links/a/original.bin", bytes: 256_000)
        try fixture.mkdir("links/b")
        #expect(link(original, fixture.path("links/b/second-name.bin")) == 0)
        try fixture.write("links/b/plain.bin", bytes: 8_000)

        let tree = try detailedScanner().scanBlocking(URL(fileURLWithPath: fixture.path("links")))

        let once = allocatedBytes(original)
        #expect(once >= 256_000)
        #expect(tree.totalBytes == once + allocatedBytes(fixture.path("links/b/plain.bin")))
        #expect(tree.totalFiles == 3)
        // One name carries the bytes, the other carries none.
        let first = tree.bytes(atPath: original) ?? 0
        let second = tree.bytes(atPath: fixture.path("links/b/second-name.bin")) ?? 0
        #expect(first + second == once)
    }

    @Test func symlinksAreNeverFollowed() throws {
        // A big folder outside the scanned one, reachable only through links.
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: outside.appendingPathComponent("huge.bin"))
        try fixture.write("scan/real.txt", bytes: 5_000)
        try fixture.symlink("scan/link-to-folder", to: outside.path)
        try fixture.symlink("scan/link-to-file", to: outside.appendingPathComponent("huge.bin").path)
        try fixture.symlink("scan/link-to-documents", to: fixture.path("Documents"))

        let tree = try detailedScanner().scanBlocking(URL(fileURLWithPath: fixture.path("scan")))

        #expect(tree.totalBytes == allocatedBytes(fixture.path("scan/real.txt")))
        #expect(tree.totalFiles == 1)
        #expect(tree.childNames(atPath: fixture.path("scan")) == ["real.txt"])
        #expect(tree.node(atPath: fixture.path("scan/link-to-folder/huge.bin")) == nil)
        #expect(tree.largestFileRecords.map(\.path) == [fixture.path("scan/real.txt")])
    }

    @Test func aLinkPickedAsTheRootIsResolved() throws {
        try fixture.write("real-folder/file.bin", bytes: 12_000)
        try fixture.symlink("shortcut", to: fixture.path("real-folder"))

        let tree = try detailedScanner().scanBlocking(URL(fileURLWithPath: fixture.path("shortcut")))

        #expect(tree.rootPath == fixture.path("real-folder"))
        #expect(tree.totalBytes == allocatedBytes(fixture.path("real-folder/file.bin")))
    }

    @Test func unreadableFolderStaysInTheTreeFlagged() throws {
        try fixture.write("vault/open/readable.bin", bytes: 20_000)
        try fixture.write("vault/locked/secret.bin", bytes: 90_000)
        let locked = fixture.path("vault/locked")
        #expect(chmod(locked, 0o000) == 0)
        defer { chmod(locked, 0o755) }

        let tree = try detailedScanner().scanBlocking(URL(fileURLWithPath: fixture.path("vault")))

        let id = try #require(tree.node(atPath: locked))
        #expect(tree[id].isUnreadable)
        #expect(tree[id].flags.contains(.permissionDenied))
        #expect(tree[id].bytes == 0)
        #expect(tree.unreadableFolders() == [id])
        #expect(tree.childNames(atPath: fixture.path("vault")).contains("locked"))
        // What could be read is still counted.
        #expect(tree.totalBytes == allocatedBytes(fixture.path("vault/open/readable.bin")))
    }

    @Test func retryReadsAFolderAgainAndUpdatesEverythingAboveIt() async throws {
        try fixture.write("vault/open/readable.bin", bytes: 20_000)
        try fixture.write("vault/deep/locked/secret.bin", bytes: 90_000)
        try fixture.write("vault/deep/locked/more/photo.jpg", bytes: 40_000)
        let locked = fixture.path("vault/deep/locked")
        #expect(chmod(locked, 0o000) == 0)
        defer { chmod(locked, 0o755) }

        let service = AnalyzeService(engine: fixture.engine(items: []), scanner: detailedScanner())
        let tree = try await service.scan(URL(fileURLWithPath: fixture.path("vault")))
        let id = try #require(tree.unreadableFolders().first)
        #expect(tree.totalBytes == fixture.allocatedTotal("vault/open"))

        #expect(chmod(locked, 0o755) == 0)
        let retried = try await service.retry(id, in: tree)

        #expect(retried.unreadableFolders().isEmpty)
        #expect(!retried[id].isUnreadable)
        #expect(retried[id].bytes == fixture.allocatedTotal("vault/deep/locked"))
        #expect(retried.bytes(atPath: fixture.path("vault/deep")) == fixture.allocatedTotal("vault/deep"))
        #expect(retried.totalBytes == fixture.allocatedTotal("vault"))
        #expect(retried.totalFiles == 3)
        #expect(retried.bytes(atPath: fixture.path("vault/deep/locked/more/photo.jpg")) == allocatedBytes(fixture.path("vault/deep/locked/more/photo.jpg")))
        #expect(retried.categoryBytes(of: retried.root).total == retried.totalBytes)
        #expect(retried.categoryBytes(of: retried.root)[.images] == allocatedBytes(fixture.path("vault/deep/locked/more/photo.jpg")))
        #expect(retried.largestFileRecords.contains { $0.path == fixture.path("vault/deep/locked/secret.bin") })
        // The cache holds the repaired tree.
        #expect(service.cachedTree(for: URL(fileURLWithPath: fixture.path("vault"))) == retried)
    }

    @Test func smallFilesAreFoldedIntoOneAggregate() throws {
        for index in 0..<10 { try fixture.write("many/small-\(index).txt", bytes: 4_000) }
        try fixture.write("many/big-1.mov", bytes: 300_000)
        try fixture.write("many/big-2.mov", bytes: 200_000)
        try fixture.write("many/empty.txt", bytes: 0)

        let scanner = detailedScanner { $0.detailDepth = 0; $0.individualFileThreshold = 100_000; $0.maxFilesPerDirectory = 8 }
        let tree = try scanner.scanBlocking(URL(fileURLWithPath: fixture.path("many")))

        let children = tree.children(of: tree.root)
        #expect(children.map { tree[$0].kind } == [.file, .file, .aggregate])
        #expect(children.map { tree.displayName(of: $0) } == ["big-1.mov", "big-2.mov", "11 other files"])
        let aggregate = tree[children[2]]
        #expect(aggregate.fileCount == 11)
        #expect(aggregate.bytes == (0..<10).reduce(0) { $0 + allocatedBytes(fixture.path("many/small-\($1).txt")) })
        #expect(aggregate.category == .documents)
        #expect(tree.path(of: children[2]) == fixture.path("many"))
        // Folding loses no bytes and no files.
        #expect(tree.totalBytes == fixture.allocatedTotal("many"))
        #expect(tree.totalFiles == 13)
        #expect(tree.categoryBytes(of: tree.root)[.video] == tree[children[0]].bytes + tree[children[1]].bytes)
        // Folded files are still found by the tree-wide list of largest files.
        #expect(tree.largestFileRecords.count == 12)
        #expect(tree.largestFileRecords.contains { $0.path == fixture.path("many/small-3.txt") })
    }

    @Test func perFolderLimitKeepsOnlyTheLargestFiles() throws {
        for index in 1...20 { try fixture.write("flat/file-\(index).bin", bytes: index * 10_000) }
        let scanner = detailedScanner { $0.maxFilesPerDirectory = 5 }
        let tree = try scanner.scanBlocking(URL(fileURLWithPath: fixture.path("flat")))

        let names = tree.children(of: tree.root).map { tree.displayName(of: $0) }
        // The fifteen folded files together outweigh any single kept one.
        #expect(names == ["15 other files", "file-20.bin", "file-19.bin", "file-18.bin", "file-17.bin", "file-16.bin"])
        #expect(tree.nodeCount == 7)
        #expect(tree.totalBytes == fixture.allocatedTotal("flat"))
    }

    @Test func progressIsReportedAndEndsAtTheTotals() throws {
        for index in 0..<30 { try fixture.write("p/dir-\(index)/file.bin", bytes: 6_000) }
        let reports = Locked<[AnalyzeProgress]>([])
        let tree = try detailedScanner().scanBlocking(URL(fileURLWithPath: fixture.path("p"))) { progress in
            reports.mutate { $0.append(progress) }
        }
        let seen = reports.get()
        #expect(seen.count == 31)
        let last = try #require(seen.max { $0.directories < $1.directories })
        #expect(last.directories == 31)
        #expect(last.files == 30)
        #expect(last.bytes == tree.totalBytes)
        #expect(seen.allSatisfy { $0.currentPath.hasPrefix(fixture.path("p")) })
    }

    @Test func cancellingStopsTheWalk() async throws {
        for index in 0..<200 { try fixture.write("c/dir-\(index)/file.bin", bytes: 1_000) }
        let url = URL(fileURLWithPath: fixture.path("c"))

        // From the outside, between folders.
        let cancellation = AnalyzeCancellation()
        #expect(throws: CancellationError.self) {
            try detailedScanner { $0.workers = 2 }.scanBlocking(url, cancellation: cancellation) { _ in cancellation.cancel() }
        }

        // Already cancelled before it starts.
        let early = Task { () -> AnalyzeTree in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await detailedScanner().scan(url)
        }
        await #expect(throws: CancellationError.self) { try await early.value }

        // Task cancellation arriving in the middle of the walk.
        let handle = Locked<Task<AnalyzeTree, any Error>?>(nil)
        let task = Task {
            try await detailedScanner { $0.workers = 2 }.scan(url) { _ in
                while handle.get() == nil { usleep(500) }
                handle.get()?.cancel()
            }
        }
        handle.set(task)
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aSingleFileCanBeScanned() throws {
        let path = try fixture.write("solo/movie.mp4", bytes: 50_000)
        let tree = try detailedScanner().scanBlocking(URL(fileURLWithPath: path))
        #expect(tree.nodeCount == 1)
        #expect(tree[tree.root].kind == .file)
        #expect(tree.totalBytes == allocatedBytes(path))
        #expect(tree[tree.root].category == .video)
    }

    @Test func aMissingFolderThrows() {
        #expect(throws: AnalyzeError.notFound(fixture.path("nope"))) {
            try detailedScanner().scanBlocking(URL(fileURLWithPath: fixture.path("nope")))
        }
    }

    @Test func pathsAndNodesRoundTrip() throws {
        try fixture.write("a/b/c/deep.txt", bytes: 3_000)
        try fixture.write("a/b/sibling with spaces.txt", bytes: 3_000)
        let tree = try detailedScanner().scanBlocking(fixture.url)

        for id in 0..<tree.nodeCount where tree[id].kind != .aggregate {
            #expect(tree.node(atPath: tree.path(of: id)) == id)
        }
        let deep = try #require(tree.node(atPath: fixture.path("a/b/c/deep.txt")))
        #expect(tree.ancestors(of: deep).map { tree.displayName(of: $0) } == ["home", "a", "b", "c", "deep.txt"])
        #expect(tree.node(atPath: fixture.path("a/missing")) == nil)
        #expect(tree.node(atPath: "/somewhere/else") == nil)
        #expect(tree.item(for: deep).name == "deep.txt")
        #expect(tree.item(for: deep).parentPath == fixture.path("a/b/c"))
    }
}

@Suite struct FileCategoryTests {
    @Test func extensionsMapToCategories() {
        let expected: [(String, FileCategory)] = [
            ("main.swift", .code), ("index.TSX", .code), ("photo.HEIC", .images), ("clip.mov", .video),
            ("song.flac", .audio), ("backup.tar.gz", .archives), ("Installer.dmg", .archives),
            ("report.pdf", .documents), ("notes.md", .documents), ("libfoo.dylib", .apps),
            ("module.o", .developer), ("Info.plist", .system), ("README", .other), (".hidden", .other),
            ("weird.", .other), ("name.with space", .other), ("unknown.zzz", .other),
        ]
        for (name, category) in expected {
            #expect(FileCategory.classify(fileName: name) == category, "\(name)")
        }
    }

    @Test func foldersGiveTheirContentsAContext() {
        #expect(FileCategory.context(forPath: "/Users/me/code/app/node_modules/react") == .developer)
        #expect(FileCategory.context(forPath: "/Users/me/Applications/Notes.app/Contents/Resources") == .apps)
        #expect(FileCategory.context(forPath: "/Users/me/Documents") == nil)
        #expect(FileCategory.context(forPath: "/System/Library/Fonts") == .system)
        #expect(FileCategory.context(forPath: "/Library/Developer/CommandLineTools") == .developer)
        #expect(FileCategory.context(forPath: "/System/Applications/Mail.app/Contents") == .apps)
        #expect(FileCategory.context(forPath: "/Users/me/Library") == nil)
        #expect(FileCategory.context(forPath: "/") == nil)
    }

    @Test func scannedFilesAreColouredByTypeAndContext() throws {
        let fixture = try FixtureHome()
        try fixture.write("work/site/index.html", bytes: 9_000)
        try fixture.write("work/site/node_modules/lib/index.js", bytes: 30_000)
        try fixture.write("work/site/node_modules/lib/logo.png", bytes: 30_000)
        try fixture.write("work/Tool.app/Contents/Resources/icon.png", bytes: 50_000)
        try fixture.write("work/holiday.jpg", bytes: 70_000)
        // A cache folder named after a bundle identifier is not an app.
        try fixture.write("work/caches/com.example.app/blob.db", bytes: 20_000)
        let tree = try detailedScanner().scanBlocking(URL(fileURLWithPath: fixture.path("work")))

        func category(_ relative: String) -> FileCategory? { tree.node(atPath: fixture.path(relative)).map { tree[$0].category } }
        #expect(category("work/site/index.html") == .code)
        #expect(category("work/site/node_modules/lib/logo.png") == .developer)
        #expect(category("work/site/node_modules") == .developer)
        #expect(category("work/Tool.app/Contents/Resources/icon.png") == .apps)
        #expect(category("work/Tool.app") == .apps)
        #expect(category("work/holiday.jpg") == .images)
        #expect(category("work/caches/com.example.app/blob.db") == .system)
        #expect(category("work/caches/com.example.app") == .system)

        let totals = tree.categoryBytes(of: tree.root)
        #expect(totals[.developer] == fixture.allocatedTotal("work/site/node_modules"))
        #expect(totals[.apps] == fixture.allocatedTotal("work/Tool.app"))
        #expect(totals[.images] == allocatedBytes(fixture.path("work/holiday.jpg")))
        #expect(totals[.code] == allocatedBytes(fixture.path("work/site/index.html")))
        #expect(totals.total == tree.totalBytes)
        #expect(totals.ranked.map(\.category).first == .images)
        // A folder takes the colour of what fills most of it.
        #expect(category("work/site") == .developer)
    }
}
