import Foundation
import SweepKit

/// How one task ended.
public struct OptimizeOutcome: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case done
        /// A gate held it back, or there was nothing to do.
        case skipped
        case failed
    }

    public var status: Status
    /// A short line for the row: what was done, or why not.
    public var message: String
    public var bytesFreed: Int64

    public init(status: Status, message: String, bytesFreed: Int64 = 0) {
        self.status = status
        self.message = message
        self.bytesFreed = bytesFreed
    }

    public static func done(_ message: String = "Done", bytesFreed: Int64 = 0) -> OptimizeOutcome {
        OptimizeOutcome(status: .done, message: message, bytesFreed: bytesFreed)
    }

    public static func skipped(_ reason: String) -> OptimizeOutcome {
        OptimizeOutcome(status: .skipped, message: reason)
    }

    public static func failed(_ reason: String) -> OptimizeOutcome {
        OptimizeOutcome(status: .failed, message: reason)
    }
}

/// Whether a task can run right now, and what it would act on.
public struct TaskCheck: Sendable, Equatable {
    public enum Readiness: Sendable, Equatable {
        case ready
        /// A safety gate holds the task back; the text says which.
        case blocked(String)
        /// Nothing for the task to act on.
        case nothingToDo(String)
    }

    /// One thing the task would act on, shown before anything happens.
    public struct PreviewItem: Sendable, Equatable, Identifiable {
        public var title: String
        public var detail: String
        /// Set when the item is a file that can be revealed in Finder.
        public var path: String?

        public var id: String { path ?? title + detail }
    }

    public var readiness: Readiness
    public var preview: [PreviewItem]

    public init(_ readiness: Readiness, preview: [PreviewItem] = []) {
        self.readiness = readiness
        self.preview = preview
    }

    public var isReady: Bool { readiness == .ready }

    /// The text shown in place of the checkbox when the task cannot run.
    public var reason: String? {
        switch readiness {
        case .ready: nil
        case .blocked(let reason), .nothingToDo(let reason): reason
        }
    }
}

public enum OptimizeEvent: Sendable {
    /// One password prompt is about to cover these tasks.
    case authorizing(taskIDs: [String])
    case started(taskID: String)
    case finished(taskID: String, outcome: OptimizeOutcome)
}

/// Checks and runs maintenance tasks, one after another, and records the run.
public struct OptimizeRunner: Sendable {
    public let engine: SweepEngine
    public let privileged: any PrivilegedRunning
    private let probe: any ConditionProbing
    private let now: @Sendable () -> Date

    public init(
        engine: SweepEngine,
        privileged: any PrivilegedRunning,
        probe: (any ConditionProbing)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.privileged = privileged
        self.probe = probe ?? SystemConditionProbe(context: engine.context)
        self.now = now
    }

    private var context: SweepContext { engine.context }

    // MARK: Checks

    /// Evaluates every gate and gathers previews, for drawing the list.
    public func check(_ tasks: [OptimizeTask] = OptimizeCatalog.all) async -> [String: TaskCheck] {
        let conditions = await probe.conditions()
        let availability = await privileged.availability
        var result: [String: TaskCheck] = [:]
        for task in tasks {
            result[task.id] = check(task, conditions: conditions, availability: availability)
        }
        return result
    }

    /// Evaluates one task's gates against fresh conditions. Called right before the task runs.
    public func check(_ task: OptimizeTask) async -> TaskCheck {
        let conditions = task.gates.isEmpty ? SystemConditions.clear : await probe.conditions()
        let availability = task.needsAdmin ? await privileged.availability : PrivilegedAvailability.helper
        return check(task, conditions: conditions, availability: availability)
    }

    func check(_ task: OptimizeTask, conditions: SystemConditions, availability: PrivilegedAvailability) -> TaskCheck {
        if task.needsAdmin, availability == .unavailable {
            return TaskCheck(.blocked("Admin tasks are not available"))
        }
        if let reason = task.blockReason(in: conditions) {
            return TaskCheck(.blocked(reason))
        }
        switch task.action {
        case .commands:
            return TaskCheck(.ready)

        case .vacuumDatabases:
            let databases = DatabaseVacuum(context: context).candidates()
            guard !databases.isEmpty else { return TaskCheck(.nothingToDo("No databases found")) }
            let preview = databases.map { database in
                TaskCheck.PreviewItem(
                    title: "\(database.app) · \((database.path as NSString).lastPathComponent)",
                    detail: database.blockedBy ?? ByteFormat.string(database.bytes),
                    path: database.path
                )
            }
            // Skipped per app: one open app must not hold back the others.
            if databases.allSatisfy({ $0.blockedBy != nil }) {
                var apps: [String] = []
                for database in databases where !apps.contains(database.app) { apps.append(database.app) }
                let names = ListFormatter.localizedString(byJoining: apps)
                return TaskCheck(.blocked(apps.count == 1 ? "\(names) is open" : "\(names) are open"), preview: preview)
            }
            return TaskCheck(.ready, preview: preview)

        case .pruneNotifications:
            switch NotificationHistory(context: context, now: now).state() {
            case .ready: return TaskCheck(.ready)
            case .needsFullDiskAccess: return TaskCheck(.blocked("Needs Full Disk Access"))
            case .notFound: return TaskCheck(.nothingToDo("No history found"))
            }

        case .removeBrokenLaunchAgents:
            let agents = BrokenLaunchAgents(engine: engine).find()
            guard !agents.isEmpty else { return TaskCheck(.nothingToDo("None found")) }
            return TaskCheck(.ready, preview: agents.map { agent in
                TaskCheck.PreviewItem(title: agent.label, detail: "Missing \(context.abbreviate(agent.program))", path: agent.path)
            })
        }
    }

