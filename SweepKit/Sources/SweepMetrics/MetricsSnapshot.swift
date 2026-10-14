import Foundation

/// One sample of everything the Status tool shows.
///
/// Fractions run from 0 to 1. Rates are per second and are computed from the
/// difference between this sample and the one before it, so the first sample
/// after sampling starts reports zero rates and `interval == 0`.
public struct MetricsSnapshot: Codable, Sendable, Equatable {
    public var date: Date
    /// Seconds between this sample and the previous one; 0 for the first sample.
    public var interval: TimeInterval
    public var cpu: CPUSample
    public var memory: MemorySample
    /// Nil when no accelerator reports utilisation, or when sampled at `.glance` detail.
    public var gpu: GPUSample?
    /// Nil when sampled at `.glance` detail.
    public var disk: DiskSample?
    /// Nil when sampled at `.glance` detail.
    public var network: NetworkSample?
    /// Nil on Macs without a battery, or when sampled at `.glance` detail.
    public var battery: BatterySample?
    public var thermal: ThermalLevel
    /// Seconds since the Mac started, including time asleep.
    public var uptime: TimeInterval
    /// Nil unless sampled at `.processes` detail.
    public var processes: [ProcessSample]?

    public init(
        date: Date,
        interval: TimeInterval,
        cpu: CPUSample,
        memory: MemorySample,
        gpu: GPUSample? = nil,
        disk: DiskSample? = nil,
        network: NetworkSample? = nil,
        battery: BatterySample? = nil,
        thermal: ThermalLevel = .nominal,
        uptime: TimeInterval = 0,
        processes: [ProcessSample]? = nil
    ) {
        self.date = date
        self.interval = interval
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.disk = disk
        self.network = network
        self.battery = battery
        self.thermal = thermal
        self.uptime = uptime
        self.processes = processes
    }
}

public struct CPUSample: Codable, Sendable, Equatable {
    /// Busy share of all cores together, 0 to 1.
    public var usage: Double
    /// Share spent in user code (including niced), 0 to 1.
    public var user: Double
    /// Share spent in the kernel, 0 to 1.
    public var system: Double
    /// Busy share of each logical core, 0 to 1, in the kernel's core order.
    public var perCore: [Double]
    /// Load averages over 1, 5 and 15 minutes.
    public var loadAverage: [Double]
    /// Performance and efficiency core counts on Apple silicon; nil elsewhere.
    public var performanceCores: Int?
    public var efficiencyCores: Int?

    public var coreCount: Int { perCore.count }

    public init(
        usage: Double,
        user: Double = 0,
        system: Double = 0,
        perCore: [Double],
        loadAverage: [Double] = [],
        performanceCores: Int? = nil,
        efficiencyCores: Int? = nil
    ) {
        self.usage = usage
        self.user = user
        self.system = system
        self.perCore = perCore
        self.loadAverage = loadAverage
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
    }
}

public enum MemoryPressure: String, Codable, Sendable, CaseIterable {
    case normal, warning, critical

    /// Maps `kern.memorystatus_vm_pressure_level` (1, 2, 4).
    public init(kernelLevel: Int32) {
        switch kernelLevel {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }
}

public struct MemorySample: Codable, Sendable, Equatable {
    /// Installed memory in bytes.
    public var total: Int64
    /// App + wired + compressed, which is what Activity Monitor calls "Memory Used".
    public var used: Int64
    public var app: Int64
    public var wired: Int64
    public var compressed: Int64
    /// File cache and purgeable memory the system can take back at once.
    public var cached: Int64
    public var free: Int64
    public var pressure: MemoryPressure
    /// How hard the system is working to find memory, 0 to 1 (1 minus the kernel's free level).
    public var pressureFraction: Double
    public var swapUsed: Int64
    public var swapTotal: Int64

    public var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }

    public init(
        total: Int64,
        used: Int64,
        app: Int64 = 0,
        wired: Int64 = 0,
        compressed: Int64 = 0,
        cached: Int64 = 0,
        free: Int64 = 0,
        pressure: MemoryPressure = .normal,
        pressureFraction: Double = 0,
        swapUsed: Int64 = 0,
        swapTotal: Int64 = 0
    ) {
        self.total = total
        self.used = used
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
        self.pressure = pressure
        self.pressureFraction = pressureFraction
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
    }
}

