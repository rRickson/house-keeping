import SweepDesign
import SweepKit
import SwiftUI

/// What is selected, at a glance: the total, a bar made of one coloured
/// segment per cache, the biggest ones by name, and how many are Caution.
struct SelectionSummary: View {
    @Environment(AppModel.self) private var model
    var legendCount = 4

    private var selected: [ScanResult] { model.checkedResults.sorted { $0.bytes > $1.bytes } }

    var body: some View {
        let selected = self.selected
        let total = selected.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let cleaning = model.cleaning {
                    SizeText(cleaning.freed, font: .system(size: 30, weight: .light), unitFont: .system(.callout))
                        .foregroundStyle(Night.text)
                    Text("freed of \(ByteFormat.string(cleaning.total))")
                        .font(.callout)
                        .foregroundStyle(Night.secondary)
                } else {
                    SizeText(total, font: .system(size: 30, weight: .light), unitFont: .system(.callout))
                        .foregroundStyle(Night.text)
                    Text(selected.isEmpty ? "nothing selected" : "in \(selected.count) cache\(selected.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(Night.secondary)
                }
                Spacer()
                tierCounts(selected)
            }

            bar(selected, total: total)

            if !selected.isEmpty {
                legend(selected, total: total)
            } else {
                Text("Pick a preset or tap the cards below.")
                    .font(.caption)
                    .foregroundStyle(Night.tertiary)
            }
        }
        .padding(14)
        .nightCard()
        .animation(.sweep, value: selected.map(\.id))
    }

    private func tierCounts(_ selected: [ScanResult]) -> some View {
        HStack(spacing: 10) {
            ForEach([RiskTier.safe, .caution], id: \.self) { tier in
                let count = selected.filter { $0.item.risk == tier }.count
                if count > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(tier.color).frame(width: 6, height: 6)
                        Text("\(count) \(tier.title)")
                            .font(.caption)
                            .foregroundStyle(Night.secondary)
                    }
                }
            }
        }
    }

    /// One segment per selected cache, in its colour, as wide as its share.
    private func bar(_ selected: [ScanResult], total: Int64) -> some View {
        GeometryReader { proxy in
            let gaps = CGFloat(max(selected.count - 1, 0)) * 2
            let usable = max(proxy.size.width - gaps, 0)
            HStack(spacing: 2) {
                if selected.isEmpty || total == 0 {
                    Capsule().fill(Color.white.opacity(0.08))
                } else {
                    ForEach(selected) { result in
                        Rectangle()
                            .fill(result.item.tintColor)
                            .frame(width: max(usable * CGFloat(result.bytes) / CGFloat(total), 2))
                            .help("\(result.item.name) · \(ByteFormat.string(result.bytes))")
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
    }

    private func legend(_ selected: [ScanResult], total: Int64) -> some View {
        let shown = Array(selected.prefix(legendCount))
        let rest = selected.dropFirst(legendCount)
        let columns = [GridItem(.flexible(), spacing: 12, alignment: .leading), GridItem(.flexible(), spacing: 12, alignment: .leading)]
        return VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(shown) { result in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(result.item.tintColor).frame(width: 8, height: 8)
                        Text(result.item.name)
                            .lineLimit(1)
                            .foregroundStyle(Night.text.opacity(0.85))
                        Spacer(minLength: 4)
                        Text(ByteFormat.string(result.bytes))
                            .monospacedDigit()
                            .foregroundStyle(Night.secondary)
                    }
                    .font(.caption)
                }
            }
            if !rest.isEmpty {
                let restBytes = rest.reduce(Int64(0)) { $0 + $1.bytes }
                Text("and \(rest.count) more · \(ByteFormat.string(restBytes))")
                    .font(.caption)
                    .foregroundStyle(Night.tertiary)
            }
        }
    }
}
