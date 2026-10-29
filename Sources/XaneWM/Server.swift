#if os(macOS)
import AppKit
import ApplicationServices
import XaneCore

/// The compositor process. Owns the pure `Compositor` (state + layout) and connects it to the
/// system: AX workers (one thread per app), window server, displays, key bindings, pointer,
/// IPC socket and the little bits of chrome. Everything here runs on the main thread; anything
/// that can block (AX IPC, socket I/O) lives elsewhere and reports back asynchronously.
final class Server: WorkerDelegate {
    let compositor = Compositor()
    private var workers: [pid_t: AppWorker] = [:]
    private let hotkeys = HotKeys()
    private let mouse = MouseMonitor()
    private let border = BorderOverlay()
    private let statusBar = StatusBar()
    private let permissions = Permissions()
    private let store = Store()
    private var ipc: SocketServer?
    private lazy var settings = SettingsWindow(model: SettingsModel(configPath: configPath))
    /// Options changed from the settings window, written to the config file shortly after.
    private var optionWrites: [(name: String, values: [String])] = []
    private var optionWrite: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []

    private var started = false
    private var shuttingDown = false
    /// Reasons not to touch anything right now (screen locked, asleep, Stage Manager…).
    private var blockers = Set<String>()

    // Commit scheduling: any number of events in one run-loop turn produce one commit.
    private var commitScheduled = false
    private var forceAll = false
    private var force = Set<WindowID>()
    private var presenceDirty = true
    private var borderScheduled = false

    // Interactive move/resize ("grab"): while the button is down nothing is moved under the user.
    private var buttonDown = false
    private var grabbed = Set<WindowID>()
    private var deferredCommit = false
    private var grabPoll: DispatchWorkItem?

    // Robustness bookkeeping.
    private var recheck: [WindowID: CGRect] = [:]
    private var fights: [WindowID: (count: Int, since: TimeInterval)] = [:]
    private var resnapshotAt: [WindowID: TimeInterval] = [:]
    private var busyRetry = Set<pid_t>()
    private var focusFallback: DispatchWorkItem?
    private var hover: DispatchWorkItem?
    /// Managed window under the pointer at the last mouse move (instant focus-follows-mouse).
    private var pointerWindow: WindowID?
    private var screenChange: DispatchWorkItem?
    /// `desktops spaces`: macOS desktop shown per display (by UUID) and the one before it.
    private var desktops: [String: (current: Int?, previous: Int?)] = [:]
    /// Switches XaneWM started that macOS has not finished, per display. macOS ignores a switch
    /// pressed while it animates another one, so the next request waits here until it is over.
    private var heading: [String: (desktop: Int, until: TimeInterval)] = [:]
    private var queuedDesktop: [String: DesktopTarget] = [:]
    /// A window is being carried to another Space with synthetic mouse events: they are ours.
    private var carrying = false

