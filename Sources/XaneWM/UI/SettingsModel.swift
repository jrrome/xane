#if os(macOS)
import AppKit
import SwiftUI
import XaneCore

/// What the settings window shows. The config file stays the truth: the server writes every
/// change there and applies it live, then feeds the result back through `load`.
final class SettingsModel: ObservableObject {
    struct BindingRow: Identifiable, Equatable {
        let id = UUID()
        var combo: KeyCombo?
        var command: String
    }

    struct RuleRow: Identifiable, Equatable {
        enum Action: String, CaseIterable { case float, tile, ignore, tags, output }
        enum Match: String, CaseIterable { case appID = "app-id", appName = "app-name", title, subrole }
        let id = UUID()
        var action: Action = .float
        /// Tag for `tags`, display index for `output`.
        var number = 1
        var matchers: [(kind: Match, value: String)] = [(.appID, "")]

        static func == (a: RuleRow, b: RuleRow) -> Bool { a.id == b.id && a.sameContent(as: b) }

        func sameContent(as o: RuleRow) -> Bool {
            action == o.action && number == o.number
                && matchers.map(\.kind) == o.matchers.map(\.kind) && matchers.map(\.value) == o.matchers.map(\.value)
        }
    }

    @Published private(set) var options = Options()
    @Published var bindings: [BindingRow] = []
    @Published var rules: [RuleRow] = []
    @Published private(set) var problems: [String] = []
    /// Bindings macOS takes first (System Settings → Keyboard → Keyboard Shortcuts).
    @Published private(set) var conflicts: Set<KeyCombo> = []
    @Published private(set) var paused = false
    @Published var recording: UUID? { didSet { if recording != oldValue { onRecording?(recording != nil) } } }
    let configPath: String

    var onSetOption: ((String, [String]) -> Void)?
    var onSetBinding: ((_ old: KeyCombo?, _ new: KeyCombo?, _ command: String) -> Void)?
    var onSetRules: (([Rule]) -> Void)?
    var onRecording: ((Bool) -> Void)?
    var onCommand: ((String) -> Void)?
    var onOpenConfig: (() -> Void)?

    init(configPath: String) { self.configPath = configPath }

    // MARK: - From the server

    func load(options: Options, paused: Bool) {
        if options != self.options { self.options = options }
        if paused != self.paused { self.paused = paused }
    }

    /// After a (re)load of the config. Rows being edited keep their identity when nothing changed.
    func load(bindings: [(combo: KeyCombo, command: String)], rules ruleList: [Rule], problems: [String], conflicts: Set<KeyCombo>) {
        let old = Dictionary(self.bindings.compactMap { r in r.combo.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        self.bindings = bindings.map { b in
            var row = old[b.combo] ?? BindingRow(combo: b.combo, command: b.command)
            row.command = b.command
            return row
        } + self.bindings.filter { $0.combo == nil || Self.check(command: $0.command) != nil }
        let rows = rules.filter { $0.toRule() != nil }
        rules = ruleList.enumerated().map { i, r in
            let row = RuleRow(rule: r)
            return i < rows.count && row.sameContent(as: rows[i]) ? rows[i] : row
        } + rules.filter { $0.toRule() == nil }
        self.problems = problems
        self.conflicts = conflicts
    }

    // MARK: - Options

    /// A two-way binding to an option that writes `set <name> …` on change.
    func option<T: Equatable>(_ path: WritableKeyPath<Options, T>, _ name: String, _ encode: @escaping (T) -> [String]) -> Binding<T> {
        Binding(get: { self.options[keyPath: path] }, set: { v in
            guard v != self.options[keyPath: path] else { return }
            self.options[keyPath: path] = v
            self.onSetOption?(name, encode(v))
        })
    }

    func flag(_ path: WritableKeyPath<Options, Bool>, _ name: String) -> Binding<Bool> {
        option(path, name) { [$0 ? "on" : "off"] }
    }

    func pick<T: RawRepresentable & Equatable>(_ path: WritableKeyPath<Options, T>, _ name: String) -> Binding<T> where T.RawValue == String {
        option(path, name) { [$0.rawValue] }
    }

    func number(_ path: WritableKeyPath<Options, CGFloat>, _ name: String) -> Binding<Double> {
        let b = option(path, name) { [Self.format(Double($0))] }
        return Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = CGFloat($0.rounded()) })
    }

