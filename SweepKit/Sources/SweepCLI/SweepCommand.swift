import ArgumentParser
import Foundation
import SweepKit

public struct SweepCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "housekeeping",
        abstract: "Reclaim developer caches and build artifacts.",
        discussion: "Every destructive command previews what it will remove and accepts --dry-run.",
        version: "1.0.0",
        subcommands: [Scan.self, Clean.self, Purge.self, Status.self, History.self]
    )

    public init() {}
}

// MARK: Shared helpers

enum Output {
    static func json<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func rightPad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    /// Asks before deleting. In a script there is nobody to ask, so `--yes` is required.
    static func confirm(_ question: String, assumeYes: Bool) throws {
        if assumeYes { return }
        guard isInteractive else {
            throw ValidationError("Nothing was removed. Pass --yes to run without a prompt, or --dry-run to preview.")
        }
        print("\(question) [y/N] ", terminator: "")
        let answer = readLine()?.lowercased() ?? ""
        guard answer == "y" || answer == "yes" else { throw ExitCode(1) }
    }

    static func report(_ operation: SweepOperation, noun: String) {
        for entry in operation.entries where entry.result != .removed && entry.result != .dryRun {
            print("  \(entry.result.rawValue): \(entry.target) (\(entry.reason ?? "no reason"))")
        }
        if operation.dryRun {
            print("Dry run: would free at most \(ByteFormat.string(operation.bytesPlanned)). Nothing was removed.")
        } else {
            print(operation.summary(noun: noun))
        }
    }
}

struct ScanRow: Encodable {
    var id: String
    var name: String
    var group: String
    var risk: String
    var status: String
    var reason: String?
    var bytes: Int64
    var files: Int
    var paths: [String]
    var action: String
    var source: String
    var lastModified: Date?
    var entries: [Entry]?

    struct Entry: Encodable {
        var label: String
        var bytes: Int64
        var detail: String?
    }

    init(_ result: ScanResult) {
        id = result.id
        name = result.item.name
        group = result.item.group.title
        risk = result.item.risk.rawValue
        switch result.status {
        case .ready: status = "ready"
        case .missing: status = "missing"
        case .blocked: status = "blocked"
        case .permissionDenied: status = "permissionDenied"
        }
        reason = result.status.isReady ? nil : result.status.reason
        bytes = result.bytes
        files = result.fileCount
        paths = result.roots
        action = result.actionDescription
        source = result.source.description
        lastModified = result.lastModified
        entries = result.selectable ? result.targets.map { Entry(label: $0.label, bytes: $0.bytes, detail: $0.detail) } : nil
    }
}

func printTable(_ results: [ScanResult], showMissing: Bool) {
    let visible = results.filter { showMissing || $0.status != .missing }
    for group in CatalogGroup.allCases {
        let rows = visible.filter { $0.item.group == group }
        guard !rows.isEmpty else { continue }
        print(group.title)
        for row in rows {
            let size = row.status == .missing ? "-" : ByteFormat.string(row.bytes)
            var line = "  " + Output.pad(row.item.name, 46) + Output.rightPad(size, 10) + "  " + Output.pad(row.item.risk.title, 8)
            if let reason = row.status.reason { line += " " + reason }
            print(line)
        }
    }
}

// MARK: scan

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List every catalog item with its size and status.")

    @Flag(name: .long, help: "Print JSON.") var json = false
    @Flag(name: .long, help: "Include items that were not found.") var all = false
    @Argument(help: "Catalog ids to scan. Scans everything when omitted.") var ids: [String] = []

    func run() async throws {
        let engine = SweepEngine()
        let items = try selectItems(engine, ids: ids)
        let results = await engine.scanAllCollected(items)
        if json {
            Output.json(results.map(ScanRow.init))
            return
        }
        printTable(results, showMissing: all)
        let safe = engine.oneClickSelection(from: results).reduce(Int64(0)) { $0 + $1.result.bytes }
        let total = results.reduce(Int64(0)) { $0 + $1.bytes }
        print("\nOne-click (\(engine.settings.oneClickTiers.sorted().map(\.title).joined(separator: " + "))): \(ByteFormat.string(safe))   All items: \(ByteFormat.string(total))")
        for warning in engine.catalog.warnings { print("warning: \(warning)") }
    }
}

