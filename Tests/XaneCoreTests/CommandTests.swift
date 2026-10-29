import XCTest
@testable import XaneCore

final class CommandTests: XCTestCase {
    func parse(_ s: String) -> [Result<Command, CommandError>] { CommandParser.parseLine(s) }

    func one(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> Command? {
        let r = parse(s)
        XCTAssertEqual(r.count, 1, file: file, line: line)
        return try? r.first?.get()
    }

    func testBasicCommands() {
        XCTAssertEqual(one("focus left"), .focus(.direction(.left)))
        XCTAssertEqual(one("swap next"), .swap(.next))
        XCTAssertEqual(one("layout tile"), .layout(.kind(.tile)))
        XCTAssertEqual(one("layout next"), .layout(.next))
        XCTAssertEqual(one("main-ratio +0.05"), .mainRatio(.delta(0.05)))
        XCTAssertEqual(one("main-ratio 0.6"), .mainRatio(.set(0.6)))
        XCTAssertEqual(one("main-count -1"), .mainCount(.delta(-1)))
        XCTAssertEqual(one("resize grow 0.1 horizontal"), .resize(delta: 0.1, axis: .horizontal))
        XCTAssertEqual(one("resize shrink"), .resize(delta: -0.05, axis: nil))
        XCTAssertEqual(one("view 3"), .view(.mask(4)))
        XCTAssertEqual(one("view 1,3"), .view(.mask(5)))
        XCTAssertEqual(one("view prev"), .view(.previous))
        XCTAssertEqual(one("tag all"), .tag(Tags.all))
        XCTAssertEqual(one("set-focused-tags 0x6"), .view(.mask(6)))
        XCTAssertEqual(one("focus-output 2"), .focusOutput(.index(2)))
        XCTAssertEqual(one("toggle-float"), .float(.toggle))
        XCTAssertEqual(one("fullscreen on"), .fullscreen(.on))
        XCTAssertEqual(one("set gap 12"), .set("gap", ["12"]))
        XCTAssertEqual(one("set border-color #ff8800"), .set("border-color", ["#ff8800"]))
        XCTAssertEqual(one("exec open -a Terminal"), .exec("open -a Terminal"))
        XCTAssertEqual(one("query windows"), .query("windows"))
    }

    func testErrors() {
        XCTAssertEqual(parse("frobnicate").first.flatMap { if case .failure(let e) = $0 { return e } else { return nil } },
                       .unknownCommand("frobnicate"))
        XCTAssertThrowsError(try parse("view 33").first!.get())
        XCTAssertThrowsError(try parse("set gap banana").first!.get())
        XCTAssertThrowsError(try parse("layout spiral").first!.get())
        XCTAssertThrowsError(try parse("rule float").first!.get())
        XCTAssertThrowsError(try parse("bind ctrl+alt+nokey focus left").first!.get())
        XCTAssertThrowsError(try parse("bind ctrl+alt+h frobnicate").first!.get())
    }

    func testSemicolonsAndComments() {
        let r = parse("view 2; focus main # trailing comment")
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(try r[1].get(), .focus(.main))
        XCTAssertTrue(parse("   # only a comment").isEmpty)
        XCTAssertEqual(parse("exec \"echo a; echo b\"").count, 1)
    }

    func testBindKeepsRestOfLine() {
        guard case .bind(let combo, let cmd)? = one("bind ctrl+alt+x layout monocle; focus main") else {
            return XCTFail()
        }
        XCTAssertEqual(combo, KeyCombo(keyCode: 0x07, modifiers: [.ctrl, .alt]))
        XCTAssertEqual(cmd, "layout monocle; focus main")
        guard case .bind(_, let c2)? = one("bind ctrl+alt+f toggle-fullscreen   # it's a comment") else { return XCTFail() }
        XCTAssertEqual(c2, "toggle-fullscreen")
    }

    func testKeyCombos() {
        XCTAssertEqual(KeyCombo.parse("hyper+return"), KeyCombo(keyCode: 0x24, modifiers: .hyper))
        XCTAssertEqual(KeyCombo.parse("cmd+shift+["), KeyCombo(keyCode: 0x21, modifiers: [.cmd, .shift]))
        XCTAssertEqual(KeyCombo.parse("ctrl+alt+0x31")?.keyCode, 0x31)
        XCTAssertNil(KeyCombo.parse("ctrl+alt+"))
        XCTAssertNil(KeyCombo.parse("foo+h"))
        XCTAssertEqual(KeyCombo.parse("ctrl+alt+shift+h")?.description, "ctrl+alt+shift+h")
    }

    func testTokenizer() {
        XCTAssertEqual(try Tokenizer.tokenize(#"rule float title "Picture in Picture""#).get(),
                       ["rule", "float", "title", "Picture in Picture"])
        XCTAssertEqual(try Tokenizer.tokenize(#"a 'b c' "d\"e""#).get(), ["a", "b c", "d\"e"])
        XCTAssertThrowsError(try Tokenizer.tokenize("\"open").get())
        let s = "weird \"value\"; # x"
        XCTAssertEqual(try Tokenizer.tokenize(Tokenizer.quote(s)).get(), [s])
    }

    func testRules() throws {
        guard case .rule(let r)? = one("rule tags 9 app-id com.spotify.client") else { return XCTFail() }
        XCTAssertEqual(r.action, .tags(256))
        let s = WindowSnapshot(id: 1, pid: 1, bundleID: "com.spotify.client")
        XCTAssertTrue(r.matches(s))
        XCTAssertEqual(classify(s, rules: [r]).tags, 256)
        guard case .rule(let t)? = one("rule float title \"^Picture in Picture$\"") else { return XCTFail() }
        XCTAssertTrue(t.matches(WindowSnapshot(id: 2, pid: 1, title: "Picture in Picture")))
        XCTAssertFalse(t.matches(WindowSnapshot(id: 2, pid: 1, title: "Not Picture in Picture")))
    }

    func testClassificationHeuristics() {
        XCTAssertEqual(classify(WindowSnapshot(id: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600)), rules: []).management, .tile)
        XCTAssertEqual(classify(WindowSnapshot(id: 1, pid: 1, subrole: "AXDialog", frame: CGRect(x: 0, y: 0, width: 800, height: 600)), rules: []).management, .float)
        XCTAssertEqual(classify(WindowSnapshot(id: 1, pid: 1, subrole: "AXUnknown", frame: CGRect(x: 0, y: 0, width: 800, height: 600)), rules: []).management, .ignore)
        XCTAssertEqual(classify(WindowSnapshot(id: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), isSizeSettable: false), rules: []).management, .float)
        XCTAssertEqual(classify(WindowSnapshot(id: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), hasFullscreenButton: false), rules: []).management, .float)
        XCTAssertEqual(classify(WindowSnapshot(id: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), hasFullscreenButton: false, hasDocument: true), rules: []).management, .tile)
    }

