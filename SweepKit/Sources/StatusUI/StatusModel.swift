import AppKit
import Observation
import SweepKit
import SweepMetrics
import SwiftUI

/// The state behind the Status tool: who is sampling, how the table is sorted,
/// what is pinned, and the quit flow.
@MainActor
@Observable
final class StatusModel {
    let sampler: MetricsSampler
    private let terminator: ProcessTerminator
    private let defaults: UserDefaults
    /// Set when quitting is switched off altogether (a fixture run); shown in place of the action.
    let quitUnavailableReason: String?

    var sortOrder: [KeyPathComparator<ProcessSample>] = [KeyPathComparator(\.cpuSortValue, order: .reverse)]
    var selection: ProcessSample.ID?
    /// Text typed into the filter field; empty shows every process.
    var query = ""
    private(set) var pinned: Set<String>
    /// The process waiting in the confirmation dialog.
    var pendingQuit: ProcessSample?
    /// One calm line about the last quit attempt.
    private(set) var notice: String?

    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var isWindowVisible = true
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    init(engine: SweepEngine, sampler: MetricsSampler, defaults: UserDefaults = .standard) {
        self.sampler = sampler
        self.defaults = defaults
        self.terminator = ProcessTerminator()
        self.pinned = PinnedProcesses.load(from: defaults)
        self.quitUnavailableReason = engine.context.isFixture
            ? "Quitting is off while House Keeping runs against a fixture home."
            : nil
    }

    // MARK: Sampling

    /// The view came on screen or left it.
    func setOnScreen(_ onScreen: Bool) {
        isOnScreen = onScreen
        updateObservation()
    }

    /// The window became visible, or was hidden, minimised or fully covered.
    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        updateObservation()
    }

    /// Samples only while the tool is on screen in a window somebody can see.
    private func updateObservation() {
        let shouldObserve = isOnScreen && isWindowVisible
        guard shouldObserve != isObserving else { return }
        isObserving = shouldObserve
        if shouldObserve {
            sampler.start(.processes)
        } else {
            sampler.stop(.processes)
        }
    }

    // MARK: Table

    var sort: ProcessSort {
        guard let first = sortOrder.first else { return .default }
        let ascending = first.order == .forward
        let keyPath: AnyKeyPath = first.keyPath
        if keyPath == \ProcessSample.cpuSortValue { return ProcessSort(.cpu, ascending: ascending) }
        if keyPath == \ProcessSample.memorySortValue { return ProcessSort(.memory, ascending: ascending) }
        if keyPath == \ProcessSample.name { return ProcessSort(.name, ascending: ascending) }
        if keyPath == \ProcessSample.pid { return ProcessSort(.pid, ascending: ascending) }
        if keyPath == \ProcessSample.userSortValue { return ProcessSort(.user, ascending: ascending) }
        return .default
    }

    var rows: [ProcessSample] {
        ProcessOrdering.sorted(ProcessOrdering.filtered(sampler.processes, matching: query), by: sort, pinned: pinned)
    }

    var selected: ProcessSample? {
        guard let selection else { return nil }
        return sampler.processes.first { $0.pid == selection }
    }

    func process(_ id: ProcessSample.ID) -> ProcessSample? {
        sampler.processes.first { $0.pid == id }
    }

    func isPinned(_ process: ProcessSample) -> Bool { pinned.contains(process.name) }

    func togglePin(_ process: ProcessSample) {
        pinned = PinnedProcesses.toggling(process.name, in: pinned)
        PinnedProcesses.save(pinned, to: defaults)
    }

    func icon(for process: ProcessSample) -> NSImage? {
        guard let path = process.bundlePath else { return nil }
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    // MARK: Quit

    /// Why this process cannot be quit; nil when it can.
    func quitRefusal(for process: ProcessSample) -> String? {
        quitUnavailableReason ?? terminator.refusal(for: process)?.errorDescription
    }

    func askToQuit(_ process: ProcessSample) {
        guard quitRefusal(for: process) == nil else { return }
        pendingQuit = process
    }

    func quit(_ process: ProcessSample, force: Bool) {
        guard quitUnavailableReason == nil else { return }
        do {
            try terminator.quit(process, force: force)
            show(force ? "Forced \(process.name) to quit." : "Asked \(process.name) to quit.")
            if selection == process.pid { selection = nil }
        } catch {
            show(error.errorDescription ?? "\(process.name) could not be quit.")
        }
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
