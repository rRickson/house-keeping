import Foundation
import SweepAnalyze
import SweepTestSupport
import Testing

/// Checks the properties every squarified layout must have.
private func expectValidLayout(
    _ sizes: [Double],
    in bounds: CGRect,
    sourceLocation: SourceLocation = #_sourceLocation
) -> [CGRect] {
    let rects = Treemap.squarify(sizes, in: bounds)
    #expect(rects.count == sizes.count, sourceLocation: sourceLocation)
    guard rects.count == sizes.count else { return rects }

    let total = sizes.filter { $0 > 0 && $0.isFinite }.reduce(0, +)
    let area = Double(bounds.width * bounds.height)
    let tolerance = max(area, 1) * 1e-9
    let edge = max(Double(max(bounds.width, bounds.height)), 1) * 1e-9
    var covered = 0.0
    for (index, rect) in rects.enumerated() {
        let rectArea = Double(rect.width * rect.height)
        guard sizes[index] > 0, sizes[index].isFinite, total > 0, area > 0 else {
            #expect(rectArea == 0, "item \(index) has no size and must get no area", sourceLocation: sourceLocation)
            continue
        }
        // Area proportional to size.
        let expected = sizes[index] / total * area
        #expect(abs(rectArea - expected) <= max(expected * 1e-6, tolerance), "item \(index): area \(rectArea), expected \(expected)", sourceLocation: sourceLocation)
        // Inside the bounds.
        #expect(Double(rect.minX) >= Double(bounds.minX) - edge && Double(rect.maxX) <= Double(bounds.maxX) + edge, sourceLocation: sourceLocation)
        #expect(Double(rect.minY) >= Double(bounds.minY) - edge && Double(rect.maxY) <= Double(bounds.maxY) + edge, sourceLocation: sourceLocation)
        #expect(rect.width >= 0 && rect.height >= 0, sourceLocation: sourceLocation)
        covered += rectArea
    }
    if total > 0, area > 0 {
        // Together they fill the bounds exactly.
        #expect(abs(covered - area) <= area * 1e-6, sourceLocation: sourceLocation)
    }

    // No two rectangles overlap.
    let drawn = rects.enumerated().filter { $0.element.width > 0 && $0.element.height > 0 }
    if drawn.count <= 400 {
        for (position, first) in drawn.enumerated() {
            for second in drawn[(position + 1)...] {
                let overlap = first.element.intersection(second.element)
                let overlapArea = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
                #expect(overlapArea <= tolerance * 10, "items \(first.offset) and \(second.offset) overlap by \(overlapArea)", sourceLocation: sourceLocation)
            }
        }
    }
    return rects
}

private func aspect(_ rect: CGRect) -> Double {
    Double(max(rect.width / rect.height, rect.height / rect.width))
}

@Suite struct TreemapLayoutTests {
    let bounds = CGRect(x: 20, y: 10, width: 800, height: 500)

    @Test func areasAreProportionalInsideBoundsWithoutOverlap() {
        _ = expectValidLayout([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 6, height: 4))
        _ = expectValidLayout([500, 300, 200, 100, 50, 25, 12, 6, 3, 1], in: bounds)
        _ = expectValidLayout(Array(repeating: 1, count: 37), in: bounds)
    }

    @Test func matchesThePublishedExample() {
        // The worked example from the squarified treemaps paper: a 6 x 4
        // rectangle and areas 6, 6, 4, 3, 2, 2, 1. The first two share a column.
        let rects = expectValidLayout([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 6, height: 4))
        #expect(rects[0] == CGRect(x: 0, y: 0, width: 3, height: 2))
        #expect(rects[1] == CGRect(x: 0, y: 2, width: 3, height: 2))
        #expect(abs(rects[2].width - 12.0 / 7.0) < 1e-9 && abs(rects[2].height - 7.0 / 3.0) < 1e-9)
        #expect(rects.allSatisfy { aspect($0) < 4.01 })
    }

    @Test func resultKeepsTheOrderOfTheInput() {
        let sizes: [Double] = [1, 50, 3, 200, 7]
        let rects = expectValidLayout(sizes, in: bounds)
        let areas = rects.map { Double($0.width * $0.height) }
        // The fourth item is the largest and so on, whatever order they came in.
        #expect(areas.indices.sorted { areas[$0] > areas[$1] } == [3, 1, 4, 2, 0])
        // The largest item starts in the top-left corner.
        #expect(rects[3].origin == bounds.origin)
    }

