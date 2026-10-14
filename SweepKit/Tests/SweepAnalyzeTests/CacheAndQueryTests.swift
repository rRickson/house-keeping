import Foundation
@testable import SweepAnalyze
import SweepKit
import SweepTestSupport
import Testing

@Suite struct CacheTests {
    let fixture: FixtureHome
    let engine: SweepEngine
    let service: AnalyzeService

    init() throws {
        fixture = try FixtureHome()
        try fixture.write("data/photos/one.jpg", bytes: 400_000)
        try fixture.write("data/photos/two.jpg", bytes: 300_000)
        try fixture.write("data/docs/Résumé – final ✅.pdf", bytes: 120_000)
        try fixture.write("data/code/main.swift", bytes: 9_000)
        for index in 0..<12 { try fixture.write("data/code/small/\(index).txt", bytes: 2_000) }
        try fixture.setModified("data/photos/two.jpg", daysAgo: 800)
        engine = fixture.engine(items: [])
        service = AnalyzeService(
            engine: engine,
            scanner: detailedScanner { $0.detailDepth = 2; $0.maxFilesPerDirectory = 4; $0.individualFileThreshold = 100_000 })
    }

    var dataURL: URL { URL(fileURLWithPath: fixture.path("data")) }

    @Test func treeSurvivesTheRoundTripExactly() throws {
        let tree = try service.scanner.scanBlocking(dataURL)
        #expect(tree.nodes.contains { $0.kind == .aggregate })
        #expect(!tree.oldFileRecords.isEmpty)

        let decoded = try AnalyzeTreeCodec.decode(AnalyzeTreeCodec.encode(tree))
        #expect(decoded == tree)
        #expect(decoded.path(of: decoded.nodeCount - 1) == tree.path(of: tree.nodeCount - 1))
        #expect(decoded.categoryBytes(of: decoded.root) == tree.categoryBytes(of: tree.root))
        #expect(decoded.node(atPath: fixture.path("data/docs/Résumé – final ✅.pdf")) != nil)
    }

    @Test func scanIsStoredUnderTheSupportFolderAndLoadedBack() async throws {
        #expect(service.cachedTree(for: dataURL) == nil)
        let tree = try await service.scan(dataURL)

        let folder = engine.context.supportDirectory.appendingPathComponent("AnalyzeCache")
        #expect(service.cache.directory == folder)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 1)
        #expect(files[0].hasSuffix(".sweeptree"))
        #expect(folder.path.hasPrefix(fixture.home.path))

        #expect(service.cachedTree(for: dataURL) == tree)
        // A second service, as after relaunching the app, finds it too.
        #expect(AnalyzeService(engine: fixture.engine(items: [])).cachedTree(for: dataURL) == tree)
        // The key is the scanned path: another folder has no cache.
        #expect(service.cachedTree(for: URL(fileURLWithPath: fixture.path("data/photos"))) == nil)
        #expect(service.cachedTree(for: fixture.home) == nil)
    }

    @Test func cacheExpiresAfterTwentyFourHours() async throws {
        let scannedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let tree = try await service.scan(dataURL, now: scannedAt)
        #expect(tree.scannedAt == scannedAt)
        let file = service.cache.fileURL(forPath: tree.rootPath)

        #expect(service.cachedTree(for: dataURL, now: scannedAt.addingTimeInterval(60)) == tree)
        #expect(service.cachedTree(for: dataURL, now: scannedAt.addingTimeInterval(23.9 * 3600)) == tree)
        #expect(FileManager.default.fileExists(atPath: file.path))

        #expect(service.cachedTree(for: dataURL, now: scannedAt.addingTimeInterval(24.1 * 3600)) == nil)
        // The expired file is gone, so it is not read again.
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(service.cachedTree(for: dataURL, now: scannedAt.addingTimeInterval(60)) == nil)
    }

    @Test func aScanFromTheFutureIsNotTrusted() async throws {
        let scannedAt = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await service.scan(dataURL, now: scannedAt)
        #expect(service.cachedTree(for: dataURL, now: scannedAt.addingTimeInterval(-3600)) == nil)
    }

