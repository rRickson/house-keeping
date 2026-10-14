import AppKit
import SweepDesign
import SweepKit
import SweepMetrics
import SwiftUI

/// The Status tool: a grid of live metrics over the process table.
///
/// The view samples only while it is on screen in a visible window. It
/// registers with the sampler when it appears and leaves when it disappears or
/// its window is hidden, so nothing keeps running once the user looks away.
public struct StatusView: View {
    @State private var model: StatusModel

    /// Uses `MetricsSampler.shared`, the same feed the menu bar graph reads.
    public init(engine: SweepEngine) {
        self.init(engine: engine, sampler: .shared)
    }

    /// Uses a sampler the app owns.
    public init(engine: SweepEngine, sampler: MetricsSampler) {
        self.init(model: StatusModel(engine: engine, sampler: sampler))
    }

    init(model: StatusModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ToolHeader("Status", subtitle: Self.subtitle)
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3 * SweepMetric.grid) {
                        MetricsGrid(snapshot: model.sampler.latest, history: model.sampler.history)
                        processes
                            // Tall enough to work in on its own once the cards are scrolled away.
                            .frame(height: max(320, proxy.size.height - 11 * SweepMetric.grid))
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, model.selected == nil ? 20 : 88)
                }
            }
        }
        .overlay(alignment: .bottom) { actionBar }
        .sweepAnimation(value: model.selection)
        .background(WindowVisibilityReader { visible in model.setWindowVisible(visible) })
        .onAppear { model.setOnScreen(true) }
        .onDisappear { model.setOnScreen(false) }
        .confirmationDialog(
            "Quit “\(model.pendingQuit?.name ?? "")”?",
            isPresented: Binding(
                get: { model.pendingQuit != nil },
                set: { presented in if !presented { model.pendingQuit = nil } }
            ),
            presenting: model.pendingQuit
        ) { process in
            Button("Quit") { model.quit(process, force: false) }
            Button("Force Quit") { model.quit(process, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Changes that have not been saved in this process may be lost.")
        }
    }

    private static let subtitle: String = {
        var parts: [String] = []
        if let chip = HostInfo.chipName { parts.append(chip) }
        parts.append("\(HostInfo.logicalCores) cores")
        parts.append("\(StatusFormat.memory(HostInfo.memoryBytes)) memory")
        return parts.joined(separator: " · ")
    }()

    private var processes: some View {
        @Bindable var model = model
        let rows = model.rows
        return VStack(alignment: .leading, spacing: SweepMetric.grid) {
            HStack(alignment: .firstTextBaseline, spacing: SweepMetric.grid) {
                Text("Processes")
                    .font(.headline)
                Text("\(rows.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: SweepMetric.grid)
                if let notice = model.notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                TextField("Filter", text: $model.query, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 176)
                    .accessibilityLabel("Filter processes")
            }
            .sweepAnimation(value: model.notice)

            ProcessTable(model: model, rows: rows)
                .clipShape(RoundedRectangle(cornerRadius: SweepMetric.cardRadius, style: .continuous))
        }
    }

    /// The one action of this screen, shown once a process is selected.
    @ViewBuilder
    private var actionBar: some View {
        if let process = model.selected {
            let refusal = model.quitRefusal(for: process)
            FloatingActionBar(
                "Quit Process",
                systemImage: "xmark.circle",
                isEnabled: refusal == nil,
                action: { model.askToQuit(process) }
            ) {
                HStack(spacing: SweepMetric.grid) {
                    ProcessIcon(image: model.icon(for: process))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(process.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let refusal {
                            Text(refusal)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)

                    Button {
                        model.togglePin(process)
                    } label: {
                        Image(systemName: model.isPinned(process) ? "pin.slash" : "pin")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help(model.isPinned(process) ? "Unpin" : "Pin to Top")
                    .accessibilityLabel(model.isPinned(process) ? "Unpin" : "Pin to Top")
                }
                .padding(.leading, SweepMetric.grid)
            }
            .transition(.opacity)
        }
    }
}

/// Reports whether the window that holds it can be seen at all. A minimised,
/// hidden or completely covered window reports false.
private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            report()
        }

        @objc private func occlusionChanged() { report() }

        /// Reports on the next turn of the main loop: this is called while AppKit
        /// is still building the view hierarchy, and changing state the views
        /// read from inside that pass is not allowed.
        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible)
            Task { @MainActor [weak self] in self?.onChange?(visible) }
        }
    }
}
