import Darwin
import Foundation

/// One directory entry as returned by `getattrlistbulk`.
public struct DirectoryEntry: Sendable {
    public enum Kind: Sendable { case file, directory, symlink, other }

    public var name: String
    public var kind: Kind
    /// Bytes allocated on disk. Zero for anything that is not a regular file.
    public var allocatedSize: Int64
    public var fileID: UInt64
    public var device: Int32
    public var linkCount: UInt32
    public var modified: TimeInterval
}

public struct DirectoryReadError: Error, Sendable {
    public var path: String
    public var code: Int32
    public var isPermissionDenied: Bool { code == EACCES || code == EPERM }
}

/// Reads a directory with one `getattrlistbulk` call per batch of entries,
/// which returns names, types and allocated sizes without a `stat` per file.
public enum DirectoryReader {
    // Attribute bits, spelled out so the packing order below is easy to check
    // against <sys/attr.h>.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004

    private static let vReg: UInt32 = 1
    private static let vDir: UInt32 = 2
    private static let vLnk: UInt32 = 5

    /// Calls `body` for every entry of `path`. Entries the kernel could not
    /// describe are counted in the return value instead of being passed on.
    @discardableResult
    public static func read(_ path: String, _ body: (DirectoryEntry) -> Void) throws(DirectoryReadError) -> Int {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DirectoryReadError(path: path, code: errno) }
        defer { close(fd) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = cmnReturnedAttrs | cmnName | cmnDevID | cmnObjType | cmnModTime | cmnFileID | cmnError
        attributes.fileattr = fileLinkCount | fileAllocSize

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var unreadable = 0
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, bufferSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DirectoryReadError(path: path, code: errno)
            }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + MemoryLayout<UInt32>.size
                defer { entry += length }

                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                var errorCode: UInt32 = 0
                if returned.commonattr & cmnError != 0 {
                    errorCode = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }

                var name = ""
                if returned.commonattr & cmnName != 0 {
                    let reference = field.loadUnaligned(as: attrreference_t.self)
                    let start = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    name = String(cString: start)
                    field += MemoryLayout<attrreference_t>.size
                }
                if errorCode != 0 {
                    unreadable += 1
                    continue
                }

                var device: Int32 = 0
                if returned.commonattr & cmnDevID != 0 {
                    device = field.loadUnaligned(as: Int32.self)
                    field += MemoryLayout<Int32>.size
                }
                var type: UInt32 = 0
                if returned.commonattr & cmnObjType != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var modified: TimeInterval = 0
                if returned.commonattr & cmnModTime != 0 {
                    let time = field.loadUnaligned(as: timespec.self)
                    modified = TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
                    field += MemoryLayout<timespec>.size
                }
                var fileID: UInt64 = 0
                if returned.commonattr & cmnFileID != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += MemoryLayout<UInt64>.size
                }
                var linkCount: UInt32 = 1
                if returned.fileattr & fileLinkCount != 0 {
                    linkCount = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var allocated: Int64 = 0
                if returned.fileattr & fileAllocSize != 0 {
                    allocated = field.loadUnaligned(as: Int64.self)
                    field += MemoryLayout<Int64>.size
                }

                let kind: DirectoryEntry.Kind
                switch type {
                case vReg: kind = .file
                case vDir: kind = .directory
                case vLnk: kind = .symlink
                default: kind = .other
                }
                body(DirectoryEntry(
                    name: name,
                    kind: kind,
                    allocatedSize: kind == .file ? allocated : 0,
                    fileID: fileID,
                    device: device,
                    linkCount: linkCount,
                    modified: modified
                ))
            }
        }
        return unreadable
    }
}
