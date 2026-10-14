import Foundation

public enum ByteFormat {
    /// "18.4 GB", using decimal units like Finder and the user's decimal separator.
    public static func string(_ bytes: Int64) -> String {
        let parts = parts(bytes)
        return "\(parts.value) \(parts.unit)"
    }

    /// Splits a size into its number and unit so the number can be animated on its own.
    public static func parts(_ bytes: Int64) -> (value: String, unit: String) {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0))
        var index = 0
        while value >= 999.5, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        // Whole numbers for bytes, kilobytes and anything with three digits; one decimal otherwise.
        let decimals = (index <= 1 || value >= 99.95) ? 0 : 1
        return (value.formatted(.number.precision(.fractionLength(decimals)).grouping(.never)), units[index])
    }

    /// Parses sizes printed by tools such as Docker and Ollama ("1.2GB", "512 MB", "12.3kB", "4.7 GiB").
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var number = ""
        var unit = ""
        for character in trimmed {
            if character.isNumber || character == "." {
                if !unit.isEmpty { break }
                number.append(character)
            } else if character.isLetter {
                unit.append(character)
            } else if !unit.isEmpty {
                break
            }
        }
        guard let value = Double(number) else { return nil }
        let multiplier: Double
        switch unit.lowercased() {
        case "", "b", "bytes", "byte": multiplier = 1
        case "k", "kb": multiplier = 1e3
        case "m", "mb": multiplier = 1e6
        case "g", "gb": multiplier = 1e9
        case "t", "tb": multiplier = 1e12
        case "kib": multiplier = 1024
        case "mib": multiplier = 1_048_576
        case "gib": multiplier = 1_073_741_824
        case "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        return Int64(value * multiplier)
    }
}

/// Free and total space of the volume that holds a path.
public struct DiskSpace: Sendable, Equatable {
    public var total: Int64
    /// Space available for important usage, which is what Finder reports.
    public var free: Int64
    public var used: Int64 { max(total - free, 0) }
    public var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 0 }

    public init(total: Int64, free: Int64) {
        self.total = total
        self.free = free
    }

    public static func of(_ url: URL = URL(fileURLWithPath: "/")) -> DiskSpace {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return DiskSpace(total: 0, free: 0) }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let free = important > 0 ? important : Int64(values.volumeAvailableCapacity ?? 0)
        return DiskSpace(total: total, free: free)
    }
}
