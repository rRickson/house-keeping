import Charts
import SweepDesign
import SweepMetrics
import SwiftUI

/// One line on a sparkline.
struct SparklineSeries: Identifiable {
    enum Emphasis {
        /// The accent colour.
        case primary
        /// A neutral grey, for the second of two lines.
        case secondary
    }

    let id: String
    let points: [MetricPoint]
    var emphasis: Emphasis = .primary

    var style: AnyShapeStyle {
        switch emphasis {
        case .primary: AnyShapeStyle(.tint)
        // A colour, not the hierarchical `.secondary` style: inside a chart
        // that style resolves against the chart's own default blue.
        case .secondary: AnyShapeStyle(Color.secondary)
        }
    }
}

/// A 60-second sparkline: a smooth line over an area that fades to transparent.
///
/// The x-axis is the sample number, so every point keeps its identity while
/// the window slides one step to the left each second.
struct Sparkline: View {
    let series: [SparklineSeries]
    /// Sample numbers the plot covers.
    let window: ClosedRange<Int>
    /// The value at the top of the plot.
    let ceiling: Double

    var body: some View {
        ZStack {
            // The area is drawn flat and then faded with a mask, so it can use
            // the tint (which is a style, not a colour) and still end transparent.
            chart(area: true)
                .mask(LinearGradient(
                    colors: [.black.opacity(0.36), .black.opacity(0)],
                    startPoint: UnitPoint(x: 0.5, y: fadeStart),
                    endPoint: .bottom
                ))
            chart(area: false)
        }
        .sweepAnimation(value: window.upperBound)
        .accessibilityHidden(true)
    }

    /// Where the fade begins, as a fraction of the plot height from the top:
    /// level with the highest point drawn, so a low line still gets a visible fill.
    private var fadeStart: CGFloat {
        let peak = series.flatMap(\.points).map(\.value).max() ?? 0
        guard ceiling > 0 else { return 0 }
        return CGFloat(min(0.85, max(0, 1 - peak / ceiling)))
    }

    private func chart(area: Bool) -> some View {
        Chart {
            ForEach(series) { line in
                ForEach(line.points) { point in
                    if area {
                        AreaMark(
                            x: .value("Sample", point.index),
                            y: .value("Value", point.value),
                            series: .value("Series", line.id),
                            stacking: .unstacked
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(line.style)
                    } else {
                        LineMark(
                            x: .value("Sample", point.index),
                            y: .value("Value", point.value),
                            series: .value("Series", line.id)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(line.style)
                    }
                }
            }
        }
        .chartXScale(domain: window.lowerBound...window.upperBound)
        .chartYScale(domain: 0...max(ceiling, .leastNonzeroMagnitude))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .clipped()
    }
}

extension MetricsHistory {
    /// A plot ceiling for rates: a little above the window's peak, and never
    /// below `floor` so an idle line stays flat instead of magnifying noise.
    func ceiling(_ metrics: MetricSeries..., floor: Double) -> Double {
        let peak = metrics.reduce(0) { best, metric in max(best, values(metric).max() ?? 0) }
        return max(floor, peak * 1.15)
    }
}