    @Test func removeExpiredKeepsFreshFilesOnly() throws {
        let cache = AnalyzeCache(directory: fixture.home.appendingPathComponent("cache-test"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try service.scanner.scanBlocking(URL(fileURLWithPath: fixture.path("data/photos")), now: now.addingTimeInterval(-30 * 3600))
        let fresh = try service.scanner.scanBlocking(URL(fileURLWithPath: fixture.path("data/docs")), now: now.addingTimeInterval(-3600))
        try cache.store(old)
        try cache.store(fresh)
        try Data("not a tree".utf8).write(to: cache.directory.appendingPathComponent("junk.sweeptree"))

        cache.removeExpired(now: now)

        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path) == [cache.fileURL(forPath: fresh.rootPath).lastPathComponent])
        #expect(cache.load(path: fresh.rootPath, now: now) == fresh)
    }

    @Test func brokenCacheFilesAreIgnoredAndRemoved() async throws {
        let tree = try await service.scan(dataURL)
        let file = service.cache.fileURL(forPath: tree.rootPath)
        let good = try Data(contentsOf: file)

        // Truncated.
        try good.prefix(good.count / 2).write(to: file)
        #expect(service.cachedTree(for: dataURL) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Not ours at all.
        try Data(repeating: 0xFF, count: 4096).write(to: file)
        #expect(service.cachedTree(for: dataURL) == nil)

        // A tree filed under the wrong path.
        let other = try service.scanner.scanBlocking(URL(fileURLWithPath: fixture.path("data/photos")))
        try service.cache.store(other)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: service.cache.fileURL(forPath: other.rootPath), to: file)
        #expect(service.cachedTree(for: dataURL) == nil)
    }

    @Test func damagedPayloadsAreRejectedNotCrashedOn() throws {
        let tree = try service.scanner.scanBlocking(dataURL)
        let payload = AnalyzeTreeCodec.encode(tree)
        #expect(throws: AnalyzeCacheError.corrupt) { try AnalyzeTreeCodec.decode(Data()) }
        #expect(throws: AnalyzeCacheError.corrupt) { try AnalyzeTreeCodec.decode(payload.prefix(payload.count - 3)) }

        // Flip bytes all over the payload: decoding either fails cleanly or
        // yields a tree that can still be walked.
        var generator = SeededGenerator(seed: 99)
        for _ in 0..<300 {
            var damaged = payload
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            guard let decoded = try? AnalyzeTreeCodec.decode(damaged) else { continue }
            var visited = 0
            decoded.walk(from: decoded.root) { id, _ in
                visited += 1
                _ = decoded.path(of: id)
                _ = decoded.categoryBytes(of: id)
            }
            #expect(visited <= decoded.nodeCount)
            _ = decoded.lists(untouchedSince: Date())
            _ = decoded.treemap(of: decoded.root, in: CGRect(x: 0, y: 0, width: 300, height: 200))
        }
    }
}

@Suite struct QueryTests {
    let fixture: FixtureHome
    let now = Date()

    init() throws {
        fixture = try FixtureHome()
        try fixture.write("q/movies/big.mov", bytes: 5_000_000)
        try fixture.write("q/movies/old-film.mkv", bytes: 3_000_000)
        try fixture.write("q/archive/2019/backup.zip", bytes: 2_000_000)
        try fixture.write("q/archive/2019/letter.pdf", bytes: 40_000)
        try fixture.write("q/archive/2019/recent.txt", bytes: 60_000)
        try fixture.write("q/project/src/main.swift", bytes: 20_000)
        try fixture.write("q/project/assets/hero.png", bytes: 900_000)
        try fixture.setModified("q/movies/old-film.mkv", daysAgo: 400, now: now)
        try fixture.setModified("q/archive/2019/backup.zip", daysAgo: 2_000, now: now)
        try fixture.setModified("q/archive/2019/letter.pdf", daysAgo: 366, now: now)
        try fixture.setModified("q/project/assets/hero.png", daysAgo: 364, now: now)
    }

