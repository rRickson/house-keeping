import Darwin
import Foundation
import Testing
@testable import SweepMetrics

@Suite struct BatteryParsingTests {
    @Test func appleSiliconKeepsCapacitiesInsideBatteryData() throws {
        // The layout this was written against: percent at the top level, mAh nested.
        let battery = try #require(BatterySample(registry: [
            "BatteryInstalled": true,
            "CurrentCapacity": 82,
            "MaxCapacity": 100,
            "CycleCount": 136,
            "IsCharging": false,
            "ExternalConnected": true,
            "FullyCharged": false,
            "TimeRemaining": 65535,
            "BatteryData": ["FullChargeCapacity": 8342, "NominalChargeCapacity": 8586, "DesignCapacity": 8579],
        ]))
        #expect(battery.charge == 0.82)
        #expect(abs((battery.health ?? 0) - 8342.0 / 8579.0) < 1e-9)
        #expect(battery.cycleCount == 136)
        #expect(!battery.isCharging)
        #expect(battery.isPluggedIn)
        #expect(battery.minutesRemaining == nil)   // 65535: still estimating
    }

    @Test func olderSystemsKeepRawCapacitiesAtTheTopLevel() throws {
        let battery = try #require(BatterySample(registry: [
            "CurrentCapacity": 50,
            "MaxCapacity": 100,
            "AppleRawMaxCapacity": 4000,
            "DesignCapacity": 5000,
            "CycleCount": 400,
            "IsCharging": true,
            "ExternalConnected": true,
            "TimeRemaining": 95,
        ]))
        #expect(battery.charge == 0.5)
        #expect(battery.health == 0.8)
        #expect(battery.isCharging)
        #expect(battery.minutesRemaining == 95)
    }

    @Test func intelReportsMilliampHoursAndStillGivesAFraction() throws {
        let battery = try #require(BatterySample(registry: [
            "CurrentCapacity": 3000,
            "MaxCapacity": 6000,
            "DesignCapacity": 7500,
        ]))
        #expect(battery.charge == 0.5)
        #expect(battery.health == 0.8)
        #expect(battery.cycleCount == nil)
    }

    @Test func healthNeverExceedsOneHundredPercentAndChargeIsClamped() throws {
        let battery = try #require(BatterySample(registry: [
            "CurrentCapacity": 104,
            "MaxCapacity": 100,
            "AppleRawMaxCapacity": 5200,
            "DesignCapacity": 5000,
        ]))
        #expect(battery.charge == 1)
        #expect(battery.health == 1)
    }

    @Test func healthIsUnknownWithoutADesignCapacity() throws {
        let battery = try #require(BatterySample(registry: ["CurrentCapacity": 70, "MaxCapacity": 100]))
        #expect(battery.health == nil)
    }

    @Test func aFullBatteryHasNoTimeRemaining() throws {
        let battery = try #require(BatterySample(registry: [
            "CurrentCapacity": 100, "MaxCapacity": 100, "FullyCharged": true, "TimeRemaining": 0,
        ]))
        #expect(battery.isFull)
        #expect(battery.minutesRemaining == nil)
    }

    @Test func noBatteryMeansNoSample() {
        #expect(BatterySample(registry: [:]) == nil)
        #expect(BatterySample(registry: ["BatteryInstalled": false, "CurrentCapacity": 0, "MaxCapacity": 100]) == nil)
        #expect(BatterySample(registry: ["CurrentCapacity": 50, "MaxCapacity": 0]) == nil)
    }
}

@Suite struct CollectorRuleTests {
    @Test func gpuPrefersDeviceUtilisation() {
        #expect(GPUCollector.utilizationPercent(["Device Utilization %": 32, "Renderer Utilization %": 90]) == 32)
        #expect(GPUCollector.utilizationPercent(["Renderer Utilization %": 20, "Tiler Utilization %": 45]) == 45)
        #expect(GPUCollector.utilizationPercent(["Alloc system memory": 1]) == nil)
    }

    @Test func onlyPhysicalInterfacesAreCounted() {
        #expect(NetworkCollector.counts(interface: "en0"))
        #expect(NetworkCollector.counts(interface: "en12"))
        #expect(NetworkCollector.counts(interface: "pdp_ip0"))
        #expect(!NetworkCollector.counts(interface: "lo0"))
        #expect(!NetworkCollector.counts(interface: "utun3"))     // VPN traffic already crossed en0
        #expect(!NetworkCollector.counts(interface: "bridge0"))
        #expect(!NetworkCollector.counts(interface: "awdl0"))
    }

    @Test func memoryPressureMapsTheKernelLevels() {
        #expect(MemoryPressure(kernelLevel: 1) == .normal)
        #expect(MemoryPressure(kernelLevel: 2) == .warning)
        #expect(MemoryPressure(kernelLevel: 4) == .critical)
        #expect(MemoryPressure(kernelLevel: 0) == .normal)
    }

