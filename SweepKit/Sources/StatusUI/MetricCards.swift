import SweepDesign
import SweepKit
import SweepMetrics
import SwiftUI

enum StatusFont {
    /// Headline numbers: SF Pro Rounded, so they match every other total in Sweep.
    static let number = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let unit = Font.system(size: 15, design: .rounded)
    /// The smaller numbers of a card that shows two values side by side.
    static let pairedNumber = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let pairedUnit = Font.system(size: 13, design: .rounded)
}

/// The frame every metric shares: what it is, the number, the last minute, one line of detail.
struct MetricCard<Value: View, Footer: View>: View {
    let title: String
    let symbol: String
    var status: String?
    var chart: Sparkline?
    @ViewBuilder var value: Value
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: SweepMetric.grid) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: SweepMetric.grid)
                if let status { Text(status).lineLimit(1) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            value
                .frame(height: 40, alignment: .bottomLeading)

            Group {
                if let chart { chart } else { Color.clear }
            }
            .frame(height: 36)

            footer
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sweepCard(padding: 2 * SweepMetric.grid)
        .accessibilityElement(children: .combine)
    }
}

/// A headline number with a quieter unit.
struct BigNumber: View {
    let text: String
    var unit: String?
    /// Drives the rolling-digit transition; nil for words such as "Normal".
    var value: Double?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(text)
                .font(StatusFont.number)
                .monospacedDigit()
                .contentTransition(value.map { .numericText(value: $0) } ?? .opacity)
            if let unit {
                Text(unit)
                    .font(StatusFont.unit)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .sweepAnimation(value: text)
    }
}

/// One of two rates on a card, with the marker that ties it to its line.
struct RateValue: View {
    let label: String
    let bytesPerSecond: Double?
    let emphasis: SparklineSeries.Emphasis

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Circle()
                    .fill(emphasis == .primary ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let bytesPerSecond {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    SizeText(Int64(bytesPerSecond.rounded()), font: StatusFont.pairedNumber, unitFont: StatusFont.pairedUnit)
                    Text("/s")
                        .font(StatusFont.pairedUnit)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            } else {
                Text("—").font(StatusFont.pairedNumber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(bytesPerSecond.map { "\(ByteFormat.string(Int64($0))) per second" } ?? "Not available")
    }
}

/// One small bar per logical core.
struct CoreBars: View {
    let usage: [Double]
    private let height: CGFloat = 16

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(usage.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.quaternary)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(.tint)
                            .frame(height: max(2, height * min(1, max(0, value))))
                    }
                    .frame(maxWidth: 10)
            }
        }
        .frame(height: height)
        .sweepAnimation(value: usage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(usage.count) cores")
    }
}

/// The grid of live metrics.
struct MetricsGrid: View {
    let snapshot: MetricsSnapshot?
    let history: MetricsHistory

