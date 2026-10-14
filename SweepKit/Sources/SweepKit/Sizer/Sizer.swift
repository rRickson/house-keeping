import Darwin
import Foundation

public struct SizeResult: Sendable, Equatable {
    /// Bytes allocated on disk, hardlinked files counted once.
    public var bytes: Int64 = 0
    public var files: Int = 0
    /// Newest modification date found anywhere inside.
    public var lastModified: Date?
    /// Folders or entries that could not be read.
    public var unreadable: Int = 0
    public var permissionDenied = false

    public init() {}

    public mutating func merge(_ other: SizeResult) {
        bytes += other.bytes
        files += other.files
        unreadable += other.unreadable
        permissionDenied = permissionDenied || other.permissionDenied
        if let date = other.lastModified, date > (lastModified ?? .distantPast) { lastModified = date }
    }
}

/// Measures allocated size. Symlinks are never followed and other volumes are
/// never entered, so a size is always the size of what a delete would remove.
public struct Sizer: Sendable {
    public init() {}

    /// Sizes several locations as one item, sharing the hardlink set between them.
    /// Throws `CancellationError` when the surrounding task is cancelled.
    public func size(of urls: [URL], progress: (@Sendable (Int64) -> Void)? = nil) throws -> SizeResult {
        var result = SizeResult()
        var seen = Set<UInt64>()
        var newest: TimeInterval = 0
        for url in urls {
            try measure(url.path, into: &result, seen: &seen, newest: &newest, progress: progress)
        }
        if newest > 0 { result.lastModified = Date(timeIntervalSince1970: newest) }
        return result
    }

    public func size(of url: URL, progress: (@Sendable (Int64) -> Void)? = nil) throws -> SizeResult {
        try size(of: [url], progress: progress)
    }

    /// The same measurement off the calling actor.
    public func sizeAsync(of urls: [URL], progress: (@Sendable (Int64) -> Void)? = nil) async throws -> SizeResult {
        let task = Task.detached(priority: .utility) { try self.size(of: urls, progress: progress) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func measure(
        _ root: String,
        into result: inout SizeResult,
        seen: inout Set<UInt64>,
        newest: inout TimeInterval,
        progress: (@Sendable (Int64) -> Void)?
    ) throws {
        var info = stat()
        guard lstat(root, &info) == 0 else {
            if errno == EACCES || errno == EPERM { result.permissionDenied = true }
            return
        }
        let modified = TimeInterval(info.st_mtimespec.tv_sec)
        if modified > newest { newest = modified }

        let type = info.st_mode & S_IFMT
        if type != S_IFDIR {
            // A file, or a symlink that is counted as the link itself.
            if type == S_IFREG {
                result.bytes += Int64(info.st_blocks) * 512
                result.files += 1
            }
            return
        }

        let rootDevice = info.st_dev
        var pending = [root]
        var sinceReport: Int64 = 0
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            var subdirectories: [String] = []
            do {
                let skipped = try DirectoryReader.read(directory) { entry in
                    if entry.modified > newest { newest = entry.modified }
                    switch entry.kind {
                    case .directory:
                        // Stay on the volume the item lives on.
                        if entry.device == rootDevice { subdirectories.append(entry.name) }
                    case .file:
                        result.files += 1
                        if entry.linkCount > 1, !seen.insert(entry.fileID).inserted { return }
                        result.bytes += entry.allocatedSize
                        sinceReport += entry.allocatedSize
                    case .symlink, .other:
                        result.files += 1
                    }
                }
                result.unreadable += skipped
            } catch {
                result.unreadable += 1
                if error.isPermissionDenied { result.permissionDenied = true }
            }
            for name in subdirectories {
                pending.append(directory + "/" + name)
            }
            if sinceReport > 32 * 1024 * 1024 {
                progress?(result.bytes)
                sinceReport = 0
            }
        }
        progress?(result.bytes)
    }
}