    @Test func aspectRatiosStayCloseToSquare() {
        // Equal items in a square: every tile is near square.
        let equal = expectValidLayout(Array(repeating: 1, count: 16), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(equal.allSatisfy { aspect($0) < 1.01 })

        // Varied items: far better than slicing the rectangle into strips.
        var generator = SeededGenerator(seed: 42)
        let sizes = (0..<120).map { _ in Double.random(in: 1...100, using: &generator) }
        let rects = expectValidLayout(sizes, in: bounds)
        let ratios = rects.map(aspect)
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        #expect(mean < 2.0, "mean aspect ratio \(mean)")
        #expect(ratios.sorted()[ratios.count * 9 / 10] < 3.5)

        let total = sizes.reduce(0, +)
        let sliced = sizes.map { size -> Double in
            let width = Double(bounds.width) * size / total
            return max(width / Double(bounds.height), Double(bounds.height) / width)
        }
        #expect(mean < sliced.reduce(0, +) / Double(sliced.count) / 10)
    }

    @Test func zeroNegativeAndBrokenSizesGetNoArea() {
        let sizes: [Double] = [10, 0, -5, .nan, .infinity, 30, 0]
        let rects = expectValidLayout(sizes, in: bounds)
        for index in [1, 2, 3, 4, 6] {
            #expect(rects[index].width * rects[index].height == 0)
        }
        #expect(abs(Double(rects[0].width * rects[0].height) - 100_000) < 1e-3)
        #expect(abs(Double(rects[5].width * rects[5].height) - 300_000) < 1e-3)
    }

    @Test func emptyAndDegenerateInputs() {
        #expect(Treemap.squarify([], in: bounds).isEmpty)
        #expect(Treemap.squarify([0, 0], in: bounds).allSatisfy { $0.width * $0.height == 0 })
        #expect(Treemap.squarify([1, 2], in: CGRect(x: 0, y: 0, width: 0, height: 100)).allSatisfy { $0.width * $0.height == 0 })
        #expect(Treemap.squarify([1, 2], in: .null).allSatisfy { $0.width * $0.height == 0 && $0.minX.isFinite })
        #expect(Treemap.squarify([1, 2], in: .infinite).allSatisfy { $0.width * $0.height == 0 })
        // A rectangle with a negative size is the same rectangle written backwards.
        let backwards = CGRect(x: 0, y: 0, width: 100, height: -50)
        #expect(Treemap.squarify([1, 2], in: backwards) == expectValidLayout([1, 2], in: backwards.standardized))
        #expect(Treemap.squarify([42], in: bounds) == [bounds])
    }

    @Test func tinyItemsNextToHugeOnes() {
        var sizes: [Double] = [1e12, 5e11]
        sizes.append(contentsOf: Array(repeating: 1, count: 200))
        sizes.append(1e-6)
        let rects = expectValidLayout(sizes, in: bounds)
        #expect(rects.allSatisfy { $0.width.isFinite && $0.height.isFinite && $0.minX.isFinite && $0.minY.isFinite })
        #expect(rects[0].width * rects[0].height > rects[1].width * rects[1].height)
    }

    @Test func randomLayoutsKeepEveryProperty() {
        var generator = SeededGenerator(seed: 2026)
        for _ in 0..<60 {
            let count = Int.random(in: 1...80, using: &generator)
            let sizes = (0..<count).map { _ -> Double in
                switch Int.random(in: 0..<10, using: &generator) {
                case 0: 0
                case 1: Double.random(in: 0...0.001, using: &generator)
                case 2: Double.random(in: 1e6...1e9, using: &generator)
                default: Double.random(in: 1...1000, using: &generator)
                }
            }
            let bounds = CGRect(
                x: Double.random(in: -50...50, using: &generator),
                y: Double.random(in: -50...50, using: &generator),
                width: Double.random(in: 1...2000, using: &generator),
                height: Double.random(in: 1...2000, using: &generator))
            _ = expectValidLayout(sizes, in: bounds)
        }
    }

    @Test func manyItemsAreLaidOutQuickly() {
        var generator = SeededGenerator(seed: 5)
        let sizes = (0..<50_000).map { _ in Double.random(in: 1...1_000_000, using: &generator) }
        let clock = ContinuousClock()
        var rects: [CGRect] = []
        let elapsed = clock.measure { rects = Treemap.squarify(sizes, in: bounds) }
        #expect(rects.count == sizes.count)
        #expect(elapsed < .seconds(2))
        let covered = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(covered - 400_000) < 0.5)
    }
}

