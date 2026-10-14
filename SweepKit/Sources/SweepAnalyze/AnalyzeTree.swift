import Foundation

/// One row of a side-panel list, or the subject of a context-menu action.
public struct AnalyzeItem: Sendable, Hashable, Identifiable {
    public var path: String
    public var bytes: Int64
    public var modified: Date?
    public var category: FileCategory
    public var isDirectory: Bool
    /// Files inside, for folders. 1 for a file.
    public var fileCount: Int

    public var id: String { path }
    public var name: String { path == "/" ? "/" : (path as NSString).lastPathComponent }
    public var parentPath: String { (path as NSString).deletingLastPathComponent }

    public init(path: String, bytes: Int64, modified: Date?, category: FileCategory, isDirectory: Bool, fileCount: Int = 1) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.category = category
        self.isDirectory = isDirectory
        self.fileCount = fileCount
    }
}

/// The three side-panel lists for one folder of the tree.
public struct AnalyzeLists: Sendable, Equatable {
    public var largestFiles: [AnalyzeItem] = []
    public var largestFolders: [AnalyzeItem] = []
    public var untouched: [AnalyzeItem] = []

    public init() {}
}

/// The size tree of one scanned folder or volume.
///
/// Nodes live in one flat array. A directory's children are contiguous and
/// always come after it, which keeps the tree compact, `Sendable`, and cheap
/// to write to the cache. Every directory is a node; within a directory only
/// the largest files are nodes and the rest are folded into one aggregate
/// node ("312 other files"), which bounds memory on trees with millions of
/// small files.
public struct AnalyzeTree: Sendable, Equatable {
    public typealias NodeID = Int

