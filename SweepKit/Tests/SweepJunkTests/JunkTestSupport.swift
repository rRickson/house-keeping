import Foundation
import SweepKit
import SweepTestSupport
@testable import SweepJunk

/// Records what it is asked to do and touches nothing.
struct FakePrivileged: PrivilegedRunning {
    let state: PrivilegedAvailability
    let bytesFreed: Int64
    let succeeds: Bool
    private let log = Locked<[PrivilegedTask]>([])

    init(_ state: PrivilegedAvailability = .helper, bytesFreed: Int64 = 12_345, succeeds: Bool = true) {
        self.state = state
        self.bytesFreed = bytesFreed
        self.succeeds = succeeds
    }

    var availability: PrivilegedAvailability { get async { state } }
    var calls: [PrivilegedTask] { log.get() }

    func run(_ task: PrivilegedTask, argument: String?) async -> PrivilegedResult {
        log.mutate { $0.append(task) }
        return PrivilegedResult(succeeded: succeeds, message: succeeds ? "" : "helper refused", bytesFreed: succeeds ? bytesFreed : 0)
    }
}

/// "Now" for scans in tests: far enough ahead that a file written a moment ago is an old download.
let ninetyDaysAhead = Date().addingTimeInterval(90 * 86_400)

extension FixtureHome {
    func scanner(
        processes: [String] = [],
        items: [CatalogItem] = [],
        settings: SweepSettings = SweepSettings(),
        privileged: any PrivilegedRunning = NoPrivilegedRunner(),
        options: JunkOptions = JunkOptions(now: ninetyDaysAhead)
    ) -> JunkScanner {
        JunkScanner(engine: engine(items: items, processes: processes, settings: settings), privileged: privileged, options: options)
    }

    func cleaner(
        processes: [String] = [],
        settings: SweepSettings = SweepSettings(),
        privileged: any PrivilegedRunning = NoPrivilegedRunner(),
        options: JunkOptions = JunkOptions(now: ninetyDaysAhead)
    ) -> JunkCleaner {
        JunkCleaner(engine: engine(items: [], processes: processes, settings: settings), privileged: privileged, options: options)
    }

    /// Marks a file as changed `days` before the scan's "now", which makes it a recent download.
    func touch(_ relative: String, daysBeforeScan days: Double) throws {
        let date = ninetyDaysAhead.addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }

    /// Writes a small zip archive (stored, no compression) with the given entry names.
    func writeZip(_ relative: String, entries: [String]) throws {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }

        var body: [UInt8] = []
        var directory: [UInt8] = []
        for name in entries {
            let nameBytes = Array(name.utf8)
            let content: [UInt8] = name.hasSuffix("/") ? [] : Array("sweep".utf8)
            let offset = body.count
            body += le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            body += le32(0) + le32(content.count) + le32(content.count) + le16(nameBytes.count) + le16(0)
            body += nameBytes + content
            directory += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            directory += le32(0) + le32(content.count) + le32(content.count)
            directory += le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset)
            directory += nameBytes
        }
        let end = le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
            + le32(directory.count) + le32(body.count) + le16(0)
        let target = path(relative)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(body + directory + end).write(to: URL(fileURLWithPath: target))
    }

    /// An iOS backup folder with the `Info.plist` Finder writes.
    func writeBackup(_ udid: String, deviceName: String, product: String, date: Date, bytes: Int = 8192) throws {
        let folder = "Library/Application Support/MobileSync/Backup/\(udid)"
        try write("\(folder)/Manifest.db", bytes: bytes)
        let info: [String: Any] = [
            "Device Name": deviceName, "Product Name": product, "Product Version": "18.2", "Last Backup Date": date,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path("\(folder)/Info.plist")))
    }

    /// One of everything the Clean tool looks for, plus things it must never list.
    func populateEverything() throws {
        try write("Library/Caches/com.spotify.client/Data/blob", bytes: 64 * 1024)
        try write("Library/Caches/com.example.editor/index", bytes: 16 * 1024)
        try write("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 32 * 1024)
        try write("Library/Caches/com.apple.Safari/Cache.db", bytes: 8192)
        try write("Library/Caches/Google/Chrome/Default/Cache/data_0", bytes: 8192)
        try write("Library/Application Support/Google/Chrome/Default/Cookies")
        try write("Library/Safari/History.db")
        try write("Library/Logs/SomeApp/app.log", bytes: 8192)
        try write("Library/Logs/install.log")
        try write("Library/Logs/DiagnosticReports/SomeApp-2026-01-01.ips")
        try write("Library/Logs/House Keeping/operations.jsonl")
        try write("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/4F2A/invoice.pdf")
        try write("Downloads/.DS_Store")
        try write("Projects/app/.DS_Store")
        try write("Projects/app/README.md")
        try write("Downloads/Old Installer.dmg", bytes: 128 * 1024)
        try writeBackup("00008030-000A1B2C3D4E", deviceName: "Rickson's iPhone", product: "iPhone 15 Pro",
                        date: Date(timeIntervalSince1970: 1_750_000_000), bytes: 256 * 1024)
        try write(".Trash/old-report.txt", bytes: 512 * 1024)
        try write("SystemCaches/com.apple.something/cache.bin", bytes: 8192)
    }
}

extension Array where Element == JunkEntry {
    func of(_ category: JunkCategory) -> [JunkEntry] { filter { $0.category == category } }
    func named(_ name: String) -> JunkEntry? { first { $0.name == name } }
    var allPaths: [String] { flatMap(\.paths) }
}
