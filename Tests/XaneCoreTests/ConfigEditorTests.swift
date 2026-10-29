import XCTest
@testable import XaneCore

final class ConfigEditorTests: XCTestCase {
    func testSetOptionKeepsCommentColumn() {
        var e = ConfigEditor("# head\nset gap-inner 8      # inner\nset border on\n")
        e.setOption("gap-inner", ["12"])
        XCTAssertEqual(e.lines[1], "set gap-inner 12     # inner")
        e.setOption("border-color", ["#FF0000"])
        XCTAssertEqual(e.lines[3], "set border-color \"#FF0000\"")
        XCTAssertEqual(e.text.last, "\n")
        var opts = Options()
        for case .success(.set(let n, let v)) in Config.parse(e.text).commands.map({ Result<Command, CommandError>.success($0) }) {
            try? opts.set(n, v)
        }
        XCTAssertEqual(opts.innerGap, 12)
        XCTAssertEqual(opts.borderColor, "#FF0000")
    }

    func testSetOptionUncommentsTemplateLine() {
        var e = ConfigEditor("set border on\n# set edges 0 0 0 0               # bars\n# bind ctrl+x close\n")
        e.setOption("edges", ["30", "0", "0", "0"])
        XCTAssertEqual(e.lines[1], "set edges 30 0 0 0")
    }

    func testBindingsRewriteRemoveAndAdd() {
        var e = ConfigEditor("bind ctrl+alt+h focus left   # vim\nbind alt+ctrl+h zoom\nbind ctrl+1 view 1\n# end\n")
        XCTAssertEqual(e.bindings.count, 2)
        XCTAssertEqual(e.bindings.first?.command, "zoom")
        e.setBinding(KeyCombo.parse("ctrl+alt+h")!, "focus right")
        // The line that won (the last) is the one rewritten.
        XCTAssertEqual(e.lines, ["bind ctrl+alt+h focus right", "bind ctrl+1 view 1", "# end", ""])
        e = ConfigEditor("bind ctrl+alt+h focus left   # vim\n")
        e.setBinding(KeyCombo.parse("ctrl+alt+h")!, "zoom")
        XCTAssertEqual(e.lines[0], "bind ctrl+alt+h zoom         # vim")
        e = ConfigEditor("bind ctrl+alt+h focus right\nbind ctrl+1 view 1\n# end\n")
        e.setBinding(KeyCombo.parse("ctrl+2")!, "view 2")
        XCTAssertEqual(e.lines[2], "bind ctrl+2 view 2")
        e.setBinding(KeyCombo.parse("ctrl+1")!, nil)
        XCTAssertEqual(e.bindings.map(\.command), ["focus right", "view 2"])
    }

    func testRulesRoundTrip() throws {
        var e = ConfigEditor("rule float app-id a.b\n# keep\nrule float app-id c.d\nbind ctrl+x close\n")
        let r1 = try Rule(action: .tags(Tags.mask(3)!), matchers: [.appName("Visual Studio Code")])
        let r2 = try Rule(action: .ignore, matchers: [.title("^Say \"hi\"$")])
        let r3 = try Rule(action: .float, matchers: [.appID("x.y")])
        e.setRules([r1, r2, r3])
        XCTAssertEqual(e.lines[1], "# keep")
        XCTAssertEqual(e.lines[3], "rule float app-id x.y")
        let parsed = Config.parse(e.text)
        XCTAssertTrue(parsed.problems.isEmpty)
        let rules = parsed.commands.compactMap { c -> Rule? in if case .rule(let r) = c { return r }; return nil }
        XCTAssertEqual(rules, [r1, r2, r3])
        e.setRules([r3])
        XCTAssertEqual(e.ruleLines.count, 1)
        XCTAssertEqual(e.lines, ["rule float app-id x.y", "# keep", "bind ctrl+x close", ""])
    }
}
