import Foundation

/// Tick counters of one logical core, as `host_processor_info` reports them.
/// They are 32-bit and wrap, so differences use wrapping arithmetic.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32 = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// A pair of ever-growing byte counters: read/written or received/sent.
public struct IOCounters: Sendable, Equatable {
    public var input: UInt64
    public var output: UInt64

    public init(input: UInt64, output: UInt64) {
        self.input = input
        self.output = output
    }
}

/// One process as the kernel reports it, before CPU time is turned into a percentage.
public struct RawProcess: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var ownerUID: UInt32
    public var ownerName: String?
    public var executablePath: String?
    public var bundlePath: String?
    public var startDate: Date?
    /// User + system CPU time since the process started, in nanoseconds. Nil when not readable.
    public var cpuTimeNanos: UInt64?
    public var residentBytes: Int64?
    public var footprintBytes: Int64?

    public init(
        pid: Int32,
        name: String,
        ownerUID: UInt32 = 0,
        ownerName: String? = nil,
        executablePath: String? = nil,
        bundlePath: String? = nil,
        startDate: Date? = nil,
        cpuTimeNanos: UInt64? = nil,
        residentBytes: Int64? = nil,
        footprintBytes: Int64? = nil
    ) {
        self.pid = pid
        self.name = name
        self.ownerUID = ownerUID
        self.ownerName = ownerName
        self.executablePath = executablePath
        self.bundlePath = bundlePath
        self.startDate = startDate
        self.cpuTimeNanos = cpuTimeNanos
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
    }
}

/// Everything read from the system in one pass: instantaneous values as they
/// are, and counters still raw. Two of these make one `MetricsSnapshot`.
public struct RawSample: Sendable {
    public var date: Date
    /// Seconds on a clock that never jumps; only differences matter.
    public var monotonic: TimeInterval
    public var cores: [CPUTicks]
    public var loadAverage: [Double]
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var memory: MemorySample
    public var gpu: GPUSample?
    public var disk: IOCounters?
    /// Byte counters per network interface.
    public var network: [String: IOCounters]?
    /// Width of the network counters. `getifaddrs` reports 32-bit counters that wrap every 4 GB.
    public var networkCounterBits: Int
    public var battery: BatterySample?
    public var thermal: ThermalLevel
    public var uptime: TimeInterval
    public var processes: [RawProcess]?

    public init(
        date: Date = Date(),
        monotonic: TimeInterval,
        cores: [CPUTicks],
        loadAverage: [Double] = [],
        performanceCores: Int? = nil,
        efficiencyCores: Int? = nil,
        memory: MemorySample,
        gpu: GPUSample? = nil,
        disk: IOCounters? = nil,
        network: [String: IOCounters]? = nil,
        networkCounterBits: Int = 32,
        battery: BatterySample? = nil,
        thermal: ThermalLevel = .nominal,
        uptime: TimeInterval = 0,
        processes: [RawProcess]? = nil
    ) {
        self.date = date
        self.monotonic = monotonic
        self.cores = cores
        self.loadAverage = loadAverage
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.memory = memory
        self.gpu = gpu
        self.disk = disk
        self.network = network
        self.networkCounterBits = networkCounterBits
        self.battery = battery
        self.thermal = thermal
        self.uptime = uptime
        self.processes = processes
    }
}

/// Where raw samples come from. The live source reads the kernel and IOKit; tests script one.
public protocol MetricsSource: Sendable {
    func read(detail: MetricsDetail) -> RawSample
}

/// The arithmetic that turns counter differences into rates and percentages.
public enum Rates {
    /// How far a counter moved between two reads. A counter of `bits` width
    /// that wrapped once is unwrapped; a counter that went backwards for any
    /// other reason (a driver or interface that reset) counts as no movement.
    public static func delta(previous: UInt64, current: UInt64, bits: Int = 64) -> UInt64 {
        if current >= previous { return current - previous }
        guard bits > 0, bits < 64 else { return 0 }
        let modulus = UInt64(1) << UInt64(bits)
        guard previous < modulus else { return 0 }
        return modulus - previous + current
    }

    /// Counter movement per second. Zero when no time passed.
    public static func perSecond(previous: UInt64, current: UInt64, elapsed: TimeInterval, bits: Int = 64) -> Double {
        guard elapsed > 0 else { return 0 }
        return Double(delta(previous: previous, current: current, bits: bits)) / elapsed
    }

    /// Busy, user and system shares of one core (or of several summed) between two tick readings, each 0 to 1.
    public static func cpuUsage(previous: CPUTicks, current: CPUTicks) -> (usage: Double, user: Double, system: Double) {
        cpuUsage(previous: [previous], current: [current])
    }