func selectItems(_ engine: SweepEngine, ids: [String]) throws -> [CatalogItem] {
    guard !ids.isEmpty else { return engine.catalog.items }
    return try ids.map { id in
        guard let item = engine.catalog.item(id) else {
            throw ValidationError("Unknown catalog id '\(id)'. Run `housekeeping scan --all` to list them.")
        }
        return item
    }
}

// MARK: clean

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clean caches by tier or by name.",
        discussion: "Examples:\n  housekeeping clean --tier safe --dry-run\n  housekeeping clean npm pip xcode-deriveddata"
    )

    @Option(name: .long, help: "Clean every ready item of a tier: safe or caution. Repeatable.")
    var tier: [String] = []
    @Flag(name: .long, help: "Show what would be removed without removing anything.") var dryRun = false
    @Flag(name: .long, help: "Move deleted folders to the Trash instead of deleting them.") var trash = false
    @Flag(name: [.customShort("y"), .long], help: "Do not ask for confirmation.") var yes = false
    @Argument(help: "Catalog ids to clean.") var ids: [String] = []

    func validate() throws {
        if tier.isEmpty && ids.isEmpty {
            throw ValidationError("Say what to clean: --tier safe, or one or more catalog ids.")
        }
        for name in tier where name != "safe" && name != "caution" {
            throw ValidationError("--tier accepts safe or caution. Ask-tier items are cleaned one by one in the app.")
        }
    }

    func run() async throws {
        let engine = SweepEngine()
        let tiers = Set(tier.compactMap(RiskTier.init(rawValue:)))
        let named = try selectItems(engine, ids: ids)
        let items = ids.isEmpty ? engine.catalog.items : named
        let results = await engine.scanAllCollected(items)

        var selections: [CleanSelection] = []
        for result in results {
            let byName = ids.contains(result.id)
            let byTier = tiers.contains(result.item.risk) && !engine.settings.disabledItems.contains(result.id)
            guard byName || byTier else { continue }
            if result.selectable {
                if byName { print("\(result.item.name): pick the entries to remove in the House Keeping app; skipped.") }
                continue
            }
            if let reason = result.status.reason {
                if byName || result.status != .missing { print("\(result.item.name): skipped (\(reason))") }
                continue
            }
            if result.bytes > 0 || byName { selections.append(CleanSelection(result)) }
        }

        guard !selections.isEmpty else {
            print("Nothing to clean.")
            return
        }
        print(dryRun ? "Would clean:" : "About to clean:")
        for selection in selections {
            let result = selection.result
            let size = (result.isUpperBound ? "up to " : "") + ByteFormat.string(result.bytes)
            print("  " + Output.pad(result.item.name, 40) + Output.rightPad(size, 16) + "  " + result.actionDescription)
            // What will actually go: the entries for a delete, the tool's cache location for a command.
            let paths = result.targets.compactMap { target -> String? in
                if case .delete(let path) = target.action { return path }
                return nil
            }
            let listed = paths.isEmpty ? result.roots : paths
            for path in listed.prefix(12) { print("      \(engine.context.abbreviate(path))") }
            if listed.count > 12 { print("      and \(listed.count - 12) more") }
        }
        let total = selections.reduce(Int64(0)) { $0 + $1.result.bytes }
        let bounded = selections.contains { $0.result.isUpperBound }
        print("  Total: \(bounded ? "up to " : "")\(ByteFormat.string(total))")
        if bounded {
            print("  \"up to\": the tool's own prune command decides what is unused; what it frees is measured afterwards.")
        }

        if !dryRun { try Output.confirm("Clean \(selections.count) item\(selections.count == 1 ? "" : "s")?", assumeYes: yes) }
        let operation = await engine.clean(selections, source: "cli", mode: trash ? .trash : nil, dryRun: dryRun)
        Output.report(operation, noun: "cache")
        if !operation.failures.isEmpty { throw ExitCode(2) }
    }
}

// MARK: purge

