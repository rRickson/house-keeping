import AppKit
import SweepMetrics
import SwiftUI

/// A tiny CPU and memory graph for the menu bar: the last half minute of CPU
/// use as a filled line, and a slim bar at the right for memory in use.
///
/// It is drawn into a template image, so it takes the menu bar's own colour in
/// light and dark and shows up inside a `MenuBarExtra` label, which only
/// renders images and text.
///
/// ```swift
/// MenuBarExtra {
///     QuickCleanPopover()
/// } label: {
///     if settings.showsMenuBarGraph {
///         MiniMetricsGraph()          // reads MetricsSampler.shared
///     } else {
///         Image("broom")
///     }
/// }
/// ```
///
/// The graph registers with the sampler at `.glance` detail (CPU and memory
/// only) when it appears and leaves when it disappears, so sampling runs only
/// while the user has the graph switched on. An app that would rather drive
/// this from its settings passes `managesSampling: false` and calls
/// `sampler.start(.glance)` / `sampler.stop(.glance)` itself when the setting
/// changes. Give it the same sampler as `StatusView` and the two share one feed.
public struct MiniMetricsGraph: View {
    public nonisolated static let defaultSize = CGSize(width: 28, height: 16)

    private let sampler: MetricsSampler?
    private let managesSampling: Bool
    private let fixedCPU: [Double]
    private let fixedMemory: Double
    private let size: CGSize
    @State private var isObserving = false

    /// A live graph fed by a sampler.
    public init(sampler: MetricsSampler = .shared, managesSampling: Bool = true, size: CGSize = MiniMetricsGraph.defaultSize) {
        self.sampler = sampler
        self.managesSampling = managesSampling
        self.fixedCPU = []
        self.fixedMemory = 0
        self.size = size
    }

    /// A graph of fixed values, each 0 to 1, oldest first. For previews and settings.
    public init(cpu: [Double], memory: Double, size: CGSize = MiniMetricsGraph.defaultSize) {
        self.sampler = nil
        self.managesSampling = false
        self.fixedCPU = cpu
        self.fixedMemory = memory
        self.size = size
    }

    public var body: some View {
        let cpu = sampler?.history.values(.cpu) ?? fixedCPU
        let memory = sampler.map { $0.latest?.memory.usedFraction ?? 0 } ?? fixedMemory
        Image(nsImage: Self.image(cpu: cpu, memory: memory, size: size))
            .renderingMode(.template)
            .accessibilityLabel("CPU \(StatusFormat.percent(cpu.last ?? 0)) percent, memory \(StatusFormat.percent(memory)) percent")
            .onAppear {
                guard managesSampling, !isObserving, let sampler else { return }
                isObserving = true
                sampler.start(.glance)
            }
            .onDisappear {
                guard isObserving, let sampler else { return }
                isObserving = false
                sampler.stop(.glance)
            }
    }

    /// How many CPU samples fit across the graph.
    public nonisolated static let sampleSlots = 30

    /// The graph as a template image, for callers that set a status item's image directly.
    public nonisolated static func image(cpu: [Double], memory: Double, size: CGSize = MiniMetricsGraph.defaultSize) -> NSImage {
        let samples = Array(cpu.suffix(sampleSlots)).map { min(1, max(0, $0)) }
        let level = min(1, max(0, memory))
        let image = NSImage(size: size, flipped: false) { rect in
            draw(cpu: samples, memory: level, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws with black at different strengths; a template image keeps only the alpha.
    private nonisolated static func draw(cpu: [Double], memory: Double, in rect: CGRect) {
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2
        let inset: CGFloat = 1
        let plot = CGRect(x: rect.minX, y: rect.minY + inset, width: rect.width - barWidth - gap, height: rect.height - 2 * inset)

        // Memory: a track with a fill that rises from the bottom.
        let track = CGRect(x: rect.maxX - barWidth, y: plot.minY, width: barWidth, height: plot.height)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        let fill = CGRect(x: track.minX, y: track.minY, width: barWidth, height: max(barWidth, track.height * memory))
        NSColor.black.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()

        // CPU: a baseline, then the line over a soft area. The newest sample sits at the right edge.
        NSColor.black.withAlphaComponent(0.25).setFill()
        CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: 1).fill()
        guard cpu.count > 1 else { return }

        let step = plot.width / CGFloat(sampleSlots - 1)
        let lineInset: CGFloat = 0.5
        let points = cpu.enumerated().map { index, value in
            CGPoint(
                x: plot.maxX - lineInset - CGFloat(cpu.count - 1 - index) * step,
                y: plot.minY + lineInset + (plot.height - 2 * lineInset) * value
            )
        }
        let line = NSBezierPath()
        line.move(to: points[0])
        for point in points.dropFirst() { line.line(to: point) }

        let area = line.copy() as! NSBezierPath
        area.line(to: CGPoint(x: points[points.count - 1].x, y: plot.minY))
        area.line(to: CGPoint(x: points[0].x, y: plot.minY))
        area.close()
        NSColor.black.withAlphaComponent(0.3).setFill()
        area.fill()

        NSColor.black.setStroke()
        line.lineWidth = 1
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.stroke()
    }
}
