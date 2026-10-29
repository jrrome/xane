import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Every layout is expressed as a tree of binary splits. Leaves hold one window, or several
/// stacked windows sharing a region (overflow / monocle). Because the tree's axes are fixed before
/// solving, minimum sizes can be propagated exactly and every split is resolved in closed form:
///
///     first = clamp(ratio · avail, minFirst, avail − minSecond)
///
/// No bisection, no "try and check": a tree either has an exact solution or is reported infeasible.
public indirect enum LayoutNode: Equatable, Sendable {
    case leaf([Int])
    case split(Split, LayoutNode, LayoutNode)

    /// Window indices in the subtree, in order.
    public var indices: [Int] {
        switch self {
        case .leaf(let i): return i
        case .split(_, let a, let b): return a.indices + b.indices
        }
    }
}

public struct Split: Equatable, Sendable {
    public var axis: Axis
    /// Slot in the per-(output, layout, count) ratio array this split reads and writes.
    public var ratioIndex: Int
    /// Share of the first child when no ratio has been stored.
    public var defaultRatio: Double
    /// When > 0 and no ratio is stored, the first child gets exactly 1/equalShare of the space
    /// left after the gaps of `equalShare` items (so a run of linear splits is perfectly even).
    public var equalShare: Int

    public init(axis: Axis, ratioIndex: Int, defaultRatio: Double, equalShare: Int = 0) {
        self.axis = axis; self.ratioIndex = ratioIndex; self.defaultRatio = defaultRatio
        self.equalShare = equalShare
    }
}

/// A split as it was resolved, kept so interactive resizes can be mapped back to ratios.
public struct ResolvedSplit: Equatable, Sendable {
    public var axis: Axis
    public var ratioIndex: Int
    public var parent: CGRect
    public var firstEnd: CGFloat      // max edge of the first child along `axis`
    public var secondStart: CGFloat   // min edge of the second child along `axis`
    public var avail: CGFloat         // parent length minus the gap
    public var first: Set<Int>
    public var second: Set<Int>

    public var effectiveRatio: Double { avail > 0 ? Double((firstEnd - parent.start(axis)) / avail) : 0.5 }
}

public let ratioRange: ClosedRange<Double> = 0.05...0.95

/// Stored ratios use 0 (or anything outside 0…1) for "not set, use the default".
@inline(__always) func storedRatio(_ ratios: [Double], _ i: Int) -> Double? {
    guard i >= 0, i < ratios.count else { return nil }
    let r = ratios[i]
    return (r > 0 && r < 1 && r.isFinite) ? r : nil
}

struct TreeSolver {
    let gap: CGFloat
    let minimums: [CGSize]
    let ratios: [Double]

    /// Smallest size the subtree can take.
    func minimumSize(_ node: LayoutNode) -> CGSize {
        switch node {
        case .leaf(let idx):
            var s = CGSize.zero
            for i in idx {
                s.width = max(s.width, minimums[i].width)
                s.height = max(s.height, minimums[i].height)
            }
            return s
        case .split(let sp, let a, let b):
            let ma = minimumSize(a), mb = minimumSize(b)
            if sp.axis == .horizontal {
                return CGSize(width: ma.width + gap + mb.width, height: max(ma.height, mb.height))
            } else {
                return CGSize(width: max(ma.width, mb.width), height: ma.height + gap + mb.height)
            }
        }
    }

