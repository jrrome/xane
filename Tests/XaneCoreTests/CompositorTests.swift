import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import XaneCore

final class CompositorTests: XCTestCase {
    var c: Compositor!
    let main = Output(id: 1, uuid: "MAIN", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                      visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875))
    let side = Output(id: 2, uuid: "SIDE", name: "External", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                      visibleFrame: CGRect(x: 1440, y: 25, width: 1920, height: 1055))
    var now: TimeInterval = 100

    override func setUp() {
        c = Compositor()
        c.setOutputs([main])
    }

    @discardableResult
    func add(_ id: WindowID, pid: Int32 = 1, at frame: CGRect = CGRect(x: 100, y: 100, width: 600, height: 400),
             bundle: String = "app.\(1)", subrole: String = "AXStandardWindow") -> Bool {
        let s = WindowSnapshot(id: id, pid: pid, bundleID: bundle, appName: "App", title: "w\(id)",
                               subrole: subrole, frame: frame)
        return c.addWindow(s, classification: classify(s, rules: c.pending.rules), pointer: CGPoint(x: 10, y: 10))
    }

    /// Commits and acks every configure as if the client obeyed exactly.
    @discardableResult
    func commitAndObey(forceAll: Bool = false) -> Transaction {
        now += 0.1
        let tx = c.commit(now: now, forceAll: forceAll)
        for cfg in tx.configures {
            XCTAssertEqual(c.ack(cfg.window, serial: cfg.serial, frame: cfg.frame), .settled)
        }
        return tx
    }

    func frame(_ id: WindowID) -> CGRect { c.current.windows[id]!.frame }

    func testNewWindowsAreTiledAndConfigured() {
        add(1); add(2)
        let tx = commitAndObey()
        XCTAssertEqual(tx.configures.count, 2)
        XCTAssertEqual(tx.tiled, 2)
        XCTAssertLessThan(frame(1).maxX, frame(2).minX)
        // Nothing changed: an idle commit sends nothing.
        XCTAssertTrue(commitAndObey().configures.isEmpty)
    }

    func testAttachAfterFocused() {
        add(1); add(2); add(3)
        c.systemFocused(1)
        add(4)
        XCTAssertEqual(c.pending.order, [1, 4, 2, 3])
    }

    func testDialogsFloatAndAreUntouched() {
        add(1)
        add(2, subrole: "AXDialog")
        let tx = commitAndObey()
        XCTAssertEqual(tx.configures.map(\.window), [1])
        XCTAssertEqual(c.placement(of: 2), .untouched)
    }

    func testRulesOverrideHeuristics() throws {
        _ = try c.execute(CommandParser.parse(["rule", "float", "app-id", "com.apple.calculator"]).get())
        add(1, bundle: "com.apple.calculator")
        XCTAssertTrue(c.pending.windows[1]!.floating)
        _ = try c.execute(CommandParser.parse(["rule", "ignore", "app-id", "com.x.*"]).get())
        XCTAssertFalse(add(2, bundle: "com.x.thing"))
    }

    func testDesktopCommandsGoToThePlatform() throws {
        add(1); add(2); commitAndObey()
        c.systemFocused(1)
        XCTAssertEqual(try c.execute(.desktop(.number(2))), [.showDesktop(.number(2))])
        XCTAssertEqual(try c.execute(.desktop(.back)), [.showDesktop(.back)])
        XCTAssertEqual(try c.execute(.moveToDesktop(.number(4))), [.moveToDesktop(1, .number(4))])
        // Nothing in the model changes: the window server moves things between Spaces.
        XCTAssertTrue(commitAndObey().configures.isEmpty)
    }

    func testPauseLeavesWindowsAlone() throws {
        add(1); add(2); commitAndObey()
        _ = try c.execute(.pause)
        c.setSpacePresence(onScreen: [1], known: [1, 2])
        XCTAssertTrue(commitAndObey().configures.isEmpty)
    }

    func testStrandedWindowFromPreviousRunIsBroughtBack() {
        // Hidden off-screen by an older version that crashed.
        add(1, at: CGRect(x: 1439, y: 899, width: 600, height: 400))
        add(2, at: CGRect(x: 1439, y: 899, width: 400, height: 300), subrole: "AXDialog")
        let tx = commitAndObey()
        XCTAssertEqual(tx.configures.count, 2)
        XCTAssertTrue(main.visibleFrame.contains(frame(1)))
        XCTAssertTrue(main.visibleFrame.contains(frame(2)))
    }

    func testSpacePresence() {
        add(1); add(2); commitAndObey()
        c.setSpacePresence(onScreen: [1], known: [1, 2])
        commitAndObey()
        XCTAssertGreaterThan(frame(1).width, 1300)   // 2 is on another Space: 1 takes everything
        XCTAssertEqual(c.current.tiled(on: 1), [1])
    }

    func testRetileForcesEveryone() {
        add(1); add(2); commitAndObey()
        XCTAssertEqual(c.commit(now: now + 1, forceAll: true).configures.count, 2)
    }

    func testPersistenceRoundTrip() throws {
        add(1); add(2); commitAndObey()
        c.systemFocused(2)
        _ = try c.execute(.float(.on))
        _ = try c.execute(.layout(.kind(.tile)))
        commitAndObey()
        let data = try JSONEncoder().encode(c.persisted())
        let p = try JSONDecoder().decode(PersistedState.self, from: data)

        let d = Compositor()
        d.restore(p)
        d.setOutputs([main])
        XCTAssertEqual(d.pending.outputs[1]!.layout, .tile)
        let s = WindowSnapshot(id: 2, pid: 1, bundleID: "app.1", frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        d.addWindow(s, classification: classify(s, rules: []), pointer: nil)
        XCTAssertTrue(d.pending.windows[2]!.floating)
    }

    func testConfigDoesNotOverrideRestoredOutputSettings() throws {
        _ = try c.execute(.layout(.kind(.tile)))
        commitAndObey()
        let d = Compositor()
        d.restore(c.persisted())
        d.setOutputs([main, side])
        // Start-up order in the server: outputs first, then the config.
        _ = try d.execute(.set("default-layout", ["grid"]))
        XCTAssertEqual(d.pending.outputs[1]!.layout, .tile)
        XCTAssertEqual(d.pending.outputs[2]!.layout, .grid)
    }

    func testQueriesAreValidJSON() throws {
        add(1); commitAndObey()
        for q in ["windows", "outputs", "state", "bindings", "rules", "options", "tree"] {
            let json = c.query(q)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)), q)
        }
    }

    func testEvents() throws {
        let a = c.current
        _ = try c.execute(.layout(.kind(.grid)))
        _ = c.commit(now: now)
        let ev = Compositor.events(from: a, to: c.current)
        XCTAssertTrue(ev.contains { $0.contains("\"layout\"") })
    }
}
