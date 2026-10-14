import Foundation

public enum ProcessSortKey: String, Sendable, CaseIterable, Codable {
    case cpu, memory, name, pid, user
}

public struct ProcessSort: Sendable, Equatable, Codable {
    public var key: ProcessSortKey
    public var ascending: Bool

    public init(_ key: ProcessSortKey, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }

    /// Busiest first, the order the table opens with.
    public static let `default` = ProcessSort(.cpu, ascending: false)
}

/// The order of the process table.
public enum ProcessOrdering {
    /// Sorts processes for the table.
    ///
    /// - Pinned names come first whatever the sort, and are sorted among themselves the same way.
    /// - A process whose value is unknown (another user's CPU or memory) comes
    ///   after every process with a value, in both directions.
    /// - Equal values keep a steady order by pid, so rows do not swap between refreshes.
    public static func sorted(_ processes: [ProcessSample], by sort: ProcessSort = .default, pinned: Set<String> = []) -> [ProcessSample] {
        processes.sorted { lhs, rhs in
            let lhsPinned = pinned.contains(lhs.name)
            let rhsPinned = pinned.contains(rhs.name)
            if lhsPinned != rhsPinned { return lhsPinned }
            switch compare(lhs, rhs, by: sort.key, ascending: sort.ascending) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.pid < rhs.pid
            }
        }
    }

    /// Processes whose name, owner or pid contains the query. An empty query keeps everything.
    public static func filtered(_ processes: [ProcessSample], matching query: String) -> [ProcessSample] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return processes }
        return processes.filter { process in
            process.name.localizedCaseInsensitiveContains(needle)
                || (process.ownerName?.localizedCaseInsensitiveContains(needle) ?? false)
                || String(process.pid) == needle
        }
    }

    /// `.orderedAscending` when `lhs` belongs before `rhs`.
    private static func compare(_ lhs: ProcessSample, _ rhs: ProcessSample, by key: ProcessSortKey, ascending: Bool) -> ComparisonResult {
        switch key {
        case .cpu: return compare(lhs.cpuPercent, rhs.cpuPercent, ascending: ascending)
        case .memory: return compare(lhs.residentBytes, rhs.residentBytes, ascending: ascending)
        case .pid: return compare(lhs.pid, rhs.pid, ascending: ascending)
        case .name: return directed(lhs.name.localizedStandardCompare(rhs.name), ascending: ascending)
        case .user:
            switch (lhs.ownerName, rhs.ownerName) {
            case let (left?, right?): return directed(left.localizedStandardCompare(right), ascending: ascending)
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            }
        }
    }

    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left == right { return .orderedSame }
            return (left < right) == ascending ? .orderedAscending : .orderedDescending
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        }
    }

    private static func directed(_ result: ComparisonResult, ascending: Bool) -> ComparisonResult {
        guard !ascending else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// The process names the user pinned to the top of the table, kept in UserDefaults.
public enum PinnedProcesses {
    public static let defaultsKey = "status.pinnedProcesses"

    public static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public static func save(_ names: Set<String>, to defaults: UserDefaults = .standard) {
        if names.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(names.sorted(), forKey: defaultsKey)
        }
    }

    /// Pins the name when it is not pinned, unpins it when it is; returns the new set.
    public static func toggling(_ name: String, in names: Set<String>) -> Set<String> {
        var result = names
        if result.remove(name) == nil { result.insert(name) }
        return result
    }
}