@Suite struct NestedTreemapTests {
    let fixture: FixtureHome
    let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)

    init() throws {
        fixture = try FixtureHome()
        try fixture.write("map/media/film.mov", bytes: 4_000_000)
        try fixture.write("map/media/stills/a.jpg", bytes: 900_000)
        try fixture.write("map/media/stills/b.jpg", bytes: 600_000)
        try fixture.write("map/code/app/main.swift", bytes: 700_000)
        try fixture.write("map/code/app/build/out.o", bytes: 1_500_000)
        try fixture.write("map/notes.pdf", bytes: 1_000_000)
        try fixture.write("map/tiny.txt", bytes: 10)
    }

    private func scan() throws -> AnalyzeTree {
        try detailedScanner().scanBlocking(URL(fileURLWithPath: fixture.path("map")))
    }

    @Test func topLevelTilesAreTheChildrenAndDoNotOverlap() throws {
        let tree = try scan()
        let tiles = tree.treemap(of: tree.root, in: bounds)
        let top = tiles.filter { $0.depth == 1 }

        #expect(Set(top.map { tree.displayName(of: $0.node) }) == ["media", "code", "notes.pdf"])
        #expect(top.allSatisfy { $0.top == $0.node })
        for (index, first) in top.enumerated() {
            #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(first.rect))
            for second in top[(index + 1)...] {
                #expect(!first.rect.intersects(second.rect))
            }
        }
        // Areas follow sizes: media is the biggest tile, then code, then the PDF.
        let ordered = top.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        #expect(ordered.map { tree.displayName(of: $0.node) } == ["media", "code", "notes.pdf"])
        let media = try #require(top.first { tree.displayName(of: $0.node) == "media" })
        let share = Double(media.rect.width * media.rect.height) / Double(bounds.width * bounds.height)
        #expect(abs(share - Double(tree[media.node].bytes) / Double(tree.totalBytes)) < 0.02)
    }

    @Test func foldersAreDrawnWithTheirContentsInside() throws {
        let tree = try scan()
        let tiles = tree.treemap(of: tree.root, in: bounds)
        let byNode = Dictionary(uniqueKeysWithValues: tiles.map { ($0.node, $0) })
        #expect(byNode.count == tiles.count)

        for (index, tile) in tiles.enumerated() where tile.depth > 1 {
            let parent = try #require(tree.parent(of: tile.node))
            let container = try #require(byNode[parent])
            #expect(container.isContainer)
            #expect(container.depth == tile.depth - 1)
            #expect(container.rect.insetBy(dx: -0.001, dy: -0.001).contains(tile.rect))
            #expect(tile.rect.minY >= container.rect.minY + container.headerHeight)
            #expect(tile.top == container.top)
            // A container comes before what is inside it.
            #expect(tiles.firstIndex { $0.node == parent }! < index)
        }
        let media = try #require(tiles.first { tree.displayName(of: $0.node) == "media" })
        #expect(media.isContainer && media.headerHeight > 0)
        let film = try #require(tiles.first { tree.displayName(of: $0.node) == "film.mov" })
        #expect(film.depth == 2 && film.category == .video && !film.isContainer)
        #expect(tiles.contains { tree.displayName(of: $0.node) == "out.o" && $0.depth == 4 } == false)
        #expect(tiles.contains { tree.displayName(of: $0.node) == "build" && $0.depth == 3 })
        #expect(tiles.map(\.depth).max() == 3)
    }

    @Test func drillingDownLaysOutTheChosenFolder() throws {
        let tree = try scan()
        let code = try #require(tree.node(atPath: fixture.path("map/code/app")))
        let tiles = tree.treemap(of: code, in: bounds)
        #expect(Set(tiles.filter { $0.depth == 1 }.map { tree.displayName(of: $0.node) }) == ["build", "main.swift"])
        #expect(tiles.contains { tree.displayName(of: $0.node) == "out.o" && $0.depth == 2 })
    }

    @Test func tinyAndEmptyThingsAreLeftOut() throws {
        let tree = try scan()
        var options = TreemapOptions()
        options.maxDepth = 1
        let tiles = tree.treemap(of: tree.root, in: bounds, options: options)
        #expect(tiles.allSatisfy { $0.depth == 1 && !$0.isContainer })
        #expect(tiles.allSatisfy { $0.rect.width >= options.minTile && $0.rect.height >= options.minTile })
        #expect(!tiles.contains { tree.displayName(of: $0.node) == "tiny.txt" })
        #expect(tree.treemap(of: tree.root, in: .zero).isEmpty)
        #expect(tree.treemap(of: 9_999, in: bounds).isEmpty)
    }

    @Test func unreadableFoldersKeepATile() throws {
        try fixture.write("map/locked/secret.bin", bytes: 500_000)
        let locked = fixture.path("map/locked")
        #expect(chmod(locked, 0o000) == 0)
        defer { chmod(locked, 0o755) }

        let tree = try scan()
        let tiles = tree.treemap(of: tree.root, in: bounds)
        let tile = try #require(tiles.first { tree.displayName(of: $0.node) == "locked" })
        #expect(tile.isUnreadable && !tile.isContainer)
        // Big enough to carry a badge, small enough not to distort the picture.
        let share = Double(tile.rect.width * tile.rect.height) / Double(bounds.width * bounds.height)
        #expect(share > 0.005 && share < 0.02)
        #expect(tile.rect.width > 16 && tile.rect.height > 16)
    }
}