    private var windowServerCache: (at: TimeInterval, snapshot: WindowServer.Snapshot)?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// CGWindowList costs a few ms; bursts (every app re-enumerating after a Space switch) share one.
    private func windowServerSnapshot() -> WindowServer.Snapshot {
        let t = now
        if let c = windowServerCache, t - c.at < 0.05 { return c.snapshot }
        let snap = WindowServer.snapshot()
        windowServerCache = (t, snap)
        return snap
    }
    private var configPath: String {
        Config.path(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    // MARK: - Lifecycle

    func launch() {
        installSignalHandlers()
        startIPC()   // first: quits right away if another instance is running
        statusBar.install()
        statusBar.onCommand = { [weak self] line in self?.run(line, client: nil) }
        statusBar.onOpenConfig = { [weak self] in self?.openConfig() }
        statusBar.onAccessibility = { [weak self] in self?.permissions.openSettings() }
        statusBar.onSetOption = { [weak self] name, values in self?.setOption(name, values) }
        statusBar.onSettings = { [weak self] in self?.settings.show() }
        statusBar.state = { [weak self] in self?.menuState() ?? .init() }
        connectSettings()
        if permissions.isTrusted {
            start()
        } else {
            statusBar.set(status: "Needs Accessibility access", active: false)
            Log.main.info("Waiting for Accessibility access")
            permissions.prompt()
            permissions.waitForTrust { [weak self] in self?.start() }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        // Upper bound for any AX call that has no explicit timeout of its own.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        if let saved = store.load() { compositor.restore(saved) }
        compositor.setOutputs(Displays.outputs())
        loadConfig(initial: true)
        hotkeys.onPress = { [weak self] combo in self?.hotkey(combo) }
        hotkeys.install()
        syncInput()
        observeSystem()
        mouse.onDown = { [weak self] in self?.mouseDown() }
        mouse.onUp = { [weak self] in self?.mouseUp() }
        mouse.onMove = { [weak self] in self?.pointerMoved() }
        mouse.start()
        updateStageManager()
        for app in NSWorkspace.shared.runningApplications { addWorker(app) }
        Log.main.info("Watching \(self.workers.count, privacy: .public) apps")
        scheduleCommit()
    }

    /// Saves state and lets go of everything. Safe to call more than once.
    func shutdown() {
        guard !shuttingDown else { return }
        if started { store.save(compositor.persisted()) }
        shuttingDown = true
        ipc?.stop()
        border.hide()
        for w in workers.values { w.stop() }
        workers.removeAll()
        Log.main.info("Stopped")
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                if sig == SIGHUP { self?.run("reload", client: nil) } else { self?.shutdown(); exit(0) }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private func startIPC() {
        let path = Wire.socketPath(uid: getuid(), environment: ProcessInfo.processInfo.environment)
        let server = SocketServer(path: path)
        server.onLine = { [weak self] line, client in
            guard let self else { client.reply(Wire.error("shutting down")); return }
            self.run(line, client: client)
        }
        do {
            try server.start()
            ipc = server
            Log.main.info("Listening on \(path, privacy: .public)")
        } catch SocketServer.Failure.alreadyRunning(let p) {
            Log.main.error("Another XaneWM is already running (\(p, privacy: .public))")
            exit(0)   // never touch windows another instance is managing (0: launchd must not retry)
        } catch {
            Log.main.error("IPC disabled: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Config and commands

    private func loadConfig(initial: Bool) {
        flushOptionWrites()
        let path = configPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = fm.createFile(atPath: path, contents: Data(Config.defaultText.utf8))
            Log.main.info("Wrote the default config to \(path, privacy: .public)")
        }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? Config.defaultText
        let (commands, problems) = Config.parse(text)
        // The config owns rules, bindings and options: rebuild them so removing a line takes effect.
        compositor.pending.rules = []
        compositor.pending.bindings = [:]
        compositor.pending.options = Options()
        var errors = problems.map(\.description)
        for cmd in commands {
            switch cmd {
            case .quit, .reload, .subscribe, .query, .settings: continue
            case .exec(let c): if initial { spawn(c) }; continue
            default: break
            }
            do { _ = try compositor.execute(cmd) } catch { errors.append("\(error)") }
        }
        for (combo, id) in SystemShortcuts.conflicts(with: Set(compositor.pending.bindings.keys)) {
            // macOS doing the same thing on the same keys is no clash.
            if isSameAsSystem(compositor.pending.bindings[combo] ?? "", id) { continue }
            errors.append("\(combo) is taken by a macOS shortcut (System Settings → Keyboard → Keyboard Shortcuts)")
        }
        if !NativeSpaces.isAvailable { errors.append("desktops: \(NativeSpaces.Failure.unavailable)") }
        statusBar.set(problems: errors)
        for e in errors { Log.main.error("Config: \(e, privacy: .public)") }
        let bound = Set(compositor.pending.bindings.keys)
        settings.model.load(bindings: ConfigEditor(text).bindings, rules: compositor.pending.rules, problems: errors,
                            conflicts: Set(SystemShortcuts.conflicts(with: bound).map(\.combo)))
        settings.model.load(options: compositor.pending.options, paused: compositor.pending.paused)
        syncInput()
        hotkeys.retryFailed()
        scheduleCommit(forceAll: !initial)
    }

    private func syncInput() {
        // While the settings window records a shortcut, the keys must reach it.
        hotkeys.sync(settings.model.recording != nil ? [] : Set(compositor.pending.bindings.keys))
        mouse.trackMoves(compositor.pending.options.focusFollowsMouse)
    }

    private func hotkey(_ combo: KeyCombo) {
        guard let line = compositor.pending.bindings[combo] else { return }
        run(line, client: nil)
    }

    /// Runs a command line (from a key binding, the socket or the menu): apply to pending state,
    /// commit atomically, then perform side effects (focus after the windows are in place).
    func run(_ line: String, client: SocketServer.Client?) {
        var effects: [Effect] = []
        var errors: [String] = []
        var mutates = false
        for r in CommandParser.parseLine(line) {
            switch r {
            case .failure(let e):
                errors.append(e.description)
            case .success(let cmd):
                if !cmd.isReadOnly { mutates = true }
                do { effects += try compositor.execute(cmd) } catch { errors.append("\(error)") }
            }
        }
        if mutates {
            syncInput()
            commitNow()
        }
        var replied = false
        for e in effects {
            do { if try perform(e, client: client) { replied = true } } catch { errors.append("\(error)") }
        }
        if let client, !replied {
            client.reply(errors.isEmpty ? Wire.ok() : Wire.error(errors.joined(separator: "; ")))
        }
        if client == nil, !errors.isEmpty {
            Log.input.error("'\(line, privacy: .public)': \(errors.joined(separator: "; "), privacy: .public)")
        }
    }

    /// Returns true if it answered the client.
    private func perform(_ e: Effect, client: SocketServer.Client?) throws -> Bool {
        switch e {
        case .focus(let id):
            focus(id)
        case .close(let id):
            worker(of: id)?.close(id)
        case .warp(let p):
            _ = CGWarpMouseCursorPosition(p)
            _ = CGAssociateMouseAndMouseCursorPosition(1)
        case .exec(let c):
            spawn(c)
        case .reload:
            loadConfig(initial: false)
        case .quit:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
        case .retile:
            scheduleCommit(forceAll: true)
        case .reply(let json):
            if let client { client.reply(Wire.ok(data: json)); return true }
            Log.main.info("\(json, privacy: .public)")
        case .subscribe:
            if let client { client.subscribe(greeting: Wire.ok()); return true }
        case .openSettings:
            settings.show()
        case .showDesktop(let t):
            try showDesktop(t)
        case .moveToDesktop(let id, let t):
            try carry(id, to: t)
        }
        return false
    }

    // MARK: - Desktops (macOS Spaces)

    private var focusedDisplay: String? {
        let s = compositor.current
        return (s.focusedOutput ?? s.outputOrder.first).flatMap { s.outputs[$0]?.uuid }
    }

    private func isSameAsSystem(_ command: String, _ id: Int) -> Bool {
        if SystemShortcuts.desktopIDs.contains(id) { return command == "desktop \(id - 117)" }
        if id == SystemShortcuts.moveLeft { return command == "desktop left" }
        if id == SystemShortcuts.moveRight { return command == "desktop right" }
        return false
    }

    private func trackDesktops() {
        for o in compositor.current.outputs.values {
            let shown = NativeSpaces.current(on: o.uuid)
            if let h = heading[o.uuid] {
                // Desktops passed on the way are not "the previous one".
                guard shown == h.desktop || now >= h.until else { continue }
                heading[o.uuid] = nil
                if let next = queuedDesktop.removeValue(forKey: o.uuid) {
                    DispatchQueue.main.async { [weak self] in
                        do { try self?.showDesktop(next, on: o.uuid) } catch {
                            Log.input.error("desktop: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            }
            let old = desktops[o.uuid]
            guard old?.current != shown else { continue }
            desktops[o.uuid] = (shown, old?.current ?? old?.previous)
            if let n = shown { ipc?.broadcast("{\"desktop\":\(n),\"event\":\"desktop\",\"output\":\(o.id)}") }
        }
    }

    private func isSwitching(_ uuid: String) -> Bool {
        heading[uuid].map { now < $0.until } ?? false
    }

    /// The desktop a target means on a display, or nil when there is nothing to do.
    private func resolve(_ t: DesktopTarget, on uuid: String) -> Int? {
        let shown = NativeSpaces.current(on: uuid)
        let previous = desktops[uuid]?.previous
        switch t {
        case .number(let n):
            return n == shown ? (compositor.current.options.desktopBackAndForth ? previous : nil) : n
        case .back: return previous
        // At either end there is nowhere to go, which is not an error.
        case .left, .right:
            guard let here = NativeSpaces.desktops(on: uuid), let cur = shown else { return nil }
            let n = t == .left ? cur - 1 : cur + 1
            return here.range.contains(n) ? n : nil
        }
    }

    private func showDesktop(_ t: DesktopTarget, on display: String? = nil) throws {
        guard let uuid = display ?? focusedDisplay else { return }
        if isSwitching(uuid) { queuedDesktop[uuid] = t; return }
        guard let n = resolve(t, on: uuid) else { return }
        SystemShortcuts.press(try switchKeys(to: n, on: uuid))
    }

    /// The keys that take a display to desktop `n`; notes the switch as under way until macOS
    /// reports it done (or it should have).
    private func switchKeys(to n: Int, on uuid: String) throws -> [KeyCombo] {
        guard n != NativeSpaces.current(on: uuid) else { return [] }
        let keys = try NativeSpaces.keys(toShow: n, from: nil, on: uuid)
        guard !keys.isEmpty else { return [] }
        let wait = 0.9 + 0.3 * Double(keys.count)
        heading[uuid] = (n, now + wait)
        // In case macOS dropped the keys and no Space change ever arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in self?.trackDesktops() }
        return keys
    }

    /// There is no public way to move another app's window to a Space (and the private one needs
    /// SIP off since macOS 14.5). So, like Amethyst: hold the window by its title bar, press the
    /// desktop shortcut and let go once the Dock has carried it over.
    private func carry(_ id: WindowID, to t: DesktopTarget) throws {
        guard !carrying, let w = compositor.current.windows[id], w.isPresent, !w.nativeFullscreen,
              let uuid = compositor.current.outputs[w.output]?.uuid,
              !isSwitching(uuid), let n = resolve(t, on: uuid), n != NativeSpaces.current(on: uuid),
              worker(of: id) != nil else { return }
        let keys = try switchKeys(to: n, on: uuid)
        guard let worker = worker(of: id) else { return }
        carrying = true
        worker.grabPoint(id) { [weak self] p in
            guard let self else { return }
            // The press has to land on the window itself: a panel or another window on top would
            // get it instead, and the switch would leave the window behind.
            guard let p, self.compositor.current.windows[id]?.frame.contains(p) == true,
                  WindowServer.topWindow(at: p, excluding: getpid()) == id else {
                self.carrying = false
                NSSound.beep()
                Log.input.error("Can't carry window \(id, privacy: .public): its title bar is missing or covered")
                return
            }
            Log.input.info("Carrying window \(id, privacy: .public) to desktop \(n, privacy: .public), held at (\(Int(p.x), privacy: .public), \(Int(p.y), privacy: .public))")
            let back = Displays.pointer()
            func post(_ type: CGEventType, _ at: CGPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, p)
            post(.leftMouseDown, p)
            // A few pixels of real drag: apps that drag their own title bar (Chromium, Electron) only
            // start moving the window past a small threshold.
            let held = CGPoint(x: p.x + 12, y: p.y)
            for (i, dx) in [3.0, 6, 9, 12].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i + 1)) {
                    post(.leftMouseDragged, CGPoint(x: p.x + dx, y: p.y))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                SystemShortcuts.press(keys) {
                    // Let go once the switch animation is over.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        post(.leftMouseUp, held)
                        _ = CGWarpMouseCursorPosition(back)
                        _ = CGAssociateMouseAndMouseCursorPosition(1)
                        self.carrying = false
                        self.presenceDirty = true
                        self.scheduleCommit()
                    }
                }
            }
        }
    }

    private func focus(_ id: WindowID) {
        guard let w = compositor.pending.windows[id], let worker = workers[w.pid] else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != w.pid {
            _ = NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
        }
        worker.focus(id)
        if compositor.pending.options.mouseFollowsFocus {
            let f: CGRect?
            if case .frame(let r)? = compositor.placement(of: id) { f = r } else { f = compositor.current.windows[id]?.frame }
            if let f, !f.contains(Displays.pointer()) {
                _ = CGWarpMouseCursorPosition(f.center)
                _ = CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }

    private func worker(of id: WindowID) -> AppWorker? {
        compositor.pending.windows[id].flatMap { workers[$0.pid] }
    }

    private func spawn(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        if let path = ipc?.path { env["XANEWM_SOCKET"] = path }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.main.error("exec failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Settings window and menu

    private func connectSettings() {
        let m = settings.model
        m.onCommand = { [weak self] line in self?.run(line, client: nil) }
        m.onOpenConfig = { [weak self] in self?.openConfig() }
        m.onSetOption = { [weak self] name, values in self?.setOption(name, values) }
        m.onRecording = { [weak self] _ in self?.syncInput() }
        m.onSetBinding = { [weak self] old, new, command in
            self?.editConfig { e in
                if let old, old != new { e.setBinding(old, nil) }
                if let new { e.setBinding(new, command) }
            }
        }
        m.onSetRules = { [weak self] rules in self?.editConfig { $0.setRules(rules) } }
    }

    /// Applies an option now and writes it to the config file a moment later (sliders send many).
    private func setOption(_ name: String, _ values: [String]) {
        run((["set", name] + values.map(Tokenizer.quote)).joined(separator: " "), client: nil)
        optionWrites.removeAll { $0.name == name }
        optionWrites.append((name, values))
        optionWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushOptionWrites() }
        optionWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flushOptionWrites() {
        optionWrite?.cancel()
        optionWrite = nil
        guard !optionWrites.isEmpty else { return }
        let writes = optionWrites
        optionWrites = []
        writeConfig { e in for w in writes { e.setOption(w.name, w.values) } }
    }

    /// Rewrites the config file and reloads it.
    private func editConfig(_ change: (inout ConfigEditor) -> Void) {
        flushOptionWrites()
        if writeConfig(change) { loadConfig(initial: false) }
    }

    @discardableResult
    private func writeConfig(_ change: (inout ConfigEditor) -> Void) -> Bool {
        // Through symlinks, so a config kept in a dotfiles repo stays a link.
        let url = URL(fileURLWithPath: configPath).resolvingSymlinksInPath()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? Config.defaultText
        var e = ConfigEditor(text)
        change(&e)
        guard e.text != text else { return false }
        do { try e.text.write(to: url, atomically: true, encoding: .utf8) } catch {
            Log.main.error("Could not write the config: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    private func menuState() -> StatusBar.State {
        let s = compositor.current
        let oid = s.focusedOutput ?? s.outputOrder.first
        let o = oid.flatMap { s.outputs[$0] }
        let here = o.flatMap { NativeSpaces.desktops(on: $0.uuid) }
        return .init(layout: o?.layout, desktops: here?.range, desktop: here?.current,
                     focusFollowsMouse: s.options.focusFollowsMouse, border: s.options.border)
    }

    private func openConfig() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", configPath]
        try? p.run()
    }

    // MARK: - Commit

    func scheduleCommit(forceAll all: Bool = false) {
        if all { forceAll = true }
        guard !commitScheduled else { return }
        commitScheduled = true
        DispatchQueue.main.async { [weak self] in self?.commitNow() }
    }

    private func commitNow() {
        commitScheduled = false
        guard started, !shuttingDown, blockers.isEmpty else { return }
        if carrying { return }   // a commit follows the drop
        if MouseMonitor.isLeftButtonDown {
            // Never move windows while the user holds the pointer (dragging, selecting…).
            deferredCommit = true
            pollGrabEnd()
            return
        }
        if buttonDown { finishGrab() }   // a missed mouse-up: the hardware state is the truth
        if presenceDirty {
            presenceDirty = false
            let ws = windowServerSnapshot()
            compositor.setSpacePresence(onScreen: presentWindows(ws), known: ws.all)
        }
        let t0 = now
        let before = compositor.current
        let tx = compositor.commit(now: t0, forceAll: forceAll, force: force)
        forceAll = false
        force.removeAll()
        dispatch(tx)
        if !tx.configures.isEmpty {
            let ms = (now - t0) * 1000
            Log.tiling.debug("Commit: \(tx.configures.count, privacy: .public) configures · \(tx.tiled, privacy: .public) tiled · \(tx.floating, privacy: .public) floating · \(ms, format: .fixed(precision: 2), privacy: .public) ms")
        }
        if let ipc {
            for e in Compositor.events(from: before, to: compositor.current) { ipc.broadcast(e) }
        }
        updateStatus()
        scheduleBorderUpdate()
        store.scheduleSave { [weak self] in self?.compositor.persisted() ?? PersistedState() }
    }

    private func dispatch(_ tx: Transaction) {
        guard !tx.isEmpty else { return }
        let toggle = !NSWorkspace.shared.isVoiceOverEnabled
        for (pid, list) in Dictionary(grouping: tx.configures, by: { $0.pid }) {
            workers[pid]?.apply(list, toggleEnhancedUI: toggle)
        }
        for id in tx.raise { worker(of: id)?.raise(id) }
    }

    // MARK: - Pointer

    private func mouseDown() {
        guard !carrying else { return }
        buttonDown = true
        grabbed.removeAll()
    }

    private func mouseUp() {
        guard !carrying else { return }
        // AX notifications for the end of a drag can trail the release by a few milliseconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !MouseMonitor.isLeftButtonDown else { return }
            self.finishGrab()
        }
    }

    private func pollGrabEnd() {
        guard grabPoll == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.grabPoll = nil
            if MouseMonitor.isLeftButtonDown { self.pollGrabEnd() } else { self.finishGrab() }
        }
        grabPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// End of the grab: resizes become split ratios, drops become swaps or display moves.
    private func finishGrab() {
        guard buttonDown || deferredCommit || !grabbed.isEmpty else { return }
        buttonDown = false
        let pointer = Displays.pointer()
        var needsCommit = deferredCommit
        for id in grabbed {
            if compositor.interactiveEnd(id, pointer: pointer) { needsCommit = true }
        }
        grabbed.removeAll()
        deferredCommit = false
        if needsCommit { scheduleCommit() }
    }

    private func pointerMoved() {
        guard compositor.current.options.focusFollowsMouse, !buttonDown, !carrying, blockers.isEmpty else { return }
        let delay = compositor.current.options.focusFollowsMouseDelay
        if delay <= 0 {
            // Instant (sway's focus_follows_mouse): focus on entering a window. Moving inside the
            // same window does nothing, so ⌘-Tab elsewhere is not undone by the next nudge.
            let p = Displays.pointer()
            let target = compositor.window(at: p)
            guard target != pointerWindow else { return }
            guard let target, target != compositor.current.focused else { pointerWindow = target; return }
            // Covered by a menu, the Dock, a popover…: try again on the next move.
            guard !MouseMonitor.isLeftButtonDown,
                  WindowServer.topWindow(at: p, excluding: getpid()) == target else { return }
            pointerWindow = target
            focus(target)
            return
        }
        hover?.cancel()
        let start = Displays.pointer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let p = Displays.pointer()
            // Only when the pointer rests: passing over windows on the way elsewhere changes nothing.
            guard hypot(p.x - start.x, p.y - start.y) < 6, !MouseMonitor.isLeftButtonDown,
                  let target = self.compositor.window(at: p), target != self.compositor.current.focused,
                  WindowServer.topWindow(at: p, excluding: getpid()) == target else { return }
            self.focus(target)
        }
        hover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + compositor.current.options.focusFollowsMouseDelay, execute: work)
    }

    // MARK: - Workers

    private func shouldManage(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier > 0 && app.processIdentifier != getpid() && !app.isTerminated
    }

    private func addWorker(_ app: NSRunningApplication) {
        guard started, !shuttingDown, shouldManage(app), workers[app.processIdentifier] == nil else { return }
        let w = AppWorker(app: app)
        w.delegate = self
        workers[app.processIdentifier] = w
        w.start()
    }

    private func appTerminated(_ pid: pid_t) {
        workers.removeValue(forKey: pid)?.stop()
        busyRetry.remove(pid)
        let gone = compositor.pending.windows.values.filter { $0.pid == pid }
        guard !gone.isEmpty else { return }
        let focused = compositor.pending.focused
        let output = gone.first(where: { $0.id == focused })?.output
        for w in gone { forgetBookkeeping(w.id); compositor.removeWindow(w.id) }
        presenceDirty = true
        scheduleCommit()
        if let output { scheduleFocusFallback(output) }
    }

    func worker(_ worker: AppWorker, produced e: WorkerEvent) {
        guard workers[worker.pid] === worker, !shuttingDown else { return }
        switch e {
        case .window(let s):
            windowReported(s)
        case .destroyed(let id):
            windowDestroyed(id)
        case .frame(let id, let f, let fs):
            frameChanged(id, f, nativeFullscreen: fs, worker: worker)
        case .minimized(let id, let v):
            let wasFocused = compositor.pending.focused == id
            compositor.setMinimized(id, v)
            presenceDirty = true
            scheduleCommit()
            if v, wasFocused, let o = compositor.pending.windows[id]?.output { scheduleFocusFallback(o) }
        case .focused(let pid, let id):
            // Background apps also change their internal focus; only the frontmost app counts.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            compositor.systemFocused(id)
            if let id, compositor.pending.windows[id] != nil { focusFallback?.cancel() }
            presenceDirty = true   // switching native tabs changes which window is on screen
            scheduleCommit()
            scheduleBorderUpdate()
        case .hidden(let pid, let v):
            compositor.setAppHidden(pid: pid, v)
            presenceDirty = true
            scheduleCommit()
        case .ack(let id, let serial, let frame):
            ack(id, serial, frame)
        case .discovered(let pid, let seen):
            discovered(pid, seen)
        case .unresponsive(let pid):
            guard !busyRetry.contains(pid) else { return }
            busyRetry.insert(pid)
            Log.events.info("\(worker.appName, privacy: .private) didn't answer in time; keeping its windows")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.busyRetry.remove(pid)
                self?.scheduleCommit()
            }
        }
    }

    private func windowReported(_ s: WindowSnapshot) {
        if compositor.pending.windows[s.id] != nil {
            compositor.setMinimized(s.id, s.isMinimized)
            compositor.setNativeFullscreen(s.id, s.isNativeFullscreen)
            compositor.setTitle(s.id, s.title)
            presenceDirty = true
            scheduleCommit()
            return
        }
        // Floating panels and overlays (layer above normal) are not part of the layout, even when
        // AX calls them standard windows.
        if windowServerSnapshot().raised.contains(s.id) { return }
        let c = classify(s, rules: compositor.pending.rules)
        guard c.management != .ignore,
              compositor.addWindow(s, classification: c, pointer: Displays.pointer()) else { return }
        Log.tiling.info("New window \(s.id, privacy: .public) of \(s.appName, privacy: .private): \(c.management.rawValue, privacy: .public) (\(c.reason, privacy: .public))")
        presenceDirty = true
        scheduleCommit()
    }

    private func windowDestroyed(_ id: WindowID) {
        guard let w = compositor.pending.windows[id] else { return }
        let hadFocus = compositor.pending.focused == id
        forgetBookkeeping(id)
        compositor.removeWindow(id)
        presenceDirty = true
        scheduleCommit()
        if hadFocus { scheduleFocusFallback(w.output) }
    }

    private func frameChanged(_ id: WindowID, _ frame: CGRect, nativeFullscreen fs: Bool?, worker: AppWorker) {
        guard let w = compositor.pending.windows[id] else {
            // Not managed (yet): windows created tiny or half-built get another look once they change.
            let t = now
            if t - (resnapshotAt[id] ?? 0) > 0.5 {
                if resnapshotAt.count > 512 { resnapshotAt.removeAll() }
                resnapshotAt[id] = t
                worker.resnapshot(id)
            }
            return
        }
        if let fs, fs != w.nativeFullscreen {
            compositor.setNativeFullscreen(id, fs)
            presenceDirty = true
            scheduleCommit()
            return
        }
        let observation = compositor.observe(id, frame: frame, now: now)
        if id == compositor.current.focused { scheduleBorderUpdate() }
        guard observation == .external, !carrying else { return }
        if buttonDown || MouseMonitor.isLeftButtonDown {
            buttonDown = true
            grabbed.insert(id)   // the user is moving/resizing it: decide on release
            pollGrabEnd()        // in case the global mouse-up monitor misses the release
            return
        }
        // The app moved a window the compositor placed: the compositor has the last word…
        guard compositor.pending.options.enforceLayout, !compositor.pending.paused else { return }
        switch compositor.placement(of: id) {
        case .frame?:
            // …unless it keeps fighting back (some apps animate or snap): then let it be for a while.
            if isFighting(id) {
                if fights[id]?.count == 5 {
                    Log.tiling.info("Window \(id, privacy: .public) keeps changing its own frame; leaving it alone for a moment")
                }
                return
            }
            scheduleCommit()
        default:
            break
        }
    }

    private func isFighting(_ id: WindowID) -> Bool {
        let t = now
        var f = fights[id] ?? (count: 0, since: t)
        if t - f.since > 3 { f = (count: 0, since: t) }
        f.count += 1
        fights[id] = f
        return f.count > 4
    }

    private func ack(_ id: WindowID, _ serial: UInt64, _ frame: CGRect?) {
        guard let frame else { return }
        switch compositor.ack(id, serial: serial, frame: frame) {
        case .settled:
            recheck[id] = nil
        case .stale:
            break
        case .tooBig(let asked):
            if recheck[id] != nil || compositor.isSuspectMinimum(id) {
                recheck[id] = nil
                let outcome = compositor.learnMinimum(id, asked: asked, got: frame)
                Log.tiling.info("Window \(id, privacy: .public) can't be smaller than about \(Int(frame.width), privacy: .public)×\(Int(frame.height), privacy: .public) (\(String(describing: outcome), privacy: .public))")
                scheduleCommit()
            } else {
                // Some apps catch up late. Ask once more before taking it as a minimum size.
                recheck[id] = asked
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self, self.recheck[id] != nil, self.compositor.pending.windows[id] != nil else { return }
                    self.force.insert(id)
                    self.scheduleCommit()
                }
            }
        }
        if id == compositor.current.focused { scheduleBorderUpdate() }
    }

    private func discovered(_ pid: pid_t, _ seen: Set<WindowID>) {
        let ws = windowServerSnapshot()
        let gone = compositor.pending.windows.values.filter {
            $0.pid == pid && ((!seen.contains($0.id) && !ws.all.contains($0.id)) || ws.raised.contains($0.id))
        }
        for w in gone {
            // Neither AX nor the window server knows it any more (it closed without telling us), or
            // it went above normal level.
            Log.tiling.info("Window \(w.id, privacy: .public) went away or now floats above the rest")
            forgetBookkeeping(w.id)
            compositor.removeWindow(w.id)
            workers[pid]?.forgetWindow(w.id)
        }
        compositor.setSpacePresence(onScreen: presentWindows(ws), known: ws.all)
        presenceDirty = false
        scheduleCommit()
    }

    /// Windows on the desktop each display shows. By Space membership when the window server
    /// tells, so a desktop switch in progress (both desktops on screen) does not mix them up.
    private func presentWindows(_ ws: WindowServer.Snapshot) -> Set<WindowID> {
        guard let bySpace = NativeSpaces.onShownDesktops(compositor.windowIDs) else { return ws.onScreen }
        // A window the window server can't place for a moment keeps what it had: falling back to
        // "on screen" mid-switch is exactly what mixes both desktops up.
        let keep = bySpace.unknown.filter { compositor.pending.windows[$0]?.onCurrentSpace ?? true }
        return bySpace.present.union(keep)
    }

    private func forgetBookkeeping(_ id: WindowID) {
        recheck[id] = nil
        fights[id] = nil
        resnapshotAt[id] = nil
        grabbed.remove(id)
    }

    private func scheduleFocusFallback(_ output: OutputID) {
        focusFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let s = self.compositor.pending
            if let f = s.focused, s.isVisible(f) { return }   // the app already focused something
            if let c = s.focusCandidate(on: output) { self.focus(c) }
        }
        focusFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - System events

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ center: NotificationCenter, _ f: @escaping (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: f))
        }
        func app(_ n: Notification) -> NSRunningApplication? {
            n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        on(NSWorkspace.didLaunchApplicationNotification, ws) { [weak self] n in
            if let a = app(n) { self?.addWorker(a) }
        }
        on(NSWorkspace.didTerminateApplicationNotification, ws) { [weak self] n in
            if let a = app(n) { self?.appTerminated(a.processIdentifier) }
        }
        on(NSWorkspace.didActivateApplicationNotification, ws) { [weak self] n in
            guard let self, let a = app(n) else { return }
            if a.processIdentifier == getpid() {
                self.compositor.systemFocused(nil)
                self.scheduleBorderUpdate()
                return
            }
            if self.workers[a.processIdentifier] == nil { self.addWorker(a) }   // apps that became regular late
            self.workers[a.processIdentifier]?.requestFocusReport()
            self.presenceDirty = true
            self.updateStageManager()
        }
        on(NSWorkspace.didHideApplicationNotification, ws) { [weak self] n in
            guard let self, let a = app(n) else { return }
            self.compositor.setAppHidden(pid: a.processIdentifier, true)
            self.presenceDirty = true
            self.scheduleCommit()
        }
        on(NSWorkspace.didUnhideApplicationNotification, ws) { [weak self] n in
            guard let self, let a = app(n) else { return }
            self.compositor.setAppHidden(pid: a.processIdentifier, false)
            self.presenceDirty = true
            self.scheduleCommit()
        }
        on(NSWorkspace.activeSpaceDidChangeNotification, ws) { [weak self] _ in self?.spaceChanged() }
        on(NSWorkspace.willSleepNotification, ws) { [weak self] _ in self?.block("asleep") }
        on(NSWorkspace.screensDidSleepNotification, ws) { [weak self] _ in self?.block("asleep") }
        on(NSWorkspace.didWakeNotification, ws) { [weak self] _ in self?.unblock("asleep") }
        on(NSWorkspace.screensDidWakeNotification, ws) { [weak self] _ in self?.unblock("asleep") }
        on(NSWorkspace.sessionDidResignActiveNotification, ws) { [weak self] _ in self?.block("user switched") }
        on(NSWorkspace.sessionDidBecomeActiveNotification, ws) { [weak self] _ in self?.unblock("user switched") }
        on(NSApplication.didChangeScreenParametersNotification, NotificationCenter.default) { [weak self] _ in
            self?.screensChanged()
        }
        let dnc = DistributedNotificationCenter.default()
        on(Notification.Name("com.apple.screenIsLocked"), dnc) { [weak self] _ in self?.block("screen locked") }
        on(Notification.Name("com.apple.screenIsUnlocked"), dnc) { [weak self] _ in self?.unblock("screen locked") }
    }

    private func spaceChanged() {
        border.hide()
        trackDesktops()
        presenceDirty = true
        updateStageManager()
        // AX only lists the windows of the current Space: look again (first visit = new windows).
        for w in workers.values { w.rediscover() }
        scheduleCommit()
        // The window server settles shortly after the notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.presenceDirty = true
            self?.scheduleCommit()
        }
    }

    private func screensChanged() {
        screenChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.compositor.setOutputs(Displays.outputs())
            Log.main.info("Displays changed: \(self.compositor.pending.outputs.count, privacy: .public) connected")
            self.presenceDirty = true
            self.scheduleCommit(forceAll: true)
        }
        screenChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func updateStageManager() {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        let on = (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) as? Bool) ?? false
        if on, !blockers.contains("Stage Manager") {
            block("Stage Manager")
        } else if !on {
            unblock("Stage Manager")
        }
    }

    private func block(_ why: String) {
        guard blockers.insert(why).inserted else { return }
        border.hide()
        Log.main.info("Pausing: \(why, privacy: .public)")
        updateStatus()
    }

    private func unblock(_ why: String) {
        guard blockers.remove(why) != nil else { return }
        updateStatus()
        guard blockers.isEmpty else { return }
        Log.main.info("Resuming after: \(why, privacy: .public)")
        // Things changed while we weren't looking (displays, apps, windows): catch up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.blockers.isEmpty else { return }
            self.compositor.setOutputs(Displays.outputs())
            for w in self.workers.values { w.rediscover() }
            self.presenceDirty = true
            self.hotkeys.retryFailed()
            self.scheduleCommit(forceAll: true)
        }
    }

    // MARK: - Chrome

    private func scheduleBorderUpdate() {
        guard !borderScheduled else { return }
        borderScheduled = true
        DispatchQueue.main.async { [weak self] in self?.updateBorder() }
    }

    private func updateBorder() {
        borderScheduled = false
        let s = compositor.current
        guard started, s.options.border, blockers.isEmpty, !s.paused, let id = s.focused, let w = s.windows[id],
              s.isVisible(w), !w.fullscreen else {
            border.hide()
            return
        }
        border.show(around: w.frame, below: id, width: s.options.borderWidth, radius: s.options.borderRadius,
                    color: BorderOverlay.color(s.options.borderColor))
    }

    private func updateStatus() {
        let s = compositor.current
        guard let oid = s.focusedOutput ?? s.outputOrder.first, let o = s.outputs[oid] else { return }
        trackDesktops()
        let desktop = desktops[o.uuid]?.current.map { "desktop \($0) · " } ?? ""
        let reason = blockers.sorted().first ?? (s.paused ? "paused" : nil)
        let status = reason.map { "Not tiling: \($0)" }
            ?? "\(desktop)\(o.layout.rawValue) · \(s.tiled(on: oid).count) tiled · \(s.windows.count) windows"
        statusBar.set(status: status, active: reason == nil, paused: s.paused)
        settings.model.load(options: compositor.pending.options, paused: s.paused)
    }
}
#endif
