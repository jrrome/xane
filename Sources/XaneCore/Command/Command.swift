import Foundation

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknownCommand(String)
    case missingArgument(String)
    case invalidArgument(String)
    case nothingToActOn

    public var description: String {
        switch self {
        case .empty: return "empty command"
        case .unknownCommand(let c): return "unknown command '\(c)'"
        case .missingArgument(let a): return "missing argument: \(a)"
        case .invalidArgument(let a): return "invalid argument: \(a)"
        case .nothingToActOn: return "no window to act on"
        }
    }
}

public enum Target: Equatable, Sendable {
    case direction(Direction), next, previous, main, recent
}

public enum OutputTarget: Equatable, Sendable {
    case next, previous, direction(Direction), index(Int)
}

public enum Toggle: Equatable, Sendable { case toggle, on, off }

public enum Adjust: Equatable, Sendable {
    case set(Double), delta(Double)
    public func apply(to v: Double) -> Double {
        switch self { case .set(let x): return x; case .delta(let d): return v + d }
    }
}

public enum LayoutChoice: Equatable, Sendable { case kind(LayoutKind), next, previous }

public enum TagArg: Equatable, Sendable { case mask(UInt32), previous }

/// Everything the compositor can be asked to do. Key bindings, the config file and `xanectl`
/// all speak this same language (one parser, one executor).
public enum Command: Equatable, Sendable {
    case focus(Target), swap(Target), zoom
    case float(Toggle), fullscreen(Toggle), close
    case layout(LayoutChoice), mainRatio(Adjust), mainCount(Adjust), orientation(Orientation?)
    case resize(delta: Double, axis: Axis?), resetLayout
    case view(TagArg), viewToggle(UInt32), tag(UInt32), tagToggle(UInt32)
    case focusOutput(OutputTarget), sendToOutput(OutputTarget)
    case retile, reload, pause, resume, togglePause, quit, settings
    case set(String, [String])
    case rule(Rule), ruleClear
    case bind(KeyCombo, String), unbind(KeyCombo?)
    case query(String), subscribe
    case exec(String)

    /// Commands that only read state.
    public var isReadOnly: Bool {
        switch self { case .query, .subscribe, .settings: return true; default: return false }
    }

    public static let names = [
        "focus", "swap", "zoom", "float", "toggle-float", "fullscreen", "toggle-fullscreen", "close",
        "layout", "main-ratio", "main-count", "orientation", "resize", "reset-layout", "view", "view-toggle",
        "tag", "tag-toggle", "set-focused-tags", "set-view-tags", "focus-output", "send-to-output", "retile",
        "reload", "pause", "resume", "toggle-pause", "quit", "set", "rule", "rule-clear", "bind", "unbind",
        "query", "subscribe", "exec",
    ]
}

// MARK: - Parsing

public enum CommandParser {
    /// Parses a line that may contain several commands separated by `;`. `bind` and `exec`
    /// take the rest of their command (up to the next unquoted `;` for exec; the whole rest of the
    /// line for bind, so a binding can itself contain `;`).
    public static func parseLine(_ line: String) -> [Result<Command, CommandError>] {
        var out: [Result<Command, CommandError>] = []
        var rest = Substring(line)
        while true {
            let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.isEmpty || trimmed.hasPrefix("#") { break }
            let head = trimmed.prefix(while: { !$0.isWhitespace && $0 != ";" })
            if head == "bind" {
                out.append(parseBind(String(trimmed.dropFirst(4))))
                break
            }
            let (segment, remainder) = splitAtSemicolon(trimmed)
            if head == "exec" || head == "spawn" {
                out.append(parseExec(segment.dropFirst(head.count)))
                guard let r = remainder else { break }
                rest = r
                continue
            }
            switch Tokenizer.tokenize(String(segment)) {
            case .success(let tokens):
                if !tokens.isEmpty { out.append(parse(tokens)) }
            case .failure(let e): out.append(.failure(e))
            }
            guard let r = remainder else { break }
            rest = r
        }
        return out
    }