    @Test func thermalLevelsAreOrderedCoolToHot() {
        #expect(ThermalLevel(.nominal) == .nominal)
        #expect(ThermalLevel(.critical) == .critical)
        #expect(ThermalLevel.allCases.map(\.rank) == [0, 1, 2, 3])
        #expect(ThermalLevel.fair < .serious)
    }

    @Test func memoryUsedFractionIsClamped() {
        #expect(MemorySample(total: 100, used: 25).usedFraction == 0.25)
        #expect(MemorySample(total: 100, used: 250).usedFraction == 1)
        #expect(MemorySample(total: 0, used: 10).usedFraction == 0)
    }
}

/// One real read of this machine. Nothing here changes any state.
@Suite struct LiveSmokeTests {
    @Test func oneRealSnapshotHasSaneValues() async throws {
        let collector = MetricsCollector()
        let snapshot = await collector.measure(detail: .processes, over: .milliseconds(250))

        #expect(snapshot.interval > 0.1)
        #expect(snapshot.cpu.coreCount > 0)
        #expect(snapshot.cpu.coreCount == ProcessInfo.processInfo.activeProcessorCount)
        #expect((0...1).contains(snapshot.cpu.usage))
        #expect(snapshot.cpu.perCore.allSatisfy { (0...1).contains($0) })
        #expect(abs(snapshot.cpu.user + snapshot.cpu.system - snapshot.cpu.usage) < 1e-6)
        #expect(snapshot.cpu.loadAverage.count == 3)

        #expect(snapshot.memory.total > 0)
        #expect(snapshot.memory.total == Int64(ProcessInfo.processInfo.physicalMemory))
        #expect(snapshot.memory.used > 0)
        #expect(snapshot.memory.used <= snapshot.memory.total)
        #expect((0...1).contains(snapshot.memory.pressureFraction))
        #expect(snapshot.memory.swapUsed >= 0)
        #expect(snapshot.memory.swapUsed <= max(snapshot.memory.swapTotal, snapshot.memory.swapUsed))

        #expect(snapshot.uptime > 0)
        #expect(ThermalLevel.allCases.contains(snapshot.thermal))

        if let gpu = snapshot.gpu { #expect((0...1).contains(gpu.utilization)) }
        if let battery = snapshot.battery {
            #expect((0...1).contains(battery.charge))
            if let health = battery.health { #expect(health > 0 && health <= 1) }
            if let cycles = battery.cycleCount { #expect(cycles >= 0) }
        }
        let disk = try #require(snapshot.disk)
        #expect(disk.readBytesPerSecond >= 0)
        #expect(disk.writeBytesPerSecond >= 0)
        #expect(disk.totalRead > 0)
        let network = try #require(snapshot.network)
        #expect(network.inBytesPerSecond >= 0)
        #expect(network.outBytesPerSecond >= 0)
    }

    @Test func theProcessListContainsThisTestRunner() async throws {
        let collector = MetricsCollector()
        let snapshot = await collector.measure(detail: .processes, over: .milliseconds(250))
        let processes = try #require(snapshot.processes)
        #expect(processes.count > 10)
        #expect(Set(processes.map(\.pid)).count == processes.count)

        let own = try #require(processes.first { $0.pid == getpid() })
        #expect(own.ownerUID == getuid())
        #expect(!own.name.isEmpty)
        #expect(own.executablePath != nil)
        #expect((own.residentBytes ?? 0) > 0)
        #expect((own.cpuPercent ?? -1) >= 0)
        #expect(own.startDate != nil)

        // launchd is always there, belongs to root, and may not be quit.
        let launchd = try #require(processes.first { $0.pid == 1 })
        #expect(launchd.ownerUID == 0)
        #expect(ProcessTerminator(control: FakeProcessControl()).refusal(for: launchd) == .systemProcess)
    }

    @Test func glanceDetailSkipsTheExpensiveCollectors() async {
        let snapshot = await MetricsCollector().sample(detail: .glance)
        #expect(snapshot.cpu.coreCount > 0)
        #expect(snapshot.memory.total > 0)
        #expect(snapshot.gpu == nil)
        #expect(snapshot.disk == nil)
        #expect(snapshot.network == nil)
        #expect(snapshot.battery == nil)
        #expect(snapshot.processes == nil)
    }

    @Test func theLiveIdentityLookupKnowsThisProcessAndNotAMadeUpOne() {
        let identity = SystemProcessControl().identity(of: getpid())
        #expect(identity?.ownerUID == getuid())
        #expect(identity?.startDate != nil)
        #expect(SystemProcessControl().identity(of: 999_999_999) == nil)
    }

    @Test func hostInfoDescribesThisMac() {
        #expect(HostInfo.logicalCores > 0)
        #expect(HostInfo.memoryBytes > 0)
    }
}
