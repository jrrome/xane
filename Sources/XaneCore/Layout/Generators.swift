import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Layout generators, in the spirit of river's layout protocol: a pure function from
/// (area, number of windows, parameters) to geometry. They only build the split tree; the solver
/// takes care of minimum sizes and rounding.
public enum LayoutKind: String, Codable, CaseIterable, Sendable {
    /// BSP that always cuts the longest side of the remaining area. Adapts by itself to
    /// portrait, ultrawide and anything in between: no special cases.
    case dwindle
    /// Main area + stack (river's rivertile / Shoji's "side"). Orientation and main count are tunable.
    case tile
    case columns
    case rows
    /// Near-square grid adapted to the aspect ratio of the area.
    case grid
    /// Every window takes the whole area; they stack.
    case monocle
}

public enum Orientation: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom
}

public struct LayoutParams: Codable, Equatable, Sendable {
    public var mainRatio: Double = 0.55
    public var mainCount: Int = 1
    public var orientation: Orientation = .left
    public init(mainRatio: Double = 0.55, mainCount: Int = 1, orientation: Orientation = .left) {
        self.mainRatio = mainRatio; self.mainCount = mainCount; self.orientation = orientation
    }
}

struct TreeBuilder {
    let params: LayoutParams
    let ratios: [Double]
    private(set) var nextRatio = 0

    init(params: LayoutParams, ratios: [Double]) { self.params = params; self.ratios = ratios }

    private mutating func allocate() -> Int { defer { nextRatio += 1 }; return nextRatio }

    mutating func build(_ kind: LayoutKind, leaves: [[Int]], area: CGRect, gap: CGFloat) -> LayoutNode {
        precondition(!leaves.isEmpty)
        switch kind {
        case .dwindle: return dwindle(leaves[...], area: area, gap: gap, depth: 0)
        case .tile: return tile(leaves)
        case .columns: return linear(leaves[...], axis: .horizontal)
        case .rows: return linear(leaves[...], axis: .vertical)
        case .grid: return grid(leaves, area: area)
        case .monocle: return .leaf(leaves.flatMap { $0 })
        }
    }

    private mutating func dwindle(_ leaves: ArraySlice<[Int]>, area: CGRect, gap: CGFloat, depth: Int) -> LayoutNode {
        guard leaves.count > 1 else { return .leaf(leaves.first!) }
        let axis: Axis = area.width >= area.height ? .horizontal : .vertical
        let ri = allocate()
        let def = depth == 0 ? params.mainRatio : 0.5
        let r = min(max(storedRatio(ratios, ri) ?? def, ratioRange.lowerBound), ratioRange.upperBound)
        // Estimate of the remaining area, only used to pick the next axis.
        let first = (area.length(axis) - gap) * CGFloat(r)
        var rest = area
        if axis == .horizontal { rest.origin.x += first + gap; rest.size.width -= first + gap }
        else { rest.origin.y += first + gap; rest.size.height -= first + gap }
        let head = LayoutNode.leaf(leaves.first!)
        let tail = dwindle(leaves.dropFirst(), area: rest, gap: gap, depth: depth + 1)
        return .split(Split(axis: axis, ratioIndex: ri, defaultRatio: def), head, tail)
    }

    /// Sequential splits: item i takes 1/(remaining) of what is left by default, so all items are
    /// equal until the user moves a boundary.
    private mutating func linear(_ leaves: ArraySlice<[Int]>, axis: Axis) -> LayoutNode {
        guard leaves.count > 1 else { return .leaf(leaves.first!) }
        let ri = allocate()
        let head = LayoutNode.leaf(leaves.first!)
        let tail = linear(leaves.dropFirst(), axis: axis)
        return .split(Split(axis: axis, ratioIndex: ri, defaultRatio: 1.0 / Double(leaves.count),
                            equalShare: leaves.count), head, tail)
    }

    private mutating func tile(_ leaves: [[Int]]) -> LayoutNode {
        let o = params.orientation
        let mainAxis: Axis = (o == .left || o == .right) ? .horizontal : .vertical
        let m = max(0, min(params.mainCount, leaves.count))
        if m == 0 || m >= leaves.count { return linear(leaves[...], axis: mainAxis.opposite) }
        let ri = allocate()
        let main = linear(leaves[0..<m], axis: mainAxis.opposite)
        let stack = linear(leaves[m...], axis: mainAxis.opposite)
        let mainFirst = (o == .left || o == .top)
        let def = mainFirst ? params.mainRatio : 1 - params.mainRatio
        return .split(Split(axis: mainAxis, ratioIndex: ri, defaultRatio: def),
                      mainFirst ? main : stack, mainFirst ? stack : main)
    }

    private mutating func grid(_ leaves: [[Int]], area: CGRect) -> LayoutNode {
        let n = leaves.count
        guard n > 1 else { return .leaf(leaves[0]) }
        let aspect = area.height > 0 ? Double(area.width / area.height) : 1
        var cols = Int((Double(n) * aspect).squareRoot().rounded())
        cols = min(max(cols, 1), n)
        let rows = Int(ceil(Double(n) / Double(cols)))
        // Rebalance so rows differ by at most one item; later rows get the extra ones.
        let base = n / rows, extra = n % rows
        var rowNodes: [[[Int]]] = []
        var k = 0
        for r in 0..<rows {
            let count = base + (r >= rows - extra ? 1 : 0)
            rowNodes.append(Array(leaves[k..<(k + count)]))
            k += count
        }
        if rows == 1 { return linear(leaves[...], axis: .horizontal) }
        return gridRows(rowNodes[...])
    }

    private mutating func gridRows(_ rows: ArraySlice<[[Int]]>) -> LayoutNode {
        if rows.count == 1 { return linear(rows.first![...], axis: .horizontal) }
        let ri = allocate()
        let head = linear(rows.first![...], axis: .horizontal)
        let tail = gridRows(rows.dropFirst())
        return .split(Split(axis: .vertical, ratioIndex: ri, defaultRatio: 1.0 / Double(rows.count),
                            equalShare: rows.count), head, tail)
    }
}