    func testDefaultConfigParsesWithoutProblems() {
        let (cmds, problems) = Config.parse(Config.defaultText)
        XCTAssertEqual(problems, [])
        XCTAssertGreaterThan(cmds.count, 60)
        let c = Compositor()
        for cmd in cmds { XCTAssertNoThrow(try c.execute(cmd)) }
        XCTAssertEqual(c.pending.bindings[KeyCombo.parse("ctrl+alt+h")!], "focus left")
        XCTAssertGreaterThan(c.pending.rules.count, 10)
    }

    func testConfigAndLayoutCommandsWithOutputsConnected() throws {
        // Regression: these loops used to write to `pending` while iterating it (exclusivity crash).
        let c = Compositor()
        c.setOutputs([Output(id: 1, uuid: "A", name: "A", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875)),
                      Output(id: 2, uuid: "B", name: "B", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                             visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))])
        for cmd in Config.parse(Config.defaultText).commands { _ = try c.execute(cmd) }
        _ = c.commit(now: 1)
        c.pending.ratios["A|tile|2"] = [0.3]
        c.pending.ratios["A|dwindle|3"] = [0.4, 0.5]
        _ = try c.execute(.mainRatio(.set(0.6)))
        XCTAssertEqual(c.pending.ratios["A|tile|2"], [0])
        _ = try c.execute(.resetLayout)
        XCTAssertNil(c.pending.ratios["A|dwindle|3"])
    }

    func testExecKeepsShellQuoting() {
        XCTAssertEqual(one(#"exec open -a "Visual Studio Code""#), .exec(#"open -a "Visual Studio Code""#))
        XCTAssertEqual(one("exec 'echo a; echo b'"), .exec("echo a; echo b"))
        XCTAssertEqual(try parse("exec echo a; focus left").map { try $0.get() }, [.exec("echo a"), .focus(.direction(.left))])
        XCTAssertThrowsError(try parse("exec").first!.get())
    }

    func testRuleWithTwoTitleMatchers() throws {
        guard case .rule(let r)? = one(#"rule float title "^Foo" title "Bar$""#) else { return XCTFail() }
        XCTAssertTrue(r.matches(WindowSnapshot(id: 1, pid: 1, title: "Foo Bar")))
        XCTAssertFalse(r.matches(WindowSnapshot(id: 1, pid: 1, title: "Foo Baz")))
        XCTAssertFalse(r.matches(WindowSnapshot(id: 1, pid: 1, title: "Qux Bar")))
    }

    func testConfigProblemsHaveLineNumbers() {
        let (_, p) = Config.parse("set gap 8\n\nfocus sideways\nlayout \\\n  tile")
        XCTAssertEqual(p.map(\.line), [3])
    }

    func testOptions() throws {
        var o = Options()
        try o.set("edges", ["10", "20", "30", "40"])
        XCTAssertEqual(o.edges, EdgeInsets(top: 10, left: 40, bottom: 30, right: 20))
        try o.set("gap", ["4"])
        XCTAssertEqual(o.innerGap, 4); XCTAssertEqual(o.outerGap, 4)
        XCTAssertThrowsError(try o.set("nope", ["1"]))
        XCTAssertNotNil(Options.parseHexColor("#11223344"))
        XCTAssertNil(Options.parseHexColor("#123"))
    }

    func testMinimumSizeStoreMigration() {
        var s = MinimumSizeStore()
        s.record("a|AXStandardWindow", width: 900, height: nil)
        s.version = 0
        s.migrateIfNeeded()
        XCTAssertTrue(s.isSuspect("a|AXStandardWindow"))
        XCTAssertEqual(s.minimum(for: "a|AXStandardWindow"), .zero)
        s.record("a|AXStandardWindow", width: 800, height: nil)
        XCTAssertEqual(s.minimum(for: "a|AXStandardWindow").width, 800)
        XCTAssertTrue(s.lower("a|AXStandardWindow", accepted: CGSize(width: 700, height: 100)))
        XCTAssertEqual(s.minimum(for: "a|AXStandardWindow").width, 700)
    }

    func testSocketPath() {
        XCTAssertEqual(Wire.socketPath(uid: 501, environment: [:]), "/tmp/xanewm-501.sock")
        XCTAssertEqual(Wire.socketPath(uid: 501, environment: ["XANEWM_SOCKET": "/x"]), "/x")
        XCTAssertEqual(Wire.error("a\"b"), #"{"error":"a\"b","ok":false}"#)
    }
}
