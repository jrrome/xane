#if os(macOS)
import AppKit
import ApplicationServices
import XaneCore

/// What a worker reports to the server (always delivered on the main queue).
enum WorkerEvent {
    case window(WindowSnapshot)
    case destroyed(WindowID)
    case frame(WindowID, CGRect, nativeFullscreen: Bool?)
    case minimized(WindowID, Bool)
    case focused(pid_t, WindowID?)
    case hidden(pid_t, Bool)
    case ack(WindowID, serial: UInt64, frame: CGRect?)
    /// Result of a full enumeration: the windows AX reports for this app on the current Space.
    case discovered(pid_t, Set<WindowID>)
    case unresponsive(pid_t)
}

protocol WorkerDelegate: AnyObject {
    func worker(_ worker: AppWorker, produced event: WorkerEvent)
}

/// One per application: a dedicated thread with its own run loop that owns the app's AXObserver
/// and performs every AX call for that app.
///
/// Every AX call is a synchronous IPC round-trip into the other process. Keeping them off the
/// main thread, serialised per app and parallel across apps means a hung app only ever stalls
/// its own worker: the compositor, the other apps and the UI keep going.
final class AppWorker {
    let pid: pid_t
    let bundleID: String
    let appName: String
    weak var delegate: WorkerDelegate?

