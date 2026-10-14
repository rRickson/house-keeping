import Foundation

/// Append-only log of every operation, one JSON object per line, in
/// `~/Library/Logs/Sweep/operations.jsonl`.
public final class Ledger: Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("operations.jsonl")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Appends an operation. Dry runs and empty operations are not recorded.
    public func append(_ operation: SweepOperation) {
        guard !operation.dryRun, !operation.entries.isEmpty else { return }
        guard var line = try? Self.encoder().encode(operation) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Every recorded operation, newest first.
    public func operations(limit: Int? = nil) -> [SweepOperation] {
        lock.lock()
        let data = try? Data(contentsOf: fileURL)
        lock.unlock()
        guard let data else { return [] }
        let decoder = Self.decoder()
        var result: [SweepOperation] = []
        for line in data.split(separator: 0x0A).reversed() {
            if let operation = try? decoder.decode(SweepOperation.self, from: line) {
                result.append(operation)
                if let limit, result.count >= limit { break }
            }
        }
        return result
    }

    /// Bytes freed per week, oldest first, for the History chart.
    public func weeklyTotals(weeks: Int = 12, now: Date = Date(), calendar: Calendar = .current) -> [(weekStart: Date, bytes: Int64)] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var totals: [Date: Int64] = [:]
        for operation in operations() {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: operation.date)?.start else { continue }
            totals[start, default: 0] += operation.bytesFreed
        }
        return (0..<weeks).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek) else { return nil }
            return (start, totals[start] ?? 0)
        }
    }
}
