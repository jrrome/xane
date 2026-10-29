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
            let w = c.pending.windows[cfg.window]!
            let f = cfg.frame ?? CGRect(origin: cfg.origin, size: w.frame.size)
            XCTAssertEqual(c.ack(cfg.window, serial: cfg.serial, frame: f), .settled)
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

    func testTagsParkAndRestore() throws {
        add(1); add(2)
        commitAndObey()
        c.systemFocused(2)
        let tiledFrame1 = frame(1)
        _ = try c.execute(.tag(Tags.mask(2)!))                 // window 2 → tag 2
        let effects = try c.execute(.view(.mask(Tags.mask(1)!))) // still viewing 1
        XCTAssertTrue(effects.isEmpty || effects == [.focus(1)])
        let tx = commitAndObey()
        let park = tx.configures.first { $0.window == 2 }!
        XCTAssertTrue(park.isParking)
        XCTAssertNil(park.frame)
        XCTAssertGreaterThanOrEqual(park.origin.x, main.frame.maxX - 1)  // out of view
        // Window 1 now takes the whole screen.
        XCTAssertGreaterThan(frame(1).width, tiledFrame1.width)
        // Viewing tag 2 brings window 2 back and focuses it.
        let e2 = try c.execute(.view(.mask(Tags.mask(2)!)))
        XCTAssertEqual(e2, [.focus(2)])
        let tx2 = commitAndObey()
        XCTAssertTrue(tx2.configures.contains { $0.window == 1 && $0.isParking })
        XCTAssertTrue(tx2.configures.contains { $0.window == 2 && !$0.isParking })
        XCTAssertTrue(main.visibleFrame.contains(frame(2)))
    }

    func testViewBackAndForth() throws {
        _ = try c.execute(.view(.mask(Tags.mask(3)!)))
        _ = try c.execute(.view(.mask(Tags.mask(3)!)))
        XCTAssertEqual(c.pending.outputs[1]!.tags, 1)
    }

    func testEmptyTagFocusesDesktop() throws {
        add(1); commitAndObey(); c.systemFocused(1)
        XCTAssertEqual(try c.execute(.view(.mask(Tags.mask(5)!))), [.focusDesktop])
    }

    func testActivationOfHiddenWindowShowsItsTag() throws {
        add(1); add(2); commitAndObey()
        c.systemFocused(2)
        _ = try c.execute(.tag(Tags.mask(4)!))
        commitAndObey()
        XCTAssertFalse(c.current.isVisible(2))
        // ⌘-Tab to window 2.
        XCTAssertTrue(c.systemFocused(2))
        XCTAssertEqual(c.pending.outputs[1]!.tags, Tags.mask(4)!)
    }

    func testFloatingWindowParksAtItsOwnFrameAndComesBack() throws {
        add(1, at: CGRect(x: 300, y: 300, width: 400, height: 300), subrole: "AXDialog")
        commitAndObey()
        _ = try c.execute(.view(.mask(Tags.mask(2)!)))
        commitAndObey()
        XCTAssertTrue(c.parked.contains(1))
        _ = try c.execute(.view(.previous))
        commitAndObey()
        XCTAssertEqual(frame(1), CGRect(x: 300, y: 300, width: 400, height: 300))
    }

    func testEchoesAreIgnoredAndExternalMovesDetected() {
        add(1); add(2)
        now += 0.1
        let tx = c.commit(now: now)
        let cfg = tx.configures[0]
        // Notification arrives before the ack: echo.
        XCTAssertEqual(c.observe(cfg.window, frame: cfg.frame!, now: now + 0.01), .echo)
        XCTAssertEqual(c.ack(cfg.window, serial: cfg.serial, frame: cfg.frame!), .settled)
        for x in tx.configures.dropFirst() { _ = c.ack(x.window, serial: x.serial, frame: x.frame!) }
        // Later, the app moves itself.
        var moved = cfg.frame!; moved.origin.x += 50
        XCTAssertEqual(c.observe(cfg.window, frame: moved, now: now + 5), .external)
        // The next commit puts it back.
        let tx2 = c.commit(now: now + 5)
        XCTAssertEqual(tx2.configures.map(\.window), [cfg.window])
    }

    func testStaleAcksDoNotResolveNewerConfigures() {
        add(1)
        now += 0.1
        let a = c.commit(now: now).configures[0]
        let b = c.commit(now: now + 2, forceAll: true).configures[0]
        XCTAssertEqual(c.ack(1, serial: a.serial, frame: a.frame!), .stale)
        XCTAssertEqual(c.ack(1, serial: b.serial, frame: b.frame!), .settled)
    }

    func testMinimumSizeLearning() {
        add(1); add(2)
        now += 0.1
        let tx = c.commit(now: now)
        let cfg = tx.configures.first { $0.window == 1 }!
        var got = cfg.frame!; got.size.width = 900   // app refuses to be narrower than 900
        XCTAssertEqual(c.ack(1, serial: cfg.serial, frame: got), .tooBig(asked: cfg.frame!))
        XCTAssertEqual(c.learnMinimum(1, asked: cfg.frame!, got: got), .saved)
        commitAndObey()
        XCTAssertGreaterThanOrEqual(c.current.windows[1]!.frame.width, 900)
        XCTAssertGreaterThanOrEqual(c.placement(of: 1).flatMap { if case .frame(let f) = $0 { return f.width } else { return nil } } ?? 0, 900)
        // Another window of the same app and kind inherits it.
        add(3, bundle: "app.1")
        XCTAssertEqual(c.minimum(for: c.pending.windows[3]!).width, 900)
    }

    func testNearlyFullScreenMinimumIsSessionOnly() {
        add(1); add(2)
        now += 0.1
        let cfg = c.commit(now: now).configures.first { $0.window == 1 }!
        var got = cfg.frame!; got.size.width = 1400
        XCTAssertEqual(c.learnMinimum(1, asked: cfg.frame!, got: got), .sessionOnly)
        XCTAssertTrue(c.minimumSizes.entries.isEmpty)
    }

    func testInteractiveResizeBecomesRatio() {
        add(1); add(2)
        commitAndObey()
        let before = frame(1)
        var dragged = before; dragged.size.width += 150
        XCTAssertEqual(c.observe(1, frame: dragged, now: now + 3), .external)
        XCTAssertTrue(c.interactiveEnd(1, pointer: CGPoint(x: dragged.maxX, y: dragged.midY)))
        commitAndObey()
        XCTAssertEqual(frame(1).maxX, dragged.maxX, accuracy: 2)
        XCTAssertEqual(frame(2).minX - frame(1).maxX, 8)
    }

    func testInteractiveMoveSwaps() {
        add(1); add(2)
        commitAndObey()
        let f2 = frame(2)
        var dragged = frame(1); dragged.origin.x += 700
        _ = c.observe(1, frame: dragged, now: now + 3)
        XCTAssertTrue(c.interactiveEnd(1, pointer: f2.center))
        XCTAssertEqual(c.pending.order, [2, 1])
        commitAndObey()
        XCTAssertEqual(frame(1), f2)
    }

    func testDirectionalFocusAndSwap() throws {
        add(1); add(2); add(3)
        commitAndObey()
        c.systemFocused(1)
        XCTAssertEqual(try c.execute(.focus(.direction(.right))), [.focus(2)])
        c.systemFocused(2)
        XCTAssertEqual(try c.execute(.focus(.direction(.down))), [.focus(3)])
        c.systemFocused(3)
        XCTAssertEqual(try c.execute(.focus(.direction(.left))), [.focus(1)])
        c.systemFocused(1)
        // Right of 1 are 2 and 3; 3 was focused more recently, so it wins (stable back-and-forth).
        _ = try c.execute(.swap(.direction(.right)))
        XCTAssertEqual(c.pending.order, [3, 2, 1])
    }

    func testZoom() throws {
        add(1); add(2); add(3); commitAndObey()
        c.systemFocused(3)
        _ = try c.execute(.zoom)
        XCTAssertEqual(c.pending.order, [3, 1, 2])
    }

    func testMultipleOutputsAndSendToOutput() throws {
        c.setOutputs([main, side])
        add(1); add(2)
        commitAndObey()
        c.systemFocused(2)
        XCTAssertEqual(try c.execute(.sendToOutput(.next)), [.focus(2)])
        commitAndObey()
        XCTAssertTrue(side.visibleFrame.contains(frame(2)))
        XCTAssertGreaterThan(frame(1).width, 1300)           // alone on the main display
        // Focus left crosses displays.
        c.systemFocused(2)
        XCTAssertEqual(try c.execute(.focus(.direction(.left))), [.focus(1)])
    }

    func testOutputDisconnectMovesWindows() {
        c.setOutputs([main, side])
        add(1, at: CGRect(x: 1600, y: 100, width: 800, height: 600))
        c.pending.windows[1]?.output = 2
        commitAndObey()
        c.setOutputs([main])
        commitAndObey()
        XCTAssertEqual(c.current.windows[1]!.output, 1)
        XCTAssertTrue(main.visibleFrame.contains(frame(1)))
    }

    func testPauseRevealsParkedWindows() throws {
        add(1); add(2); commitAndObey()
        c.systemFocused(2)
        _ = try c.execute(.tag(Tags.mask(3)!))
        commitAndObey()
        XCTAssertTrue(c.parked.contains(2))
        _ = try c.execute(.pause)
        let tx = commitAndObey()
        XCTAssertTrue(tx.configures.contains { $0.window == 2 && !$0.isParking })
        XCTAssertTrue(main.frame.intersects(frame(2)))
    }

    func testStrandedWindowFromPreviousRunIsBroughtBack() {
        add(1, at: CGRect(x: 1439, y: 899, width: 600, height: 400))   // parked by a crashed run
        let tx = commitAndObey()
        XCTAssertEqual(tx.configures.count, 1)
        XCTAssertTrue(main.visibleFrame.contains(frame(1)))
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
        _ = try c.execute(.tag(Tags.mask(2)!))
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
        XCTAssertEqual(d.pending.windows[2]!.tags, Tags.mask(2)!)
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
        _ = try c.execute(.view(.mask(Tags.mask(2)!)))
        _ = c.commit(now: now)
        let ev = Compositor.events(from: a, to: c.current)
        XCTAssertTrue(ev.contains { $0.contains("\"tags\"") })
    }
}
