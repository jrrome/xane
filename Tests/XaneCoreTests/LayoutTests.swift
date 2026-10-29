import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import XaneCore

final class LayoutTests: XCTestCase {
    let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)

    func layout(_ kind: LayoutKind, _ n: Int, mins: [CGSize]? = nil, area: CGRect? = nil,
                params: LayoutParams = .init(), ratios: [Double] = [], gap: CGFloat = 8,
                maxTiled: Int = 0, overflow: OverflowMode = .stack) -> LayoutResult {
        let req = LayoutRequest(kind: kind, area: area ?? screen,
                                minimums: mins ?? Array(repeating: .zero, count: n), params: params,
                                innerGap: gap, outerGap: gap, maxTiled: maxTiled, overflow: overflow)
        return LayoutEngine.layout(req) { _ in ratios }
    }

    /// Frames are inside the area, integral, and tiles never overlap.
    func assertSane(_ r: LayoutResult, file: StaticString = #filePath, line: UInt = #line) {
        let tiles = Set(r.frames.compactMap { $0.map(Rect.init) }.map { "\($0.x),\($0.y),\($0.w),\($0.h)" })
        let frames = r.frames.compactMap { $0 }
        for f in frames {
            XCTAssertTrue(r.area.contains(f), "\(f) outside \(r.area)", file: file, line: line)
            XCTAssertEqual(f.minX, f.minX.rounded(), file: file, line: line)
            XCTAssertEqual(f.width, f.width.rounded(), file: file, line: line)
        }
        let unique = tiles.compactMap { s -> CGRect? in
            let p = s.split(separator: ",").compactMap { Double($0) }
            return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        }
        for i in 0..<unique.count {
            for j in (i + 1)..<unique.count {
                XCTAssertFalse(unique[i].intersects(unique[j]), "\(unique[i]) overlaps \(unique[j])", file: file, line: line)
            }
        }
    }

    func testEveryLayoutIsSaneForManyCounts() {
        for kind in LayoutKind.allCases {
            for n in 1...9 {
                let r = layout(kind, n)
                XCTAssertEqual(r.frames.compactMap { $0 }.count, n, "\(kind) \(n)")
                assertSane(r)
            }
        }
    }

    func testDwindleCutsLongestSide() {
        let r = layout(.dwindle, 3)
        let f = r.frames.map { $0! }
        // Landscape: first cut is vertical (side by side).
        XCTAssertEqual(f[0].minY, f[1].minY)
        XCTAssertLessThan(f[0].maxX, f[1].minX)
        // Remaining area is portrait-ish (≈ 640×859): second cut is horizontal.
        XCTAssertEqual(f[1].minX, f[2].minX)
        XCTAssertLessThan(f[1].maxY, f[2].minY)
        // Main ratio 0.55 of the available width.
        let avail = (1440 - 16) - 8
        XCTAssertEqual(f[0].width, floor(CGFloat(avail) * 0.55))
    }

    func testDwindlePortraitCutsHorizontallyFirst() {
        let r = layout(.dwindle, 2, area: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        let f = r.frames.map { $0! }
        XCTAssertEqual(f[0].minX, f[1].minX)
        XCTAssertLessThan(f[0].maxY, f[1].minY)
    }

    func testGapsAreExact() {
        let r = layout(.columns, 3, gap: 10)
        let f = r.frames.map { $0! }
        XCTAssertEqual(f[0].minX, 10)
        XCTAssertEqual(f[1].minX - f[0].maxX, 10)
        XCTAssertEqual(f[2].minX - f[1].maxX, 10)
        XCTAssertEqual(f[2].maxX, 1430)
        // Equal widths within a point.
        XCTAssertLessThanOrEqual(abs(f[0].width - f[2].width), 2)
    }

    func testMinimumsAreRespectedExactly() {
        // Window 0 needs 1000 pt: the main share (55% ≈ 776) is not enough, so it grows.
        let mins = [CGSize(width: 1000, height: 0), .zero]
        let r = layout(.tile, 2, mins: mins)
        let f = r.frames.map { $0! }
        XCTAssertGreaterThanOrEqual(f[0].width, 1000)
        XCTAssertEqual(r.tileCount, 2)
        assertSane(r)
    }

    func testOverflowStacksWhenMinimumsDoNotFit() {
        // Three windows that each need 600 pt wide on a 1440 screen: only two fit side by side.
        let mins = Array(repeating: CGSize(width: 600, height: 0), count: 3)
        let r = layout(.columns, 3, mins: mins)
        XCTAssertEqual(r.tileCount, 2)
        XCTAssertEqual(r.stacked, [2])
        XCTAssertEqual(r.frames[2], r.frames[1])   // stacked on the last tile
        for (i, f) in r.frames.enumerated() { XCTAssertGreaterThanOrEqual(f!.width, mins[i].width) }
    }

    func testOverflowStacksOnFocusedTile() {
        let mins = Array(repeating: CGSize(width: 600, height: 0), count: 3)
        let req = LayoutRequest(kind: .columns, area: screen, minimums: mins, stackTarget: 0)
        let r = LayoutEngine.layout(req) { _ in [] }
        XCTAssertEqual(r.frames[2], r.frames[0])
    }

    func testOverflowFloat() {
        let mins = Array(repeating: CGSize(width: 600, height: 0), count: 3)
        let r = layout(.columns, 3, mins: mins, overflow: .float)
        XCTAssertNil(r.frames[2])
        XCTAssertEqual(r.tileCount, 2)
    }

    func testWindowBiggerThanScreenIsLeftOut() {
        let mins = [CGSize(width: 5000, height: 0), .zero]
        let r = layout(.dwindle, 2, mins: mins)
        XCTAssertNil(r.frames[0])
        XCTAssertNotNil(r.frames[1])
    }

    func testMaxTiled() {
        let r = layout(.tile, 5, maxTiled: 3)
        XCTAssertEqual(r.tileCount, 3)
        XCTAssertEqual(r.stacked.count, 2)
    }

    func testTileOrientations() {
        for o in Orientation.allCases {
            let r = layout(.tile, 3, params: LayoutParams(mainRatio: 0.6, mainCount: 1, orientation: o))
            let f = r.frames.map { $0! }
            let main = f[0], s1 = f[1]
            switch o {
            case .left: XCTAssertLessThan(main.maxX, s1.minX)
            case .right: XCTAssertGreaterThan(main.minX, s1.maxX)
            case .top: XCTAssertLessThan(main.maxY, s1.minY)
            case .bottom: XCTAssertGreaterThan(main.minY, s1.maxY)
            }
            assertSane(r)
        }
    }

    func testTileMainCount() {
        let r = layout(.tile, 4, params: LayoutParams(mainRatio: 0.5, mainCount: 2, orientation: .left))
        let f = r.frames.map { $0! }
        XCTAssertEqual(f[0].minX, f[1].minX)    // both mains in the left column
        XCTAssertEqual(f[2].minX, f[3].minX)    // stack in the right column
        XCTAssertLessThan(f[0].maxX, f[2].minX)
    }

    func testGridIsSquareish() {
        let r = layout(.grid, 4)
        let f = r.frames.map { $0! }
        let xs = Set(f.map(\.minX)), ys = Set(f.map(\.minY))
        XCTAssertEqual(xs.count, 2)
        XCTAssertEqual(ys.count, 2)
    }

    func testMonocle() {
        let r = layout(.monocle, 3)
        XCTAssertTrue(r.frames.allSatisfy { $0 == r.frames[0] })
        XCTAssertNotNil(r.frames[0])
    }

    func testStoredRatiosAreUsed() {
        let r = layout(.columns, 2, ratios: [0.25])
        let f = r.frames.map { $0! }
        let avail = 1440 - 16 - 8
        XCTAssertEqual(f[0].width, floor(CGFloat(avail) * 0.25))
    }

    func testResizeMapsBackToRatio() {
        let r = layout(.tile, 3)
        let f = r.frames.map { $0! }
        // User drags the right edge of the main window 100 pt to the right.
        var new = f[0]; new.size.width += 100
        let ratios = ratiosAfterResize([], splits: r.splits, index: 0, old: f[0], new: new, gap: 8)
        let r2 = layout(.tile, 3, ratios: ratios)
        XCTAssertEqual(r2.frames[0]!.maxX, new.maxX, accuracy: 2)
        // Dragging the left edge of a stack window has the same effect on the shared boundary.
        var s = f[1]; s.origin.x += 100; s.size.width -= 100
        let ratios2 = ratiosAfterResize([], splits: r.splits, index: 1, old: f[1], new: s, gap: 8)
        let r3 = layout(.tile, 3, ratios: ratios2)
        XCTAssertEqual(r3.frames[1]!.minX, s.minX, accuracy: 2)
    }

    func testResizeOfStackBoundary() {
        let r = layout(.tile, 3)
        let f = r.frames.map { $0! }
        var new = f[1]; new.size.height += 120   // bottom edge of first stack window
        let ratios = ratiosAfterResize([], splits: r.splits, index: 1, old: f[1], new: new, gap: 8)
        let r2 = layout(.tile, 3, ratios: ratios)
        XCTAssertEqual(r2.frames[1]!.maxY, new.maxY, accuracy: 2)
        XCTAssertEqual(r2.frames[0], f[0])        // main untouched
    }

    func testGrowShrink() {
        let r = layout(.dwindle, 2)
        let f0 = r.frames[0]!.width
        let grown = ratiosAfterGrow([], splits: r.splits, index: 0, delta: 0.1)!
        XCTAssertGreaterThan(layout(.dwindle, 2, ratios: grown).frames[0]!.width, f0)
        let shrunk = ratiosAfterGrow([], splits: r.splits, index: 1, delta: 0.1)!   // grow window 1
        XCTAssertLessThan(layout(.dwindle, 2, ratios: shrunk).frames[0]!.width, f0)
    }

    func testUsableAreaKeepsMinimum() {
        let v = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let u = usableArea(v, reserving: EdgeInsets(top: 0, left: 500, bottom: 0, right: 500))
        XCTAssertEqual(u.width, 400, accuracy: 0.01)
        XCTAssertEqual(u.minX, 300, accuracy: 0.01)
    }

    func testPerformance() {
        let mins = (0..<12).map { CGSize(width: CGFloat(200 + $0 * 10), height: 150) }
        measure {
            for _ in 0..<1000 {
                _ = LayoutEngine.layout(LayoutRequest(kind: .dwindle, area: screen, minimums: mins)) { _ in [] }
            }
        }
    }
}
