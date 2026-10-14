import Charts
import SweepDesign
import SweepKit
import SwiftUI

/// Every operation with date, items, bytes freed and failures, plus space freed per week.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<UUID> = []

    private struct Week: Identifiable {
        var id: Date { start }
        var start: Date
        var bytes: Int64
    }

    private var weeks: [Week] {
        model.engine.ledger.weeklyTotals(weeks: 12).map { Week(start: $0.weekStart, bytes: $0.bytes) }
    }

    private var totalFreed: Int64 { model.history.reduce(0) { $0 + $1.bytesFreed } }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader("History", subtitle: model.history.isEmpty
                       ? "Every clean is recorded here"
                       : "\(ByteFormat.string(totalFreed)) freed in \(model.history.count) operation\(model.history.count == 1 ? "" : "s")") {
                Button("Show Log in Finder") { Finder.reveal(model.engine.ledger.fileURL.path) }
                    .disabled(model.history.isEmpty)
            }
            if model.history.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Operations appear here after the first clean."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        chart
                        operations
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear { model.reloadHistory() }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Space freed per week").font(.headline)
            Chart(weeks) { week in
                BarMark(
                    x: .value("Week", week.start, unit: .weekOfYear),
                    y: .value("Freed", Double(week.bytes) / 1_000_000_000)
                )
                .foregroundStyle(.tint)
                .cornerRadius(4)
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let gigabytes = value.as(Double.self) {
                            Text("\(gigabytes, format: .number.precision(.fractionLength(0...1))) GB")
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 160)
        }
        .sweepCard(padding: 20)
    }

    private var operations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Operations").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(model.history.enumerated()), id: \.element.id) { index, operation in
                    VStack(alignment: .leading, spacing: 6) {
                        OperationRow(operation: operation)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.sweep) {
                                    if !expanded.insert(operation.id).inserted { expanded.remove(operation.id) }
                                }
                            }
                        if expanded.contains(operation.id) {
                            entries(of: operation)
                        }
                    }
                    .padding(.vertical, 8)
                    if index < model.history.count - 1 { Divider() }
                }
            }
        }
        .sweepCard(padding: 20)
    }

    private func entries(of operation: SweepOperation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(operation.entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: entry.result))
                        .foregroundStyle(entry.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .frame(width: 14)
                    Text(model.context.abbreviate(entry.target))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let reason = entry.reason {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(entry.mode).font(.caption).foregroundStyle(.tertiary)
                    Text(ByteFormat.string(entry.bytes))
                        .font(.system(.caption, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 32)
    }

    private func symbol(for result: OperationEntry.Result) -> String {
        switch result {
        case .removed: "checkmark"
        case .skipped: "arrow.uturn.right"
        case .refused: "hand.raised"
        case .failed: "xmark"
        case .dryRun: "eye"
        }
    }
}
