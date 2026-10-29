import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum AttachMode: String, Codable, CaseIterable, Sendable {
    /// New windows become the main window.
    case top
    /// New windows go to the end of the stack.
    case bottom
    /// New windows go right after the focused one (dwindle splits the focused tile).
    case afterFocused = "after-focused"
}

public enum NewWindowOutput: String, Codable, CaseIterable, Sendable {
    /// The display under the pointer — where the user is looking.
    case pointer
    /// The display of the focused window.
    case focused
    /// Wherever the app opened it.
    case app
}

public enum DesktopMode: String, Codable, CaseIterable, Sendable {
    /// XaneWM's own desktops (river/dwm tags) on one macOS Space: they switch instantly.
    case tags
    /// macOS Spaces: `view`/`tag` go through Mission Control and each Space tiles its own windows.
    case spaces
}

public struct Options: Codable, Equatable, Sendable {
    public var innerGap: CGFloat = 8
    public var outerGap: CGFloat = 8
    public var defaultLayout: LayoutKind = .dwindle
    public var mainRatio: Double = 0.55
    public var attach: AttachMode = .afterFocused
    public var overflow: OverflowMode = .stack
    public var maxTiled: Int = 0
    public var newWindowOutput: NewWindowOutput = .pointer
    public var focusFollowsMouse = true
    /// 0 = focus on entering a window; otherwise only once the pointer rests that long.
    public var focusFollowsMouseDelay: Double = 0
    public var mouseFollowsFocus = false
    /// `view N` while already on N goes back to the previous tags.
    public var viewBackAndForth = true
    /// Focusing a window on a hidden tag (⌘-Tab, Dock click) switches to that tag.
    public var followActivation = true
    public var border = true
    public var borderWidth: CGFloat = 3
    /// "accent" or #RRGGBB / #RRGGBBAA.
    public var borderColor = "accent"
    public var borderRadius: CGFloat = 12
    /// Reserved screen edges for other apps' bars/docks.
    public var edges = EdgeInsets.zero
    /// Re-assert the layout when an app moves or resizes a tiled window by itself.
    public var enforceLayout = true
    public var desktops: DesktopMode = .tags

    public init() {}

    public enum Failure: Error, CustomStringConvertible {
        case unknown(String), invalid(String, String)
        public var description: String {
            switch self {
            case .unknown(let n): return "unknown option '\(n)'"
            case .invalid(let n, let v): return "invalid value '\(v)' for '\(n)'"
            }
        }
    }

    public static let names = [
        "gap", "gap-inner", "gap-outer", "default-layout", "main-ratio", "attach", "overflow", "max-tiled",
        "new-window-output", "focus-follows-mouse", "focus-follows-mouse-delay", "mouse-follows-focus",
        "view-back-and-forth", "follow-activation", "border", "border-width", "border-color", "border-radius",
        "edges", "enforce-layout", "desktops",
    ]

    /// `set <name> <values…>`
    public mutating func set(_ name: String, _ values: [String]) throws {
        let v = values.first ?? ""
        func num(_ range: ClosedRange<Double>) throws -> Double {
            guard let d = Double(v), range.contains(d) else { throw Failure.invalid(name, v) }
            return d
        }
        func bool() throws -> Bool {
            switch v.lowercased() {
            case "on", "true", "yes", "1": return true
            case "off", "false", "no", "0": return false
            default: throw Failure.invalid(name, v)
            }
        }
        func pick<T: RawRepresentable>(_: T.Type) throws -> T where T.RawValue == String {
            guard let t = T(rawValue: v.lowercased()) else { throw Failure.invalid(name, v) }
            return t
        }
        switch name {
        case "gap": innerGap = CGFloat(try num(0...200)); outerGap = innerGap
        case "gap-inner": innerGap = CGFloat(try num(0...200))
        case "gap-outer": outerGap = CGFloat(try num(0...400))
        case "default-layout": defaultLayout = try pick(LayoutKind.self)
        case "main-ratio": mainRatio = try num(ratioRange)
        case "attach": attach = try pick(AttachMode.self)
        case "overflow": overflow = try pick(OverflowMode.self)
        case "max-tiled": maxTiled = Int(try num(0...64))
        case "new-window-output": newWindowOutput = try pick(NewWindowOutput.self)
        case "focus-follows-mouse": focusFollowsMouse = try bool()
        case "focus-follows-mouse-delay": focusFollowsMouseDelay = try num(0...2)
        case "mouse-follows-focus": mouseFollowsFocus = try bool()
        case "view-back-and-forth": viewBackAndForth = try bool()
        case "follow-activation": followActivation = try bool()
        case "border": border = try bool()
        case "border-width": borderWidth = CGFloat(try num(0...30))
        case "border-color":
            guard v == "accent" || Options.parseHexColor(v) != nil else { throw Failure.invalid(name, v) }
            borderColor = v
        case "border-radius": borderRadius = CGFloat(try num(0...60))
        case "edges":
            // edges <all> | <vertical> <horizontal> | <top> <right> <bottom> <left>  (CSS order)
            let n = try values.map { s -> CGFloat in
                guard let d = Double(s), (0...2000).contains(d) else { throw Failure.invalid(name, s) }
                return CGFloat(d)
            }
            switch n.count {
            case 1: edges = EdgeInsets(top: n[0], left: n[0], bottom: n[0], right: n[0])
            case 2: edges = EdgeInsets(top: n[0], left: n[1], bottom: n[0], right: n[1])
            case 4: edges = EdgeInsets(top: n[0], left: n[3], bottom: n[2], right: n[1])
            default: throw Failure.invalid(name, values.joined(separator: " "))
            }
        case "enforce-layout": enforceLayout = try bool()
        case "desktops": desktops = try pick(DesktopMode.self)
        default: throw Failure.unknown(name)
        }
    }

    /// #RRGGBB or #RRGGBBAA → (r, g, b, a) in 0…1.
    public static func parseHexColor(_ s: String) -> (Double, Double, Double, Double)? {
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let v = UInt32(hex, radix: 16) else { return nil }
        let full = hex.count == 6 ? (v << 8) | 0xFF : v
        return (Double((full >> 24) & 0xFF) / 255, Double((full >> 16) & 0xFF) / 255,
                Double((full >> 8) & 0xFF) / 255, Double(full & 0xFF) / 255)
    }
}
