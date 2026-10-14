import CryptoKit
import Foundation
import SweepKit

public enum AnalyzeCacheError: Error, Sendable, Equatable {
    case corrupt
}

/// Keeps the last scan of each folder on disk for a day, so reopening Analyze
/// shows the treemap at once instead of walking the disk again.
///
/// One file per scanned path under `Application Support/Sweep/AnalyzeCache/`.
/// The tree is written as plain columns of numbers plus one block of names,
/// then compressed, which is far smaller and faster than JSON for a million nodes.
public struct AnalyzeCache: Sendable {
    public static let defaultLifetime: TimeInterval = 24 * 3600

    public let directory: URL
    /// A cached tree older than this is treated as missing.
    public var lifetime: TimeInterval

    public init(directory: URL, lifetime: TimeInterval = AnalyzeCache.defaultLifetime) {
        self.directory = directory
        self.lifetime = lifetime
    }

    public init(context: SweepContext, lifetime: TimeInterval = AnalyzeCache.defaultLifetime) {
        self.init(directory: context.supportDirectory.appendingPathComponent("AnalyzeCache", isDirectory: true), lifetime: lifetime)
    }

    /// The cache file for a scanned path. The name is a digest, so any path maps to a flat, legal file name.
    public func fileURL(forPath path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".sweeptree")
    }

    public func store(_ tree: AnalyzeTree) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = AnalyzeTreeCodec.encode(tree)
        let compressed = try (payload as NSData).compressed(using: .lzfse) as Data
        var file = Data(AnalyzeTreeCodec.magic)
        file.append(compressed)
        try file.write(to: fileURL(forPath: tree.rootPath), options: .atomic)
    }

    /// The cached tree for `path`, or nil when there is none, it cannot be
    /// read, or it is older than `lifetime`. Stale and broken files are removed.
    public func load(path: String, now: Date = Date()) -> AnalyzeTree? {
        let url = fileURL(forPath: path)
        guard let file = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard let tree = Self.decode(file), tree.rootPath == path else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard isFresh(tree, now: now) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return tree
    }

    public func isFresh(_ tree: AnalyzeTree, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(tree.scannedAt)
        // A scan dated in the future means the clock moved; do not trust it.
        return age < lifetime && age > -60
    }

    public func remove(path: String) {
        try? FileManager.default.removeItem(at: fileURL(forPath: path))
    }

    /// Deletes every cache file that has expired or cannot be read.
    public func removeExpired(now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "sweeptree" {
            guard let file = try? Data(contentsOf: url, options: .mappedIfSafe), let tree = Self.decode(file),
                  isFresh(tree, now: now) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
        }
    }

    private static func decode(_ file: Data) -> AnalyzeTree? {
        let magic = AnalyzeTreeCodec.magic
        guard file.count > magic.count, file.prefix(magic.count).elementsEqual(magic) else { return nil }
        let compressed = file.dropFirst(magic.count)
        guard let payload = try? (Data(compressed) as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? AnalyzeTreeCodec.decode(payload)
    }
}

/// The compact binary form of a tree: a small header, one column per node
/// field, the names as one UTF-8 block, the per-folder category totals, and
/// the two lists of remembered files. Integers are little-endian; dates are
/// seconds since the reference date, so they survive the round trip exactly.
enum AnalyzeTreeCodec {
    /// Bump the last byte when the layout changes; old files then read as missing.
    static let magic: [UInt8] = Array("SWPTREE".utf8) + [2]

    static func encode(_ tree: AnalyzeTree) -> Data {
        var writer = ByteWriter()
        let nodes = tree.nodes
        writer.write(tree.rootPath)
        writer.write(tree.scannedAt.timeIntervalSinceReferenceDate)
        writer.write(tree.scanDuration)
        writer.write(tree.oldCutoff.timeIntervalSinceReferenceDate)
        writer.write(UInt32(nodes.count))

        writer.writeColumn(nodes.map(\.bytes))
        writer.writeColumn(nodes.map(\.modifiedTime.bitPattern))
        writer.writeColumn(nodes.map(\.parent))
        writer.writeColumn(nodes.map(\.firstChild))
        writer.writeColumn(nodes.map(\.childCount))
        writer.writeColumn(nodes.map(\.files))
        writer.writeColumn(nodes.map(\.slot))
        writer.writeColumn(nodes.map(\.kind.rawValue))
        writer.writeColumn(nodes.map(\.category.rawValue))
        writer.writeColumn(nodes.map(\.flags.rawValue))

        var lengths: [UInt32] = []
        lengths.reserveCapacity(nodes.count)
        var names = Data()
        for node in nodes {
            let utf8 = node.name.utf8
            lengths.append(UInt32(utf8.count))
            names.append(contentsOf: utf8)
        }
        writer.writeColumn(lengths)
        writer.write(UInt64(names.count))
        writer.data.append(names)

        writer.write(UInt32(tree.categoryTotals.count))
        writer.writeColumn(Array(tree.categoryTotals))

        for records in [tree.largestFileRecords, tree.oldFileRecords] {
            writer.write(UInt32(records.count))
            for record in records {
                writer.write(record.path)
                writer.write(record.bytes)
                writer.write(record.modified?.timeIntervalSinceReferenceDate ?? .nan)
                writer.write(record.category.rawValue)
            }
        }
        return writer.data
    }

