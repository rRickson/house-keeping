import Foundation

/// A fixed-size buffer that keeps the newest `capacity` elements.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0
    /// How many elements were ever appended, including the ones that have been overwritten.
    public private(set) var totalAppended = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var isFull: Bool { storage.count == capacity }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
        totalAppended += 1
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Oldest first.
    public var elements: [Element] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    public var first: Element? { storage.isEmpty ? nil : storage[storage.count == capacity ? head : 0] }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[storage.count == capacity ? (head + capacity - 1) % capacity : storage.count - 1]
    }
}

extension RingBuffer: Equatable where Element: Equatable {
    public static func == (lhs: RingBuffer, rhs: RingBuffer) -> Bool {
        lhs.capacity == rhs.capacity && lhs.elements == rhs.elements
    }
}

/// One value on a sparkline. `index` is the number of the sample it came from, so
/// a point keeps its identity while the window slides past it.
public struct MetricPoint: Sendable, Equatable, Identifiable {
    public var index: Int
    public var value: Double
    public var id: Int { index }

    public init(index: Int, value: Double) {
        self.index = index
        self.value = value
    }
}

/// The metrics that keep a history.
public enum MetricSeries: String, Sendable, CaseIterable {
    /// Fractions, 0 to 1.
    case cpu, memory, memoryPressure, gpu, battery
    /// Bytes.
    case swap
    /// Bytes per second.
    case diskRead, diskWrite, networkIn, networkOut
    /// 0 (nominal) to 3 (critical).
    case thermal
    /// One-minute load average.
    case load
}

/// The last minute of every metric, for sparklines.
///
/// Every series shares one sample numbering, so a metric that was not
/// collected in some sample (GPU on a Mac that reports none, disk at `.glance`
/// detail) leaves a gap instead of shifting its line.
public struct MetricsHistory: Sendable, Equatable {
    /// Samples kept per metric: the window divided by the sampling interval.
    public let capacity: Int
    /// A pause longer than this many seconds between two samples starts the history over.
    public let gapThreshold: TimeInterval
    /// Samples appended so far. The next sample gets this index.
    public private(set) var sampleCount = 0
    public private(set) var lastDate: Date?

    private var series: [MetricSeries: RingBuffer<MetricPoint>] = [:]
    private var cores: [RingBuffer<MetricPoint>] = []

    /// - Parameters:
    ///   - window: how much time to keep, 60 seconds by default.
    ///   - interval: seconds between samples.
    public init(window: TimeInterval = 60, interval: TimeInterval = 1) {
        let step = max(interval, 0.05)
        capacity = max(2, Int((window / step).rounded()))
        gapThreshold = max(5, step * 3)
    }

    public init(capacity: Int, gapThreshold: TimeInterval = 5) {
        self.capacity = max(2, capacity)
        self.gapThreshold = gapThreshold
    }

    /// Sample indices the window covers; the x-domain of every sparkline.
    public var indexRange: ClosedRange<Int> {
        let upper = max(sampleCount - 1, capacity - 1)
        return (upper - capacity + 1)...upper
    }

    public var isEmpty: Bool { sampleCount == 0 || series.values.allSatisfy(\.isEmpty) }

    public mutating func append(_ snapshot: MetricsSnapshot) {
        if let lastDate, abs(snapshot.date.timeIntervalSince(lastDate)) > gapThreshold {
            removeAll()
        }
        lastDate = snapshot.date
        let index = sampleCount
        sampleCount += 1

        record(.cpu, snapshot.cpu.usage, at: index)
        record(.memory, snapshot.memory.usedFraction, at: index)
        record(.memoryPressure, snapshot.memory.pressureFraction, at: index)
        record(.swap, Double(snapshot.memory.swapUsed), at: index)
        record(.thermal, Double(snapshot.thermal.rank), at: index)
        if let load = snapshot.cpu.loadAverage.first { record(.load, load, at: index) }
        if let gpu = snapshot.gpu { record(.gpu, gpu.utilization, at: index) }
        if let disk = snapshot.disk {
            record(.diskRead, disk.readBytesPerSecond, at: index)
            record(.diskWrite, disk.writeBytesPerSecond, at: index)
        }
        if let network = snapshot.network {
            record(.networkIn, network.inBytesPerSecond, at: index)
            record(.networkOut, network.outBytesPerSecond, at: index)
        }
        if let battery = snapshot.battery { record(.battery, battery.charge, at: index) }

        if cores.count != snapshot.cpu.perCore.count {
            cores = Array(repeating: RingBuffer(capacity: capacity), count: snapshot.cpu.perCore.count)
        }
        for (core, usage) in snapshot.cpu.perCore.enumerated() {
            cores[core].append(MetricPoint(index: index, value: usage))
        }
    }

    /// Forgets every value. Sample numbering continues, so new points never reuse an old identity.
    public mutating func removeAll() {
        series.removeAll(keepingCapacity: true)
        cores.removeAll(keepingCapacity: true)
        lastDate = nil
    }

    /// The points of one metric that fall inside the window, oldest first.
    public func points(_ metric: MetricSeries) -> [MetricPoint] {
        guard let buffer = series[metric] else { return [] }
        return visible(buffer)
    }

    public func values(_ metric: MetricSeries) -> [Double] { points(metric).map(\.value) }

    public func latest(_ metric: MetricSeries) -> Double? { series[metric]?.last?.value }

    /// The largest value of the given metrics inside the window.
    public func peak(_ metrics: MetricSeries...) -> Double {
        metrics.reduce(0) { best, metric in max(best, points(metric).map(\.value).max() ?? 0) }
    }

    public var coreCount: Int { cores.count }

    /// The points of one core, oldest first.
    public func corePoints(_ core: Int) -> [MetricPoint] {
        guard cores.indices.contains(core) else { return [] }
        return visible(cores[core])
    }

    private mutating func record(_ metric: MetricSeries, _ value: Double, at index: Int) {
        guard value.isFinite else { return }
        var buffer = series[metric] ?? RingBuffer(capacity: capacity)
        buffer.append(MetricPoint(index: index, value: value))
        series[metric] = buffer
    }

    private func visible(_ buffer: RingBuffer<MetricPoint>) -> [MetricPoint] {
        let lowest = indexRange.lowerBound
        let all = buffer.elements
        guard let first = all.first, first.index < lowest else { return all }
        return all.filter { $0.index >= lowest }
    }
}
