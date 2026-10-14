import Foundation

/// Squarified treemap layout (Bruls, Huizing and van Wijk): rectangles whose
/// areas are proportional to their sizes and whose shapes stay close to square.
public enum Treemap {
    /// Lays `sizes` out inside `bounds`.
    ///
    /// Returns one rectangle per size, in the order given. Sizes that are zero,
    /// negative or not finite get an empty rectangle. The rectangles of the
    /// positive sizes tile `bounds` exactly: no gaps and no overlaps.
    public static func squarify(_ sizes: [Double], in bounds: CGRect) -> [CGRect] {
        let bounds = bounds.isNull || bounds.isInfinite ? .zero : bounds.standardized
        var rects = [CGRect](repeating: CGRect(origin: bounds.origin, size: .zero), count: sizes.count)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return rects }

        var order = sizes.indices.filter { sizes[$0] > 0 && sizes[$0].isFinite }
        guard !order.isEmpty else { return rects }
        // Callers usually pass sizes largest first; only sort when they did not.
        let isSorted = zip(order, order.dropFirst()).allSatisfy { sizes[$0] >= sizes[$1] }
        if !isSorted { order.sort { sizes[$0] != sizes[$1] ? sizes[$0] > sizes[$1] : $0 < $1 } }

        let total = order.reduce(0.0) { $0 + sizes[$1] }
        guard total > 0, total.isFinite else { return rects }
        let scale = Double(bounds.width) * Double(bounds.height) / total

        var free = bounds
        var start = 0
        while start < order.count {
            let side = Double(min(free.width, free.height))
            guard side > 0 else { break }

            // Grow the row while its worst aspect ratio keeps improving.
            var end = start
            var sum = 0.0
            var largest = 0.0
            var smallest = Double.infinity
            var worst = Double.infinity
            while end < order.count {
                let area = sizes[order[end]] * scale
                let nextSum = sum + area
                let nextLargest = max(largest, area)
                let nextSmallest = min(smallest, area)
                let candidate = worstRatio(sum: nextSum, largest: nextLargest, smallest: nextSmallest, side: side)
                if end > start, candidate > worst { break }
                sum = nextSum
                largest = nextLargest
                smallest = nextSmallest
                worst = candidate
                end += 1
            }

            // The last row takes whatever is left, so rounding never leaves a sliver.
            let isLastRow = end == order.count
            if free.width >= free.height {
                // A column on the left edge, items stacked top to bottom.
                let width = isLastRow ? free.width : min(CGFloat(sum / Double(free.height)), free.width)
                var y = free.minY
                for position in start..<end {
                    let isLast = position == end - 1
                    let share = sizes[order[position]] * scale / sum
                    let height = isLast ? free.maxY - y : min(CGFloat(share) * free.height, free.maxY - y)
                    rects[order[position]] = CGRect(x: free.minX, y: y, width: width, height: max(height, 0))
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY, width: max(free.width - width, 0), height: free.height)
            } else {
                // A strip along the top edge, items side by side.
                let height = isLastRow ? free.height : min(CGFloat(sum / Double(free.width)), free.height)
                var x = free.minX
                for position in start..<end {
                    let isLast = position == end - 1
                    let share = sizes[order[position]] * scale / sum
                    let width = isLast ? free.maxX - x : min(CGFloat(share) * free.width, free.maxX - x)
                    rects[order[position]] = CGRect(x: x, y: free.minY, width: max(width, 0), height: height)
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: max(free.height - height, 0))
            }
            start = end
        }
        return rects
    }

    /// The worst aspect ratio in a row of the given total area laid along `side`.
    private static func worstRatio(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
        guard sum > 0, smallest > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }
}

/// One rectangle of the nested treemap drawn for a folder.
public struct TreemapTile: Sendable, Equatable, Identifiable {
    public var node: AnalyzeTree.NodeID
    public var rect: CGRect
    /// 1 for a direct child of the folder shown, 2 for a grandchild, and so on.
    public var depth: Int
    /// The direct child of the folder shown that this tile sits in (itself at depth 1).
    public var top: AnalyzeTree.NodeID
    public var category: FileCategory
    /// True when the tile is a folder whose contents are drawn inside it.
    public var isContainer: Bool
    /// Height of the label band at the top of a container; zero when it has none.
    public var headerHeight: CGFloat
    public var isUnreadable: Bool

