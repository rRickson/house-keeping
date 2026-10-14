import Foundation
import SweepMetrics

/// How the Status tool writes its numbers.
enum StatusFormat {
    /// A 0-to-1 fraction as a whole percentage, without the sign: "23".
    static func percent(_ fraction: Double) -> String {
        String(Int((min(1, max(0, fraction)) * 100).rounded()))
    }

    /// A process's CPU use: "12.3", or a dash when it is not known.
    static func processCPU(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return percent.formatted(.number.precision(.fractionLength(1)))
    }

    /// Memory in binary units, the way Activity Monitor and About This Mac count
    /// it: a Mac sold with 48 GB reads "48 GB", not "51.5 GB".
    static func memoryParts(_ bytes: Int64) -> (value: String, unit: String) {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0))
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let digits = index < 2 || value >= 100 ? 0...0 : (value >= 10 ? 0...1 : 0...2)
        return (value.formatted(.number.precision(.fractionLength(digits))), units[index])
    }

    static func memory(_ bytes: Int64) -> String {
        let parts = memoryParts(bytes)
        return "\(parts.value) \(parts.unit)"
    }

    /// "3d 4h", "4h 12m" or "12m".
    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// "3 hr 20 min" for the time a battery has left.
    static func remaining(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    static func load(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }

    /// "13 Oct, 15:02"
    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func thermalTitle(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very Hot"
        }
    }

    static func thermalDetail(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: "Nothing is being slowed down"
        case .fair: "Fans may run to keep things cool"
        case .serious: "macOS is easing off to cool down"
        case .critical: "macOS is pausing heavy work to cool down"
        }
    }

    static func pressureTitle(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "High"
        }
    }
}

extension ProcessSample {
    // Sort keys for the table's column headers. The real ordering, with pinned
    // rows first and unknown values last, is `ProcessOrdering.sorted`.
    var cpuSortValue: Double { cpuPercent ?? -1 }
    var memorySortValue: Int64 { residentBytes ?? -1 }
    var userSortValue: String { ownerName ?? "" }
}
