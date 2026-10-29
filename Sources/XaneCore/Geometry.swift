import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Window identifier. On macOS this is the window server's `CGWindowID`, which is stable for the
/// lifetime of the window and shared by AX and `CGWindowList`.
public typealias WindowID = UInt32
/// Display identifier (`CGDirectDisplayID` on macOS).
public typealias OutputID = UInt32

/// All rectangles in XaneCore use the window-server coordinate space: origin at the top-left corner
/// of the primary display, y growing downwards (the same space AX and CGWindowList use).

/// The axis a split runs along. `.horizontal` places children side by side (cuts the x extent),
/// `.vertical` stacks them top to bottom (cuts the y extent).
public enum Axis: String, Codable, Sendable {
    case horizontal, vertical

    public var opposite: Axis { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    public var axis: Axis { (self == .left || self == .right) ? .horizontal : .vertical }
}

extension CGRect {
    @inlinable public func length(_ axis: Axis) -> CGFloat { axis == .horizontal ? width : height }
    @inlinable public func crossLength(_ axis: Axis) -> CGFloat { axis == .horizontal ? height : width }
    @inlinable public func start(_ axis: Axis) -> CGFloat { axis == .horizontal ? minX : minY }
    @inlinable public func end(_ axis: Axis) -> CGFloat { axis == .horizontal ? maxX : maxY }
    @inlinable public var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Snaps to whole points, shrinking inwards so the result never grows past the original.
    public var snappedInward: CGRect {
        let x0 = ceil(minX), y0 = ceil(minY), x1 = floor(maxX), y1 = floor(maxY)
        return CGRect(x: x0, y: y0, width: Swift.max(0, x1 - x0), height: Swift.max(0, y1 - y0))
    }

    public func isClose(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public func inset(by e: EdgeInsets) -> CGRect {
        CGRect(x: minX + e.left, y: minY + e.top,
               width: Swift.max(0, width - e.left - e.right),
               height: Swift.max(0, height - e.top - e.bottom))
    }

    /// Fraction of `self` covered by `other` (0…1).
    public func coverage(by other: CGRect) -> CGFloat {
        let i = intersection(other)
        guard !i.isNull, width > 0, height > 0 else { return 0 }
        return (i.width * i.height) / (width * height)
    }

    /// Moves (without resizing, unless it does not fit) so the rect lies inside `bounds`.
    public func clamped(into bounds: CGRect) -> CGRect {
        let w = Swift.min(width, bounds.width), h = Swift.min(height, bounds.height)
        let x = Swift.min(Swift.max(minX, bounds.minX), bounds.maxX - w)
        let y = Swift.min(Swift.max(minY, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

extension CGPoint {
    public func isClose(to other: CGPoint, tolerance: CGFloat) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}

extension CGSize {
    @inlinable public func length(_ axis: Axis) -> CGFloat { axis == .horizontal ? width : height }
    @inlinable public func crossLength(_ axis: Axis) -> CGFloat { axis == .horizontal ? height : width }
    public func fits(in rect: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        width <= rect.width + tolerance && height <= rect.height + tolerance
    }
}

public struct EdgeInsets: Codable, Equatable, Sendable {
    public var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    public static let zero = EdgeInsets()
}

/// Reserved screen edges (docks/bars of other apps). Never leaves less than `minimumUsable`
/// points of usable area: when the reservation is too large it is scaled down proportionally.
public func usableArea(_ visible: CGRect, reserving e: EdgeInsets,
                       minimumUsable: CGSize = CGSize(width: 400, height: 300)) -> CGRect {
    var l = Swift.max(0, e.left), r = Swift.max(0, e.right), t = Swift.max(0, e.top), b = Swift.max(0, e.bottom)
    let maxH = Swift.max(0, visible.width - minimumUsable.width)
    if l + r > maxH, l + r > 0 { let k = maxH / (l + r); l *= k; r *= k }
    let maxV = Swift.max(0, visible.height - minimumUsable.height)
    if t + b > maxV, t + b > 0 { let k = maxV / (t + b); t *= k; b *= k }
    return visible.inset(by: EdgeInsets(top: t, left: l, bottom: b, right: r))
}

/// A Codable, JSON-friendly rectangle for the wire protocol and persistence.
public struct Rect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(_ r: CGRect) { x = Double(r.minX); y = Double(r.minY); w = Double(r.width); h = Double(r.height) }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