    public enum NodeKind: UInt8, Sendable {
        case directory, file
        /// The small files of a directory, folded into one tile.
        case aggregate
    }

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// The folder could not be read. It stays in the tree so the UI can offer a retry.
        public static let unreadable = Flags(rawValue: 1 << 0)
        /// A mount point of another volume; never entered.
        public static let otherVolume = Flags(rawValue: 1 << 1)
        /// A cloud folder whose contents are not on this Mac; listing it would download it.
        public static let cloudOnly = Flags(rawValue: 1 << 2)
        /// Moved to the Trash after the scan.
        public static let removed = Flags(rawValue: 1 << 3)
        /// The reason the folder was unreadable was a permission error.
        public static let permissionDenied = Flags(rawValue: 1 << 4)
    }

    public struct Node: Sendable, Equatable {
        public internal(set) var name: String
        /// Allocated bytes; for a directory, of everything inside, hardlinks counted once.
        public internal(set) var bytes: Int64
        /// Seconds since 1970. For a directory, the newest date found inside.
        public internal(set) var modifiedTime: TimeInterval
        var parent: Int32
        var firstChild: Int32
        var childCount: Int32
        var files: Int32
        /// Index of this directory's per-category totals; -1 for files.
        var slot: Int32
        public internal(set) var kind: NodeKind
        /// The file's type; for a directory or aggregate, the type that holds the most bytes.
        public internal(set) var category: FileCategory
        public internal(set) var flags: Flags

        public var isDirectory: Bool { kind == .directory }
        public var isUnreadable: Bool { flags.contains(.unreadable) }
        /// Number of files this node stands for.
        public var fileCount: Int { Int(files) }
        public var modified: Date? { modifiedTime > 0 ? Date(timeIntervalSince1970: modifiedTime) : nil }
    }

    /// Absolute path of the scanned folder.
    public let rootPath: String
    public internal(set) var scannedAt: Date
    public internal(set) var scanDuration: TimeInterval
    public internal(set) var nodes: ContiguousArray<Node>
    /// `CategoryBytes.count` values per directory slot.
    var categoryTotals: ContiguousArray<Int64>
    /// The largest files anywhere in the tree, including ones folded into aggregates.
    public internal(set) var largestFileRecords: [AnalyzeItem]
    /// The largest files that were already older than `oldCutoff` at scan time.
    public internal(set) var oldFileRecords: [AnalyzeItem]
    public internal(set) var oldCutoff: Date

    init(
        rootPath: String,
        scannedAt: Date,
        scanDuration: TimeInterval,
        nodes: ContiguousArray<Node>,
        categoryTotals: ContiguousArray<Int64>,
        largestFileRecords: [AnalyzeItem],
        oldFileRecords: [AnalyzeItem],
        oldCutoff: Date
    ) {
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.scanDuration = scanDuration
        self.nodes = nodes
        self.categoryTotals = categoryTotals
        self.largestFileRecords = largestFileRecords
        self.oldFileRecords = oldFileRecords
        self.oldCutoff = oldCutoff
    }

    // MARK: Reading

    public var root: NodeID { 0 }
    public subscript(id: NodeID) -> Node { nodes[id] }
    public var totalBytes: Int64 { nodes[0].bytes }
    public var totalFiles: Int { nodes[0].fileCount }
    public var nodeCount: Int { nodes.count }

    public func isValid(_ id: NodeID) -> Bool {
        id >= 0 && id < nodes.count && !nodes[id].flags.contains(.removed)
    }

    /// The node's children that still exist, in stored order (largest first after a scan).
    public func children(of id: NodeID) -> [NodeID] {
        let node = nodes[id]
        guard node.childCount > 0 else { return [] }
        let range = Int(node.firstChild)..<Int(node.firstChild + node.childCount)
        return range.filter { !nodes[$0].flags.contains(.removed) }
    }

    public func parent(of id: NodeID) -> NodeID? {
        let parent = nodes[id].parent
        return parent >= 0 ? Int(parent) : nil
    }

    /// The chain from the root down to `id`, both included. This is the breadcrumb.
    public func ancestors(of id: NodeID) -> [NodeID] {
        var chain = [id]
        var current = id
        while let parent = parent(of: current) {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    /// The absolute path. An aggregate has no path of its own and answers with its folder's.
    public func path(of id: NodeID) -> String {
        if id == 0 { return rootPath }
        var names: [String] = []
        var current = id
        if nodes[current].kind == .aggregate, let parent = parent(of: current) { current = parent }
        while current != 0 {
            names.append(nodes[current].name)
            current = Int(nodes[current].parent)
        }
        var path = rootPath == "/" ? "" : rootPath
        for name in names.reversed() {
            path += "/" + name
        }
        return path.isEmpty ? "/" : path
    }

    /// The name to show: the file or folder name, or "312 other files" for an aggregate.
    public func displayName(of id: NodeID) -> String {
        let node = nodes[id]
        switch node.kind {
        case .aggregate:
            let count = node.fileCount.formatted()
            return node.fileCount == 1 ? "1 other file" : "\(count) other files"
        case .directory, .file:
            if id == 0 { return rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent }
            return node.name
        }
    }

    /// Bytes per file type below a node.
    public func categoryBytes(of id: NodeID) -> CategoryBytes {
        let node = nodes[id]
        if node.slot >= 0 {
            let start = Int(node.slot) * CategoryBytes.count
            return CategoryBytes(values: Array(categoryTotals[start..<start + CategoryBytes.count]))
        }
        var result = CategoryBytes()
        result[node.category] = node.bytes
        return result
    }

    /// Finds the node for an absolute path at or below the root.
    public func node(atPath path: String) -> NodeID? {
        if path == rootPath { return 0 }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var current = 0
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = children(of: current).first(where: { nodes[$0].kind != .aggregate && nodes[$0].name == component }) else {
                return nil
            }
            current = next
        }
        return current
    }

    public func item(for id: NodeID) -> AnalyzeItem {
        let node = nodes[id]
        return AnalyzeItem(
            path: path(of: id),
            bytes: node.bytes,
            modified: node.modified,
            category: node.category,
            isDirectory: node.kind == .directory,
            fileCount: node.fileCount
        )
    }

    /// Folders at or below `scope` that could not be read.
    public func unreadableFolders(under scope: NodeID = 0) -> [NodeID] {
        var result: [NodeID] = []
        walk(from: scope) { id, node in
            if node.flags.contains(.unreadable) { result.append(id) }
        }
        return result
    }

    /// Visits every node at or below `scope` that still exists.
    func walk(from scope: NodeID, _ visit: (NodeID, Node) -> Void) {
        guard isValid(scope) else { return }
        var pending = [scope]
        while let id = pending.popLast() {
            let node = nodes[id]
            visit(id, node)
            guard node.childCount > 0 else { continue }
            for child in Int(node.firstChild)..<Int(node.firstChild + node.childCount)
            where !nodes[child].flags.contains(.removed) {
                pending.append(child)
            }
        }
    }

    // MARK: Side-panel queries

    /// A folder is left out of "largest folders" when one subfolder holds at
    /// least this share of it: the subfolder is the more useful answer.
    static let dominatedShare = 0.8

    /// The three side-panel lists for everything below `scope`, in one pass.
    public func lists(under scope: NodeID = 0, limit: Int = 50, untouchedSince cutoff: Date) -> AnalyzeLists {
        var lists = AnalyzeLists()
        guard isValid(scope), limit > 0 else { return lists }
        let cutoffTime = cutoff.timeIntervalSince1970

        var files = TopNodes(limit: limit)
        var folders = TopNodes(limit: limit)
        var old = TopNodes(limit: limit)
        walk(from: scope) { id, node in
            switch node.kind {
            case .file:
                files.offer(id, node.bytes)
                if node.modifiedTime > 0, node.modifiedTime < cutoffTime { old.offer(id, node.bytes) }
            case .directory:
                guard id != scope, node.bytes > 0 else { return }
                var largestSubfolder: Int64 = 0
                if node.childCount > 0 {
                    for child in Int(node.firstChild)..<Int(node.firstChild + node.childCount) {
                        let candidate = nodes[child]
                        if candidate.kind == .directory, !candidate.flags.contains(.removed), candidate.bytes > largestSubfolder {
                            largestSubfolder = candidate.bytes
                        }
                    }
                }
                if Double(largestSubfolder) < Double(node.bytes) * Self.dominatedShare { folders.offer(id, node.bytes) }
            case .aggregate:
                break
            }
        }

        let scopePath = path(of: scope)
        func inScope(_ item: AnalyzeItem) -> Bool {
            scopePath == "/" || item.path.hasPrefix(scopePath + "/") || item.path == scopePath
        }
        func merged(_ top: TopNodes, with records: [AnalyzeItem]) -> [AnalyzeItem] {
            var top = top
            var seen = Set<String>()
            var items: [AnalyzeItem] = []
            for id in top.sorted() {
                let item = item(for: id)
                if seen.insert(item.path).inserted { items.append(item) }
            }
            for record in records where inScope(record) && seen.insert(record.path).inserted {
                items.append(record)
            }
            items.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            return Array(items.prefix(limit))
        }

        lists.largestFiles = merged(files, with: largestFileRecords)
        lists.untouched = merged(old, with: oldFileRecords.filter { ($0.modified ?? .distantFuture) < cutoff })
        lists.largestFolders = folders.sorted().map(item(for:))
        return lists
    }

    public func largestFiles(under scope: NodeID = 0, limit: Int = 50) -> [AnalyzeItem] {
        lists(under: scope, limit: limit, untouchedSince: .distantPast).largestFiles
    }

    public func largestFolders(under scope: NodeID = 0, limit: Int = 50) -> [AnalyzeItem] {
        lists(under: scope, limit: limit, untouchedSince: .distantPast).largestFolders
    }

    /// The largest files whose modification date is before `cutoff`.
    public func untouchedFiles(under scope: NodeID = 0, olderThan cutoff: Date, limit: Int = 50) -> [AnalyzeItem] {
        lists(under: scope, limit: limit, untouchedSince: cutoff).untouched
    }

    // MARK: Updating in place

    /// Takes a path out of the tree after it was moved to the Trash, and
    /// shrinks every folder above it. Returns the bytes the tree gave up.
    @discardableResult
    public mutating func remove(path: String) -> Int64 {
        var removed: Int64 = 0
        if let id = node(atPath: path) {
            guard id != 0 else { return 0 }
            let node = nodes[id]
            removed = node.bytes
            subtract(bytes: node.bytes, files: node.files, categories: categoryBytes(of: id), fromAncestorsOf: id)
            nodes[id].flags.insert(.removed)
        } else if let record = (largestFileRecords + oldFileRecords).first(where: { $0.path == path }),
                  let folder = node(atPath: record.parentPath),
                  let aggregate = children(of: folder).first(where: { nodes[$0].kind == .aggregate }) {
            // A file that was folded into its folder's aggregate.
            removed = min(record.bytes, nodes[aggregate].bytes)
            var categories = CategoryBytes()
            categories[record.category] = removed
            nodes[aggregate].bytes -= removed
            nodes[aggregate].files = max(nodes[aggregate].files - 1, 0)
            subtract(bytes: removed, files: 1, categories: categories, fromAncestorsOf: aggregate)
            if nodes[aggregate].files == 0 { nodes[aggregate].flags.insert(.removed) }
        }
        let prefix = path + "/"
        largestFileRecords.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
        oldFileRecords.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
        return removed
    }

    private mutating func subtract(bytes: Int64, files: Int32, categories: CategoryBytes, fromAncestorsOf id: NodeID) {
        var current = nodes[id].parent
        while current >= 0 {
            let index = Int(current)
            nodes[index].bytes = max(nodes[index].bytes - bytes, 0)
            nodes[index].files = max(nodes[index].files - files, 0)
            adjustCategories(of: index, by: categories, sign: -1)
            current = nodes[index].parent
        }
    }

    private mutating func adjustCategories(of id: NodeID, by delta: CategoryBytes, sign: Int64) {
        let slot = nodes[id].slot
        guard slot >= 0 else { return }
        let start = Int(slot) * CategoryBytes.count
        for offset in 0..<CategoryBytes.count {
            categoryTotals[start + offset] = max(categoryTotals[start + offset] + sign * delta.values[offset], 0)
        }
        if let dominant = categoryBytes(of: id).dominant { nodes[id].category = dominant }
    }

    /// Replaces the contents of the folder `id` with a fresh scan of that same
    /// folder, and updates every folder above it. Used to retry an unreadable folder.
    public mutating func graft(_ subtree: AnalyzeTree, at id: NodeID) {
        guard isValid(id), nodes[id].kind == .directory, subtree.nodes[0].kind == .directory else { return }
        let old = nodes[id]
        let oldCategories = categoryBytes(of: id)
        let fresh = subtree.nodes[0]

        // Old children are simply forgotten; the fresh ones go at the end,
        // which keeps "children come after their parent" true.
        let offset = Int32(nodes.count - 1)
        let slotOffset = Int32(categoryTotals.count / CategoryBytes.count)
        nodes.reserveCapacity(nodes.count + subtree.nodes.count - 1)
        for var node in subtree.nodes.dropFirst() {
            node.parent = node.parent == 0 ? Int32(id) : node.parent + offset
            if node.childCount > 0 { node.firstChild += offset }
            if node.slot >= 0 { node.slot += slotOffset }
            nodes.append(node)
        }
        categoryTotals.append(contentsOf: subtree.categoryTotals)

        nodes[id].firstChild = fresh.childCount > 0 ? fresh.firstChild + offset : 0
        nodes[id].childCount = fresh.childCount
        nodes[id].bytes = fresh.bytes
        nodes[id].files = fresh.files
        nodes[id].flags = fresh.flags
        nodes[id].modifiedTime = max(old.modifiedTime, fresh.modifiedTime)
        nodes[id].category = fresh.category
        nodes[id].slot = fresh.slot >= 0 ? fresh.slot + slotOffset : old.slot

        // Fold the difference into the ancestors.
        let newCategories = categoryBytes(of: id)
        var current = old.parent
        while current >= 0 {
            let index = Int(current)
            nodes[index].bytes = max(nodes[index].bytes + fresh.bytes - old.bytes, 0)
            nodes[index].files = max(nodes[index].files + fresh.files - old.files, 0)
            nodes[index].modifiedTime = max(nodes[index].modifiedTime, fresh.modifiedTime)
            adjustCategories(of: index, by: oldCategories, sign: -1)
            adjustCategories(of: index, by: newCategories, sign: 1)
            current = nodes[index].parent
        }

        let path = path(of: id)
        let prefix = path == "/" ? "/" : path + "/"
        func refreshed(_ existing: [AnalyzeItem], _ incoming: [AnalyzeItem], limit: Int) -> [AnalyzeItem] {
            var items = existing.filter { !$0.path.hasPrefix(prefix) } + incoming
            items.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            return Array(items.prefix(limit))
        }
        largestFileRecords = refreshed(largestFileRecords, subtree.largestFileRecords, limit: max(largestFileRecords.count, subtree.largestFileRecords.count))
        oldFileRecords = refreshed(oldFileRecords, subtree.oldFileRecords, limit: max(oldFileRecords.count, subtree.oldFileRecords.count))
    }
}

/// Keeps the `limit` largest node ids seen, without sorting every candidate.
struct TopNodes {
    private var entries: [(id: Int, bytes: Int64)] = []
    private var floor: Int64 = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = max(limit, 1)
        entries.reserveCapacity(self.limit * 2)
    }

    mutating func offer(_ id: Int, _ bytes: Int64) {
        guard bytes > floor else { return }
        entries.append((id, bytes))
        if entries.count >= limit * 2 { trim() }
    }

    private mutating func trim() {
        entries.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
            floor = entries[entries.count - 1].bytes - 1
        }
    }

    /// Node ids, largest first.
    mutating func sorted() -> [Int] {
        trim()
        return entries.map(\.id)
    }
}
