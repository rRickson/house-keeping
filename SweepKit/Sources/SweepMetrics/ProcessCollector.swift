import Darwin
import Foundation
import SweepKit

/// Naming rules for processes, kept apart from the kernel calls so they can be tested.
public enum ProcessNaming {
    /// The innermost `.app` bundle that contains an executable:
    /// `/Applications/Safari.app/Contents/MacOS/Safari` → `/Applications/Safari.app`.
    /// Nil for executables outside any bundle.
    public static func bundlePath(forExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// The name shown for a process: the executable's file name, or the
    /// kernel's short command name when the path is not readable.
    public static func displayName(executablePath: String?, command: String, pid: Int32) -> String {
        if let executablePath, !executablePath.isEmpty {
            let name = (executablePath as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        if !command.isEmpty { return command }
        return pid == 0 ? "kernel_task" : "pid \(pid)"
    }
}

/// What stays the same for the life of a process, so it is read once.
struct ProcessIdentityCache: Sendable {
    struct Entry: Sendable {
        var startSeconds: Int
        var startMicros: Int32
        var name: String
        var executablePath: String?
        var bundlePath: String?
    }

    var entries: [Int32: Entry] = [:]
    var userNames: [UInt32: String] = [:]
}

enum ProcessCollector {
    /// Every process on the system. CPU time and memory are filled in for the
    /// processes the current user may inspect, which without root means their own.
    static func list(cache: Locked<ProcessIdentityCache>) -> [RawProcess] {
        let table = processTable()
        guard !table.isEmpty else { return [] }

        var known = cache.get()
        var next: [Int32: ProcessIdentityCache.Entry] = [:]
        next.reserveCapacity(table.count)
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let timebase = Kernel.timebase

        var result: [RawProcess] = []
        result.reserveCapacity(table.count)
        for info in table {
            let pid = info.kp_proc.p_pid
            guard pid >= 0 else { continue }
            let uid = info.kp_eproc.e_ucred.cr_uid
            let start = info.kp_proc.p_un.__p_starttime

            let identity: ProcessIdentityCache.Entry
            if let cached = known.entries[pid], cached.startSeconds == start.tv_sec, cached.startMicros == start.tv_usec {
                identity = cached
            } else {
                let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
                let path = length > 0
                    ? String(decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    : nil
                identity = ProcessIdentityCache.Entry(
                    startSeconds: start.tv_sec,
                    startMicros: start.tv_usec,
                    name: ProcessNaming.displayName(executablePath: path, command: command(of: info), pid: pid),
                    executablePath: path,
                    bundlePath: path.flatMap(ProcessNaming.bundlePath(forExecutable:))
                )
            }
            next[pid] = identity

            let ownerName: String?
            if let cached = known.userNames[uid] {
                ownerName = cached
            } else {
                ownerName = userName(uid)
                if let ownerName { known.userNames[uid] = ownerName }
            }

            var process = RawProcess(
                pid: pid,
                name: identity.name,
                ownerUID: uid,
                ownerName: ownerName,
                executablePath: identity.executablePath,
                bundlePath: identity.bundlePath,
                startDate: start.tv_sec > 0
                    ? Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
                    : nil
            )
            if let usage = resourceUsage(pid) {
                let ticks = usage.ri_user_time &+ usage.ri_system_time
                process.cpuTimeNanos = ticks.multipliedReportingOverflow(by: timebase.numer).overflow
                    ? ticks / timebase.denom * timebase.numer
                    : ticks * timebase.numer / timebase.denom
                process.residentBytes = Int64(clamping: usage.ri_resident_size)
                process.footprintBytes = Int64(clamping: usage.ri_phys_footprint)
            }
            result.append(process)
        }

        known.entries = next
        cache.set(known)
        return result
    }

    /// The kernel's process table in one call.
    private static func processTable() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes that start between the two calls.
        let capacity = size / stride + 32
        return [kinfo_proc](unsafeUninitializedCapacity: capacity) { buffer, count in
            var length = capacity * stride
            if sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &length, nil, 0) == 0 {
                count = min(capacity, length / stride)
            } else {
                count = 0
            }
        }
    }

    private static func command(of info: kinfo_proc) -> String {
        withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func resourceUsage(_ pid: Int32) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage : nil
    }

    private static func userName(_ uid: UInt32) -> String? {
        var entry = passwd()
        var found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        guard getpwuid_r(uid, &entry, &buffer, buffer.count, &found) == 0, found != nil, let name = entry.pw_name else { return nil }
        return String(cString: name)
    }

    /// Owner and start date of one live process; nil when it no longer exists.
    static func identity(of pid: Int32) -> ProcessIdentity? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(
            ownerUID: info.kp_eproc.e_ucred.cr_uid,
            startDate: start.tv_sec > 0
                ? Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
                : nil
        )
    }
}

/// Reads the real machine.
public struct LiveMetricsSource: MetricsSource {
    private let cache = Locked(ProcessIdentityCache())

    public init() {}

    public func read(detail: MetricsDetail) -> RawSample {
        let kinds = CPUCollector.coreKinds
        var sample = RawSample(
            date: Date(),
            monotonic: Kernel.monotonicSeconds(),
            cores: CPUCollector.ticks(),
            loadAverage: CPUCollector.loadAverage(),
            performanceCores: kinds.performance,
            efficiencyCores: kinds.efficiency,
            memory: MemoryCollector.sample(),
            networkCounterBits: NetworkCollector.counterBits,
            thermal: SystemCollector.thermal(),
            uptime: SystemCollector.uptime()
        )
        if detail >= .system {
            sample.gpu = GPUCollector.sample()
            sample.disk = DiskCollector.counters()
            sample.network = NetworkCollector.counters()
            sample.battery = BatteryCollector.sample()
        }
        if detail >= .processes {
            sample.processes = ProcessCollector.list(cache: cache)
        }
        return sample
    }
}
