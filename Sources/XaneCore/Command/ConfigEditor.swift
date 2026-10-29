import Foundation

/// Edits the config file as text, for the settings window: the file stays the user's (comments,
/// order, blank lines, `exec` lines…) and each change rewrites only the command it is about.
public struct ConfigEditor {
    public private(set) var lines: [String]

    public init(_ text: String) {
        lines = text.components(separatedBy: "\n")
    }

    public var text: String { lines.joined(separator: "\n") }

    /// One command line split into what the editor needs. Continued (`\`) lines are left alone.
    struct Parsed {
        var tokens: [String]
        /// Text after the command (` # comment`), kept when the line is rewritten.
        var comment: Substring
        var commandWidth: Int
    }

    func parse(_ i: Int, commented: Bool = false) -> Parsed? {
        var line = Substring(lines[i])
        if line.hasSuffix("\\") || (i > 0 && lines[i - 1].hasSuffix("\\")) { return nil }
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        if commented {
            guard trimmed.hasPrefix("#") else { return nil }
            line = trimmed.dropFirst().drop(while: { $0 == " " })
        } else if trimmed.hasPrefix("#") {
            return nil
        }
        let command = CommandParser.stripComment(line)
        guard case .success(let tokens) = Tokenizer.tokenize(String(command)), !tokens.isEmpty else { return nil }
        return Parsed(tokens: tokens, comment: commented ? "" : line[command.endIndex...], commandWidth: command.count)
    }

    /// The new command, padded so a trailing comment stays in its column.
    func rewrite(_ old: Parsed, _ command: String) -> String {
        guard !old.comment.isEmpty else { return command }
        let pad = max(old.commandWidth - command.count, 1)
        return command + String(repeating: " ", count: pad) + old.comment.drop(while: { $0 == " " || $0 == "\t" })
    }

    // MARK: - Options

    /// `set name values…`: rewrites the last line setting it, else uncomments a commented-out one
    /// (`# set edges 0 0 0 0`), else adds it to the end.
    public mutating func setOption(_ name: String, _ values: [String]) {
        let command = (["set", name] + values.map(Tokenizer.quote)).joined(separator: " ")
        func isIt(_ p: Parsed?) -> Bool { p.map { $0.tokens.count >= 2 && $0.tokens[0] == "set" && $0.tokens[1] == name } ?? false }
        if let i = lines.indices.last(where: { isIt(parse($0)) }) {
            lines[i] = rewrite(parse(i)!, command)
        } else if let i = lines.indices.last(where: { isIt(parse($0, commented: true)) }) {
            lines[i] = command
        } else {
            append(command, after: { $0.tokens.first == "set" })
        }
    }

    // MARK: - Bindings

    /// The binding lines as the file has them (later lines win, like at load time).
    public var bindings: [(combo: KeyCombo, command: String)] {
        var seen: [KeyCombo: Int] = [:]
        var out: [(combo: KeyCombo, command: String)] = []
        for i in lines.indices {
            guard let (combo, command) = binding(at: i) else { continue }
            if let j = seen[combo] { out[j].command = command } else { seen[combo] = out.count; out.append((combo, command)) }
        }
        return out
    }

    func binding(at i: Int) -> (KeyCombo, String)? {
        guard let p = parse(i), p.tokens.count >= 3, p.tokens[0] == "bind" else { return nil }
        guard case .success(.bind(let combo, let command))? = CommandParser.parseLine(lines[i]).first else { return nil }
        return (combo, command)
    }

    /// Binds `combo` to `command`, or unbinds it when `command` is nil. Every line for that combo
    /// goes, except the one rewritten in place.
    public mutating func setBinding(_ combo: KeyCombo, _ command: String?) {
        let at = lines.indices.filter { binding(at: $0)?.0 == combo }
        if let command {
            let line = "bind \(combo) \(command)"
            if let last = at.last {
                lines[last] = rewrite(parse(last)!, line)
                for i in at.dropLast().reversed() { lines.remove(at: i) }
            } else {
                append(line, after: { $0.tokens.first == "bind" })
            }
        } else {
            for i in at.reversed() { lines.remove(at: i) }
        }
    }

    // MARK: - Rules

    public var ruleLines: [Int] {
        lines.indices.filter { parse($0)?.tokens.first == "rule" }
    }

    /// Replaces the rules. Lines are rewritten in place as far as they go, so comments around them
    /// stay put; extra rules go after the last one.
    public mutating func setRules(_ rules: [Rule]) {
        let at = ruleLines
        let new = rules.map { "rule " + $0.description }
        for (k, i) in at.enumerated() where k < new.count { lines[i] = rewrite(parse(i)!, new[k]) }
        if at.count > new.count {
            for i in at[new.count...].reversed() { lines.remove(at: i) }
        } else if new.count > at.count {
            let tail = Array(new[at.count...])
            if let last = at.last { lines.insert(contentsOf: tail, at: last + 1) }
            else { for l in tail { append(l, after: { $0.tokens.first == "rule" }) } }
        }
    }

    // MARK: -

    /// After the last line of the same kind, or at the end.
    private mutating func append(_ line: String, after sameKind: (Parsed) -> Bool) {
        if let i = lines.indices.last(where: { parse($0).map(sameKind) ?? false }) {
            lines.insert(line, at: i + 1)
            return
        }
        if lines.last == "" { lines.insert(line, at: lines.count - 1) } else { lines.append(line) }
    }
}
