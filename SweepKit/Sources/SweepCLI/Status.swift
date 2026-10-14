import ArgumentParser
import Foundation
import SweepKit
import SweepMetrics

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Disk space and reclaimable totals.")

    @Flag(name: .long, help: "Print JSON.") var json = false

    struct Report: Encodable {
        var diskTotal: Int64
        var diskFree: Int64
        var diskUsed: Int64
        var reclaimableOneClick: Int64
        var reclaimableAll: Int64
        var lastOperation: Date?
        /// CPU, memory, GPU, disk, network, battery and thermal state right now. Only in the JSON output.
        var metrics: MetricsSnapshot?
    }

    func run() async throws {
        let engine = SweepEngine()
        // Rates need two reads half a second apart; they are taken while the scan runs.
        async let metrics: MetricsSnapshot? = json ? MetricsCollector().measure(detail: .system) : nil
        let results = await engine.scanAllCollected()
        let disk = DiskSpace.of(engine.context.home)
        let report = Report(
            diskTotal: disk.total,
            diskFree: disk.free,
            diskUsed: disk.used,
            reclaimableOneClick: engine.oneClickSelection(from: results).reduce(0) { $0 + $1.result.bytes },
            reclaimableAll: results.reduce(0) { $0 + $1.bytes },
            lastOperation: engine.ledger.operations(limit: 1).first?.date,
            metrics: await metrics
        )
        if json {
            Output.json(report)
            return
        }
        print("Disk         \(ByteFormat.string(report.diskUsed)) used of \(ByteFormat.string(report.diskTotal)), \(ByteFormat.string(report.diskFree)) free")
        print("Reclaimable  \(ByteFormat.string(report.reclaimableOneClick)) in one click, \(ByteFormat.string(report.reclaimableAll)) across all items")
    }
}
