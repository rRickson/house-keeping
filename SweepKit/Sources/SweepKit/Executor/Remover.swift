import Darwin
import Foundation

/// The only place in SweepKit that removes files. Every caller must have
/// passed the path through `SafetyGuard` first; `GuardedRemover` does both.
enum Remover {
    /// Deletes a file or folder. Symbolic links inside a folder are unlinked, never followed.
    static func removePermanently(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            // Go's module cache and some package stores are read-only on purpose.
            guard makeWritable(path) else { throw error }
            try FileManager.default.removeItem(atPath: path)
        }
    }

    /// Adds owner write permission to every folder below `path`. Returns false when nothing changed.
    private static func makeWritable(_ path: String) -> Bool {
        var changed = false
        var pending = [path]
        while let directory = pending.popLast() {
            var info = stat()
            guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            if info.st_mode & S_IWUSR == 0 || info.st_mode & S_IXUSR == 0 || info.st_mode & S_IRUSR == 0 {
                if chmod(directory, info.st_mode | S_IRWXU) == 0 { changed = true }
            }
            _ = try? DirectoryReader.read(directory) { entry in
                if entry.kind == .directory { pending.append(directory + "/" + entry.name) }
            }
        }
        return changed
    }
}

/// What happened to one path.
public enum RemovalOutcome: Sendable, Equatable {
    case removed(bytes: Int64)
    case dryRun(bytes: Int64)
    case skipped(String)
    case refused(String)
    case failed(String, bytesFreed: Int64)
}

/// Guarded deletion shared by every tool: allowlist, deny list, symlink
/// resolution and the identity re-check all run here, right before the delete.
public struct GuardedRemover: Sendable {
    public let context: SweepContext
    public let safety: SafetyGuard
    public let sizer: Sizer

    public init(context: SweepContext, safety: SafetyGuard? = nil, sizer: Sizer = Sizer()) {
        self.context = context
        self.safety = safety ?? SafetyGuard(home: context.home)
        self.sizer = sizer
    }

    /// Removes `path` if, and only if, it is inside one of `allowedRoots` and passes every check.
    /// - Parameters:
    ///   - allowedRoots: real paths of the locations a rule or the user named.
    ///   - fingerprint: identity recorded at scan time; a mismatch skips the path.
    public func remove(
        _ path: String,
        allowedRoots: [String],
        scope: SafetyGuard.Scope,
        fingerprint: Fingerprint?,
        mode: DeleteMode,
        dryRun: Bool
    ) -> RemovalOutcome {
        guard FileManager.default.fileExists(atPath: path) || Fingerprint(path: path) != nil else {
            return .skipped("already gone")
        }
        let verdict = safety.evaluate(path, allowedRoots: allowedRoots, scope: scope)
        guard verdict.allowed else { return .refused(verdict.reason ?? "refused") }

        if let fingerprint, !safety.stillMatches(path, fingerprint: fingerprint) {
            return .skipped("changed since the scan")
        }
        guard let current = Fingerprint(path: path) else { return .skipped("already gone") }
        if current.owner != getuid(), !context.isFixture {
            return .skipped("owned by another user")
        }

        // Re-read the size right before acting; this is the number reported as freed.
        let url = URL(fileURLWithPath: path)
        let before = (try? sizer.size(of: url))?.bytes ?? 0
        if dryRun { return .dryRun(bytes: before) }

        do {
            switch mode {
            case .trash:
                try context.trash.trash(url)
            case .permanent:
                try Remover.removePermanently(path)
            }
            return .removed(bytes: before)
        } catch {
            let remaining = (try? sizer.size(of: url))?.bytes ?? 0
            let reason = Self.describe(error)
            return .failed(reason, bytesFreed: max(before - remaining, 0))
        }
    }

    static func describe(_ error: Error) -> String {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain {
            switch cocoa.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "permission denied"
            case NSFileNoSuchFileError: return "already gone"
            case NSFileWriteFileExistsError: return "a file with that name is already in the Trash"
            default: break
            }
        }
        if let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            switch Int32(underlying.code) {
            case EACCES, EPERM: return "permission denied"
            case EBUSY: return "in use"
            default: break
            }
        }
        return cocoa.localizedDescription
    }
}
