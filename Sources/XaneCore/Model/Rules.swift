import Foundation

/// Window rules, like sway's `for_window` / river's `rule-add`:
///
///     rule float app-id com.apple.calculator
///     rule tags 3 app-id com.spotify.client
///     rule ignore title "^Picture in Picture$"
///     rule tile subrole AXDialog app-id com.example.Thing
public struct Rule: Equatable, @unchecked Sendable {
    public enum Action: Equatable, Sendable {
        case float, tile, ignore
        case tags(UInt32)
        case output(Int)   // 1-based index in left-to-right display order
    }

    public enum Matcher: Equatable, Sendable {
        case appID(String)       // exact bundle identifier, or prefix when it ends in '*'
        case appName(String)     // exact localized app name
        case title(String)       // regular expression
        case subrole(String)     // AXStandardWindow, AXDialog…
    }

    public var action: Action
    public var matchers: [Matcher]
    private let titleRegexes: [String: NSRegularExpression]

    public init(action: Action, matchers: [Matcher]) throws {
        self.action = action
        self.matchers = matchers
        var regexes: [String: NSRegularExpression] = [:]
        for case .title(let pattern) in matchers {
            do { regexes[pattern] = try NSRegularExpression(pattern: pattern) } catch {
                throw CommandError.invalidArgument("bad title regex: \(pattern)")
            }
        }
        self.titleRegexes = regexes
    }

    public static func == (a: Rule, b: Rule) -> Bool { a.action == b.action && a.matchers == b.matchers }

    public func matches(_ s: WindowSnapshot) -> Bool {
        for m in matchers {
            switch m {
            case .appID(let id):
                if id.hasSuffix("*") { if !s.bundleID.hasPrefix(String(id.dropLast())) { return false } }
                else if s.bundleID != id { return false }
            case .appName(let n): if s.appName != n { return false }
            case .subrole(let r): if s.subrole != r { return false }
            case .title(let pattern):
                let range = NSRange(s.title.startIndex..., in: s.title)
                if titleRegexes[pattern]?.firstMatch(in: s.title, range: range) == nil { return false }
            }
        }
        return !matchers.isEmpty
    }

    public var description: String {
        let a: String
        switch action {
        case .float: a = "float"
        case .tile: a = "tile"
        case .ignore: a = "ignore"
        case .tags(let t): a = "tags \(Tags.describe(t))"
        case .output(let o): a = "output \(o)"
        }
        let m = matchers.map { m -> String in
            switch m {
            case .appID(let v): return "app-id \(Tokenizer.quote(v))"
            case .appName(let v): return "app-name \(Tokenizer.quote(v))"
            case .title(let v): return "title \(Tokenizer.quote(v))"
            case .subrole(let v): return "subrole \(Tokenizer.quote(v))"
            }
        }
        return ([a] + m).joined(separator: " ")
    }
}

public struct Classification: Equatable, Sendable {
    public var management: Management
    public var tags: UInt32?
    public var outputIndex: Int?
    public var reason: String
}

/// Decides how a new window is managed. Pure: rules first, then heuristics on AX attributes.
public func classify(_ s: WindowSnapshot, rules: [Rule]) -> Classification {
    var c = Classification(management: .tile, tags: nil, outputIndex: nil, reason: "a normal window")
    var managementFromRule = false
    // Later rules override earlier ones, like a config file is expected to behave.
    for r in rules where r.matches(s) {
        switch r.action {
        case .float: c.management = .float; managementFromRule = true; c.reason = "rule"
        case .tile: c.management = .tile; managementFromRule = true; c.reason = "rule"
        case .ignore: c.management = .ignore; managementFromRule = true; c.reason = "rule"
        case .tags(let t): c.tags = t
        case .output(let o): c.outputIndex = o
        }
    }
    if managementFromRule { return c }

    if s.role != "AXWindow" { c.management = .ignore; c.reason = "not a window"; return c }
    switch s.subrole {
    case "AXStandardWindow": break
    case "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow":
        c.management = .float; c.reason = "subrole \(s.subrole)"; return c
    default:
        c.management = .ignore; c.reason = "subrole \(s.subrole.isEmpty ? "none" : s.subrole)"; return c
    }
    if s.frame.width < 60 || s.frame.height < 40 { c.management = .ignore; c.reason = "too small"; return c }
    if !s.isSizeSettable || !s.isPositionSettable { c.management = .float; c.reason = "not resizable"; return c }
    if s.isModal || s.hasDialogButtons { c.management = .float; c.reason = "has OK/Cancel buttons"; return c }
    if !s.hasMinimizeButton { c.management = .float; c.reason = "no minimize button"; return c }
    if !s.hasFullscreenButton && !s.hasDocument { c.management = .float; c.reason = "no full-screen button"; return c }
    return c
}
