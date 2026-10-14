import SweepAnalyze
import SweepDesign
import SweepKit
import SwiftUI

/// Identifies one layout of the treemap: which folder, of which state of the tree, at which size.
struct TreemapLayoutKey: Hashable, Sendable {
    var focus: AnalyzeTree.NodeID
    var version: Int
    var width: Int
    var height: Int

    init(focus: AnalyzeTree.NodeID, version: Int, size: CGSize) {
        self.focus = focus
        self.version = version
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
}

/// Remembers the last few layouts, so hovering and zooming do not lay the tree out again.
@MainActor
final class TreemapLayoutCache {
    private var entries: [(key: TreemapLayoutKey, tiles: [TreemapTile])] = []

    func tiles(for key: TreemapLayoutKey, in tree: AnalyzeTree) -> [TreemapTile] {
        if let hit = entries.first(where: { $0.key == key }) { return hit.tiles }
        let tiles = tree.isValid(key.focus) ? tree.treemap(of: key.focus, in: key.bounds) : []
        entries.append((key, tiles))
        if entries.count > 4 { entries.removeFirst(entries.count - 4) }
        return tiles
    }
}

/// The squarified treemap of one folder, with hover, click-to-zoom and a context menu.
struct TreemapView<Menu: View>: View {
    let tree: AnalyzeTree
    let version: Int
    let focus: AnalyzeTree.NodeID
    let highlighted: AnalyzeTree.NodeID?
    let retrying: Set<AnalyzeTree.NodeID>
    @Binding var hovered: AnalyzeTree.NodeID?
    let onOpen: (AnalyzeTree.NodeID) -> Void
    let onRetry: (AnalyzeTree.NodeID) -> Void
    @ViewBuilder let menu: (AnalyzeTree.NodeID) -> Menu

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cache = TreemapLayoutCache()
    @State private var zoom: Zoom?
    @State private var progress: CGFloat = 1
    /// The tile a context menu acts on: the last one the pointer was over.
    @State private var menuTarget: AnalyzeTree.NodeID?

