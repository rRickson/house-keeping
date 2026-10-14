import Foundation
import Observation

/// Reads the system and turns pairs of raw reads into snapshots. An actor, so
/// the reads never run on the main thread and never overlap.
public actor MetricsCollector {
    private let source: any MetricsSource
    private var previous: RawSample?

    public init(source: any MetricsSource = LiveMetricsSource()) {
        self.source = source
    }

    /// Takes one sample. Rates cover the time since the previous call; the first call reports zero rates.
    public func sample(detail: MetricsDetail = .system) -> MetricsSnapshot {
        let raw = source.read(detail: detail)
        let snapshot = MetricsSnapshot(previous: previous, current: raw)
        previous = raw
        return snapshot
    }

    /// Forgets the previous read, so the next rates do not span a pause.
    public func reset() {
        previous = nil
    }

    /// Two reads `window` apart, for callers that want real rates from one call (the CLI).
    public func measure(detail: MetricsDetail = .system, over window: Duration = .milliseconds(500)) async -> MetricsSnapshot {
        _ = sample(detail: detail)
        try? await Task.sleep(for: window)
        return sample(detail: detail)
    }
}

/// The live feed behind the Status tool and the menu bar graph.
///
/// The sampler only works while somebody is watching. Each view calls
/// `start(_:)` when it appears and `stop(_:)` with the same detail when it
/// goes away; the sampler counts them, samples at the highest detail anyone
/// asked for, and stops the moment the last one leaves. Nothing runs in the
/// background otherwise.
///
/// The app owns one sampler (`MetricsSampler.shared` unless it wants its own)
/// and hands it to `StatusView` and `MiniMetricsGraph`, so both read the same
/// feed and the system is sampled once.
@MainActor
@Observable
public final class MetricsSampler {
    /// The sampler the views use when none is passed in.
    public static let shared = MetricsSampler()

    /// The newest sample, or nil before the first one arrives.
    public private(set) var latest: MetricsSnapshot?
    /// The last 60 seconds of every metric.
    public private(set) var history: MetricsHistory
    /// The newest process list. Kept apart from `latest` so it survives samples taken at a lower
    /// detail; it is as old as the last sample taken at `.processes` detail.
    public private(set) var processes: [ProcessSample] = []
    public private(set) var isSampling = false

    public let interval: Duration

    @ObservationIgnored private let collector: MetricsCollector
    @ObservationIgnored private var observers: [MetricsDetail: Int] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - interval: time between samples; one second by default.
    ///   - window: how much history to keep, in seconds.
    ///   - source: where raw samples come from; the real machine by default.
    public init(interval: Duration = .seconds(1), window: TimeInterval = 60, source: any MetricsSource = LiveMetricsSource()) {
        self.interval = interval
        self.collector = MetricsCollector(source: source)
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        self.history = MetricsHistory(window: window, interval: seconds)
    }

    /// The highest detail any observer asked for; nil when nobody is observing.
    public var activeDetail: MetricsDetail? {
        observers.filter { $0.value > 0 }.keys.max()
    }

    /// How many `start` calls are still waiting for their `stop`.
    public var observerCount: Int { observers.values.reduce(0, +) }

    /// Registers an observer and starts sampling if it is the first.
    public func start(_ detail: MetricsDetail = .system) {
        observers[detail, default: 0] += 1
        guard loop == nil else { return }
        isSampling = true
        loop = Task(priority: .utility) { [weak self, collector, interval] in
            await collector.reset()
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                guard let detail = self?.activeDetail else { return }
                let snapshot = await collector.sample(detail: detail)
                // `self` is only borrowed for the call, so a sleeping loop never keeps the sampler alive.
                guard !Task.isCancelled, self?.ingest(snapshot) != nil else { return }
                deadline = max(deadline + interval, clock.now)
                try? await clock.sleep(until: deadline, tolerance: interval / 10)
            }
        }
    }

    /// Removes an observer registered with the same detail. Sampling stops when the last one leaves.
    public func stop(_ detail: MetricsDetail = .system) {
        guard let count = observers[detail], count > 0 else { return }
        observers[detail] = count > 1 ? count - 1 : nil
        guard observerCount == 0 else { return }
        loop?.cancel()
        loop = nil
        isSampling = false
    }

    /// Takes one sample right now, whether or not the timer is running. Used for an on-demand refresh.
    public func refresh(_ detail: MetricsDetail = .processes) async {
        ingest(await collector.sample(detail: detail))
    }

    private func ingest(_ snapshot: MetricsSnapshot) {
        latest = snapshot
        history.append(snapshot)
        if let list = snapshot.processes { processes = list }
    }
}