    /// Resolves the tree inside `rect`. Returns nil when the minimums cannot be satisfied.
    func solve(_ node: LayoutNode, in rect: CGRect,
               frames: inout [Int: CGRect], splits: inout [ResolvedSplit]) -> Bool {
        switch node {
        case .leaf(let idx):
            for i in idx where !minimums[i].fits(in: rect) { return false }
            for i in idx { frames[i] = rect }
            return true

        case .split(let sp, let a, let b):
            let axis = sp.axis
            let len = rect.length(axis)
            let avail = len - gap
            guard avail >= 2 else { return false }
            let ma = minimumSize(a), mb = minimumSize(b)
            let crossNeed = max(ma.crossLength(axis), mb.crossLength(axis))
            guard crossNeed <= rect.crossLength(axis) + 0.5 else { return false }
            let minFirst = ceil(ma.length(axis) - 0.5), minSecond = ceil(mb.length(axis) - 0.5)
            guard minFirst + minSecond <= avail else { return false }

            var size: CGFloat
            if let stored = storedRatio(ratios, sp.ratioIndex) {
                size = floor(avail * CGFloat(min(max(stored, ratioRange.lowerBound), ratioRange.upperBound)))
            } else if sp.equalShare > 1 {
                let k = CGFloat(sp.equalShare)
                size = floor((len - (k - 1) * gap) / k)
            } else {
                size = floor(avail * CGFloat(min(max(sp.defaultRatio, ratioRange.lowerBound), ratioRange.upperBound)))
            }
            size = max(size, max(1, minFirst))
            size = min(size, floor(avail - max(1, minSecond)))
            guard size >= 1, avail - size >= 1 else { return false }

            let firstRect: CGRect, secondRect: CGRect
            if axis == .horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: size, height: rect.height)
                secondRect = CGRect(x: rect.minX + size + gap, y: rect.minY,
                                    width: len - size - gap, height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: size)
                secondRect = CGRect(x: rect.minX, y: rect.minY + size + gap,
                                    width: rect.width, height: len - size - gap)
            }
            splits.append(ResolvedSplit(axis: axis, ratioIndex: sp.ratioIndex, parent: rect,
                                        firstEnd: firstRect.end(axis), secondStart: secondRect.start(axis),
                                        avail: avail, first: Set(a.indices), second: Set(b.indices)))
            return solve(a, in: firstRect, frames: &frames, splits: &splits)
                && solve(b, in: secondRect, frames: &frames, splits: &splits)
        }
    }
}

// MARK: - Mapping edits back to ratios

/// Interactive resize: the user dragged an edge of window `index` from `old` to `new`.
/// Each moved edge is matched to the split whose boundary it sits on; that split's ratio becomes
/// whatever reproduces the new edge. Edges that are on the output border have no split and are
/// ignored (the window snaps back on that side).
public func ratiosAfterResize(_ ratios: [Double], splits: [ResolvedSplit], index: Int,
                              old: CGRect, new: CGRect, gap: CGFloat, threshold: CGFloat = 2) -> [Double] {
    var out = ratios
    func set(_ sp: ResolvedSplit, firstLength: CGFloat) {
        guard sp.avail > 0 else { return }
        let r = min(max(Double(firstLength / sp.avail), ratioRange.lowerBound), ratioRange.upperBound)
        if out.count <= sp.ratioIndex { out += Array(repeating: 0, count: sp.ratioIndex + 1 - out.count) }
        out[sp.ratioIndex] = (r * 1000).rounded() / 1000
    }
    let tol: CGFloat = max(1.5, gap / 2 + 1)
    // Leading edges (left / top) — the window is in the second child of the split.
    for axis in [Axis.horizontal, .vertical] {
        let oldStart = old.start(axis), newStart = new.start(axis)
        if abs(newStart - oldStart) > threshold,
           let sp = splits.first(where: { $0.axis == axis && $0.second.contains(index) && abs($0.secondStart - oldStart) <= tol }) {
            set(sp, firstLength: newStart - gap - sp.parent.start(axis))
        }
        let oldEnd = old.end(axis), newEnd = new.end(axis)
        if abs(newEnd - oldEnd) > threshold,
           let sp = splits.first(where: { $0.axis == axis && $0.first.contains(index) && abs($0.firstEnd - oldEnd) <= tol }) {
            set(sp, firstLength: newEnd - sp.parent.start(axis))
        }
    }
    return out
}

/// Keyboard resize: grows (delta > 0) or shrinks the window by moving the boundary of the
/// innermost split that contains it, optionally restricted to one axis.
public func ratiosAfterGrow(_ ratios: [Double], splits: [ResolvedSplit], index: Int,
                            delta: Double, axis: Axis? = nil) -> [Double]? {
    // Innermost split = smallest parent area among those containing the window.
    let candidates = splits.filter { ($0.first.contains(index) || $0.second.contains(index)) && (axis == nil || $0.axis == axis) }
    guard let sp = candidates.min(by: { $0.parent.width * $0.parent.height < $1.parent.width * $1.parent.height }) else {
        return nil
    }
    var out = ratios
    if out.count <= sp.ratioIndex { out += Array(repeating: 0, count: sp.ratioIndex + 1 - out.count) }
    let base = sp.effectiveRatio
    let r = sp.first.contains(index) ? base + delta : base - delta
    out[sp.ratioIndex] = (min(max(r, ratioRange.lowerBound), ratioRange.upperBound) * 1000).rounded() / 1000
    return out
}
