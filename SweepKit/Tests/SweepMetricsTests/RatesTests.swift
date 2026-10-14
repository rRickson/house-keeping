import Foundation
import Testing
@testable import SweepMetrics

@Suite struct RatesTests {
    @Test func deltaOfAGrowingCounter() {
        #expect(Rates.delta(previous: 100, current: 350) == 250)
        #expect(Rates.delta(previous: 7, current: 7) == 0)
    }

    @Test func thirtyTwoBitCounterThatWrappedIsUnwrapped() {
        let nearTop = UInt64(UInt32.max) - 9
        #expect(Rates.delta(previous: nearTop, current: 90, bits: 32) == 100)
    }

    @Test func counterThatResetCountsAsNoMovement() {
        // A 64-bit counter cannot plausibly wrap; going backwards means the driver started over.
        #expect(Rates.delta(previous: 5_000_000, current: 10) == 0)
        // A "32-bit" counter whose old value never fit in 32 bits was not a wrap either.
        #expect(Rates.delta(previous: 1 << 40, current: 10, bits: 32) == 0)
    }

    @Test func ratePerSecondDividesByElapsedTime() {
        #expect(Rates.perSecond(previous: 1000, current: 4000, elapsed: 2) == 1500)
        #expect(Rates.perSecond(previous: 1000, current: 4000, elapsed: 0.5) == 6000)
    }

    @Test func rateIsZeroWhenNoTimePassed() {
        #expect(Rates.perSecond(previous: 0, current: 4000, elapsed: 0) == 0)
        #expect(Rates.perSecond(previous: 0, current: 4000, elapsed: -1) == 0)
    }

    @Test func cpuUsageIsBusyTicksOverAllTicks() {
        let before = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let after = CPUTicks(user: 130, system: 60, idle: 860, nice: 0)
        let result = Rates.cpuUsage(previous: before, current: after)
        #expect(abs(result.usage - 0.4) < 1e-9)
        #expect(abs(result.user - 0.3) < 1e-9)
        #expect(abs(result.system - 0.1) < 1e-9)
    }

    @Test func nicedTimeCountsAsUserTime() {
        let before = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let after = CPUTicks(user: 10, system: 0, idle: 80, nice: 10)
        let result = Rates.cpuUsage(previous: before, current: after)
        #expect(abs(result.usage - 0.2) < 1e-9)
        #expect(abs(result.user - 0.2) < 1e-9)
    }

    @Test func cpuUsageWithNoTicksIsZeroNotNaN() {
        let ticks = CPUTicks(user: 5, system: 5, idle: 5)
        let result = Rates.cpuUsage(previous: ticks, current: ticks)
        #expect(result.usage == 0)
        #expect(result.user == 0)
        #expect(result.system == 0)
    }

    @Test func cpuTickCountersThatWrapStillGiveTheRightShare() {
        let before = CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 29)
        let after = CPUTicks(user: 10, system: 0, idle: 30)
        let result = Rates.cpuUsage(previous: before, current: after)
        #expect(abs(result.usage - 0.25) < 1e-9)
    }

    @Test func totalUsageWeighsEveryCoreByItsTicks() {
        let before = [CPUTicks(user: 0, system: 0, idle: 0), CPUTicks(user: 0, system: 0, idle: 0)]
        let after = [CPUTicks(user: 100, system: 0, idle: 0), CPUTicks(user: 0, system: 0, idle: 100)]
        #expect(abs(Rates.cpuUsage(previous: before, current: after).usage - 0.5) < 1e-9)
    }

    @Test func processPercentIsCPUTimeOverWallTime() {
        // Half a second of CPU in one second is 50 %.
        #expect(abs(Rates.processCPUPercent(previousNanos: 0, currentNanos: 500_000_000, elapsed: 1) - 50) < 1e-9)
        // Three seconds of CPU in one second: three cores busy.
        #expect(abs(Rates.processCPUPercent(previousNanos: 1_000_000_000, currentNanos: 4_000_000_000, elapsed: 1) - 300) < 1e-9)
        // The same CPU time over twice the wall time is half the percentage.
        #expect(abs(Rates.processCPUPercent(previousNanos: 0, currentNanos: 500_000_000, elapsed: 2) - 25) < 1e-9)
    }

    @Test func processPercentIsZeroWhenTheCounterWentBackwardsOrTimeStood() {
        #expect(Rates.processCPUPercent(previousNanos: 900, currentNanos: 100, elapsed: 1) == 0)
        #expect(Rates.processCPUPercent(previousNanos: 0, currentNanos: 100, elapsed: 0) == 0)
    }
}

