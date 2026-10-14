import Darwin
import Foundation
import SweepKit

/// How far a running scan has got.
public struct AnalyzeProgress: Sendable, Equatable {
    public var files: Int = 0
    public var directories: Int = 0
    /// Allocated bytes found so far, hardlinks counted once.
    public var bytes: Int64 = 0
    /// Folders that could not be read.
    public var unreadable: Int = 0
    /// The folder a worker finished most recently.
    public var currentPath: String = ""

    public init() {}
}

public enum AnalyzeError: Error, Sendable, Equatable {
    case notFound(String)
}

/// A flag a scan checks between folders. Cancelling a `Task` that awaits
/// `AnalyzeScanner.scan` sets one for you.
public final class AnalyzeCancellation: Sendable {
    private let flag = Locked(false)
    public init() {}
    public func cancel() { flag.set(true) }
    public var isCancelled: Bool { flag.get() }
}

/// Walks a folder or volume and builds its size tree.
///
/// Sizes are allocated bytes. A hardlinked file is counted the first time it
/// is met, symbolic links are never followed, and folders on another volume
/// are listed but not entered. Folders that cannot be read stay in the tree,
/// flagged, so they can be shown and retried.
public struct AnalyzeScanner: Sendable {
    public struct Options: Sendable {
        /// At most this many files of one folder become nodes; the rest are folded.
        public var maxFilesPerDirectory = 64
        /// Smaller files are folded into their folder's aggregate, except near the root.
        public var individualFileThreshold: Int64 = 1 << 20
        /// Folders fewer than this many levels below the root keep their small files as nodes.
        public var detailDepth = 3
        /// How many of the largest (and largest old) files are remembered tree-wide.
        public var recordLimit = 200
        /// A file counts as untouched when it was last modified longer ago than this.
        public var untouchedAfter: TimeInterval = 365 * 24 * 3600
        public var workers = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
        /// Minimum seconds between progress reports. Zero reports after every folder.
        public var progressInterval: TimeInterval = 0.1

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Scans off the calling actor. Throws `CancellationError` when the surrounding task is cancelled.
    public func scan(
        _ url: URL,
        now: Date = Date(),
        progress: (@Sendable (AnalyzeProgress) -> Void)? = nil
    ) async throws -> AnalyzeTree {
        let cancellation = AnalyzeCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let tree: AnalyzeTree = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try scanBlocking(url, now: now, cancellation: cancellation, progress: progress)
                    })
                }
            }
            try Task.checkCancellation()
            return tree
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Scans on the calling thread plus a few workers, and returns when the tree is complete.
    public func scanBlocking(
        _ url: URL,
        now: Date = Date(),
        cancellation: AnalyzeCancellation? = nil,
        progress: (@Sendable (AnalyzeProgress) -> Void)? = nil
    ) throws -> AnalyzeTree {
        let started = DispatchTime.now().uptimeNanoseconds
        let standardized = url.standardizedFileURL.path
        // The folder the user picked may itself be a link (`/tmp`); links below it are never followed.
        let rootPath = SafetyGuard.realpath(standardized) ?? standardized

        var info = stat()
        guard lstat(rootPath, &info) == 0 else { throw AnalyzeError.notFound(rootPath) }
        let cutoff = now.addingTimeInterval(-options.untouchedAfter)
        let rootName = rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent
        let modified = TimeInterval(info.st_mtimespec.tv_sec)

        if (info.st_mode & S_IFMT) != S_IFDIR {
            // A single file: a tree of one node.
            let category = FileCategory.context(forPath: (rootPath as NSString).deletingLastPathComponent)
                ?? FileCategory.classify(fileName: rootName)
            let bytes = (info.st_mode & S_IFMT) == S_IFREG ? Int64(info.st_blocks) * 512 : 0
            let node = AnalyzeTree.Node(
                name: rootName, bytes: bytes, modifiedTime: modified, parent: -1, firstChild: 0, childCount: 0,
                files: 1, slot: -1, kind: .file, category: category, flags: [])
            return AnalyzeTree(
                rootPath: rootPath, scannedAt: now, scanDuration: 0, nodes: [node], categoryTotals: [],
                largestFileRecords: [], oldFileRecords: [], oldCutoff: cutoff)
        }

        var devices: Set<Int32> = [info.st_dev]
        if rootPath == "/" {
            // The startup volume is a read-only system volume plus a data volume
            // joined by firmlinks. Both belong to "/"; the data volume's own
            // mount point is skipped below so nothing is counted twice.
            var data = stat()
            if lstat(Walk.dataVolumeMount, &data) == 0 { devices.insert(data.st_dev) }
        }

        let walk = Walk(
            options: options,
            rootPath: rootPath,
            rootName: rootName,
            rootModified: modified,
            rootContext: FileCategory.context(forPath: rootPath),
            devices: devices,
            cutoff: cutoff.timeIntervalSince1970,
            cancellation: cancellation,
            progress: progress
        )
        walk.run()
        if cancellation?.isCancelled == true { throw CancellationError() }

        let duration = TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        return walk.finish(scannedAt: now, duration: duration, cutoff: cutoff)
    }
}

