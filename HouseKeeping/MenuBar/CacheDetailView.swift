import SweepDesign
import SweepKit
import SwiftUI

/// One cache up close: its size as a big number, a slider, and four facts.
struct CacheDetailView: View {
    @Environment(AppModel.self) private var model
    let id: String
    let back: () -> Void
    @State private var confirmCaution = false

    var body: some View {
        if let result = model.results[id] {
            content(result)
        } else {
            ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func content(_ result: ScanResult) -> some View {
        let isErasing = model.cleaning?.active.contains(id) == true
        return VStack(alignment: .leading, spacing: 18) {
            // Title row.
            HStack(spacing: 12) {
                NightCircleButton(symbol: "chevron.left", size: 36, action: back)
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.item.name)
                        .font(.headline)
                        .foregroundStyle(Night.text)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(result.item.risk.color).frame(width: 6, height: 6)
                        Text(subtitle(result))
                            .font(.caption)
                            .foregroundStyle(Night.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                NightCircleButton(symbol: "sparkles", size: 50, prominent: true,
                                  progress: isErasing ? 0.6 : nil,
                                  isEnabled: canErase(result)) { erase(result) }
                    .help("Erase now")
            }

            // The size, big.
            HStack(alignment: .firstTextBaseline) {
                let parts = ByteFormat.parts(outcomeBytes(result) ?? result.bytes)
                Text(parts.value)
                    .font(.system(size: 64, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(Night.text)
                    .contentTransition(.numericText())
                Text(parts.unit)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(Night.blueLight)
                Spacer()
                selectionSwitch(result)
            }
            .animation(.sweep, value: result.bytes)

            if let caption = outcomeCaption(result) {
                Text(caption.text)
                    .font(.callout)
                    .foregroundStyle(caption.isError ? Night.failure : Night.green)
                    .padding(.top, -12)
            }

            slider(result)

            // Four facts, like the controls under a device.
            HStack(spacing: 8) {
                FactTile(symbol: isCommand(result) ? "terminal" : "trash", caption: "Mode",
                         value: isCommand(result) ? "Command" : "Delete", help: result.actionDescription)
                FactTile(symbol: "shield", caption: "Risk", value: result.item.risk.title,
                         accent: result.item.risk.color, help: result.item.risk.explanation)
                FactTile(symbol: "folder", caption: "Found", value: foundBy(result), showsArrow: !result.roots.isEmpty,
                         help: result.roots.first.map(model.context.abbreviate) ?? "") {
                    if let root = result.roots.first { Finder.reveal(root) }
                }
                FactTile(symbol: "clock", caption: "Changed", value: result.lastModified.map(Self.short) ?? "—")
            }

            if let note = result.item.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Night.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .confirmationDialog("Erase \(result.item.name)?", isPresented: $confirmCaution) {
            Button("Erase \(ByteFormat.string(result.bytes))") { model.clean([CleanSelection(result)], source: "menubar") }
        } message: {
            Text(result.item.note ?? RiskTier.caution.explanation)
        }
    }

    // MARK: Pieces

    /// "Include in clean", the counterpart of the reference's Eco Mode switch.
    private func selectionSwitch(_ result: ScanResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(Night.secondary)
            Text("Selected")
                .font(.callout.weight(.medium))
                .foregroundStyle(Night.text)
                .fixedSize()
            Toggle("", isOn: Binding(get: { model.isChecked(result) }, set: { model.setChecked(result, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!model.isCheckable(result) || model.cleaning != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Night.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Night.stroke, lineWidth: 1))
    }

    /// Agent history items get a real slider: how many days untouched makes a session old.
    /// Everything else shows its share of what can be reclaimed.
    @ViewBuilder
    private func slider(_ result: ScanResult) -> some View {
        if result.item.group == .aiAgents, result.item.risk == .caution, result.item.clean.olderThanDays != nil {
            @Bindable var model = model
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    NightCircleButton(symbol: "minus", size: 34) { model.settings.oldSessionDays = max(1, model.settings.oldSessionDays - 1) }
                    NightSlider(value: Binding(get: { Double(model.settings.oldSessionDays) },
                                               set: { model.settings.oldSessionDays = Int($0.rounded()) }),
                                range: 1...90, label: "\(model.settings.oldSessionDays)d")
                    NightCircleButton(symbol: "plus", size: 34) { model.settings.oldSessionDays = min(90, model.settings.oldSessionDays + 1) }
                }
                HStack {
                    Text("Old after 1 day")
                    Spacer()
                    Text("90 days")
                }
                .font(.caption)
                .foregroundStyle(Night.tertiary)
                .padding(.horizontal, 44)
            }
        } else {
            let total = max(model.checkableResults.reduce(Int64(0)) { $0 + $1.bytes }, result.bytes, 1)
            let share = Double(result.bytes) / Double(total)
            VStack(spacing: 8) {
                NightSlider(value: .constant(share), range: 0...1, label: "\(Int((share * 100).rounded()))%", isInteractive: false)
                HStack {
                    Text("Share of what can be cleaned")
                    Spacer()
                    Text(ByteFormat.string(total))
                }
                .font(.caption)
                .foregroundStyle(Night.tertiary)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Helpers

    private func subtitle(_ result: ScanResult) -> String {
        if let reason = result.status.reason { return reason }
        return result.roots.first.map(model.context.abbreviate) ?? result.actionDescription
    }

    private func isCommand(_ result: ScanResult) -> Bool {
        result.targets.contains { if case .command = $0.action { true } else { false } }
    }

    private func foundBy(_ result: ScanResult) -> String {
        switch result.source {
        case .tool: "Tool"
        case .environment(let name): "$\(name)"
        case .defaultPath: "Default"
        case .handler: "Tool"
        case .none: "—"
        }
    }

    private func canErase(_ result: ScanResult) -> Bool {
        result.status.isReady && result.bytes > 0 && !result.selectable && result.item.risk != .ask && model.cleaning == nil
    }

    private func erase(_ result: ScanResult) {
        if result.item.risk == .caution {
            confirmCaution = true
        } else {
            model.quickErase(result)
        }
    }

    private func outcomeBytes(_ result: ScanResult) -> Int64? {
        if case .freed(let bytes) = model.outcomes[result.id], bytes > 0, result.bytes == 0 { return bytes }
        return nil
    }

    private func outcomeCaption(_ result: ScanResult) -> (text: String, isError: Bool)? {
        switch model.outcomes[result.id] {
        case .freed(let bytes) where bytes > 0: ("Freed \(ByteFormat.string(bytes))", false)
        case .failed(let reason): (reason, true)
        case .skipped(let reason): (reason, true)
        default: nil
        }
    }

    private static func short(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "en_US")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// A thick slider: a blue fill, faint tick marks, and a white handle.
struct NightSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var label: String = ""
    var isInteractive = true

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knob: CGFloat = 30
            let x = max(knob / 2, min(width - knob / 2, width * fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                    .overlay(Capsule().strokeBorder(Night.stroke, lineWidth: 1))
                // Tick marks along the empty part.
                HStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { _ in
                        Spacer()
                        Capsule().fill(Color.white.opacity(0.12)).frame(width: 1.5, height: 12)
                    }
                    Spacer()
                }
                Capsule()
                    .fill(LinearGradient(colors: [Night.blue, Night.blueLight], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(x + knob / 2, knob))
                if isInteractive {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                        .frame(width: knob, height: 44)
                        .overlay(Capsule().fill(Color.black.opacity(0.18)).frame(width: 3, height: 14))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        .offset(x: x - knob / 2)
                } else {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .padding(.leading, 12)
                }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard isInteractive else { return }
                let fraction = min(max(drag.location.x / width, 0), 1)
                value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { direction in
            guard isInteractive else { return }
            let step = (range.upperBound - range.lowerBound) / 90
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

/// One fact under the slider: icon, caption, value.
private struct FactTile: View {
    let symbol: String
    let caption: String
    let value: String
    var accent: Color?
    var showsArrow = false
    var help = ""
    var action: (() -> Void)?

    var body: some View {
        let tile = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(Night.blueLight)
                Spacer()
                if let accent {
                    Circle().fill(accent).frame(width: 7, height: 7).padding(.top, 4)
                } else if showsArrow {
                    Image(systemName: "arrow.up.right").font(.caption2.weight(.bold)).foregroundStyle(Night.tertiary)
                }
            }
            Spacer(minLength: 10)
            Text(caption).font(.caption).foregroundStyle(Night.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Night.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .leading)
        .nightCard(radius: Night.tileRadius)
        .help(help)

        if let action {
            Button(action: action) { tile }.buttonStyle(.plain)
        } else {
            tile
        }
    }
}