    // MARK: Run

    /// Runs the tasks in order and writes one operation to the ledger.
    ///
    /// Each task's gates are evaluated again right before it runs. When admin
    /// tasks need the password prompt, they are authorised together so macOS
    /// asks once; their gates are evaluated right before that prompt.
    @discardableResult
    public func run(
        _ tasks: [OptimizeTask],
        source: String = "window",
        onEvent: (@Sendable (OptimizeEvent) -> Void)? = nil
    ) async -> SweepOperation {
        var operation = SweepOperation(kind: .optimize, source: source)
        var early: [String: Early] = [:]

        let admin = tasks.filter(\.needsAdmin)
        if admin.count > 1, let batcher = privileged as? any BatchPrivilegedRunning, await privileged.availability == .passwordPrompt {
            var ready: [OptimizeTask] = []
            for task in admin {
                let check = await check(task)
                if let reason = check.reason {
                    early[task.id] = .skipped(reason)
                } else {
                    ready.append(task)
                }
            }
            if ready.count > 1 {
                onEvent?(.authorizing(taskIDs: ready.map(\.id)))
                let results = await batcher.run(batch: ready.compactMap(\.privilegedTask))
                for task in ready {
                    if let privilegedTask = task.privilegedTask, let result = results[privilegedTask] {
                        early[task.id] = .authorized(result)
                    }
                }
            }
        }

        for task in tasks {
            if Task.isCancelled { break }
            onEvent?(.started(taskID: task.id))
            let (outcome, entries) = await perform(task, early: early[task.id])
            operation.entries.append(contentsOf: entries ?? [entry(for: task, outcome)])
            onEvent?(.finished(taskID: task.id, outcome: outcome))
        }
        engine.ledger.append(operation)
        return operation
    }

    /// What is already known about a task before its turn comes.
    private enum Early {
        case skipped(String)
        case authorized(PrivilegedResult)
    }

    private func entry(for task: OptimizeTask, _ outcome: OptimizeOutcome) -> OperationEntry {
        let result: OperationEntry.Result
        switch outcome.status {
        case .done: result = .removed
        case .skipped: result = .skipped
        case .failed: result = .failed
        }
        return OperationEntry(
            itemID: task.id, itemName: task.title, target: task.title, bytes: outcome.bytesFreed,
            mode: "command", result: result, reason: outcome.status == .done ? nil : outcome.message
        )
    }

    private func perform(_ task: OptimizeTask, early: Early?) async -> (OptimizeOutcome, [OperationEntry]?) {
        var authorized: PrivilegedResult?
        switch early {
        case .skipped(let reason):
            return (.skipped(reason), nil)
        case .authorized(let result):
            authorized = result
        case nil:
            // The gates, right before the task runs.
            if let reason = await check(task).reason { return (.skipped(reason), nil) }
        }

        switch task.action {
        case .commands(let privilegedTask, let steps):
            if let privilegedTask {
                let result: PrivilegedResult
                if let authorized {
                    result = authorized
                } else {
                    result = await privileged.run(privilegedTask, argument: nil)
                }
                guard result.succeeded else {
                    return (.failed(result.message.isEmpty ? "The admin step failed" : result.message), nil)
                }
            }
            for step in steps {
                let result = await context.runner.run(step.argv, timeout: engine.commandTimeout)
                if !result.succeeded, step.required { return (.failed(result.failureReason), nil) }
            }
            return (.done(), nil)

        case .vacuumDatabases:
            let summary = await DatabaseVacuum(context: context, timeout: engine.commandTimeout).run()
            if summary.compacted == 0, !summary.failed.isEmpty { return (.failed(summary.message), nil) }
            return (.done(summary.message, bytesFreed: summary.bytesFreed), nil)

        case .pruneNotifications:
            return (await NotificationHistory(context: context, now: now).prune(), nil)

        case .removeBrokenLaunchAgents:
            let finder = BrokenLaunchAgents(engine: engine)
            let agents = finder.find()
            guard !agents.isEmpty else { return (.skipped("None found"), nil) }
            let entries = await finder.remove(agents)
            let removed = entries.filter { $0.result == .removed }
            let bytes = removed.reduce(0) { $0 + $1.bytes }
            if removed.isEmpty {
                let reason = entries.first(where: \.isFailure)?.reason ?? entries.first?.reason ?? "Nothing was moved"
                return (entries.contains(where: \.isFailure) ? .failed(reason) : .skipped(reason), entries)
            }
            var message = "Moved \(removed.count) to the Trash"
            let rest = entries.count - removed.count
            if rest > 0 { message += ", \(rest) left in place" }
            return (.done(message, bytesFreed: bytes), entries)
        }
    }
}