    private let columns = [GridItem(.adaptive(minimum: 208, maximum: 480), spacing: 2 * SweepMetric.grid)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2 * SweepMetric.grid) {
            cpu
            memory
            gpu
            disk
            network
            battery
            thermal
            uptime
        }
    }

    private func line(_ metric: MetricSeries, _ emphasis: SparklineSeries.Emphasis = .primary) -> SparklineSeries {
        SparklineSeries(id: metric.rawValue, points: history.points(metric), emphasis: emphasis)
    }

    private func sparkline(_ series: [SparklineSeries], ceiling: Double) -> Sparkline {
        Sparkline(series: series, window: history.indexRange, ceiling: ceiling)
    }

    // MARK: Cards

    private var cpu: some View {
        MetricCard(
            title: "CPU",
            symbol: "cpu",
            status: snapshot.map { "\($0.cpu.coreCount) cores" },
            chart: sparkline([line(.cpu)], ceiling: 1)
        ) {
            if let cpu = snapshot?.cpu {
                BigNumber(text: StatusFormat.percent(cpu.usage), unit: "%", value: cpu.usage * 100)
            } else {
                BigNumber(text: "—")
            }
        } footer: {
            CoreBars(usage: snapshot?.cpu.perCore ?? [])
        }
    }

    private var memory: some View {
        MetricCard(
            title: "Memory",
            symbol: "memorychip",
            status: snapshot.map { "Pressure \(StatusFormat.pressureTitle($0.memory.pressure))" },
            chart: sparkline([line(.memoryPressure)], ceiling: 1)
        ) {
            if let memory = snapshot?.memory {
                let used = StatusFormat.memoryParts(memory.used)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    BigNumber(text: used.value, unit: used.unit, value: Double(memory.used))
                    Text("of \(StatusFormat.memory(memory.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            } else {
                BigNumber(text: "—")
            }
        } footer: {
            if let memory = snapshot?.memory {
                Text(memory.swapUsed > 0
                    ? "Swap \(StatusFormat.memory(memory.swapUsed)) · Compressed \(StatusFormat.memory(memory.compressed))"
                    : "No swap in use · Compressed \(StatusFormat.memory(memory.compressed))")
            }
        }
    }

    private var gpu: some View {
        MetricCard(
            title: "GPU",
            symbol: "square.stack.3d.up",
            chart: sparkline([line(.gpu)], ceiling: 1)
        ) {
            if let gpu = snapshot?.gpu {
                BigNumber(text: StatusFormat.percent(gpu.utilization), unit: "%", value: gpu.utilization * 100)
            } else {
                BigNumber(text: "—")
            }
        } footer: {
            if let gpu = snapshot?.gpu {
                Text(gpu.name ?? "Graphics processor")
            } else if snapshot != nil {
                Text("This Mac does not report GPU use")
            }
        }
    }

    private var disk: some View {
        MetricCard(
            title: "Disk",
            symbol: "internaldrive",
            chart: sparkline(
                [line(.diskWrite, .secondary), line(.diskRead)],
                ceiling: history.ceiling(.diskRead, .diskWrite, floor: 1_000_000)
            )
        ) {
            HStack(alignment: .bottom, spacing: SweepMetric.grid) {
                RateValue(label: "Read", bytesPerSecond: snapshot?.disk?.readBytesPerSecond, emphasis: .primary)
                RateValue(label: "Write", bytesPerSecond: snapshot?.disk?.writeBytesPerSecond, emphasis: .secondary)
            }
        } footer: {
            if let disk = snapshot?.disk {
                Text("\(ByteFormat.string(Int64(clamping: disk.totalWritten))) written since startup")
            }
        }
    }

    private var network: some View {
        MetricCard(
            title: "Network",
            symbol: "network",
            chart: sparkline(
                [line(.networkOut, .secondary), line(.networkIn)],
                ceiling: history.ceiling(.networkIn, .networkOut, floor: 100_000)
            )
        ) {
            HStack(alignment: .bottom, spacing: SweepMetric.grid) {
                RateValue(label: "In", bytesPerSecond: snapshot?.network?.inBytesPerSecond, emphasis: .primary)
                RateValue(label: "Out", bytesPerSecond: snapshot?.network?.outBytesPerSecond, emphasis: .secondary)
            }
        } footer: {
            if let network = snapshot?.network {
                Text(network.interfaces.isEmpty
                    ? "No network interface"
                    : "Peak \(ByteFormat.string(Int64(history.peak(.networkIn, .networkOut))))/s this minute")
            }
        }
    }

    private var battery: some View {
        let sample = snapshot?.battery
        return MetricCard(
            title: "Battery",
            symbol: sample?.isCharging == true ? "battery.100percent.bolt" : "battery.75percent",
            status: sample.map(batteryStatus),
            chart: sparkline([line(.battery)], ceiling: 1)
        ) {
            if let sample {
                BigNumber(text: StatusFormat.percent(sample.charge), unit: "%", value: sample.charge * 100)
            } else {
                BigNumber(text: "—")
            }
        } footer: {
            if let sample {
                Text(batteryDetail(sample))
            } else if snapshot != nil {
                Text("This Mac has no battery")
            }
        }
    }

    private func batteryStatus(_ battery: BatterySample) -> String {
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return battery.isFull ? "Charged" : "Plugged In" }
        if let minutes = battery.minutesRemaining { return "\(StatusFormat.remaining(minutes: minutes)) left" }
        return "On Battery"
    }

    private func batteryDetail(_ battery: BatterySample) -> String {
        var parts: [String] = []
        if let health = battery.health { parts.append("Health \(StatusFormat.percent(health))%") }
        if let cycles = battery.cycleCount { parts.append("\(cycles) cycles") }
        return parts.isEmpty ? "Health not reported" : parts.joined(separator: " · ")
    }

    private var thermal: some View {
        MetricCard(
            title: "Thermal State",
            symbol: "thermometer.medium",
            chart: sparkline([line(.thermal)], ceiling: 3)
        ) {
            BigNumber(text: snapshot.map { StatusFormat.thermalTitle($0.thermal) } ?? "—")
        } footer: {
            if let snapshot { Text(StatusFormat.thermalDetail(snapshot.thermal)) }
        }
    }

    private var uptime: some View {
        MetricCard(
            title: "Uptime",
            symbol: "clock",
            status: snapshot?.cpu.loadAverage.first.map { "Load \(StatusFormat.load($0))" },
            chart: sparkline([line(.load)], ceiling: history.ceiling(.load, floor: 2))
        ) {
            BigNumber(text: snapshot.map { StatusFormat.uptime($0.uptime) } ?? "—")
        } footer: {
            if let snapshot {
                Text("Since \(StatusFormat.moment(snapshot.date.addingTimeInterval(-snapshot.uptime)))")
            }
        }
    }
}
