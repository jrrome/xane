import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum OverflowMode: String, Codable, CaseIterable, Sendable {
    /// Windows that do not fit share a tile with another window (the focused one if possible).
    case stack
    /// Windows that do not fit float, centred on the output.
    case float
}

public struct LayoutRequest: Sendable {
    public var kind: LayoutKind
    /// Usable area of the output (visible frame minus reserved edges), before the outer gap.
    public var area: CGRect
    /// Minimum size of each window, in tiling order.
    public var minimums: [CGSize]
    public var params: LayoutParams
    public var innerGap: CGFloat
    public var outerGap: CGFloat
    public var maxTiled: Int            // 0 = unlimited
    public var overflow: OverflowMode
    /// Index of the window extra windows should stack with (usually the focused one).
    public var stackTarget: Int?

    public init(kind: LayoutKind, area: CGRect, minimums: [CGSize], params: LayoutParams = .init(),
                innerGap: CGFloat = 8, outerGap: CGFloat = 8, maxTiled: Int = 0,
                overflow: OverflowMode = .stack, stackTarget: Int? = nil) {
        self.kind = kind; self.area = area; self.minimums = minimums; self.params = params
        self.innerGap = innerGap; self.outerGap = outerGap; self.maxTiled = maxTiled
        self.overflow = overflow; self.stackTarget = stackTarget
    }
}

public struct LayoutResult: Equatable, Sendable {
    /// Frame for each window index. nil = does not fit anywhere; the caller floats it.
    public var frames: [CGRect?]
    /// Resolved splits, for mapping resizes back to ratios.
    public var splits: [ResolvedSplit]
    /// Number of tiles (leaves). Ratios are stored per tile count.
    public var tileCount: Int
    /// Indices that were stacked onto another tile because there was no room.
    public var stacked: Set<Int>
    public var area: CGRect

    public static func empty(_ n: Int, area: CGRect) -> LayoutResult {
        LayoutResult(frames: Array(repeating: nil, count: n), splits: [], tileCount: 0, stacked: [], area: area)
    }
}

public enum LayoutEngine {
    /// Computes the frames for one output.
    ///
    /// Strategy: try to give every window its own tile; if the minimum sizes make that impossible,
    /// drop one tile at a time (largest feasible n), stacking or floating the rest. Each attempt is
    /// an exact closed-form solve, so the whole thing is O(n²) tiny operations — microseconds.
    /// - Parameter ratios: stored ratios for a given tile count.
    public static func layout(_ req: LayoutRequest, ratios: (Int) -> [Double]) -> LayoutResult {
        let n = req.minimums.count
        let inner = req.area.insetBy(dx: max(0, req.outerGap), dy: max(0, req.outerGap)).snappedInward
        guard n > 0, inner.width >= 1, inner.height >= 1 else { return .empty(n, area: inner) }

        // Windows that cannot fit in the whole area at all are out from the start.
        let eligible = (0..<n).filter { req.minimums[$0].fits(in: inner) }
        var result = LayoutResult.empty(n, area: inner)
        guard !eligible.isEmpty else { return result }
        let gap = max(0, req.innerGap)

        if req.kind == .monocle {
            for i in eligible { result.frames[i] = inner }
            result.tileCount = 1
            return result
        }

        var upper = eligible.count
        if req.maxTiled > 0 { upper = min(upper, req.maxTiled) }

        for tiles in stride(from: upper, through: 1, by: -1) {
            var leaves = eligible.prefix(tiles).map { [$0] }
            let extras = Array(eligible.dropFirst(tiles))
            if !extras.isEmpty && req.overflow == .stack {
                let target = req.stackTarget.flatMap { t in leaves.firstIndex(where: { $0.first == t }) }
                    ?? (leaves.count - 1)
                leaves[target] += extras
            }
            let r = ratios(tiles)
            var builder = TreeBuilder(params: req.params, ratios: r)
            let tree = builder.build(req.kind, leaves: leaves, area: inner, gap: gap)
            let solver = TreeSolver(gap: gap, minimums: req.minimums, ratios: r)
            var frames: [Int: CGRect] = [:]
            var splits: [ResolvedSplit] = []
            if solver.solve(tree, in: inner, frames: &frames, splits: &splits) {
                for (i, f) in frames { result.frames[i] = f }
                result.splits = splits
                result.tileCount = tiles
                result.stacked = req.overflow == .stack ? Set(extras) : []
                return result
            }
        }
        return result
    }

    /// Where windows that could not be tiled go: centred, cascading 28 pt per window.
    public static func overflowFrames(count: Int, sizes: [CGSize], in area: CGRect) -> [CGRect] {
        (0..<count).map { i in
            let s = sizes[i]
            let w = min(max(s.width, 200), area.width), h = min(max(s.height, 150), area.height)
            let off = CGFloat(i % 8) * 28
            return CGRect(x: area.midX - w / 2 + off, y: area.midY - h / 2 + off, width: w, height: h)
                .clamped(into: area).snappedInward
        }
    }
}