    /// The same shares over a set of cores taken together.
    public static func cpuUsage(previous: [CPUTicks], current: [CPUTicks]) -> (usage: Double, user: Double, system: Double) {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        for (before, after) in zip(previous, current) {
            user += UInt64(after.user &- before.user) + UInt64(after.nice &- before.nice)
            system += UInt64(after.system &- before.system)
            idle += UInt64(after.idle &- before.idle)
        }
        let total = user + system + idle
        guard total > 0 else { return (0, 0, 0) }
        let scale = 1 / Double(total)
        return (Double(user + system) * scale, Double(user) * scale, Double(system) * scale)
    }

    /// CPU time used over wall time elapsed, where 100 is one core fully busy.
    /// Zero when time did not move forward or the counter went backwards.
    public static func processCPUPercent(previousNanos: UInt64, currentNanos: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, currentNanos >= previousNanos else { return 0 }
        return Double(currentNanos - previousNanos) / (elapsed * 1_000_000_000) * 100
    }
}

extension MetricsSnapshot {
    /// Builds a snapshot from two raw reads. With no `previous` read every rate is zero.
    public init(previous: RawSample?, current: RawSample) {
        let elapsed = previous.map { max(0, current.monotonic - $0.monotonic) } ?? 0

        // CPU
        var perCore = [Double](repeating: 0, count: current.cores.count)
        var totals: (usage: Double, user: Double, system: Double) = (0, 0, 0)
        if let before = previous?.cores, before.count == current.cores.count {
            for index in current.cores.indices {
                perCore[index] = Rates.cpuUsage(previous: before[index], current: current.cores[index]).usage
            }
            totals = Rates.cpuUsage(previous: before, current: current.cores)
        }
        let cpu = CPUSample(
            usage: totals.usage,
            user: totals.user,
            system: totals.system,
            perCore: perCore,
            loadAverage: current.loadAverage,
            performanceCores: current.performanceCores,
            efficiencyCores: current.efficiencyCores
        )

        // Disk
        let disk = current.disk.map { now -> DiskSample in
            let before = previous?.disk
            return DiskSample(
                readBytesPerSecond: before.map { Rates.perSecond(previous: $0.input, current: now.input, elapsed: elapsed) } ?? 0,
                writeBytesPerSecond: before.map { Rates.perSecond(previous: $0.output, current: now.output, elapsed: elapsed) } ?? 0,
                totalRead: now.input,
                totalWritten: now.output
            )
        }

        // Network: per interface, so one wrapped or vanished interface cannot distort the sum.
        let network = current.network.map { now -> NetworkSample in
            var received: UInt64 = 0
            var sent: UInt64 = 0
            if let before = previous?.network {
                for (name, counters) in now {
                    guard let old = before[name] else { continue }
                    received += Rates.delta(previous: old.input, current: counters.input, bits: current.networkCounterBits)
                    sent += Rates.delta(previous: old.output, current: counters.output, bits: current.networkCounterBits)
                }
            }
            return NetworkSample(
                inBytesPerSecond: elapsed > 0 ? Double(received) / elapsed : 0,
                outBytesPerSecond: elapsed > 0 ? Double(sent) / elapsed : 0,
                interfaces: now.keys.sorted()
            )
        }

        // Processes
        let processes = current.processes.map { now -> [ProcessSample] in
            var earlier: [Int32: RawProcess] = [:]
            if let before = previous?.processes {
                earlier.reserveCapacity(before.count)
                for process in before { earlier[process.pid] = process }
            }
            return now.map { process in
                var percent: Double?
                // A pid that was reused by a new process has a different start date.
                if let cpuTime = process.cpuTimeNanos,
                   let old = earlier[process.pid], old.startDate == process.startDate,
                   let oldTime = old.cpuTimeNanos, elapsed > 0 {
                    percent = Rates.processCPUPercent(previousNanos: oldTime, currentNanos: cpuTime, elapsed: elapsed)
                }
                return ProcessSample(
                    pid: process.pid,
                    name: process.name,
                    cpuPercent: percent,
                    residentBytes: process.residentBytes,
                    footprintBytes: process.footprintBytes,
                    ownerUID: process.ownerUID,
                    ownerName: process.ownerName,
                    executablePath: process.executablePath,
                    bundlePath: process.bundlePath,
                    startDate: process.startDate
                )
            }
        }

        self.init(
            date: current.date,
            interval: elapsed,
            cpu: cpu,
            memory: current.memory,
            gpu: current.gpu,
            disk: disk,
            network: network,
            battery: current.battery,
            thermal: current.thermal,
            uptime: current.uptime,
            processes: processes
        )
    }
}