// MARK: - The walk

/// Shared state of one scan. Everything mutable is guarded by `condition`,
/// except the hardlink set, which has its own lock.
private final class Walk: @unchecked Sendable {
    static let dataVolumeMount = "/System/Volumes/Data"
    /// `SF_DATALESS`: the folder's listing lives in the cloud.
    static let dataless: UInt32 = 0x4000_0000

    struct Job {
        var node: Int32
        var path: String
        var depth: Int
        var context: FileCategory?
        /// Set for a folder named like an app. Cache folders are often named
        /// after a bundle identifier that ends in ".app"; only a folder with
        /// `Contents` inside is a bundle, and anything else falls back to this.
        var unlessBundle: FileCategory??
    }

    struct FileEntry {
        var name: String
        var size: Int64
        var modified: TimeInterval
        var fileID: UInt64
        var device: Int32
        var linked: Bool
        var category: FileCategory
    }

    struct LinkKey: Hashable {
        var device: Int32
        var fileID: UInt64
    }

    let options: AnalyzeScanner.Options
    let rootPath: String
    let devices: Set<Int32>
    let cutoff: TimeInterval
    let cancellation: AnalyzeCancellation?
    let progress: (@Sendable (AnalyzeProgress) -> Void)?

    private let condition = NSCondition()
    private var queue: [Job] = []
    private var active = 0
    private var waiting = 0
    private var nodes = ContiguousArray<AnalyzeTree.Node>()
    private var categoryTotals = ContiguousArray<Int64>()
    private var largest: TopItems
    private var old: TopItems
    private var counters = AnalyzeProgress()
    private var lastReport: UInt64 = 0

    private let linkLock = NSLock()
    private var seenLinks = Set<LinkKey>()

    init(
        options: AnalyzeScanner.Options,
        rootPath: String,
        rootName: String,
        rootModified: TimeInterval,
        rootContext: FileCategory?,
        devices: Set<Int32>,
        cutoff: TimeInterval,
        cancellation: AnalyzeCancellation?,
        progress: (@Sendable (AnalyzeProgress) -> Void)?
    ) {
        self.options = options
        self.rootPath = rootPath
        self.devices = devices
        self.cutoff = cutoff
        self.cancellation = cancellation
        self.progress = progress
        largest = TopItems(limit: options.recordLimit)
        old = TopItems(limit: options.recordLimit)
        nodes.append(AnalyzeTree.Node(
            name: rootName, bytes: 0, modifiedTime: rootModified, parent: -1, firstChild: 0, childCount: 0,
            files: 0, slot: 0, kind: .directory, category: rootContext ?? .other, flags: []))
        categoryTotals.append(contentsOf: repeatElement(0, count: CategoryBytes.count))
        queue.append(Job(node: 0, path: rootPath, depth: 0, context: rootContext, unlessBundle: nil))
    }

    func run() {
        let workers = max(options.workers, 1)
        let group = DispatchGroup()
        for _ in 1..<max(workers, 1) {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { self.work() }
        }
        work()
        group.wait()
    }

    private func work() {
        while true {
            condition.lock()
            while queue.isEmpty, active > 0, cancellation?.isCancelled != true {
                waiting += 1
                condition.wait()
                waiting -= 1
            }
            if queue.isEmpty || cancellation?.isCancelled == true {
                // Nothing left, or told to stop: let the other workers see it too.
                condition.broadcast()
                condition.unlock()
                return
            }
            let job = queue.removeLast()
            active += 1
            condition.unlock()

            let report = process(job)
            if let report { progress?(report) }
        }
    }