    var url: URL { URL(fileURLWithPath: fixture.path("q")) }
    var yearAgo: Date { now.addingTimeInterval(-365 * 24 * 3600) }

    @Test func largestFilesComeLargestFirst() throws {
        let tree = try detailedScanner().scanBlocking(url, now: now)
        let files = tree.largestFiles()
        #expect(files.map(\.name) == ["big.mov", "old-film.mkv", "backup.zip", "hero.png", "recent.txt", "letter.pdf", "main.swift"])
        #expect(files.allSatisfy { !$0.isDirectory })
        #expect(files[0].bytes == allocatedBytes(fixture.path("q/movies/big.mov")))
        #expect(files[0].category == .video)
        #expect(files[0].path == fixture.path("q/movies/big.mov"))
        #expect(tree.largestFiles(limit: 2).map(\.name) == ["big.mov", "old-film.mkv"])
    }

    @Test func listsCanBeScopedToAFolder() throws {
        let tree = try detailedScanner().scanBlocking(url, now: now)
        let archive = try #require(tree.node(atPath: fixture.path("q/archive")))
        let lists = tree.lists(under: archive, untouchedSince: yearAgo)
        #expect(lists.largestFiles.map(\.name) == ["backup.zip", "recent.txt", "letter.pdf"])
        #expect(lists.untouched.map(\.name) == ["backup.zip", "letter.pdf"])
        #expect(lists.largestFolders.map(\.name) == ["2019"])
    }

    @Test func largestFoldersSkipFoldersThatAreJustWrappers() throws {
        let tree = try detailedScanner().scanBlocking(url, now: now)
        let folders = tree.largestFolders()
        // "archive" only wraps "2019", and "project" is mostly "assets":
        // the inner folders are the useful answers.
        #expect(folders.map(\.name) == ["movies", "2019", "assets", "src"])
        #expect(folders.allSatisfy { $0.isDirectory })
        #expect(folders[0].bytes == fixture.allocatedTotal("q/movies"))
        #expect(folders[0].fileCount == 2)
        #expect(folders.map(\.bytes) == folders.map(\.bytes).sorted(by: >))
    }

    @Test func untouchedFilesAreOlderThanAYear() throws {
        let tree = try detailedScanner().scanBlocking(url, now: now)
        let old = tree.untouchedFiles(olderThan: yearAgo)
        #expect(old.map(\.name) == ["old-film.mkv", "backup.zip", "letter.pdf"])
        for item in old {
            let modified = try #require(item.modified)
            #expect(modified < yearAgo)
        }
        // A later cutoff lets in the file that is 364 days old.
        #expect(tree.untouchedFiles(olderThan: now.addingTimeInterval(-300 * 24 * 3600)).map(\.name).contains("hero.png"))
        #expect(tree.untouchedFiles(olderThan: now.addingTimeInterval(-3_000 * 24 * 3600)).isEmpty)
        #expect(tree.oldCutoff == yearAgo)
    }

    @Test func foldedFilesStillAppearInTheLists() throws {
        // Fold every file that shares its folder: those are not nodes, yet the lists still know them.
        let scanner = detailedScanner { $0.detailDepth = 0; $0.individualFileThreshold = .max }
        let tree = try scanner.scanBlocking(url, now: now)
        #expect(tree.node(atPath: fixture.path("q/movies/big.mov")) == nil)
        #expect(tree.node(atPath: fixture.path("q/archive/2019/backup.zip")) == nil)
        #expect(tree.childNames(atPath: fixture.path("q/movies")) == ["2 other files"])
        // A file alone in its folder is cheaper as itself than as an aggregate of one.
        #expect(tree.childNames(atPath: fixture.path("q/project/src")) == ["main.swift"])
        #expect(tree.totalBytes == fixture.allocatedTotal("q"))

        let lists = tree.lists(untouchedSince: yearAgo)
        #expect(lists.largestFiles.map(\.name).prefix(3) == ["big.mov", "old-film.mkv", "backup.zip"])
        #expect(lists.untouched.map(\.name) == ["old-film.mkv", "backup.zip", "letter.pdf"])
        let movies = try #require(tree.node(atPath: fixture.path("q/movies")))
        #expect(tree.lists(under: movies, untouchedSince: yearAgo).largestFiles.map(\.name) == ["big.mov", "old-film.mkv"])
    }

