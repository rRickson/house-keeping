import Foundation
import Observation
import SweepKit
import SweepOptimize

/// State of the Optimize list: which tasks are ticked, what holds a task back,
/// and how the current run is going.
@MainActor
@Observable
final class OptimizeModel {
    enum Phase: Equatable {
        case idle
        /// Covered by the password prompt that is on screen.
        case authorizing
        case running
        case finished(OptimizeOutcome)
    }

    struct Row: Identifiable {
        let task: OptimizeTask
        var isSelected: Bool
        /// Nil until the gates have been evaluated once.
        var check: TaskCheck?
        var phase: Phase = .idle

        var id: String { task.id }

        /// Ticked and free to run.
        var willRun: Bool { isSelected && (check?.isReady ?? false) }
    }

    private(set) var rows: [Row]
    private(set) var availability: PrivilegedAvailability?
    private(set) var isRunning = false
    private(set) var finishedCount = 0
    private(set) var runCount = 0
    /// Bumped when a run ends, to play the completion effect once.
    private(set) var completedRuns = 0

    private let runner: OptimizeRunner

    init(engine: SweepEngine, privileged: any PrivilegedRunning) {
        runner = OptimizeRunner(engine: engine, privileged: privileged)
        rows = OptimizeCatalog.all.map { Row(task: $0, isSelected: $0.selectedByDefault) }
    }

    var selectedCount: Int { rows.filter(\.willRun).count }

    var actionTitle: String {
        if isRunning { return "Running \(min(finishedCount + 1, runCount)) of \(runCount)" }
        switch selectedCount {
        case 0: return "Run tasks"
        case 1: return "Run 1 task"
        default: return "Run \(selectedCount) tasks"
        }
    }

    /// Re-evaluates every gate. Cheap enough to call whenever the tool comes to the front.
    func refresh() async {
        guard !isRunning else { return }
        let checks = await runner.check(rows.map(\.task))
        let availability = await runner.privileged.availability
        guard !isRunning else { return }
        self.availability = availability
        for index in rows.indices {
            rows[index].check = checks[rows[index].task.id]
        }
    }

    func toggle(_ id: String) {
        guard !isRunning, let index = rows.firstIndex(where: { $0.id == id }), rows[index].check?.isReady == true else { return }
        rows[index].isSelected.toggle()
        rows[index].phase = .idle
    }

    func setSelected(_ id: String, _ selected: Bool) {
        guard !isRunning, let index = rows.firstIndex(where: { $0.id == id }), rows[index].isSelected != selected else { return }
        rows[index].isSelected = selected
        rows[index].phase = .idle
    }

    func run() {
        guard !isRunning else { return }
        let tasks = rows.filter(\.willRun).map(\.task)
        guard !tasks.isEmpty else { return }
        isRunning = true
        finishedCount = 0
        runCount = tasks.count
        for index in rows.indices { rows[index].phase = .idle }

        let runner = self.runner
        let (events, continuation) = AsyncStream.makeStream(of: OptimizeEvent.self)
        Task.detached(priority: .userInitiated) {
            await runner.run(tasks, source: "window") { continuation.yield($0) }
            continuation.finish()
        }
        Task {
            for await event in events { apply(event) }
            isRunning = false
            completedRuns += 1
            await refresh()
        }
    }

    private func apply(_ event: OptimizeEvent) {
        switch event {
        case .authorizing(let ids):
            for index in rows.indices where ids.contains(rows[index].id) { rows[index].phase = .authorizing }
        case .started(let id):
            setPhase(.running, for: id)
        case .finished(let id, let outcome):
            setPhase(.finished(outcome), for: id)
            finishedCount += 1
        }
    }

    private func setPhase(_ phase: Phase, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].phase = phase
    }
}