    static func splitAtSemicolon(_ s: Substring) -> (Substring, Substring?) {
        var quote: Character?
        var escaped = false
        for i in s.indices {
            let c = s[i]
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            // Inline comment: a lone '#' surrounded by whitespace (so #RRGGBB colours still work).
            if c == "#", i > s.startIndex, s[s.index(before: i)].isWhitespace {
                let n = s.index(after: i)
                if n == s.endIndex || s[n].isWhitespace { return (s[..<i], nil) }
            }
            if c == ";" { return (s[..<i], s[s.index(after: i)...]) }
        }
        return (s, nil)
    }

    /// Drops a trailing ` # comment` (outside quotes).
    static func stripComment(_ s: Substring) -> Substring {
        var quote: Character?
        var escaped = false
        for i in s.indices {
            let c = s[i]
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "#", i > s.startIndex, s[s.index(before: i)].isWhitespace {
                let n = s.index(after: i)
                if n == s.endIndex || s[n].isWhitespace { return s[..<i] }
            }
        }
        return s
    }

    /// `exec` hands its text to `sh -c` as written, so shell quoting survives
    /// (`exec open -a "Visual Studio Code"`). A single quoted argument is unwrapped, so
    /// `exec "a; b"` can carry a `;`.
    static func parseExec(_ rest: Substring) -> Result<Command, CommandError> {
        let raw = rest.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return .failure(.missingArgument("command")) }
        switch Tokenizer.tokenize(raw) {
        case .failure(let e): return .failure(e)
        case .success(let tokens):
            if tokens.count == 1, let q = raw.first, q == "\"" || q == "'", raw.last == q { return .success(.exec(tokens[0])) }
            return .success(.exec(raw))
        }
    }

    static func parseBind(_ rest: String) -> Result<Command, CommandError> {
        let t = rest.drop(while: { $0.isWhitespace })
        let comboText = t.prefix(while: { !$0.isWhitespace })
        guard !comboText.isEmpty else { return .failure(.missingArgument("key combination")) }
        guard let combo = KeyCombo.parse(String(comboText)) else {
            return .failure(.invalidArgument("key combination '\(comboText)'"))
        }
        let cmd = stripComment(t.dropFirst(comboText.count)).trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return .failure(.missingArgument("command for \(comboText)")) }
        // Validate now so a typo in the config is reported at load time, not on key press.
        for r in parseLine(cmd) { if case .failure(let e) = r { return .failure(e) } }
        return .success(.bind(combo, cmd))
    }

    public static func parse(_ tokens: [String]) -> Result<Command, CommandError> {
        do { return .success(try parseThrowing(tokens)) } catch let e as CommandError { return .failure(e) }
        catch { return .failure(.invalidArgument("\(error)")) }
    }

    static func parseThrowing(_ t: [String]) throws -> Command {
        guard let name = t.first?.lowercased() else { throw CommandError.empty }
        let args = Array(t.dropFirst())
        func arg(_ i: Int, _ what: String) throws -> String {
            guard i < args.count else { throw CommandError.missingArgument(what) }
            return args[i]
        }
        func toggle() throws -> Toggle {
            guard let a = args.first else { return .toggle }
            switch a.lowercased() {
            case "toggle": return .toggle
            case "on", "enable", "true": return .on
            case "off", "disable", "false": return .off
            default: throw CommandError.invalidArgument(a)
            }
        }
        switch name {
        case "focus": return .focus(try target(arg(0, "direction")))
        case "swap": return .swap(try target(arg(0, "direction")))
        case "zoom": return .zoom
        case "float": return .float(try toggle())
        case "toggle-float": return .float(.toggle)
        case "fullscreen": return .fullscreen(try toggle())
        case "toggle-fullscreen": return .fullscreen(.toggle)
        case "close": return .close
        case "layout":
            let a = try arg(0, "layout").lowercased()
            if a == "next" { return .layout(.next) }
            if a == "prev" || a == "previous" { return .layout(.previous) }
            guard let k = LayoutKind(rawValue: a) else { throw CommandError.invalidArgument("layout '\(a)'") }
            return .layout(.kind(k))
        case "main-ratio": return .mainRatio(try adjust(arg(0, "ratio"), range: 0...1))
        case "main-count": return .mainCount(try adjust(arg(0, "count"), range: 0...16))
        case "orientation":
            let a = try arg(0, "orientation").lowercased()
            if a == "next" { return .orientation(nil) }
            guard let o = Orientation(rawValue: a) else { throw CommandError.invalidArgument(a) }
            return .orientation(o)
        case "resize":
            let dir = try arg(0, "grow|shrink").lowercased()
            guard dir == "grow" || dir == "shrink" else { throw CommandError.invalidArgument(dir) }
            var amount = 0.05
            var axis: Axis?
            for a in args.dropFirst() {
                if let d = Double(a), d > 0, d < 1 { amount = d }
                else if a == "horizontal" || a == "width" { axis = .horizontal }
                else if a == "vertical" || a == "height" { axis = .vertical }
                else { throw CommandError.invalidArgument(a) }
            }
            return .resize(delta: dir == "grow" ? amount : -amount, axis: axis)
        case "reset-layout": return .resetLayout
        case "view":
            let a = try arg(0, "tag")
            if a == "prev" || a == "previous" || a == "back" { return .view(.previous) }
            return .view(.mask(try tagMask(a)))
        case "view-toggle": return .viewToggle(try tagMask(arg(0, "tag")))
        case "tag": return .tag(try tagMask(arg(0, "tag")))
        case "tag-toggle": return .tagToggle(try tagMask(arg(0, "tag")))
        case "set-focused-tags": return .view(.mask(try rawMask(arg(0, "mask"))))
        case "set-view-tags": return .tag(try rawMask(arg(0, "mask")))
        case "focus-output": return .focusOutput(try outputTarget(arg(0, "output")))
        case "send-to-output": return .sendToOutput(try outputTarget(arg(0, "output")))
        case "retile": return .retile
        case "reload": return .reload
        case "pause": return .pause
        case "resume": return .resume
        case "toggle-pause": return .togglePause
        case "quit", "exit": return .quit
        case "settings", "preferences": return .settings
        case "set":
            let opt = try arg(0, "option").lowercased()
            guard args.count >= 2 else { throw CommandError.missingArgument("value for \(opt)") }
            var probe = Options()
            do { try probe.set(opt, Array(args.dropFirst())) } catch {
                throw CommandError.invalidArgument("\(error)")
            }
            return .set(opt, Array(args.dropFirst()))
        case "rule": return .rule(try rule(args))
        case "rule-clear": return .ruleClear
        case "bind": return try parseBind(args.joined(separator: " ")).get()
        case "unbind":
            let a = try arg(0, "key combination")
            if a == "all" { return .unbind(nil) }
            guard let c = KeyCombo.parse(a) else { throw CommandError.invalidArgument(a) }
            return .unbind(c)
        case "query", "get":
            let what = (args.first ?? "state").lowercased()
            guard ["windows", "outputs", "state", "bindings", "rules", "options", "tree"].contains(what) else {
                throw CommandError.invalidArgument(what)
            }
            return .query(what)
        case "subscribe": return .subscribe
        case "exec", "spawn":
            guard !args.isEmpty else { throw CommandError.missingArgument("command") }
            return .exec(args.joined(separator: " "))
        default: throw CommandError.unknownCommand(name)
        }
    }

    static func target(_ s: String) throws -> Target {
        switch s.lowercased() {
        case "left", "h": return .direction(.left)
        case "right", "l": return .direction(.right)
        case "up", "k": return .direction(.up)
        case "down", "j": return .direction(.down)
        case "next": return .next
        case "prev", "previous": return .previous
        case "main", "master": return .main
        case "recent", "last": return .recent
        default: throw CommandError.invalidArgument("direction '\(s)'")
        }
    }

    static func outputTarget(_ s: String) throws -> OutputTarget {
        switch s.lowercased() {
        case "next": return .next
        case "prev", "previous": return .previous
        case "left": return .direction(.left)
        case "right": return .direction(.right)
        case "up": return .direction(.up)
        case "down": return .direction(.down)
        default:
            guard let i = Int(s), i >= 1 else { throw CommandError.invalidArgument("output '\(s)'") }
            return .index(i)
        }
    }

    static func adjust(_ s: String, range: ClosedRange<Double>) throws -> Adjust {
        if s.hasPrefix("+") || s.hasPrefix("-") {
            guard let d = Double(s) else { throw CommandError.invalidArgument(s) }
            return .delta(d)
        }
        guard let v = Double(s), range.contains(v) else { throw CommandError.invalidArgument(s) }
        return .set(v)
    }

    static func tagMask(_ s: String) throws -> UInt32 {
        if s.lowercased() == "all" { return Tags.all }
        // "1", or "1,3" to address several tags at once.
        var mask: UInt32 = 0
        for part in s.split(separator: ",") {
            guard let n = Int(part), let m = Tags.mask(n) else { throw CommandError.invalidArgument("tag '\(s)'") }
            mask |= m
        }
        guard mask != 0 else { throw CommandError.invalidArgument("tag '\(s)'") }
        return mask
    }

    static func rawMask(_ s: String) throws -> UInt32 {
        let v: UInt32? = s.lowercased().hasPrefix("0x") ? UInt32(s.dropFirst(2), radix: 16) : UInt32(s)
        guard let m = v, m != 0 else { throw CommandError.invalidArgument("mask '\(s)'") }
        return m
    }

    static func rule(_ a: [String]) throws -> Rule {
        guard let first = a.first?.lowercased() else { throw CommandError.missingArgument("rule action") }
        var i = 1
        let action: Rule.Action
        switch first {
        case "float": action = .float
        case "tile": action = .tile
        case "ignore": action = .ignore
        case "tags", "tag":
            guard i < a.count else { throw CommandError.missingArgument("tags") }
            action = .tags(try tagMask(a[i])); i += 1
        case "output":
            guard i < a.count, let n = Int(a[i]), n >= 1 else { throw CommandError.missingArgument("output index") }
            action = .output(n); i += 1
        default: throw CommandError.invalidArgument("rule action '\(first)'")
        }
        var matchers: [Rule.Matcher] = []
        while i < a.count {
            let key = a[i].lowercased()
            guard i + 1 < a.count else { throw CommandError.missingArgument("value for \(key)") }
            let v = a[i + 1]
            switch key {
            case "app-id", "bundle-id", "app": matchers.append(.appID(v))
            case "app-name", "name": matchers.append(.appName(v))
            case "title": matchers.append(.title(v))
            case "subrole": matchers.append(.subrole(v))
            default: throw CommandError.invalidArgument("rule matcher '\(key)'")
            }
            i += 2
        }
        guard !matchers.isEmpty else { throw CommandError.missingArgument("rule matcher (app-id, title…)") }
        return try Rule(action: action, matchers: matchers)
    }
}

/// Shell-like tokenizer: whitespace separated, "double" and 'single' quotes, backslash escapes.
public enum Tokenizer {
    public static func tokenize(_ s: String) -> Result<[String], CommandError> {
        var tokens: [String] = []
        var cur = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for c in s {
            if escaped { cur.append(c); escaped = false; inToken = true; continue }
            if c == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; inToken = true; continue }
            if c.isWhitespace {
                if inToken { tokens.append(cur); cur = ""; inToken = false }
                continue
            }
            cur.append(c); inToken = true
        }
        if quote != nil { return .failure(.invalidArgument("unterminated quote")) }
        if escaped { cur.append("\\") }
        if inToken { tokens.append(cur) }
        return .success(tokens)
    }

    /// Quotes a token so `tokenize` gives it back unchanged.
    public static func quote(_ s: String) -> String {
        if !s.isEmpty && !s.contains(where: { $0.isWhitespace || "\"'\\;#".contains($0) }) { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
