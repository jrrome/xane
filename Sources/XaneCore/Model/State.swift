import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The compositor's whole world as plain values. The compositor keeps two copies, like a
/// wl_surface: requests mutate `pending`, `commit()` turns it into `current` atomically.
public struct State: Sendable {
    public var windows: [WindowID: Window] = [:]
    /// Global tiling order (river's view list). Each output tiles the visible windows of this list
    /// that belong to it, in this order.
    public var order: [WindowID] = []
    public var focused: WindowID?
    /// Most recently focused first.
    public var focusHistory: [WindowID] = []
    public var outputs: [OutputID: Output] = [:]
    public var focusedOutput: OutputID?
    public var options = Options()
    public var rules: [Rule] = []
    public var bindings: [KeyCombo: String] = [:]
    /// Split ratios per "uuid|layout|tiles".
    public var ratios: [String: [Double]] = [:]
    public var paused = false

    public init() {}

    /// Outputs left to right, then top to bottom.
    public var outputOrder: [OutputID] {
        outputs.values.sorted {
            $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }.map(\.id)
    }

    public func isVisible(_ id: WindowID) -> Bool {
        guard let w = windows[id] else { return false }
        return isVisible(w)
    }

    public func isVisible(_ w: Window) -> Bool {
        // Desktops are macOS Spaces: the window server hides the others (see `onCurrentSpace`).
        w.isPresent && outputs[w.output] != nil
    }

    /// Visible windows of an output in tiling order.
    public func visible(on output: OutputID) -> [WindowID] {
        order.filter { id in windows[id].map { $0.output == output && isVisible($0) } ?? false }
    }

    /// Visible windows of an output that take part in the layout.
    public func tiled(on output: OutputID) -> [WindowID] {
        order.filter { id in
            guard let w = windows[id] else { return false }
            return w.output == output && !w.floating && !w.fullscreen && isVisible(w)
        }
    }

    public func usableArea(of output: Output) -> CGRect {
        XaneCore.usableArea(output.visibleFrame, reserving: options.edges)
    }

    public func ratioKey(_ output: Output, _ kind: LayoutKind, _ tiles: Int) -> String {
        "\(output.uuid)|\(kind.rawValue)|\(tiles)"
    }

    /// The output containing a point (or the closest one).
    public func output(at p: CGPoint) -> OutputID? {
        if let o = outputs.values.first(where: { $0.frame.contains(p) }) { return o.id }
        return outputs.values.min(by: { distance($0.frame, p) < distance($1.frame, p) })?.id
    }

    /// The output showing most of a rectangle.
    public func output(for rect: CGRect) -> OutputID? {
        let best = outputs.values.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
        if let b = best, b.frame.intersects(rect) { return b.id }
        return output(at: rect.center)
    }

    /// The window that should get focus on an output when nothing else says so: most recently
    /// focused visible window, else the first visible one.
    public func focusCandidate(on output: OutputID) -> WindowID? {
        let vis = Set(visible(on: output))
        return focusHistory.first(where: vis.contains) ?? visible(on: output).first
    }

    /// The window commands act on: the focused one, or the most recent visible one.
    public var subject: WindowID? {
        if let f = focused, isVisible(f) { return f }
        if let o = focusedOutput { return focusCandidate(on: o) }
        return focusHistory.first(where: { isVisible($0) })
    }

    public var subjectOutput: OutputID? {
        if let s = subject, let w = windows[s] { return w.output }
        return focusedOutput ?? outputOrder.first
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
    let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
    return (dx * dx + dy * dy).squareRoot()
}
