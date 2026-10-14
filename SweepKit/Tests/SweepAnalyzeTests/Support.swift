import Darwin
import Foundation
import SweepAnalyze
import SweepKit
import SweepTestSupport

/// Bytes the file system reports as allocated for one path, without following links.
func allocatedBytes(_ path: String) -> Int64 {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return 0 }
    return Int64(info.st_blocks) * 512
}

extension FixtureHome {
    /// Allocated bytes of every regular file below `relative`, each inode once.
    func allocatedTotal(_ relative: String = "") -> Int64 {
        let base = relative.isEmpty ? home : home.appendingPathComponent(relative)
        guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { return 0 }
        var seen = Set<UInt64>()
        var total: Int64 = 0
        for case let name as String in enumerator {
            let path = base.path + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            if seen.insert(UInt64(info.st_ino)).inserted { total += Int64(info.st_blocks) * 512 }
        }
        return total
    }

    func setModified(_ relative: String, daysAgo days: Double, now: Date = Date()) throws {
        let date = now.addingTimeInterval(-days * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }

    var url: URL { home }
}

/// A scanner that reports after every folder and keeps every file as its own node.
func detailedScanner(_ adjust: (inout AnalyzeScanner.Options) -> Void = { _ in }) -> AnalyzeScanner {
    var options = AnalyzeScanner.Options()
    options.workers = 4
    options.progressInterval = 0
    options.detailDepth = 64
    adjust(&options)
    return AnalyzeScanner(options: options)
}

extension AnalyzeTree {
    /// Names of the children of the node at `path`.
    func childNames(atPath path: String) -> [String] {
        guard let id = node(atPath: path) else { return [] }
        return children(of: id).map { displayName(of: $0) }
    }

    func bytes(atPath path: String) -> Int64? {
        node(atPath: path).map { self[$0].bytes }
    }
}