    private let app: AXUIElement
    private var runLoop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)
    private var stopped = false

    // Worker-thread state.
    private var observer: AXObserver?
    private var observerAttempts = 0
    private var discoverRetries = 0
    private var windows: [WindowID: AXUIElement] = [:]
    private var ids: [AXKey: WindowID] = [:]

    // Configures are coalesced: only the latest request per window is applied.
    private let lock = NSLock()
    private var queued: [WindowID: Configure] = [:]
    private var queuedOrder: [WindowID] = []
    private var drainScheduled = false
    private var toggleEnhancedUI = true

    static let windowTimeout: Float = 0.25
    static let appTimeout: Float = 0.5
    static let appNotifications = ["AXWindowCreated", "AXFocusedWindowChanged", "AXApplicationHidden", "AXApplicationShown"]
    static let windowNotifications = ["AXUIElementDestroyed", "AXMoved", "AXResized", "AXWindowMiniaturized", "AXWindowDeminiaturized"]
    static let snapshotAttributes = [
        "AXRole", "AXSubrole", "AXTitle", "AXPosition", "AXSize", "AXMinimized", "AXFullScreen", "AXModal",
        "AXMinimizeButton", "AXFullScreenButton", "AXCloseButton", "AXDefaultButton", "AXCancelButton",
        "AXDocument", "AXIdentifier",
    ] as CFArray
    static let frameAttributes = ["AXPosition", "AXSize"] as CFArray
    static let frameAndFullscreenAttributes = ["AXPosition", "AXSize", "AXFullScreen"] as CFArray

    init(app: NSRunningApplication) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier ?? ""
        appName = app.localizedName ?? bundleID
        self.app = AXUIElementCreateApplication(pid)
    }

    // MARK: - Thread

    func start() {
        let thread = Thread { [self] in threadMain() }
        thread.name = "xanewm.ax.\(pid)"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    func stop() {
        perform { [self] in
            stopped = true
            if let rl = runLoop { CFRunLoopStop(rl) }
        }
    }

    private func threadMain() {
        let rl: CFRunLoop = CFRunLoopGetCurrent()
        runLoop = rl
        // An inert source keeps the run loop alive even before the AX observer exists.
        var ctx = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx)
        CFRunLoopAddSource(rl, keepAlive, .defaultMode)
        started.signal()

        AXUIElementSetMessagingTimeout(app, Self.appTimeout)
        attachObserver()
        discover()
        while !stopped {
            autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 3600, false) }
        }
        detachObserver()
        CFRunLoopRemoveSource(rl, keepAlive, .defaultMode)
    }

    /// Runs a block on the worker thread.
    private func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    private func after(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.perform(block)
        }
    }

    private func emit(_ e: WorkerEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.worker(self, produced: e)
        }
    }

    // MARK: - Observer

    private func attachObserver() {
        guard !stopped, observer == nil, let rl = runLoop else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let obs = created else {
            retryAttach(); return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var notReady = false
        for n in Self.appNotifications {
            let r = AXObserverAddNotification(obs, app, n as CFString, refcon)
            if r == .cannotComplete { notReady = true }
        }
        // The app is still launching and not answering yet: try again shortly.
        if notReady { retryAttach(); return }
        CFRunLoopAddSource(rl, AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        for el in windows.values { watch(el) }
    }

    private func retryAttach() {
        observerAttempts += 1
        guard observerAttempts <= 8 else { return }
        let delay = min(0.25 * pow(2, Double(observerAttempts - 1)), 4)
        after(delay) { [weak self] in
            self?.attachObserver()
            self?.discover()
        }
    }

    private func detachObserver() {
        guard let obs = observer, let rl = runLoop else { return }
        CFRunLoopRemoveSource(rl, AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = nil
    }

    private func watch(_ el: AXUIElement) {
        guard let obs = observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.windowNotifications { _ = AXObserverAddNotification(obs, el, n as CFString, refcon) }
    }

    fileprivate func handle(_ name: String, _ el: AXUIElement) {
        switch name {
        case "AXWindowCreated":
            adopt(el, announce: true)
            // Many apps finish building the window a moment later (size, subrole, title).
            after(0.2) { [weak self] in self?.refresh(el) }
            after(0.8) { [weak self] in self?.refresh(el) }
        case "AXUIElementDestroyed":
            guard let id = ids[AXKey(element: el)] else { return }
            forget(id)
            emit(.destroyed(id))
        case "AXMoved", "AXResized":
            guard let id = ids[AXKey(element: el)] else { return }
            let (frame, fs) = readFrame(el, fullscreen: name == "AXResized")
            if let frame { emit(.frame(id, frame, nativeFullscreen: fs)) }
        case "AXWindowMiniaturized", "AXWindowDeminiaturized":
            guard let id = ids[AXKey(element: el)] else { return }
            emit(.minimized(id, name == "AXWindowMiniaturized"))
        case "AXFocusedWindowChanged":
            reportFocus()
        case "AXApplicationHidden":
            emit(.hidden(pid, true))
        case "AXApplicationShown":
            emit(.hidden(pid, false))
        default:
            break
        }
    }

    // MARK: - Inventory

    @discardableResult
    private func adopt(_ el: AXUIElement, announce: Bool) -> WindowID? {
        guard let id = el.windowID else { return nil }
        if windows[id] == nil {
            windows[id] = el
            ids[AXKey(element: el)] = id
            AXUIElementSetMessagingTimeout(el, Self.windowTimeout)
            watch(el)
        }
        if announce, let s = snapshot(windows[id]!, id) { emit(.window(s)) }
        return id
    }

    private func refresh(_ el: AXUIElement) {
        guard let id = ids[AXKey(element: el)] ?? el.windowID else { return }
        if windows[id] == nil { adopt(el, announce: true) }
        else if let s = snapshot(windows[id]!, id) { emit(.window(s)) }
    }

    private func forget(_ id: WindowID) {
        guard let el = windows.removeValue(forKey: id) else { return }
        ids[AXKey(element: el)] = nil
        if let obs = observer {
            for n in Self.windowNotifications { _ = AXObserverRemoveNotification(obs, el, n as CFString) }
        }
    }

    private func discover() {
        guard !stopped else { return }
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value)
        if err == .cannotComplete {
            emit(.unresponsive(pid))
            // Windows that already exist never send AXWindowCreated: look again while the app is busy.
            discoverRetries += 1
            if discoverRetries <= 5 { after(2) { [weak self] in self?.discover() } }
            return
        }
        discoverRetries = 0
        guard err == .success, let list = value as? [AXUIElement] else { return }
        var seen = Set<WindowID>()
        for el in list { if let id = adopt(el, announce: true) { seen.insert(id) } }
        emit(.discovered(pid, seen))
    }

    private func snapshot(_ el: AXUIElement, _ id: WindowID) -> WindowSnapshot? {
        guard let raw = AX.multiple(el, Self.snapshotAttributes), raw.count == 15 else { return nil }
        let v = raw.map { AX.unwrap($0) }
        guard let pos = v[3].flatMap(AX.point), let size = v[4].flatMap(AX.size) else { return nil }
        var s = WindowSnapshot(id: id, pid: pid, bundleID: bundleID, appName: appName)
        s.role = v[0] as? String ?? ""
        s.subrole = v[1] as? String ?? ""
        s.title = v[2] as? String ?? ""
        s.frame = CGRect(origin: pos, size: size)
        s.isMinimized = v[5] as? Bool ?? false
        s.isNativeFullscreen = v[6] as? Bool ?? false
        s.isModal = v[7] as? Bool ?? false
        s.hasMinimizeButton = v[8] != nil
        s.hasFullscreenButton = v[9] != nil
        s.hasCloseButton = v[10] != nil
        s.hasDialogButtons = v[11] != nil && v[12] != nil
        s.hasDocument = (v[13] as? String).map { !$0.isEmpty } ?? false
        s.identifier = v[14] as? String ?? ""
        s.isSizeSettable = AX.isSettable(el, "AXSize")
        s.isPositionSettable = AX.isSettable(el, "AXPosition")
        return s
    }

    private func readFrame(_ el: AXUIElement, fullscreen: Bool = false) -> (CGRect?, Bool?) {
        guard let raw = AX.multiple(el, fullscreen ? Self.frameAndFullscreenAttributes : Self.frameAttributes),
              raw.count >= 2,
              let p = AX.unwrap(raw[0]).flatMap(AX.point),
              let s = AX.unwrap(raw[1]).flatMap(AX.size) else { return (nil, nil) }
        let fs: Bool? = (fullscreen && raw.count > 2) ? (AX.unwrap(raw[2]) as? Bool) : nil
        return (CGRect(origin: p, size: s), fs)
    }

    private func reportFocus() {
        emit(.focused(pid, AX.element(app, "AXFocusedWindow")?.windowID))
    }

    // MARK: - Requests from the server (any thread)

    func rediscover() { perform { [weak self] in self?.discover() } }
    func requestFocusReport() { perform { [weak self] in self?.reportFocus() } }

    func resnapshot(_ id: WindowID) {
        perform { [weak self] in
            guard let self, let el = self.windows[id], let s = self.snapshot(el, id) else { return }
            self.emit(.window(s))
        }
    }

    func forgetWindow(_ id: WindowID) { perform { [weak self] in self?.forget(id) } }

    func focus(_ id: WindowID) {
        perform { [weak self] in
            guard let self, let el = self.windows[id] else { return }
            AX.set(self.app, "AXFrontmost", true)
            AX.set(el, "AXMain", true)
            AXUIElementPerformAction(el, "AXRaise" as CFString)
        }
    }

    func raise(_ id: WindowID) {
        perform { [weak self] in
            guard let self, let el = self.windows[id] else { return }
            AXUIElementPerformAction(el, "AXRaise" as CFString)
        }
    }

    /// A point of the title bar that drags the window: halfway between the close and minimize
    /// buttons (clear of rounded corners and of toolbar items). Delivered on the main queue.
    func grabPoint(_ id: WindowID, _ done: @escaping (CGPoint?) -> Void) {
        perform { [weak self] in
            var p: CGPoint?
            if let el = self?.windows[id], let close = AX.element(el, "AXCloseButton").flatMap(Self.frame) {
                let next = AX.element(el, "AXMinimizeButton").flatMap(Self.frame)
                p = CGPoint(x: next.map { (close.maxX + $0.minX) / 2 } ?? close.minX - 4, y: close.midY)
            }
            DispatchQueue.main.async { done(p) }
        }
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = AX.copy(el, "AXPosition").flatMap(AX.point), let s = AX.copy(el, "AXSize").flatMap(AX.size) else { return nil }
        return CGRect(origin: p, size: s)
    }

    func close(_ id: WindowID) {
        perform { [weak self] in
            guard let self, let el = self.windows[id], let button = AX.element(el, "AXCloseButton") else { return }
            AXUIElementPerformAction(button, "AXPress" as CFString)
        }
    }

    /// Queues configures; a burst of commits collapses into one application of the latest frames.
    func apply(_ configures: [Configure], toggleEnhancedUI toggle: Bool) {
        lock.lock()
        for c in configures {
            if queued[c.window] == nil { queuedOrder.append(c.window) }
            queued[c.window] = c
        }
        toggleEnhancedUI = toggle
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { perform { [weak self] in self?.drain() } }
    }

    private func drain() {
        lock.lock()
        let order = queuedOrder, batch = queued, toggle = toggleEnhancedUI
        queuedOrder = []; queued = [:]; drainScheduled = false
        lock.unlock()
        guard !order.isEmpty else { return }

        // Chrome/Electron/Firefox animate frame changes while AXEnhancedUserInterface is on
        // (set by assistive tech), making moves slow and racy. Switch it off once per batch —
        // unless VoiceOver is running, where toggling it would disturb the user.
        var restoreEnhanced = false
        if toggle, AX.bool(app, "AXEnhancedUserInterface") == true {
            AX.set(app, "AXEnhancedUserInterface", false)
            restoreEnhanced = true
        }
        defer { if restoreEnhanced { AX.set(app, "AXEnhancedUserInterface", true) } }

        for (i, id) in order.enumerated() {
            guard let c = batch[id] else { continue }
            guard let el = windows[id] else { emit(.ack(id, serial: c.serial, frame: nil)); continue }
            let (frame, err) = configure(el, c)
            if err == .invalidUIElement {
                forget(id)
                emit(.destroyed(id))
                continue
            }
            if err == .cannotComplete {
                // The app is busy. Don't queue up more timeouts behind this one.
                emit(.unresponsive(pid))
                for rest in order[(i + 1)...] { if let r = batch[rest] { emit(.ack(rest, serial: r.serial, frame: nil)) } }
                return
            }
            emit(.ack(id, serial: c.serial, frame: frame))
        }
    }

    /// Applies one configure and returns the frame the window actually took.
    ///
    /// The order of the size/position writes matters: macOS keeps windows on screen, so moving a
    /// window that is still at its old (bigger) size towards an edge gets it clamped. Shrink first
    /// when shrinking, move first when growing, and size–move–size when mixed.
    private func configure(_ el: AXUIElement, _ c: Configure) -> (CGRect?, AXError) {
        let t = c.frame
        var err: AXError = .success
        func size() { let e = AX.set(el, size: t.size); if e != .success { err = e } }
        func move() { let e = AX.set(el, position: t.origin); if e != .success { err = e } }

        if let cur = readFrame(el).0 {
            let growW = t.width > cur.width + 0.5, growH = t.height > cur.height + 0.5
            let shrinkW = t.width < cur.width - 0.5, shrinkH = t.height < cur.height - 0.5
            let moves = !cur.origin.isClose(to: t.origin, tolerance: 0.5)
            let resizes = growW || growH || shrinkW || shrinkH
            if moves && resizes {
                if !(growW || growH) { size(); move() }
                else if !(shrinkW || shrinkH) { move(); size() }
                else { size(); move(); size() }
            } else if moves {
                move()
            } else if resizes {
                size()
            }
        } else {
            size(); move(); size()
        }
        if err == .invalidUIElement || err == .cannotComplete { return (nil, err) }
        var got = readFrame(el).0
        // Verification: some apps nudge the origin while resizing. One more try.
        if let g = got, !g.origin.isClose(to: t.origin, tolerance: 0.5) {
            move()
            got = readFrame(el).0
        }
        return (got, err)
    }
}

/// C callback for every AX notification; runs on the worker's thread (its run loop owns the source).
private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let worker = Unmanaged<AppWorker>.fromOpaque(refcon).takeUnretainedValue()
    worker.handle(notification as String, element)
}
#endif
