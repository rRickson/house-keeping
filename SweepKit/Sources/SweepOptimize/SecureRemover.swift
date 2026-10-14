import Darwin
import Foundation
import SweepKit

/// Deletion for code that runs as root.
///
/// Every step is relative to an open directory descriptor and never follows a
/// symbolic link, so swapping a folder for a link while the walk is under way
/// cannot steer a delete somewhere else. A link is unlinked, never entered.
/// Mounted volumes are not crossed.
enum SecureRemover {
    struct Tally: Sendable, Equatable {
        var bytes: Int64 = 0
        var removed = 0
        var failed = 0
    }

    /// Names in the directory open at `descriptor`, as raw C strings so that
    /// names that are not valid UTF-8 still round-trip.
    static func entries(of descriptor: Int32) -> [[CChar]] {
        let copy = dup(descriptor)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [[CChar]] = []
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name: [CChar] = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) { start in
                    Array(UnsafeBufferPointer(start: start, count: length)) + [0]
                }
            }
            if name == [46, 0] || name == [46, 46, 0] { continue }
            names.append(name)
        }
        return names
    }

    /// Removes the entry `name` of the directory open at `parent`.
    /// - Parameters:
    ///   - keepDirectory: empty a folder but leave the folder itself, with its owner and mode.
    ///   - device: the volume the walk started on; entries on another one are left alone.
    /// - Returns: true when the entry is gone.
    @discardableResult
    static func remove(_ name: [CChar], in parent: Int32, keepDirectory: Bool = false, device: dev_t? = nil, tally: inout Tally) -> Bool {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        if let device, info.st_dev != device {
            tally.failed += 1
            return false
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            guard unlinkat(parent, name, 0) == 0 else {
                tally.failed += 1
                return false
            }
            tally.removed += 1
            if info.st_nlink <= 1 { tally.bytes += Int64(info.st_blocks) * 512 }
            return true
        }

        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            tally.failed += 1
            return false
        }
        defer { close(descriptor) }
        // What was opened must be what was just examined.
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            tally.failed += 1
            return false
        }
        var emptied = true
        for child in entries(of: descriptor) {
            if !remove(child, in: descriptor, device: info.st_dev, tally: &tally) { emptied = false }
        }
        if keepDirectory { return false }
        guard emptied, unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            tally.failed += 1
            return false
        }
        tally.removed += 1
        return true
    }

    /// Removes `name` inside `directory`, provided it is still the object `expected` describes.
    @discardableResult
    static func remove(name: String, inDirectory directory: String, expected: Fingerprint, tally: inout Tally) -> Bool {
        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else {
            tally.failed += 1
            return false
        }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == expected.device, UInt64(info.st_ino) == expected.inode,
              (info.st_mode & S_IFMT) != S_IFLNK else {
            tally.failed += 1
            return false
        }
        return remove(Array(name.utf8CString), in: parent, device: info.st_dev, tally: &tally)
    }

    /// True when System Integrity Protection covers the entry.
    static func isRestricted(_ info: stat) -> Bool {
        info.st_flags & UInt32(SF_RESTRICTED) != 0
    }
}

/// Answers "is anything using this?" with libproc. Root sees every process;
/// an ordinary user sees only their own.
public enum OpenFiles {
    /// True when some process has a file open at or below `path`, or is working in it.
    ///
    /// The list of open files is read once and reused for a few seconds, so
    /// asking about every entry of a folder costs one pass over the processes.
    public static func isInUse(_ path: String) -> Bool {
        isInUse(path, among: recentOpenPaths())
    }

    static func isInUse(_ path: String, among openPaths: some Sequence<String>) -> Bool {
        guard let real = SafetyGuard.realpath(path) else { return false }
        let inside = real + "/"
        return openPaths.contains { $0 == real || $0.hasPrefix(inside) }
    }

    private struct Snapshot: Sendable {
        var taken: Date
        var paths: [String]
    }

    private static let snapshot = Locked<Snapshot?>(nil)

    private static func recentOpenPaths() -> [String] {
        if let current = snapshot.get(), Date().timeIntervalSince(current.taken) < 5 { return current.paths }
        let paths = Array(openPaths())
        snapshot.set(Snapshot(taken: Date(), paths: paths))
        return paths
    }

    /// Paths of the files, folders and working directories every visible process has open.
    static func openPaths() -> Set<String> {
        var result = Set<String>()
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return result }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return result }

        let descriptorSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids.prefix(count) where pid > 0 {
            var working = proc_vnodepathinfo()
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &working, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
                let path = withUnsafeBytes(of: &working.pvi_cdir.vip_path) { text($0) }
                if path.count > 1 { result.insert(path) }
            }

            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { continue }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / descriptorSize + 16)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * descriptorSize))
            guard used > 0 else { continue }
            for descriptor in descriptors.prefix(Int(used) / descriptorSize) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) > 0 else { continue }
                let path = withUnsafeBytes(of: &info.pvip.vip_path) { text($0) }
                if path.count > 1 { result.insert(path) }
            }
        }
        return result
    }

    private static func text(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// True when a running process was started from inside `directory`, such as an app bundle.
    public static func hasProcess(inside directory: String) -> Bool {
        let prefix = (SafetyGuard.realpath(directory) ?? directory) + "/"
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return false }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(count) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path.hasPrefix(prefix) { return true }
        }
        return false
    }
}