public struct GPUSample: Codable, Sendable, Equatable {
    /// Busiest accelerator's utilisation, 0 to 1.
    public var utilization: Double
    /// For example "Apple M4 Max".
    public var name: String?

    public init(utilization: Double, name: String? = nil) {
        self.utilization = utilization
        self.name = name
    }
}

public struct DiskSample: Codable, Sendable, Equatable {
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    /// Bytes read and written by all block storage drivers since boot.
    public var totalRead: UInt64
    public var totalWritten: UInt64

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double, totalRead: UInt64 = 0, totalWritten: UInt64 = 0) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.totalRead = totalRead
        self.totalWritten = totalWritten
    }
}

public struct NetworkSample: Codable, Sendable, Equatable {
    public var inBytesPerSecond: Double
    public var outBytesPerSecond: Double
    /// Interfaces that carried the counted traffic, sorted by name.
    public var interfaces: [String]

    public init(inBytesPerSecond: Double, outBytesPerSecond: Double, interfaces: [String] = []) {
        self.inBytesPerSecond = inBytesPerSecond
        self.outBytesPerSecond = outBytesPerSecond
        self.interfaces = interfaces
    }
}

public struct BatterySample: Codable, Sendable, Equatable {
    /// Charge, 0 to 1.
    public var charge: Double
    /// Full-charge capacity against design capacity, 0 to 1. Nil when the battery does not report it.
    public var health: Double?
    public var cycleCount: Int?
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFull: Bool
    /// Minutes until empty (on battery) or full (charging); nil while the system is still estimating.
    public var minutesRemaining: Int?

    public init(
        charge: Double,
        health: Double? = nil,
        cycleCount: Int? = nil,
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        isFull: Bool = false,
        minutesRemaining: Int? = nil
    ) {
        self.charge = charge
        self.health = health
        self.cycleCount = cycleCount
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isFull = isFull
        self.minutesRemaining = minutesRemaining
    }
}

/// `ProcessInfo.ThermalState` as a codable value.
public enum ThermalLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    /// 0 (nominal) to 3 (critical).
    public var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }
}

public struct ProcessSample: Codable, Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var name: String
    /// CPU use since the previous sample in Activity Monitor's unit: 100 is one
    /// core fully busy, so a process on several cores can exceed 100. Nil when
    /// the process belongs to another user (its counters are not readable
    /// without root) or has only been seen once.
    public var cpuPercent: Double?
    /// Resident memory in bytes; nil when not readable.
    public var residentBytes: Int64?
    /// Physical footprint in bytes (Activity Monitor's "Memory"); nil when not readable.
    public var footprintBytes: Int64?
    public var ownerUID: UInt32
    public var ownerName: String?
    public var executablePath: String?
    /// The innermost `.app` bundle that contains the executable, if any.
    public var bundlePath: String?
    public var startDate: Date?

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        name: String,
        cpuPercent: Double? = nil,
        residentBytes: Int64? = nil,
        footprintBytes: Int64? = nil,
        ownerUID: UInt32 = 0,
        ownerName: String? = nil,
        executablePath: String? = nil,
        bundlePath: String? = nil,
        startDate: Date? = nil
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.ownerUID = ownerUID
        self.ownerName = ownerName
        self.executablePath = executablePath
        self.bundlePath = bundlePath
        self.startDate = startDate
    }
}

/// How much one sampling pass collects. Higher levels include the lower ones.
public enum MetricsDetail: Int, Sendable, Comparable, CaseIterable, Codable {
    /// CPU, memory, thermal state and uptime: two Mach calls, cheap enough for a menu bar graph.
    case glance
    /// Everything in `glance` plus GPU, disk I/O, network and battery.
    case system
    /// Everything in `system` plus the process list.
    case processes

    public static func < (lhs: MetricsDetail, rhs: MetricsDetail) -> Bool { lhs.rawValue < rhs.rawValue }
}
