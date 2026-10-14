import Foundation
import SweepKit

/// An APFS local snapshot, as listed by `tmutil listlocalsnapshots`.
public struct LocalSnapshot: Sendable, Equatable, Identifiable {
    /// For example `com.apple.TimeMachine.2026-10-13-101530.local`.
    public var name: String
    /// When it was taken, when the name carries a date.
    public var date: Date?

    public var id: String { name }

    public init(name: String, date: Date? = nil) {
        self.name = name
        self.date = date
    }
}

/// Where a volume's space is, including the parts a file listing cannot see.
public struct VolumeSpace: Sendable, Equatable {
    public var mountPoint: String
    public var name: String?
    public var total: Int64
    /// Free right now.
    public var available: Int64
    /// Free once macOS has dropped what it may drop. This is the number Finder shows.
    public var availableForImportantUsage: Int64
    public var snapshots: [LocalSnapshot]

    public init(
        mountPoint: String,
        name: String? = nil,
        total: Int64,
        available: Int64,
        availableForImportantUsage: Int64,
        snapshots: [LocalSnapshot] = []
    ) {
        self.mountPoint = mountPoint
        self.name = name
        self.total = total
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
        self.snapshots = snapshots
    }

    /// Space held by caches, snapshots and cloud copies that macOS frees by
    /// itself when it is needed: the gap between the two "available" numbers.
    public var purgeable: Int64 { max(availableForImportantUsage - available, 0) }

    public var used: Int64 { max(total - available, 0) }

    /// Used space that the scanned files do not account for. Only meaningful
    /// when the whole volume was scanned.
    public func unaccounted(scannedBytes: Int64) -> Int64 { max(used - scannedBytes, 0) }

    /// True when there is something to tell the user about "missing" space.
    public var hasHiddenSpace: Bool { purgeable > 0 || !snapshots.isEmpty }
}

/// Reads capacity numbers and local snapshots for the volume a path lives on.
public struct VolumeInspector: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func inspect(_ url: URL) async -> VolumeSpace {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let mountPoint = values?.volume?.path ?? "/"
        let available = Int64(values?.volumeAvailableCapacity ?? 0)
        return VolumeSpace(
            mountPoint: mountPoint,
            name: values?.volumeName,
            total: Int64(values?.volumeTotalCapacity ?? 0),
            available: available,
            // Zero means the volume does not report it; fall back to plain free space.
            availableForImportantUsage: max(values?.volumeAvailableCapacityForImportantUsage ?? 0, available),
            snapshots: await snapshots(mountPoint: mountPoint)
        )
    }

    /// Local snapshots of the volume mounted at `mountPoint`; empty when `tmutil` is missing or fails.
    public func snapshots(mountPoint: String) async -> [LocalSnapshot] {
        let result = await runner.run("tmutil", ["listlocalsnapshots", mountPoint], timeout: 10)
        guard result.succeeded else { return [] }
        return Self.parseSnapshots(result.stdout)
    }

    /// Parses the output of `tmutil listlocalsnapshots <mount point>`:
    ///
    ///     Snapshots for volume group containing disk /:
    ///     com.apple.TimeMachine.2026-10-13-101530.local
    public static func parseSnapshots(_ output: String, timeZone: TimeZone = .current) -> [LocalSnapshot] {
        var snapshots: [LocalSnapshot] = []
        var seen = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            // Skip the heading and anything that is not a snapshot name.
            guard !name.isEmpty, !name.hasSuffix(":"), !name.contains(" "), name.contains("."), seen.insert(name).inserted else { continue }
            snapshots.append(LocalSnapshot(name: name, date: date(inSnapshotName: name, timeZone: timeZone)))
        }
        return snapshots.sorted { ($0.date ?? .distantPast, $0.name) < ($1.date ?? .distantPast, $1.name) }
    }

    /// Finds the `yyyy-MM-dd-HHmmss` stamp Time Machine puts in snapshot names.
    static func date(inSnapshotName name: String, timeZone: TimeZone) -> Date? {
        for part in name.split(separator: ".") {
            let fields = part.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2, fields[3].count == 6,
                  let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]), let clock = Int(fields[3]),
                  fields.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { continue }
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = clock / 10000
            components.minute = (clock / 100) % 100
            components.second = clock % 100
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard (1...12).contains(month), (1...31).contains(day), clock / 10000 < 24 else { continue }
            if let date = calendar.date(from: components) { return date }
        }
        return nil
    }
}