    /// A drill-down in flight: the level being left and the tile the two levels share.
    private struct Zoom: Equatable {
        let id = UUID()
        var from: AnalyzeTree.NodeID
        /// Where the deeper folder sits inside the shallower one; nil for a plain crossfade.
        var rect: CGRect?
        var inward: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let key = TreemapLayoutKey(focus: focus, version: version, size: size)
            let tiles = cache.tiles(for: key, in: tree)
            ZStack(alignment: .topLeading) {
                if let zoom {
                    let oldKey = TreemapLayoutKey(focus: zoom.from, version: version, size: size)
                    TreemapLayer(key: oldKey, tiles: cache.tiles(for: oldKey, in: tree), tree: tree)
                        .equatable()
                        .modifier(ZoomEffect(placement: placement(of: .outgoing, zoom: zoom, bounds: key.bounds)))
                        .id(zoom.id)
                        // The level being left appears at its starting place; animate from there.
                        .onAppear { runZoom(zoom) }
                }
                TreemapLayer(key: key, tiles: tiles, tree: tree)
                    .equatable()
                    .modifier(ZoomEffect(placement: placement(of: .incoming, zoom: zoom, bounds: key.bounds)))

                if zoom == nil {
                    if let highlighted, highlighted != hovered, let tile = top(highlighted, in: tiles) {
                        RoundedRectangle(cornerRadius: TreemapPainter.radius(tile.rect), style: .continuous)
                            .strokeBorder(.tint, lineWidth: 2)
                            .frame(width: tile.rect.width, height: tile.rect.height)
                            .offset(x: tile.rect.minX, y: tile.rect.minY)
                            .allowsHitTesting(false)
                    }
                    if let hovered, let tile = top(hovered, in: tiles) {
                        LiftedTile(tile: tile, tiles: tiles.filter { $0.top == hovered }, tree: tree)
                            .id(tile.node)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    ForEach(tiles.filter { $0.depth == 1 && $0.isUnreadable && min($0.rect.width, $0.rect.height) >= 26 }) { tile in
                        RetryBadge(
                            name: tree.displayName(of: tile.node),
                            compact: tile.rect.width < 84,
                            isBusy: retrying.contains(tile.node)
                        ) { onRetry(tile.node) }
                            .position(x: tile.rect.midX, y: tile.rect.midY)
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let node = zoom == nil ? tiles.first { $0.depth == 1 && $0.rect.contains(point) }?.node : nil
                    if node != hovered { hovered = node }
                    if let node { menuTarget = node }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                guard zoom == nil, let tile = tiles.first(where: { $0.depth == 1 && $0.rect.contains(point) }) else { return }
                if tree[tile.node].isDirectory, !tile.isUnreadable { onOpen(tile.node) }
            }
            .contextMenu {
                if let menuTarget, tree.isValid(menuTarget) { menu(menuTarget) }
            }
            .onChange(of: focus) { old, new in
                beginZoom(from: old, to: new, size: size)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .sweep, value: hovered)
            .accessibilityRepresentation {
                List(tiles.filter { $0.depth == 1 }) { tile in
                    Button("\(tree.displayName(of: tile.node)), \(ByteFormat.string(tree[tile.node].bytes))") { onOpen(tile.node) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SweepMetric.cardRadius - 4, style: .continuous))
    }

    private func top(_ node: AnalyzeTree.NodeID, in tiles: [TreemapTile]) -> TreemapTile? {
        tiles.first { $0.depth == 1 && $0.node == node }
    }

    // MARK: Zoom

    /// Starts the zoom between two levels. When one folder contains the other,
    /// the shared tile grows to fill the map (or shrinks back into place);
    /// otherwise, and with Reduce Motion, the levels simply crossfade.
    private func beginZoom(from old: AnalyzeTree.NodeID, to new: AnalyzeTree.NodeID, size: CGSize) {
        hovered = nil
        guard tree.isValid(old), tree.isValid(new), size.width > 0, size.height > 0 else {
            zoom = nil
            return
        }
        var rect: CGRect?
        var inward = true
        if !reduceMotion {
            let down = tree.ancestors(of: new)
            let up = tree.ancestors(of: old)
            if let index = down.firstIndex(of: old), index + 1 < down.count {
                rect = top(down[index + 1], in: cache.tiles(for: TreemapLayoutKey(focus: old, version: version, size: size), in: tree))?.rect
            } else if let index = up.firstIndex(of: new), index + 1 < up.count {
                rect = top(up[index + 1], in: cache.tiles(for: TreemapLayoutKey(focus: new, version: version, size: size), in: tree))?.rect
                inward = false
            }
            if let found = rect, found.width < 2 || found.height < 2 { rect = nil }
        }
        let next = Zoom(from: old, rect: rect, inward: inward)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            zoom = next
            progress = 0
        }
        // The map ignores clicks while a zoom is in flight, so a zoom must
        // always end, even if the view was off screen and never animated.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if zoom?.id == next.id {
                zoom = nil
                progress = 1
            }
        }
    }

    private func runZoom(_ current: Zoom) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .sweep) {
            progress = 1
        } completion: {
            if zoom?.id == current.id { zoom = nil }
        }
    }

    private enum Role { case incoming, outgoing }

    /// Where a level is drawn at the current point of the zoom.
    ///
    /// Both levels follow one rectangle that moves between the shared tile
    /// and the full map, so they stay in register all the way: scale and
    /// offset are linear in `progress`, which is exactly how SwiftUI interpolates them.
    private func placement(of role: Role, zoom: Zoom?, bounds: CGRect) -> ZoomEffect.Placement {
        guard let zoom else { return .identity }
        let fade = role == .incoming ? Double(progress) : Double(1 - progress)
        guard let tile = zoom.rect, bounds.width > 0, bounds.height > 0 else {
            return ZoomEffect.Placement(scale: CGSize(width: 1, height: 1), offset: .zero, opacity: fade)
        }
        // The deeper level's frame: tile -> map when zooming in, map -> tile when zooming out.
        let t = zoom.inward ? progress : 1 - progress
        let frame = CGRect(
            x: tile.minX + (bounds.minX - tile.minX) * t,
            y: tile.minY + (bounds.minY - tile.minY) * t,
            width: tile.width + (bounds.width - tile.width) * t,
            height: tile.height + (bounds.height - tile.height) * t)
        let isDeeper = (role == .incoming) == zoom.inward
        if isDeeper {
            return ZoomEffect.Placement(
                scale: CGSize(width: frame.width / bounds.width, height: frame.height / bounds.height),
                offset: CGSize(width: frame.minX, height: frame.minY),
                opacity: fade)
        }
        // The shallower level is scaled so that its tile lands on the same frame.
        let scale = CGSize(width: frame.width / tile.width, height: frame.height / tile.height)
        return ZoomEffect.Placement(
            scale: scale,
            offset: CGSize(width: frame.minX - tile.minX * scale.width, height: frame.minY - tile.minY * scale.height),
            opacity: fade)
    }
}