struct Purge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete build artifacts (node_modules, target, .venv …) inside projects.",
        discussion: "Example:\n  housekeeping purge ~/Projects --older-than 30d --dry-run"
    )

    @Argument(help: "Folders to scan. Uses the Settings scan roots when omitted.") var roots: [String] = []
    @Option(name: .long, help: "Only projects untouched for this long, such as 30d, 2w or 12h.") var olderThan: String?
    @Flag(name: .long, help: "Show what would be removed without removing anything.") var dryRun = false
    @Flag(name: .long, help: "Delete permanently instead of moving to the Trash.") var permanent = false
    @Flag(name: [.customShort("y"), .long], help: "Do not ask for confirmation.") var yes = false
    @Flag(name: .long, help: "Print the scan as JSON and remove nothing.") var json = false

    static func parseAge(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let value = Double(text.dropLast()) else { return nil }
        switch unit {
        case "h": return value * 3600
        case "d": return value * 86_400
        case "w": return value * 7 * 86_400
        case "m": return value * 30 * 86_400
        default: return nil
        }
    }

    func run() async throws {
        let engine = SweepEngine()
        var minimumAge: TimeInterval = 0
        if let olderThan {
            guard let age = Self.parseAge(olderThan) else {
                throw ValidationError("--older-than takes a number and a unit: 12h, 30d, 2w or 6m.")
            }
            minimumAge = age
        }
        let expanded = roots.map { URL(fileURLWithPath: engine.context.expand($0)).standardizedFileURL.path }
        let scanner = ProjectScanner(engine: engine)
        let projects = await scanner.scan(roots: expanded.isEmpty ? nil : expanded)
            .filter { Date().timeIntervalSince($0.lastTouched) >= minimumAge }

        if json {
            struct Row: Encodable {
                var project: String
                var lastTouched: Date
                var bytes: Int64
                var artifacts: [Artifact]
                struct Artifact: Encodable {
                    var path: String
                    var kind: String
                    var bytes: Int64
                }
            }
            Output.json(projects.map { project in
                Row(project: project.path, lastTouched: project.lastTouched, bytes: project.bytes,
                    artifacts: project.artifacts.map { .init(path: $0.path, kind: $0.kind, bytes: $0.bytes) })
            })
            return
        }

        guard !projects.isEmpty else {
            print("No build artifacts found.")
            return
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        for project in projects {
            print("\(engine.context.abbreviate(project.path))  (\(ByteFormat.string(project.bytes)), touched \(formatter.localizedString(for: project.lastTouched, relativeTo: Date())))")
            for artifact in project.artifacts {
                print("  " + Output.pad(artifact.relativePath, 44) + Output.rightPad(ByteFormat.string(artifact.bytes), 10) + "  " + artifact.kind)
            }
        }
        let artifacts = projects.flatMap(\.artifacts)
        let total = artifacts.reduce(Int64(0)) { $0 + $1.bytes }
        print("Total: \(ByteFormat.string(total)) in \(projects.count) project\(projects.count == 1 ? "" : "s")")

        if !dryRun { try Output.confirm("Purge \(artifacts.count) folder\(artifacts.count == 1 ? "" : "s")?", assumeYes: yes) }
        let operation = await scanner.purge(artifacts, source: "cli", mode: permanent ? .permanent : nil, dryRun: dryRun)
        Output.report(operation, noun: "project")
        if !operation.failures.isEmpty { throw ExitCode(2) }
    }
}

// MARK: history

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show past operations from the ledger.")

    @Flag(name: .long, help: "Print JSON.") var json = false
    @Option(name: .long, help: "How many operations to show.") var limit = 20

    func run() async throws {
        let engine = SweepEngine()
        let operations = engine.ledger.operations(limit: limit)
        if json {
            Output.json(operations)
            return
        }
        guard !operations.isEmpty else {
            print("No operations yet.")
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for operation in operations {
            let failures = operation.failures.isEmpty ? "" : "  \(operation.failures.count) failed"
            print(Output.pad(formatter.string(from: operation.date), 24) + Output.pad(operation.kind.title, 14)
                  + Output.rightPad(ByteFormat.string(operation.bytesFreed), 10) + "  " + operation.cleanedItemNames.joined(separator: ", ") + failures)
        }
    }
}