    @Test func recordLimitBoundsTheTreeWideLists() throws {
        for index in 0..<40 { try fixture.write("q/bulk/file-\(index).bin", bytes: 10_000 + index * 5_000) }
        let scanner = detailedScanner { $0.recordLimit = 5; $0.detailDepth = 0; $0.individualFileThreshold = .max }
        let tree = try scanner.scanBlocking(url, now: now)
        #expect(tree.largestFileRecords.count == 5)
        #expect(tree.largestFileRecords.map(\.name) == ["big.mov", "old-film.mkv", "backup.zip", "hero.png", "file-39.bin"])
        #expect(tree.oldFileRecords.map(\.name) == ["old-film.mkv", "backup.zip", "letter.pdf"])
    }

    @Test func removingAFolderShrinksEverythingAboveIt() throws {
        var tree = try detailedScanner().scanBlocking(url, now: now)
        let before = tree.totalBytes
        let beforeFiles = tree.totalFiles
        let archive = fixture.allocatedTotal("q/archive/2019")
        let zip = allocatedBytes(fixture.path("q/archive/2019/backup.zip"))
        let archivesBefore = tree.categoryBytes(of: tree.root)[.archives]

        #expect(tree.remove(path: fixture.path("q/archive/2019")) == archive)

        #expect(tree.totalBytes == before - archive)
        #expect(tree.totalFiles == beforeFiles - 3)
        #expect(tree.bytes(atPath: fixture.path("q/archive")) == 0)
        #expect(tree.node(atPath: fixture.path("q/archive/2019")) == nil)
        #expect(tree.node(atPath: fixture.path("q/archive/2019/backup.zip")) == nil)
        #expect(tree.childNames(atPath: fixture.path("q/archive")).isEmpty)
        #expect(tree.categoryBytes(of: tree.root)[.archives] == archivesBefore - zip)
        #expect(tree.categoryBytes(of: tree.root).total == tree.totalBytes)
        #expect(!tree.largestFiles().contains { $0.name == "backup.zip" })
        #expect(!tree.untouchedFiles(olderThan: yearAgo).contains { $0.path.contains("/2019/") })
        #expect(!tree.largestFolders().contains { $0.name == "2019" })
        // The treemap no longer draws it.
        let tiles = tree.treemap(of: tree.root, in: CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(!tiles.contains { tree.displayName(of: $0.node) == "2019" || tree.displayName(of: $0.node) == "archive" })
        // Removing it twice, or removing the root, changes nothing.
        #expect(tree.remove(path: fixture.path("q/archive/2019")) == 0)
        #expect(tree.remove(path: tree.rootPath) == 0)
        #expect(tree.totalBytes == before - archive)
    }

    @Test func removingAFoldedFileShrinksItsAggregate() throws {
        let scanner = detailedScanner { $0.detailDepth = 0; $0.individualFileThreshold = .max }
        var tree = try scanner.scanBlocking(url, now: now)
        let before = tree.totalBytes
        let film = allocatedBytes(fixture.path("q/movies/old-film.mkv"))

        #expect(tree.remove(path: fixture.path("q/movies/old-film.mkv")) == film)

        #expect(tree.totalBytes == before - film)
        #expect(tree.bytes(atPath: fixture.path("q/movies")) == allocatedBytes(fixture.path("q/movies/big.mov")))
        let movies = try #require(tree.node(atPath: fixture.path("q/movies")))
        #expect(tree.children(of: movies).map { tree.displayName(of: $0) } == ["1 other file"])
        #expect(tree.categoryBytes(of: tree.root).total == tree.totalBytes)
        #expect(!tree.largestFiles().contains { $0.name == "old-film.mkv" })
        #expect(!tree.untouchedFiles(olderThan: yearAgo).contains { $0.name == "old-film.mkv" })
    }
}