    public var id: Int { node }
}

public struct TreemapOptions: Sendable, Equatable {
    /// How many levels of folders are drawn inside each other.
    public var maxDepth = 3
    /// Space between neighbouring tiles.
    public var gap: CGFloat = 1
    /// Height of a folder's label band.
    public var headerHeight: CGFloat = 20
    /// A top-level folder gets a label band only when it is at least this big.
    public var minHeaderSize = CGSize(width: 72, height: 48)
    /// Height of the label band of a folder one level further in.
    public var nestedHeaderHeight: CGFloat = 17
    /// A folder one level further in gets a label band only when it is at least this big.
    public var minNestedHeaderSize = CGSize(width: 110, height: 64)
    /// A folder is subdivided only when both its sides are at least this long.
    public var minSubdivide: CGFloat = 20
    /// Tiles with a side shorter than this are not drawn.
    public var minTile: CGFloat = 1.5
    /// Share of the area an unreadable folder gets, so it can show its retry badge.
    public var unreadableShare = 0.012
    /// All unreadable folders together never get more than this share.
    public var maxUnreadableShare = 0.06

    public init() {}
}

extension AnalyzeTree {
    /// The tiles to draw for the folder `root` inside `bounds`: its children,
    /// and inside each child folder its own contents, a few levels deep.
    /// A container always comes before the tiles inside it.
    public func treemap(of root: NodeID, in bounds: CGRect, options: TreemapOptions = TreemapOptions()) -> [TreemapTile] {
        guard isValid(root), bounds.width > 0, bounds.height > 0 else { return [] }
        var tiles: [TreemapTile] = []
        layout(root, in: bounds, depth: 1, top: nil, options: options, into: &tiles)
        return tiles
    }

    private func layout(_ parent: NodeID, in bounds: CGRect, depth: Int, top: NodeID?, options: TreemapOptions, into tiles: inout [TreemapTile]) {
        let children = children(of: parent)
        guard !children.isEmpty else { return }
        var weights = children.map { Double(nodes[$0].bytes) }

        if depth == 1 {
            // An unreadable folder has no size, but it must not vanish.
            let unreadable = children.indices.filter { nodes[children[$0]].isUnreadable && nodes[children[$0]].bytes == 0 }
            if !unreadable.isEmpty {
                let total = weights.reduce(0, +)
                let share = min(options.unreadableShare, options.maxUnreadableShare / Double(unreadable.count))
                let weight = total > 0 ? total * share / max(1 - share * Double(unreadable.count), 0.5) : 1
                for index in unreadable { weights[index] = weight }
            }
        }

        let rects = Treemap.squarify(weights, in: bounds)
        let inset = options.gap / 2
        for (index, child) in children.enumerated() {
            let rect = rects[index].insetBy(dx: min(inset, rects[index].width / 4), dy: min(inset, rects[index].height / 4))
            guard rect.width >= options.minTile, rect.height >= options.minTile else { continue }
            let node = nodes[child]
            let subdivide = node.kind == .directory && node.childCount > 0 && node.bytes > 0 && depth < options.maxDepth
                && min(rect.width, rect.height) >= options.minSubdivide
            var header: CGFloat = 0
            if subdivide, depth == 1, rect.width >= options.minHeaderSize.width, rect.height >= options.minHeaderSize.height {
                header = options.headerHeight
            } else if subdivide, depth == 2, rect.width >= options.minNestedHeaderSize.width, rect.height >= options.minNestedHeaderSize.height {
                header = options.nestedHeaderHeight
            }
            tiles.append(TreemapTile(
                node: child, rect: rect, depth: depth, top: top ?? child, category: node.category,
                isContainer: subdivide, headerHeight: header, isUnreadable: node.isUnreadable))
            guard subdivide else { continue }
            var content = rect.insetBy(dx: options.gap, dy: options.gap)
            content.origin.y += header
            content.size.height -= header
            if content.width > 0, content.height > 0 {
                layout(child, in: content, depth: depth + 1, top: top ?? child, options: options, into: &tiles)
            }
        }
    }
}