    static func decode(_ data: Data) throws(AnalyzeCacheError) -> AnalyzeTree {
        var reader = ByteReader(data)
        let rootPath = try reader.string()
        let scannedAt = try reader.double()
        let duration = try reader.double()
        let cutoff = try reader.double()
        let count = Int(try reader.integer(UInt32.self))
        guard count >= 1, rootPath.hasPrefix("/") else { throw .corrupt }

        let bytes = try reader.column(Int64.self, count: count)
        let modified = try reader.column(UInt64.self, count: count)
        let parents = try reader.column(Int32.self, count: count)
        let firstChildren = try reader.column(Int32.self, count: count)
        let childCounts = try reader.column(Int32.self, count: count)
        let files = try reader.column(Int32.self, count: count)
        let slots = try reader.column(Int32.self, count: count)
        let kinds = try reader.column(UInt8.self, count: count)
        let categories = try reader.column(UInt8.self, count: count)
        let flags = try reader.column(UInt8.self, count: count)
        let lengths = try reader.column(UInt32.self, count: count)
        let nameBytes = Int(clamping: try reader.integer(UInt64.self))
        let names = try reader.bytes(nameBytes)

        let totalsCount = Int(try reader.integer(UInt32.self))
        guard totalsCount % CategoryBytes.count == 0 else { throw .corrupt }
        let totals = try reader.column(Int64.self, count: totalsCount)
        let slotCount = totalsCount / CategoryBytes.count

        var nodes = ContiguousArray<AnalyzeTree.Node>()
        nodes.reserveCapacity(count)
        var nameOffset = names.startIndex
        for index in 0..<count {
            guard let kind = AnalyzeTree.NodeKind(rawValue: kinds[index]),
                  let category = FileCategory(rawValue: categories[index]) else { throw .corrupt }
            // The invariants every reader of the tree relies on.
            let parent = Int(parents[index])
            guard index == 0 ? parent == -1 : (parent >= 0 && parent < index) else { throw .corrupt }
            let childCount = Int(childCounts[index])
            let firstChild = Int(firstChildren[index])
            guard childCount >= 0, childCount == 0 || (firstChild > index && firstChild + childCount <= count) else { throw .corrupt }
            let slot = Int(slots[index])
            guard kind == .directory ? (slot >= 0 && slot < slotCount) : slot == -1 else { throw .corrupt }
            guard kind == .directory || childCount == 0 else { throw .corrupt }
            // Every child must name this node as its parent, so no node is reachable twice.
            if childCount > 0 {
                for child in firstChild..<firstChild + childCount where parents[child] != Int32(index) { throw .corrupt }
            }

            let length = Int(lengths[index])
            guard length <= names.endIndex - nameOffset else { throw .corrupt }
            let name = String(decoding: names[nameOffset..<nameOffset + length], as: UTF8.self)
            nameOffset += length

            nodes.append(AnalyzeTree.Node(
                name: name, bytes: bytes[index], modifiedTime: TimeInterval(bitPattern: modified[index]),
                parent: parents[index], firstChild: firstChildren[index], childCount: childCounts[index],
                files: files[index], slot: slots[index], kind: kind, category: category,
                flags: AnalyzeTree.Flags(rawValue: flags[index])))
        }

        var lists: [[AnalyzeItem]] = []
        for _ in 0..<2 {
            let recordCount = Int(try reader.integer(UInt32.self))
            guard recordCount <= 100_000 else { throw .corrupt }
            var records: [AnalyzeItem] = []
            records.reserveCapacity(recordCount)
            for _ in 0..<recordCount {
                let path = try reader.string()
                let size = try reader.integer(Int64.self)
                let time = try reader.double()
                guard let category = FileCategory(rawValue: try reader.integer(UInt8.self)) else { throw .corrupt }
                records.append(AnalyzeItem(
                    path: path, bytes: size, modified: time.isNaN ? nil : Date(timeIntervalSinceReferenceDate: time),
                    category: category, isDirectory: false))
            }
            lists.append(records)
        }

        return AnalyzeTree(
            rootPath: rootPath,
            scannedAt: Date(timeIntervalSinceReferenceDate: scannedAt),
            scanDuration: duration,
            nodes: nodes,
            categoryTotals: ContiguousArray(totals),
            largestFileRecords: lists[0],
            oldFileRecords: lists[1],
            oldCutoff: Date(timeIntervalSinceReferenceDate: cutoff)
        )
    }
}

struct ByteWriter {
    var data = Data()

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: Double) {
        write(value.bitPattern)
    }

    mutating func write(_ value: String) {
        let utf8 = Array(value.utf8)
        write(UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }

    /// A whole array of integers at once. Both Mac architectures are little-endian.
    mutating func writeColumn<T: FixedWidthInteger>(_ values: [T]) {
        values.withUnsafeBytes { data.append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func bytes(_ count: Int) throws(AnalyzeCacheError) -> Data {
        guard count >= 0, count <= data.endIndex - offset else { throw .corrupt }
        defer { offset += count }
        return data[offset..<offset + count]
    }

    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws(AnalyzeCacheError) -> T {
        let slice = try bytes(MemoryLayout<T>.size)
        return T(littleEndian: slice.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }

    mutating func double() throws(AnalyzeCacheError) -> Double {
        Double(bitPattern: try integer(UInt64.self))
    }

    mutating func string() throws(AnalyzeCacheError) -> String {
        let length = Int(try integer(UInt32.self))
        return String(decoding: try bytes(length), as: UTF8.self)
    }

    mutating func column<T: FixedWidthInteger>(_ type: T.Type, count: Int) throws(AnalyzeCacheError) -> [T] {
        let stride = MemoryLayout<T>.stride
        guard count >= 0, count <= (data.endIndex - offset) / max(stride, 1) else { throw .corrupt }
        let slice = try bytes(count * stride)
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            slice.withUnsafeBytes { source in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<count * stride]))
            }
            initialized = count
        }
    }
}