    /// Reads one folder, adds its children to the tree and queues its subfolders.
    private func process(_ job: Job) -> AnalyzeProgress? {
        var flags: AnalyzeTree.Flags = []
        var subfolders: [(name: String, device: Int32, modified: TimeInterval)] = []
        var files: [FileEntry] = []
        var hasLinks = false

        var info = stat()
        if lstat(job.path, &info) == 0, info.st_flags & Self.dataless != 0 {
            flags.insert(.cloudOnly)
        } else {
            do {
                try DirectoryReader.read(job.path) { entry in
                    switch entry.kind {
                    case .directory:
                        subfolders.append((entry.name, entry.device, entry.modified))
                    case .file:
                        let linked = entry.linkCount > 1
                        if linked { hasLinks = true }
                        files.append(FileEntry(
                            name: entry.name, size: entry.allocatedSize, modified: entry.modified, fileID: entry.fileID,
                            device: entry.device, linked: linked, category: .other))
                    case .symlink, .other:
                        // A link is never followed and takes no space worth showing.
                        break
                    }
                }
            } catch {
                flags.insert(.unreadable)
                if error.isPermissionDenied { flags.insert(.permissionDenied) }
            }
        }

        if hasLinks {
            // A hardlinked file takes its space once, wherever it is met first.
            linkLock.lock()
            for index in files.indices where files[index].linked {
                if !seenLinks.insert(LinkKey(device: files[index].device, fileID: files[index].fileID)).inserted {
                    files[index].size = 0
                }
            }
            linkLock.unlock()
        }

        var context = job.context
        if let fallback = job.unlessBundle, !subfolders.contains(where: { $0.name == "Contents" }) { context = fallback }

        var direct = [Int64](repeating: 0, count: CategoryBytes.count)
        var newest: TimeInterval = 0
        var directBytes: Int64 = 0
        for index in files.indices {
            files[index].category = context ?? FileCategory.classify(fileName: files[index].name)
            let file = files[index]
            direct[Int(file.category.rawValue)] += file.size
            directBytes += file.size
            if file.modified > newest { newest = file.modified }
        }
        files.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }

        // The largest files become nodes; the tail is folded into one aggregate.
        let keepSmall = job.depth < options.detailDepth
        var kept = 0
        for file in files.prefix(max(options.maxFilesPerDirectory, 0)) {
            guard file.size > 0, keepSmall || file.size >= options.individualFileThreshold else { break }
            kept += 1
        }
        if files.count - kept == 1, files[kept].size > 0 { kept += 1 }
        var foldedBytes: Int64 = 0
        var foldedNewest: TimeInterval = 0
        var foldedCategories = [Int64](repeating: 0, count: CategoryBytes.count)
        for file in files[kept...] {
            foldedBytes += file.size
            foldedCategories[Int(file.category.rawValue)] += file.size
            if file.modified > foldedNewest { foldedNewest = file.modified }
        }

        let base = job.path == "/" ? "" : job.path

        condition.lock()
        defer {
            active -= 1
            if waiting > 0 { condition.broadcast() }
            condition.unlock()
        }

        let first = Int32(nodes.count)
        var added: Int32 = 0
        for folder in subfolders {
            let path = base + "/" + folder.name
            let inherited = FileCategory.context(inheriting: context, directoryName: folder.name, path: path)
            let looksLikeApp = inherited == .apps && context != .apps
            let entered = devices.contains(folder.device) && path != Self.dataVolumeMount
            let slot = Int32(categoryTotals.count / CategoryBytes.count)
            categoryTotals.append(contentsOf: repeatElement(0, count: CategoryBytes.count))
            nodes.append(AnalyzeTree.Node(
                name: folder.name, bytes: 0, modifiedTime: folder.modified, parent: job.node, firstChild: 0,
                childCount: 0, files: 0, slot: slot, kind: .directory, category: inherited ?? .other,
                flags: entered ? [] : [.otherVolume]))
            if entered {
                queue.append(Job(
                    node: first + added, path: path, depth: job.depth + 1, context: inherited,
                    unlessBundle: looksLikeApp ? .some(context) : nil))
            }
            added += 1
        }
        for file in files[..<kept] {
            nodes.append(AnalyzeTree.Node(
                name: file.name, bytes: file.size, modifiedTime: file.modified, parent: job.node, firstChild: 0,
                childCount: 0, files: 1, slot: -1, kind: .file, category: file.category, flags: []))
            added += 1
        }
        if foldedBytes > 0 {
            let dominant = CategoryBytes(values: foldedCategories).dominant ?? .other
            nodes.append(AnalyzeTree.Node(
                name: "", bytes: foldedBytes, modifiedTime: foldedNewest, parent: job.node, firstChild: 0,
                childCount: 0, files: Int32(clamping: files.count - kept), slot: -1, kind: .aggregate,
                category: dominant, flags: []))
            added += 1
        }

