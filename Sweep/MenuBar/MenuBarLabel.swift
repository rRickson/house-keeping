import StatusUI
import SweepKit
import SwiftUI

/// What sits in the menu bar: the broom, its badge, and optionally a number.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilt: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: BroomIcon.image(
                activeDot: model.isBusy && !reduceMotion ? model.iconFrame : nil,
                badge: model.isOverThreshold && !model.isBusy,
                tilt: tilt
            ))
            if model.settings.showMenuBarGraph {
                MiniMetricsGraph(managesSampling: false)
            }
            if let text {
                Text(text).monospacedDigit()
            }
        }
        .onAppear {
            model.openMainWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onChange(of: model.iconWiggle) { wiggle() }
        .accessibilityLabel("Sweep")
    }

    private var text: String? {
        switch model.settings.menuBarDisplay {
        case .iconOnly:
            return nil
        case .iconAndReclaimable:
            guard model.lastScan != nil || model.reclaimableBytes > 0 else { return nil }
            return Self.short(model.reclaimableBytes)
        case .iconAndFreeSpace:
            return Self.short(model.disk.free)
        }
    }

    /// "18 GB": short enough for the menu bar.
    static func short(_ bytes: Int64) -> String {
        let parts = ByteFormat.parts(bytes)
        if let value = Double(parts.value), value >= 10 { return "\(Int(value.rounded())) \(parts.unit)" }
        return "\(parts.value) \(parts.unit)"
    }

    /// A single wiggle when reclaimable space crosses the threshold.
    private func wiggle() {
        guard !reduceMotion else { return }
        Task {
            for angle in [-14.0, 12.0, -8.0, 5.0, 0.0] {
                tilt = angle
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }
}
