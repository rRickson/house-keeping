import Darwin
import Foundation
import IOKit

/// Small wrappers over the kernel calls the collectors share.
enum Kernel {
    /// The host port, fetched once: every `mach_host_self()` call takes a new port reference.
    static let host: mach_port_t = mach_host_self()

    static let pageSize: Int64 = {
        var size: vm_size_t = 0
        guard host_page_size(host, &size) == KERN_SUCCESS, size > 0 else { return Int64(getpagesize()) }
        return Int64(size)
    }()

    /// Numerator and denominator that turn Mach time units into nanoseconds.
    static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Seconds on a clock that does not jump and does not run while the Mac sleeps.
    static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    /// Reads a fixed-size sysctl value. Nil when the name is unknown or the size differs.
    static func sysctl<T>(_ name: String, as type: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return pointer.pointee
    }
}

enum CPUCollector {
    /// Tick counters of every logical core.
    static func ticks() -> [CPUTicks] {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(Kernel.host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(coreCount) * states else { return [] }
        return (0..<Int(coreCount)).map { core in
            let base = core * states
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = getloadavg(&values, 3)
        return count > 0 ? Array(values.prefix(Int(count))) : []
    }

    /// Performance and efficiency core counts; nil on Macs with one kind of core.
    static let coreKinds: (performance: Int?, efficiency: Int?) = {
        guard let levels = Kernel.sysctl("hw.nperflevels", as: Int32.self), levels >= 2 else { return (nil, nil) }
        return (
            Kernel.sysctl("hw.perflevel0.logicalcpu", as: Int32.self).map(Int.init),
            Kernel.sysctl("hw.perflevel1.logicalcpu", as: Int32.self).map(Int.init)
        )
    }()
}

enum MemoryCollector {
    static func sample() -> MemorySample {
        let total = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Kernel.host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemorySample(total: total, used: 0) }

        let page = Kernel.pageSize
        let purgeable = Int64(stats.purgeable_count)
        // The same split Activity Monitor uses: used = app + wired + compressed.
        let app = max(0, Int64(stats.internal_page_count) - purgeable) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let cached = (Int64(stats.external_page_count) + purgeable) * page
        let free = max(0, Int64(stats.free_count) - Int64(stats.speculative_count)) * page

        let level = Kernel.sysctl("kern.memorystatus_vm_pressure_level", as: Int32.self) ?? 1
        let freeLevel = Kernel.sysctl("kern.memorystatus_level", as: Int32.self).map { Double($0) / 100 } ?? 1
        let swap = Kernel.sysctl("vm.swapusage", as: xsw_usage.self)

        return MemorySample(
            total: total,
            used: min(total, app + wired + compressed),
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            free: free,
            pressure: MemoryPressure(kernelLevel: level),
            pressureFraction: min(1, max(0, 1 - freeLevel)),
            swapUsed: Int64(clamping: swap?.xsu_used ?? 0),
            swapTotal: Int64(clamping: swap?.xsu_total ?? 0)
        )
    }
}

enum SystemCollector {
    static func thermal() -> ThermalLevel { ThermalLevel(ProcessInfo.processInfo.thermalState) }

