import AppKit
import SweepDesign
import SweepKit
import SweepOptimize
import SwiftUI

/// The Optimize tool: a one-tap list of maintenance tasks.
public struct OptimizeView: View {
    @State private var model: OptimizeModel

    /// - Parameter privileged: runs the admin tasks; the app passes its `HelperClient`.
    public init(engine: SweepEngine, privileged: any PrivilegedRunning) {
        _model = State(initialValue: OptimizeModel(engine: engine, privileged: privileged))
    }

    /// For previews and snapshot checks, which need a model that is already filled in.
    init(model: OptimizeModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolHeader("Optimize", subtitle: "Routine maintenance in one tap. Nothing here touches your documents.")
            ScrollView {
                VStack(alignment: .leading, spacing: SweepMetric.grid * 2) {
                    VStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            OptimizeRow(
                                row: row,
                                isLocked: model.isRunning,
                                toggle: { model.toggle(row.id) },
                                setSelected: { model.setSelected(row.id, $0) }
                            )
                        }
                    }
                    .sweepCard(padding: SweepMetric.grid)

                    AdminFootnote(availability: model.availability)
                        .padding(.horizontal, SweepMetric.grid)
                }
                .padding(.horizontal, 20)
                // Room for the floating bar, so the last row is never under it.
                .padding(.bottom, 96)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            FloatingActionBar(
                model.actionTitle,
                systemImage: "bolt",
                isBusy: model.isRunning,
                isEnabled: model.selectedCount > 0,
                action: model.run
            )
        }
        .sweepAnimation(value: model.isRunning)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: model.completedRuns) { _, _ in Haptics.done() }
    }
}

/// How admin tasks are authorised, in one calm line.
private struct AdminFootnote: View {
    let availability: PrivilegedAvailability?

    private var text: String? {
        switch availability {
        case .helper:
            "Admin tasks run through Sweep's helper, which accepts only the tasks in this list."
        case .passwordPrompt:
            "Admin tasks ask for your password once per run. Install the helper in Settings to skip the prompt."
        case .unavailable:
            "Admin tasks are not available here."
        case nil:
            nil
        }
    }

    var body: some View {
        if let text {
            Label {
                Text(text)
            } icon: {
                Image(systemName: availability == .helper ? "checkmark.shield" : "lock")
                    .symbolRenderingMode(.hierarchical)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