@Suite struct SnapshotBuilderTests {
    @Test func firstSampleHasNoRates() {
        let first = raw(
            at: 10,
            cores: [CPUTicks(user: 500, system: 100, idle: 400)],
            disk: IOCounters(input: 9_000_000, output: 4_000_000),
            network: ["en0": IOCounters(input: 123_456, output: 654_321)],
            processes: [RawProcess(pid: 7, name: "a", cpuTimeNanos: 5_000_000_000)]
        )
        let snapshot = MetricsSnapshot(previous: nil, current: first)
        #expect(snapshot.interval == 0)
        #expect(snapshot.cpu.usage == 0)
        #expect(snapshot.cpu.perCore == [0])
        #expect(snapshot.disk?.readBytesPerSecond == 0)
        #expect(snapshot.disk?.totalRead == 9_000_000)
        #expect(snapshot.network?.inBytesPerSecond == 0)
        #expect(snapshot.processes?.first?.cpuPercent == nil)
    }

    @Test func ratesComeFromTheDifferenceBetweenTwoSamples() {
        let before = raw(
            at: 10,
            cores: [CPUTicks(user: 0, system: 0, idle: 0), CPUTicks(user: 0, system: 0, idle: 0)],
            disk: IOCounters(input: 1_000_000, output: 500_000),
            network: ["en0": IOCounters(input: 1000, output: 2000)]
        )
        let after = raw(
            at: 12,
            cores: [CPUTicks(user: 150, system: 50, idle: 0), CPUTicks(user: 0, system: 0, idle: 200)],
            disk: IOCounters(input: 5_000_000, output: 1_500_000),
            network: ["en0": IOCounters(input: 21_000, output: 4000)]
        )
        let snapshot = MetricsSnapshot(previous: before, current: after)
        #expect(snapshot.interval == 2)
        #expect(snapshot.cpu.perCore == [1, 0])
        #expect(abs(snapshot.cpu.usage - 0.5) < 1e-9)
        #expect(abs(snapshot.cpu.user - 0.375) < 1e-9)
        #expect(abs(snapshot.cpu.system - 0.125) < 1e-9)
        #expect(snapshot.disk?.readBytesPerSecond == 2_000_000)
        #expect(snapshot.disk?.writeBytesPerSecond == 500_000)
        #expect(snapshot.network?.inBytesPerSecond == 10_000)
        #expect(snapshot.network?.outBytesPerSecond == 1000)
    }

    @Test func networkIsSummedPerInterfaceSoAWrapOrANewInterfaceCannotDistortIt() {
        let top = UInt64(UInt32.max)
        let before = raw(at: 0, network: [
            "en0": IOCounters(input: top - 499, output: 100),
            "en1": IOCounters(input: 10, output: 10),
        ])
        let after = raw(at: 1, network: [
            "en0": IOCounters(input: 500, output: 300),       // wrapped: 1000 bytes in
            "en5": IOCounters(input: 9_999_999, output: 9_999_999), // just appeared: no history, not counted
        ])
        let snapshot = MetricsSnapshot(previous: before, current: after)
        #expect(snapshot.network?.inBytesPerSecond == 1000)
        #expect(snapshot.network?.outBytesPerSecond == 200)
        #expect(snapshot.network?.interfaces == ["en0", "en5"])
    }