    /// Wall-clock seconds since boot, the number `uptime` prints.
    static func uptime() -> TimeInterval {
        guard let boot = Kernel.sysctl("kern.boottime", as: timeval.self), boot.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let started = TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000
        return max(0, Date().timeIntervalSince1970 - started)
    }
}

/// Reads properties of IOKit registry entries by class name.
enum Registry {
    /// Calls `body` with every registry entry of the class. The entry is released afterwards.
    static func forEach(className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

enum GPUCollector {
    /// The busiest accelerator, or nil when none reports utilisation.
    static func sample() -> GPUSample? {
        var best: GPUSample?
        Registry.forEach(className: "IOAccelerator") { entry in
            guard let statistics = Registry.property("PerformanceStatistics", of: entry) as? [String: Any],
                  let percent = utilizationPercent(statistics) else { return }
            let utilization = min(1, max(0, percent / 100))
            if best == nil || utilization > (best?.utilization ?? 0) {
                best = GPUSample(utilization: utilization, name: name(of: entry))
            }
        }
        return best
    }

    /// "Device Utilization %" where present, otherwise the busier of renderer and tiler.
    static func utilizationPercent(_ statistics: [String: Any]) -> Double? {
        if let device = number(statistics["Device Utilization %"]) { return device }
        let parts = [number(statistics["Renderer Utilization %"]), number(statistics["Tiler Utilization %"])].compactMap { $0 }
        return parts.max()
    }

    private static func name(of entry: io_registry_entry_t) -> String? {
        switch Registry.property("model", of: entry) {
        case let text as String:
            return text
        case let data as Data:
            // Intel drivers publish the model as a C string in a data blob.
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        default:
            return nil
        }
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
}

enum DiskCollector {
    /// Bytes read and written by every block storage driver since boot.
    static func counters() -> IOCounters? {
        var total = IOCounters(input: 0, output: 0)
        var found = false
        Registry.forEach(className: "IOBlockStorageDriver") { entry in
            guard let statistics = Registry.property("Statistics", of: entry) as? [String: Any] else { return }
            found = true
            total.input += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            total.output += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? total : nil
    }
}

enum NetworkCollector {
    /// Width of the counters `getifaddrs` hands out in `if_data`.
    static let counterBits = 32

    /// True for interfaces that carry real traffic once: Ethernet, Wi-Fi and
    /// cellular. Tunnels and bridges repeat bytes that already crossed one of those.
    static func counts(interface name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    /// Bytes received and sent per interface since it came up.
    static func counters() -> [String: IOCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [:] }
        defer { freeifaddrs(head) }

        var result: [String: IOCounters] = [:]
        var cursor = head
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  let data = entry.pointee.ifa_data,
                  Int32(entry.pointee.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard counts(interface: name) else { continue }
            let statistics = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = IOCounters(input: UInt64(statistics.ifi_ibytes), output: UInt64(statistics.ifi_obytes))
        }
        return result
    }
}

enum BatteryCollector {
    private static let keys = [
        "BatteryInstalled", "CurrentCapacity", "MaxCapacity", "AppleRawMaxCapacity", "NominalChargeCapacity",
        "DesignCapacity", "BatteryData", "CycleCount", "IsCharging", "ExternalConnected", "FullyCharged", "TimeRemaining",
    ]

    /// Nil on Macs without a battery.
    static func sample() -> BatterySample? {
        var sample: BatterySample?
        Registry.forEach(className: "AppleSmartBattery") { entry in
            guard sample == nil else { return }
            var properties: [String: Any] = [:]
            for key in keys {
                if let value = Registry.property(key, of: entry) { properties[key] = value }
            }
            sample = BatterySample(registry: properties)
        }
        return sample
    }
}

extension BatterySample {
    /// Reads the properties of the `AppleSmartBattery` registry entry.
    ///
    /// Charge is `CurrentCapacity` over `MaxCapacity`, which works whether the
    /// Mac reports them in percent (Apple silicon) or mAh (Intel). Health is
    /// the full-charge capacity in mAh over the design capacity; newer systems
    /// keep both inside the `BatteryData` dictionary.
    public init?(registry: [String: Any]) {
        func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        func flag(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue ?? false }

        if let installed = registry["BatteryInstalled"] as? NSNumber, !installed.boolValue { return nil }
        guard let current = integer(registry["CurrentCapacity"]),
              let maximum = integer(registry["MaxCapacity"]), maximum > 0 else { return nil }
        let nested = registry["BatteryData"] as? [String: Any] ?? [:]

        let design = integer(registry["DesignCapacity"]) ?? integer(nested["DesignCapacity"])
        let fullCharge = integer(registry["AppleRawMaxCapacity"])
            ?? integer(nested["FullChargeCapacity"])
            ?? integer(registry["NominalChargeCapacity"])
            ?? integer(nested["NominalChargeCapacity"])
            ?? (maximum > 100 ? maximum : nil)
        var health: Double?
        if let design, design > 0, let fullCharge, fullCharge > 0 {
            health = min(1, Double(fullCharge) / Double(design))
        }

        // 65535 means the system is still working out the estimate.
        var minutes = integer(registry["TimeRemaining"])
        if let value = minutes, value <= 0 || value >= 65535 { minutes = nil }
        let full = flag(registry["FullyCharged"])

        self.init(
            charge: min(1, max(0, Double(current) / Double(maximum))),
            health: health,
            cycleCount: integer(registry["CycleCount"]),
            isCharging: flag(registry["IsCharging"]),
            isPluggedIn: flag(registry["ExternalConnected"]),
            isFull: full,
            minutesRemaining: full ? nil : minutes
        )
    }
}
