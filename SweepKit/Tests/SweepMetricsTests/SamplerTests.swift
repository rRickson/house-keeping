import Foundation
import Testing
@testable import SweepMetrics

/// Waits until `condition` holds, checking every few milliseconds, for at most two seconds.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite @MainActor struct MetricsSamplerTests {
    @Test func doesNothingUntilSomebodyObserves() async throws {
        let source = ScriptedSource()
        let sampler = MetricsSampler(interval: .milliseconds(10), source: source)
        try await Task.sleep(for: .milliseconds(60))
        #expect(source.readCount == 0)
        #expect(!sampler.isSampling)
        #expect(sampler.latest == nil)
        #expect(sampler.activeDetail == nil)
    }

    @Test func samplesWhileObservedAndStopsWhenTheLastObserverLeaves() async throws {
        let source = ScriptedSource()
        let sampler = MetricsSampler(interval: .milliseconds(10), source: source)

        sampler.start(.system)
        #expect(sampler.isSampling)
        #expect(await eventually { sampler.history.values(.cpu).count >= 3 })
        // The scripted core is busy a quarter of the time, and the first sample has no rate yet.
        #expect(sampler.history.values(.cpu).first == 0)
        #expect(abs((sampler.latest?.cpu.usage ?? 0) - 0.25) < 1e-9)
        #expect(sampler.latest?.disk?.readBytesPerSecond == 1000)
        #expect(sampler.latest?.processes == nil)

        sampler.stop(.system)
        #expect(!sampler.isSampling)
        #expect(sampler.observerCount == 0)
        // A read that was already under way may still finish; after that the source stays untouched.
        try await Task.sleep(for: .milliseconds(60))
        let settled = source.readCount
        try await Task.sleep(for: .milliseconds(120))
        #expect(source.readCount == settled)
    }

    @Test func keepsSamplingUntilEveryObserverHasLeft() async throws {
        let source = ScriptedSource()
        let sampler = MetricsSampler(interval: .milliseconds(10), source: source)
        sampler.start(.system)
        sampler.start(.system)
        sampler.start(.glance)
        #expect(sampler.observerCount == 3)

        sampler.stop(.system)
        sampler.stop(.glance)
        #expect(sampler.isSampling)
        let before = source.readCount
        #expect(await eventually { source.readCount > before + 2 })

        sampler.stop(.system)
        #expect(!sampler.isSampling)
    }

    @Test func samplesAtTheHighestDetailAnyoneAskedFor() async throws {
        let source = ScriptedSource()
        let sampler = MetricsSampler(interval: .milliseconds(10), source: source)

        sampler.start(.glance)
        #expect(sampler.activeDetail == .glance)
        #expect(await eventually { sampler.latest != nil })
        #expect(sampler.latest?.disk == nil)

        sampler.start(.processes)
        #expect(sampler.activeDetail == .processes)
        #expect(await eventually { sampler.processes.first?.cpuPercent != nil })
        // Half a second of CPU per second of wall time.
        #expect(sampler.processes.first?.cpuPercent == 50)

        sampler.stop(.processes)
        #expect(sampler.activeDetail == .glance)
        let mark = source.details.count
        #expect(await eventually { source.details.count > mark + 2 })
        #expect(source.details.suffix(2).allSatisfy { $0 == .glance })

        sampler.stop(.glance)
        #expect(sampler.activeDetail == nil)
    }

    @Test func anUnmatchedStopIsIgnored() {
        let sampler = MetricsSampler(interval: .milliseconds(10), source: ScriptedSource())
        sampler.stop(.system)
        #expect(sampler.observerCount == 0)
        sampler.start(.glance)
        sampler.stop(.processes)     // nobody registered at this detail
        #expect(sampler.observerCount == 1)
        #expect(sampler.isSampling)
        sampler.stop(.glance)
        #expect(!sampler.isSampling)
    }

    @Test func restartingDoesNotStretchARateAcrossThePause() async throws {
        let source = ScriptedSource()
        let sampler = MetricsSampler(interval: .milliseconds(10), source: source)
        sampler.start(.system)
        #expect(await eventually { (sampler.latest?.interval ?? 0) > 0 })
        sampler.stop(.system)
        try await Task.sleep(for: .milliseconds(60))

        let seen = sampler.history.sampleCount
        sampler.start(.system)
        #expect(await eventually { sampler.history.sampleCount > seen })
        // The first sample after a restart starts from scratch: no interval, no rate.
        let firstAfterRestart = sampler.history.points(.diskRead).first { $0.index == seen }
        #expect(firstAfterRestart?.value == 0)
        sampler.stop(.system)
    }

    @Test func refreshTakesOneSampleOnDemand() async {
        let source = ScriptedSource()
        let sampler = MetricsSampler(interval: .seconds(3600), source: source)
        await sampler.refresh(.processes)
        #expect(source.readCount == 1)
        #expect(sampler.processes.map(\.name) == ["worker"])
        #expect(!sampler.isSampling)
    }

    @Test func aSamplerThatIsDroppedStopsItsLoop() async throws {
        let source = ScriptedSource()
        var sampler: MetricsSampler? = MetricsSampler(interval: .milliseconds(10), source: source)
        sampler?.start(.glance)
        #expect(await eventually { source.readCount > 1 })
        sampler = nil
        try await Task.sleep(for: .milliseconds(60))
        let settled = source.readCount
        try await Task.sleep(for: .milliseconds(120))
        #expect(source.readCount == settled)
    }

    @Test func theCollectorComputesRatesBetweenItsOwnCalls() async {
        let collector = MetricsCollector(source: ScriptedSource())
        let first = await collector.sample(detail: .system)
        let second = await collector.sample(detail: .system)
        #expect(first.interval == 0)
        #expect(first.disk?.readBytesPerSecond == 0)
        #expect(second.interval == 1)
        #expect(second.disk?.readBytesPerSecond == 1000)
        #expect(second.disk?.writeBytesPerSecond == 500)

        await collector.reset()
        let afterReset = await collector.sample(detail: .system)
        #expect(afterReset.interval == 0)
        #expect(afterReset.disk?.readBytesPerSecond == 0)
    }
}