/// Scales a level about its top-left corner, moves it, and fades it.
private struct ZoomEffect: ViewModifier {
    struct Placement: Equatable {
        var scale: CGSize
        var offset: CGSize
        var opacity: Double

        static let identity = Placement(scale: CGSize(width: 1, height: 1), offset: .zero, opacity: 1)
    }

    let placement: Placement

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: placement.scale.width, y: placement.scale.height, anchor: .topLeading)
            .offset(placement.offset)
            .opacity(placement.opacity)
    }
}

/// One level of the treemap, drawn in a single canvas. Equatable on its layout
/// key, so moving the pointer over the map does not redraw thousands of tiles.
private struct TreemapLayer: View, Equatable {
    let key: TreemapLayoutKey
    let tiles: [TreemapTile]
    let tree: AnalyzeTree
    @Environment(\.colorScheme) private var scheme

    nonisolated static func == (lhs: TreemapLayer, rhs: TreemapLayer) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View {
        let painter = TreemapPainter(tree: tree, scheme: scheme)
        Canvas { context, _ in
            painter.draw(tiles, in: &context)
        }
        .frame(width: CGFloat(key.width), height: CGFloat(key.height))
    }
}

/// The hovered tile, drawn again slightly larger with a shadow and a highlight edge.
private struct LiftedTile: View {
    let tile: TreemapTile
    let tiles: [TreemapTile]
    let tree: AnalyzeTree
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rect = tile.rect
        let shape = RoundedRectangle(cornerRadius: TreemapPainter.radius(rect), style: .continuous)
        let painter = TreemapPainter(tree: tree, scheme: scheme)
        Canvas { context, _ in
            context.translateBy(x: -rect.minX, y: -rect.minY)
            painter.draw(tiles, in: &context)
        }
        .frame(width: rect.width, height: rect.height)
        // Tiles are tints, so the lifted copy needs the plain background under it.
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(tile.category.color.opacity(0.9), lineWidth: 1.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 8, y: 3)
        .scaleEffect(reduceMotion ? 1 : 1 + min(0.03, 6 / max(rect.width, rect.height)))
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// The badge an unreadable folder carries instead of disappearing from the map.
private struct RetryBadge: View {
    let name: String
    let compact: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isBusy {
                ProgressView().controlSize(.small)
            } else if compact {
                Image(systemName: "arrow.clockwise")
            } else {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isBusy)
        .help("Sweep could not read “\(name)”. Click to try again.")
        .accessibilityLabel("Retry reading \(name)")
    }
}

/// Draws tiles into a graphics context. Shared by the map and the lifted hover copy.
struct TreemapPainter {
    let tree: AnalyzeTree
    let scheme: ColorScheme

    static func radius(_ rect: CGRect) -> CGFloat {
        min(5, min(rect.width, rect.height) / 4)
    }