        let index = Int(job.node)
        nodes[index].firstChild = added > 0 ? first : 0
        nodes[index].childCount = added
        nodes[index].files = Int32(clamping: files.count)
        nodes[index].flags.formUnion(flags)
        if newest > nodes[index].modifiedTime { nodes[index].modifiedTime = newest }
        let slot = Int(nodes[index].slot) * CategoryBytes.count
        for offset in 0..<CategoryBytes.count { categoryTotals[slot + offset] = direct[offset] }

        // Remember the largest files tree-wide, including the folded ones.
        // The list is sorted, so the first file that is too small ends the loop.
        for file in files {
            guard file.size > 0, largest.accepts(file.size) else { break }
            largest.offer(AnalyzeItem(
                path: base + "/" + file.name, bytes: file.size, modified: Date(timeIntervalSince1970: file.modified),
                category: file.category, isDirectory: false))
        }
        for file in files {
            guard file.size > 0, old.accepts(file.size) else { break }
            guard file.modified > 0, file.modified < cutoff else { continue }
            old.offer(AnalyzeItem(
                path: base + "/" + file.name, bytes: file.size, modified: Date(timeIntervalSince1970: file.modified),
                category: file.category, isDirectory: false))
        }

        counters.files += files.count
        counters.directories += 1
        counters.bytes += directBytes
        if flags.contains(.unreadable) { counters.unreadable += 1 }
        counters.currentPath = job.path

        guard progress != nil else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastReport >= UInt64(max(options.progressInterval, 0) * 1_000_000_000) else { return nil }
        lastReport = now
        return counters
    }

    /// Adds every folder's totals into its parent, sorts children by size, and hands the tree over.
    func finish(scannedAt: Date, duration: TimeInterval, cutoff: Date) -> AnalyzeTree {
        let width = CategoryBytes.count

        // Children always sit after their parent, so one backwards pass sees
        // every folder after everything inside it.
        for index in stride(from: nodes.count - 1, through: 0, by: -1) where nodes[index].kind == .directory {
            let slot = Int(nodes[index].slot) * width
            var total: Int64 = 0
            var best = 0
            for offset in 0..<width {
                total += categoryTotals[slot + offset]
                if categoryTotals[slot + offset] > categoryTotals[slot + best] { best = offset }
            }
            nodes[index].bytes = total
            if total > 0, let category = FileCategory(rawValue: UInt8(best)) { nodes[index].category = category }

            let parent = Int(nodes[index].parent)
            guard parent >= 0 else { continue }
            let parentSlot = Int(nodes[parent].slot) * width
            for offset in 0..<width { categoryTotals[parentSlot + offset] += categoryTotals[slot + offset] }
            nodes[parent].files = Int32(clamping: Int(nodes[parent].files) + Int(nodes[index].files))
            if nodes[index].modifiedTime > nodes[parent].modifiedTime { nodes[parent].modifiedTime = nodes[index].modifiedTime }
        }

        // Largest first within every folder. Sorting moves nodes inside their
        // own block only, so grandchildren just need their parent index fixed.
        for index in nodes.indices where nodes[index].childCount > 1 {
            let range = Int(nodes[index].firstChild)..<Int(nodes[index].firstChild + nodes[index].childCount)
            nodes[range].sort { a, b in
                if a.bytes != b.bytes { return a.bytes > b.bytes }
                if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
                return a.name < b.name
            }
            for child in range where nodes[child].childCount > 0 {
                let grandchildren = Int(nodes[child].firstChild)..<Int(nodes[child].firstChild + nodes[child].childCount)
                for grandchild in grandchildren { nodes[grandchild].parent = Int32(child) }
            }
        }

        return AnalyzeTree(
            rootPath: rootPath,
            scannedAt: scannedAt,
            scanDuration: duration,
            nodes: nodes,
            categoryTotals: categoryTotals,
            largestFileRecords: largest.sorted(),
            oldFileRecords: old.sorted(),
            oldCutoff: cutoff
        )
    }
}

/// Keeps the `limit` largest items offered to it.
struct TopItems {
    private var items: [AnalyzeItem] = []
    private var floor: Int64 = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = max(limit, 0)
    }

    /// False when an item of this size could not make the list.
    func accepts(_ bytes: Int64) -> Bool { limit > 0 && bytes > floor }

    mutating func offer(_ item: AnalyzeItem) {
        guard accepts(item.bytes) else { return }
        items.append(item)
        if items.count >= limit * 2 { trim() }
    }

    private mutating func trim() {
        items.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        if items.count >= limit, limit > 0 {
            items.removeLast(items.count - limit)
            floor = items[items.count - 1].bytes
        }
    }

    mutating func sorted() -> [AnalyzeItem] {
        trim()
        return items
    }
}
