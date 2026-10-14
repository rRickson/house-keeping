import AppKit
import Darwin
import Foundation

public struct RunningProcess: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var path: String
    public var bundleID: String?

    public init(pid: Int32, name: String, path: String = "", bundleID: String? = nil) {
        self.pid = pid
        self.name = name
        self.path = path
        self.bundleID = bundleID
    }

    /// True when `pattern` names this process: by executable name, bundle
    /// identifier, or the name of the .app bundle that contains it.
    public func matches(_ pattern: String) -> Bool {
        if name.caseInsensitiveCompare(pattern) == .orderedSame { return true }
        if let bundleID, bundleID.caseInsensitiveCompare(pattern) == .orderedSame { return true }
        return path.range(of: "/\(pattern).app/", options: .caseInsensitive) != nil
    }
}

public protocol ProcessListing: Sendable {
    func runningProcesses() -> [RunningProcess]
}

extension ProcessListing {
    /// The first pattern that matches a running process, if any.
    public func firstRunning(of patterns: [String]) -> String? {
        guard !patterns.isEmpty else { return nil }
        let processes = runningProcesses()
        return patterns.first { pattern in processes.contains { $0.matches(pattern) } }
    }
}

/// Lists processes with libproc, enriched with bundle identifiers from NSWorkspace.
public struct SystemProcessList: ProcessListing {
    public init() {}

    public func runningProcesses() -> [RunningProcess] {
        var bundleIDs: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { bundleIDs[app.processIdentifier] = id }
        }

        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }

        var result: [RunningProcess] = []
        result.reserveCapacity(count)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(count) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = (path as NSString).lastPathComponent
            result.append(RunningProcess(pid: pid, name: name, path: path, bundleID: bundleIDs[pid]))
        }
        return result
    }
}

/// A fixed process list for tests and fixture runs.
public struct StaticProcessList: ProcessListing {
    public var processes: [RunningProcess]
    public init(_ processes: [RunningProcess] = []) { self.processes = processes }
    public init(names: [String]) {
        self.processes = names.enumerated().map { RunningProcess(pid: Int32(1000 + $0.offset), name: $0.element) }
    }
    public func runningProcesses() -> [RunningProcess] { processes }
}