    @Test func aChangedCoreCountGivesZerosInsteadOfMismatchedCores() {
        let before = raw(at: 0, cores: [CPUTicks(user: 0, system: 0, idle: 0)])
        let after = raw(at: 1, cores: [CPUTicks(user: 10, system: 0, idle: 0), CPUTicks(user: 10, system: 0, idle: 0)])
        let snapshot = MetricsSnapshot(previous: before, current: after)
        #expect(snapshot.cpu.perCore == [0, 0])
        #expect(snapshot.cpu.usage == 0)
    }

    @Test func processPercentUsesTheDeltaOfCPUTime() {
        let started = Date(timeIntervalSince1970: 500)
        let before = raw(at: 0, processes: [
            RawProcess(pid: 10, name: "busy", startDate: started, cpuTimeNanos: 1_000_000_000, residentBytes: 100),
            RawProcess(pid: 11, name: "idle", startDate: started, cpuTimeNanos: 2_000_000_000, residentBytes: 200),
            RawProcess(pid: 12, name: "root-owned", startDate: started),
        ])
        let after = raw(at: 2, processes: [
            RawProcess(pid: 10, name: "busy", startDate: started, cpuTimeNanos: 4_000_000_000, residentBytes: 150),
            RawProcess(pid: 11, name: "idle", startDate: started, cpuTimeNanos: 2_000_000_000, residentBytes: 200),
            RawProcess(pid: 12, name: "root-owned", startDate: started),
            RawProcess(pid: 13, name: "new", startDate: started, cpuTimeNanos: 9_000_000_000),
        ])
        let processes = MetricsSnapshot(previous: before, current: after).processes ?? []
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        #expect(byPID[10]?.cpuPercent == 150)
        #expect(byPID[10]?.residentBytes == 150)
        #expect(byPID[11]?.cpuPercent == 0)
        #expect(byPID[12]?.cpuPercent == nil)   // counters not readable
        #expect(byPID[12]?.residentBytes == nil)
        #expect(byPID[13]?.cpuPercent == nil)   // seen once: nothing to compare with yet
    }

    @Test func aReusedPIDIsNotComparedWithTheProcessThatHadItBefore() {
        let before = raw(at: 0, processes: [
            RawProcess(pid: 10, name: "old", startDate: Date(timeIntervalSince1970: 100), cpuTimeNanos: 50_000_000_000),
        ])
        let after = raw(at: 1, processes: [
            RawProcess(pid: 10, name: "new", startDate: Date(timeIntervalSince1970: 900), cpuTimeNanos: 60_000_000_000),
        ])
        #expect(MetricsSnapshot(previous: before, current: after).processes?.first?.cpuPercent == nil)
    }

    @Test func snapshotSurvivesAJSONRoundTrip() throws {
        let original = MetricsSnapshot(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            interval: 1,
            cpu: CPUSample(usage: 0.25, user: 0.2, system: 0.05, perCore: [0.5, 0], loadAverage: [1, 2, 3], performanceCores: 1, efficiencyCores: 1),
            memory: MemorySample(total: 16, used: 8, pressure: .warning, pressureFraction: 0.4, swapUsed: 2, swapTotal: 4),
            gpu: GPUSample(utilization: 0.1, name: "Test GPU"),
            disk: DiskSample(readBytesPerSecond: 1, writeBytesPerSecond: 2, totalRead: 3, totalWritten: 4),
            network: NetworkSample(inBytesPerSecond: 5, outBytesPerSecond: 6, interfaces: ["en0"]),
            battery: BatterySample(charge: 0.8, health: 0.9, cycleCount: 100, isCharging: true, isPluggedIn: true),
            thermal: .fair,
            uptime: 3600,
            processes: [ProcessSample(pid: 1, name: "launchd", cpuPercent: 0.5, residentBytes: 10, ownerUID: 0, ownerName: "root")]
        )
        let decoded = try JSONDecoder().decode(MetricsSnapshot.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func detailLevelsAreOrdered() {
        #expect(MetricsDetail.glance < .system)
        #expect(MetricsDetail.system < .processes)
        #expect([MetricsDetail.system, .glance, .processes].max() == .processes)
    }
}
