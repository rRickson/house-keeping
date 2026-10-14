import Foundation
@testable import SweepMetrics

func memory(total: Int64 = 16_000_000_000, used: Int64 = 8_000_000_000) -> MemorySample {
    MemorySample(total: total, used: used)
}

/// A raw sample with nothing going on, `at` seconds on the monotonic clock.
func raw(
    at seconds: TimeInterval,
    cores: [CPUTicks] = [CPUTicks(user: 0, system: 0, idle: 0)],
    disk: IOCounters? = nil,
    network: [String: IOCounters]? = nil,
    processes: [RawProcess]? = nil
) -> RawSample {
    RawSample(
        date: Date(timeIntervalSince1970: 1_000_000 + seconds),
        monotonic: seconds,
        cores: cores,
        memory: memory(),
        disk: disk,
        network: network,
        processes: processes
    )
}

func snapshot(at seconds: TimeInterval, cpu: Double = 0, perCore: [Double] = [0], gpu: Double? = nil, disk: DiskSample? = nil) -> MetricsSnapshot {
    MetricsSnapshot(
        date: Date(timeIntervalSince1970: 1_000_000 + seconds),
        interval: 1,
        cpu: CPUSample(usage: cpu, perCore: perCore, loadAverage: [1.5, 1, 1]),
        memory: memory(),
        gpu: gpu.map { GPUSample(utilization: $0) },
        disk: disk
    )
}

/// A source that plays back a script: each read returns the next sample, one second after the last.
final class ScriptedSource: MetricsSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var requested: [MetricsDetail] = []

    var readCount: Int { lock.withLock { reads } }
    var details: [MetricsDetail] { lock.withLock { requested } }

    func read(detail: MetricsDetail) -> RawSample {
        let index: Int = lock.withLock {
            reads += 1
            requested.append(detail)
            return reads
        }
        // Core 0 is busy a quarter of the time: 25 busy ticks and 75 idle ticks per read.
        let ticks = UInt32(index)
        return RawSample(
            date: Date(timeIntervalSince1970: 1_000_000 + Double(index)),
            monotonic: Double(index),
            cores: [CPUTicks(user: 20 * ticks, system: 5 * ticks, idle: 75 * ticks)],
            memory: memory(),
            disk: detail >= .system ? IOCounters(input: UInt64(index) * 1000, output: UInt64(index) * 500) : nil,
            processes: detail >= .processes
                ? [RawProcess(pid: 42, name: "worker", ownerUID: 501, cpuTimeNanos: UInt64(index) * 500_000_000, residentBytes: 1000)]
                : nil
        )
    }
}

/// A process controller that records what it was asked to do and touches nothing.
final class FakeProcessControl: ProcessControlling, @unchecked Sendable {
    enum Call: Equatable {
        case terminate(pid: Int32, force: Bool)
        case signal(Int32, pid: Int32)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var identities: [Int32: ProcessIdentity] = [:]
    var apps: Set<Int32> = []
    var signalResult: Int32 = 0

    var calls: [Call] { lock.withLock { recorded } }

    func identity(of pid: Int32) -> ProcessIdentity? { identities[pid] }

    func terminateApplication(pid: Int32, force: Bool) -> Bool {
        guard apps.contains(pid) else { return false }
        lock.withLock { recorded.append(.terminate(pid: pid, force: force)) }
        return true
    }

    func send(signal: Int32, to pid: Int32) -> Int32 {
        lock.withLock { recorded.append(.signal(signal, pid: pid)) }
        return signalResult
    }
}