    func draw(_ tiles: [TreemapTile], in context: inout GraphicsContext) {
        for tile in tiles {
            let rect = tile.rect
            let radius = tile.depth == 1 ? Self.radius(rect) : min(2.5, min(rect.width, rect.height) / 4)
            let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

            if tile.isUnreadable {
                context.fill(path, with: .color(.gray.opacity(scheme == .dark ? 0.16 : 0.10)))
                context.stroke(
                    Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius, style: .continuous),
                    with: .color(.secondary.opacity(0.6)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if tile.depth == 1, rect.width >= 60, rect.height >= 58 {
                    label(tree.displayName(of: tile.node), size: nil, in: rect.insetBy(dx: 6, dy: 5), emphasized: false, context: &context)
                }
                continue
            }

            if tile.isContainer {
                // A folder: a faint wash of its dominant colour behind its contents.
                context.fill(path, with: .color(tile.category.color.opacity(tile.category.tintOpacity(scheme) * 0.28)))
                if tile.headerHeight > 0 {
                    let inset: CGFloat = tile.depth == 1 ? 6 : 5
                    let band = CGRect(x: rect.minX + inset, y: rect.minY + 3, width: rect.width - inset * 2, height: tile.headerHeight - 3)
                    header(tree.displayName(of: tile.node), bytes: tree[tile.node].bytes, in: band, emphasized: tile.depth == 1, context: &context)
                }
                continue
            }

            context.fill(path, with: .color(tile.category.tint(scheme)))
            if tile.depth == 1 {
                if rect.width >= 56, rect.height >= 22 {
                    label(
                        tree.displayName(of: tile.node),
                        size: rect.height >= 40 ? tree[tile.node].bytes : nil,
                        in: rect.insetBy(dx: 6, dy: 5), emphasized: true, context: &context)
                }
            } else if rect.width >= 76, rect.height >= 24 {
                label(
                    tree.displayName(of: tile.node),
                    size: rect.height >= 42 ? tree[tile.node].bytes : nil,
                    in: rect.insetBy(dx: 5, dy: 4), emphasized: false, context: &context)
            }
        }
    }

    /// Name on the left, size on the right, on one line.
    private func header(_ name: String, bytes: Int64, in rect: CGRect, emphasized: Bool, context: inout GraphicsContext) {
        let size = context.resolve(
            Text(sizeLabel(bytes)).font(.system(emphasized ? .caption : .caption2, design: .rounded)).monospacedDigit().foregroundStyle(.secondary))
        let sizeWidth = size.measure(in: CGSize(width: 400, height: rect.height)).width
        var nameWidth = rect.width
        if rect.width >= sizeWidth + 60 {
            context.draw(size, at: CGPoint(x: rect.maxX, y: rect.midY), anchor: .trailing)
            nameWidth -= sizeWidth + 8
        }
        let text = fitted(name, font: emphasized ? .caption.weight(.semibold) : .caption2, width: nameWidth, context: context)
        context.draw(text, at: CGPoint(x: rect.minX, y: rect.midY), anchor: .leading)
    }

    /// Name, and the size under it when given, in the tile's top-left corner.
    private func label(_ name: String, size: Int64?, in rect: CGRect, emphasized: Bool, context: inout GraphicsContext) {
        let font: Font = emphasized ? .caption.weight(.semibold) : .caption2
        let text = fitted(name, font: font, width: rect.width, context: context)
        let height = text.measure(in: CGSize(width: rect.width, height: 100)).height
        context.draw(text, at: CGPoint(x: rect.minX, y: rect.minY), anchor: .topLeading)
        guard let size, rect.height >= height * 2 else { return }
        let detail = context.resolve(
            Text(sizeLabel(size)).font(.system(emphasized ? .caption : .caption2, design: .rounded)).monospacedDigit().foregroundStyle(.secondary))
        if detail.measure(in: CGSize(width: 400, height: 100)).width <= rect.width {
            context.draw(detail, at: CGPoint(x: rect.minX, y: rect.minY + height + 1), anchor: .topLeading)
        }
    }

    /// The name shortened with an ellipsis until it fits on one line.
    private func fitted(_ name: String, font: Font, width: CGFloat, context: GraphicsContext) -> GraphicsContext.ResolvedText {
        func resolve(_ string: String) -> GraphicsContext.ResolvedText {
            context.resolve(Text(string).font(font).foregroundStyle(.primary))
        }
        let limit = CGSize(width: 4000, height: 100)
        var text = resolve(name)
        var measured = text.measure(in: limit).width
        guard measured > width, width > 0 else { return text }
        var count = name.count
        for _ in 0..<6 {
            // Shrink in proportion to the overshoot, then check again.
            count = max(1, min(count - 1, Int(Double(count) * Double(width / measured)) - 1))
            text = resolve(String(name.prefix(count)) + "…")
            measured = text.measure(in: limit).width
            if measured <= width || count == 1 { break }
        }
        return text
    }
}