    func number(_ path: WritableKeyPath<Options, Double>, _ name: String, step: Double) -> Binding<Double> {
        let b = option(path, name) { [Self.format($0)] }
        return Binding(get: { b.wrappedValue }, set: { b.wrappedValue = ($0 / step).rounded() * step })
    }

    func edge(_ path: WritableKeyPath<XaneCore.EdgeInsets, CGFloat>) -> Binding<Double> {
        let b = option(\.edges, "edges") { e in [e.top, e.right, e.bottom, e.left].map { Self.format(Double($0)) } }
        return Binding(get: { Double(b.wrappedValue[keyPath: path]) }, set: { v in
            var e = b.wrappedValue
            e[keyPath: path] = CGFloat(max(0, v.rounded()))
            b.wrappedValue = e
        })
    }

    var borderColor: Binding<Color> {
        let b = option(\.borderColor, "border-color") { [$0] }
        return Binding(get: { Color(nsColor: BorderOverlay.color(b.wrappedValue)) }, set: { c in
            guard let rgb = NSColor(c).usingColorSpace(.sRGB) else { return }
            let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent] + (rgb.alphaComponent < 1 ? [rgb.alphaComponent] : [])
            b.wrappedValue = "#" + parts.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        })
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    // MARK: - Bindings

    /// Nil when the command is fine, else what is wrong with it.
    static func check(command: String) -> String? {
        let parsed = CommandParser.parseLine(command)
        if parsed.isEmpty { return "empty command" }
        for case .failure(let e) in parsed { return e.description }
        return nil
    }

    func commit(binding row: BindingRow, previous: KeyCombo?) {
        guard Self.check(command: row.command) == nil else { return }
        if let new = row.combo, previous != new, bindings.contains(where: { $0.id != row.id && $0.combo == new }) { return }
        onSetBinding?(previous, row.combo, row.command)
    }

    func remove(binding row: BindingRow) {
        bindings.removeAll { $0.id == row.id }
        if let combo = row.combo { onSetBinding?(combo, nil, row.command) }
    }

    // MARK: - Rules

    func commitRules() {
        onSetRules?(rules.compactMap { $0.toRule() })
    }

    func addRule(for app: NSRunningApplication? = nil) {
        var row = RuleRow()
        if let id = app?.bundleIdentifier { row.matchers = [(.appID, id)] }
        rules.append(row)
        if app != nil { commitRules() }
    }
}

extension SettingsModel.RuleRow {
    init(rule: Rule) {
        switch rule.action {
        case .float: action = .float
        case .tile: action = .tile
        case .ignore: action = .ignore
        case .tags(let m): action = .tags; number = Tags.first(m) ?? 1
        case .output(let n): action = .output; number = n
        }
        matchers = rule.matchers.map { m in
            switch m {
            case .appID(let v): return (.appID, v)
            case .appName(let v): return (.appName, v)
            case .title(let v): return (.title, v)
            case .subrole(let v): return (.subrole, v)
            }
        }
    }

    /// Nil while it is incomplete (an empty value, a bad regex).
    func toRule() -> Rule? {
        let a: Rule.Action
        switch action {
        case .float: a = .float
        case .tile: a = .tile
        case .ignore: a = .ignore
        case .tags: guard let m = Tags.mask(number) else { return nil }; a = .tags(m)
        case .output: guard number >= 1 else { return nil }; a = .output(number)
        }
        var ms: [Rule.Matcher] = []
        for (kind, value) in matchers {
            let v = value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            switch kind {
            case .appID: ms.append(.appID(v))
            case .appName: ms.append(.appName(v))
            case .title: ms.append(.title(v))
            case .subrole: ms.append(.subrole(v))
            }
        }
        return ms.isEmpty ? nil : try? Rule(action: a, matchers: ms)
    }
}
#endif
