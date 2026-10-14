import Darwin
import Foundation
import SweepKit

/// A launch agent in `~/Library/LaunchAgents` whose program is gone.
public struct BrokenLaunchAgent: Sendable, Hashable, Identifiable {
    /// The real path of the property list.
    public let path: String
    public let label: String
    /// The program the agent names, which no longer exists.
    public let program: String
    public let bytes: Int64
    /// Identity of the property list when it was found; checked again before it is moved.
    public let fingerprint: Fingerprint

    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }
}

/// Finds and removes launch agents that point at a missing program.
///
/// Only the user's own `~/Library/LaunchAgents` is looked at, Apple's agents
/// are never candidates, and removal means the Trash, through the guarded remover.
public struct BrokenLaunchAgents: Sendable {
    private let engine: SweepEngine

    public init(engine: SweepEngine) {
        self.engine = engine
    }

    public var directory: String { engine.context.home.appendingPathComponent("Library/LaunchAgents").path }

    public func find() -> [BrokenLaunchAgent] {
        guard let folder = SafetyGuard.realpath(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var result: [BrokenLaunchAgent] = []
        for name in names.sorted() where name.hasSuffix(".plist") {
            if Self.isApple(name) { continue }
            let path = folder + "/" + name
            // A linked plist belongs to whoever owns the target (Homebrew services, for one).
            guard let fingerprint = Fingerprint(path: path), !fingerprint.isSymlink, !fingerprint.isDirectory else { continue }
            guard let job = Self.readJob(path) else { continue }
            let label = job.label ?? String(name.dropLast(".plist".count))
            if Self.isApple(label) { continue }
            guard let program = job.program, Self.isMissing(program) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            result.append(BrokenLaunchAgent(path: path, label: label, program: program, bytes: size, fingerprint: fingerprint))
        }
        return result
    }

    /// Moves each agent to the Trash, then asks launchd to forget it.
    /// An agent whose program has come back since it was found is left alone.
    public func remove(_ agents: [BrokenLaunchAgent]) async -> [OperationEntry] {
        var entries: [OperationEntry] = []
        for agent in agents {
            func entry(_ bytes: Int64, _ result: OperationEntry.Result, _ reason: String? = nil) -> OperationEntry {
                OperationEntry(
                    itemID: OptimizeCatalog.removeBrokenLaunchAgents.id,
                    itemName: OptimizeCatalog.removeBrokenLaunchAgents.title,
                    target: agent.path, bytes: bytes, mode: DeleteMode.trash.rawValue, result: result, reason: reason
                )
            }
            guard !Self.isApple(agent.fileName), !Self.isApple(agent.label) else {
                entries.append(entry(0, .refused, "Apple launch agents are never removed"))
                continue
            }
            guard Self.isMissing(agent.program) else {
                entries.append(entry(0, .skipped, "its program exists again"))
                continue
            }
            let outcome = engine.remover.remove(
                agent.path, allowedRoots: [agent.path], scope: .uninstall,
                fingerprint: agent.fingerprint, mode: .trash, dryRun: false
            )
            switch outcome {
            case .removed(let bytes):
                entries.append(entry(bytes, .removed))
                await unload(agent)
            case .dryRun(let bytes): entries.append(entry(bytes, .dryRun))
            case .skipped(let reason): entries.append(entry(0, .skipped, reason))
            case .refused(let reason): entries.append(entry(0, .refused, reason))
            case .failed(let reason, let freed): entries.append(entry(freed, .failed, reason))
            }
        }
        return entries
    }

    /// The job cannot start, but launchd keeps its entry until logout. Failing here is harmless.
    private func unload(_ agent: BrokenLaunchAgent) async {
        guard Self.isPlainLabel(agent.label) else { return }
        _ = await engine.context.runner.run([SystemTool.launchctl, "bootout", "gui/\(getuid())/\(agent.label)"], timeout: 10)
    }

    // MARK: Rules

    static func isApple(_ name: String) -> Bool {
        name.lowercased().hasPrefix("com.apple.")
    }

    static func isPlainLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x2D || byte == 0x5F
        }
    }

    struct Job {
        var label: String?
        /// An absolute program path, or nil when the agent cannot be judged.
        var program: String?
    }

    static func readJob(_ path: String) -> Job? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        var job = Job(label: plist["Label"] as? String)
        // A bundle-relative program belongs to an app; where that app lives is not ours to guess.
        if plist["BundleProgram"] != nil { return job }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [Any])?.first as? String
        if let program, program.hasPrefix("/") { job.program = program }
        return job
    }

    /// True only when the path certainly does not exist. A program on a volume
    /// that is not mounted, or one Sweep may not look at, is not "missing".
    static func isMissing(_ program: String) -> Bool {
        let path = URL(fileURLWithPath: program).standardizedFileURL.path
        if path.hasPrefix("/Volumes/") || path.hasPrefix("/Network/") { return false }
        var info = stat()
        if stat(path, &info) == 0 { return false }
        return errno == ENOENT || errno == ENOTDIR
    }
}
