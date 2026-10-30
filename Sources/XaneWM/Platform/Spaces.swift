#if os(macOS)
import AppKit
import XaneCore

/// macOS Spaces are XaneWM's desktops. Reading them needs SkyLight (private, read-only, the same
/// calls yabai and Hammerspoon use); switching goes through the user's own Mission Control
/// shortcuts, so the Dock stays in charge of Spaces (and of their animation).
enum NativeSpaces {
    struct Display {
        var uuid: String
        /// Desktops in Mission Control order; fullscreen apps' Spaces are not numbered.
        var desktops: [UInt64]
        /// Every Space in order, fullscreen apps' included: "Move left/right a space" steps through
        /// all of them.
        var spaces: [UInt64]
        var current: UInt64
    }

    enum Failure: Error, CustomStringConvertible {
        case unavailable, noDesktop(Int), shortcutOff(Int), cannotAdd
        var description: String {
            switch self {
            case .unavailable: return "this macOS does not expose its Spaces"
            case .cannotAdd: return "could not add a desktop through Mission Control"
            case .noDesktop(let n): return "there is no desktop \(n) (add it in Mission Control)"
            case .shortcutOff(let n):
                return "turn on “Switch to Desktop \(n)” (or “Move left/right a space”) in System Settings → Keyboard → Keyboard Shortcuts → Mission Control"
            }
        }
    }

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection = skyLight.flatMap { dlsym($0, "SLSMainConnectionID") }
        .map { unsafeBitCast($0, to: ConnectionFn.self) }
    private static let copySpaces = skyLight.flatMap { dlsym($0, "SLSCopyManagedDisplaySpaces") }
        .map { unsafeBitCast($0, to: CopySpacesFn.self) }

    private static let spacesForWindows = skyLight.flatMap { dlsym($0, "SLSCopySpacesForWindows") }
        .map { unsafeBitCast($0, to: SpacesForWindowsFn.self) }

    private typealias DockNotifyFn = @convention(c) (CFString, Int32) -> Int32
    private static let dockNotify = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        .flatMap { dlsym($0, "CoreDockSendNotification") }.map { unsafeBitCast($0, to: DockNotifyFn.self) }

    static var isAvailable: Bool { connection != nil && copySpaces != nil }

    /// Which of these windows live on a desktop some display shows right now. Unlike "on screen",
    /// it does not flicker while the Dock animates a switch (when both desktops are on screen).
    /// Windows the window server can't place (just created, or gone) come back as unknown.
    static func onShownDesktops(_ ids: Set<WindowID>) -> (present: Set<WindowID>, unknown: Set<WindowID>)? {
        guard let connection, let spacesForWindows else { return nil }
        let cid = connection()
        let shown = Set(displays().map(\.current))
        guard !shown.isEmpty else { return ([], ids) }
        var present = Set<WindowID>(), unknown = Set<WindowID>()
        for id in ids {
            // 7: every kind of Space (desktops, fullscreen apps, the ones the system keeps).
            let spaces = (spacesForWindows(cid, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber]) ?? []
            if spaces.isEmpty { unknown.insert(id) }
            else if spaces.contains(where: { shown.contains($0.uint64Value) }) { present.insert(id) }
        }
        return (present, unknown)
    }

    static func displays() -> [Display] {
        guard let connection, let copySpaces,
              let list = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        func id(_ space: [String: Any]?) -> UInt64? { (space?["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        return list.map { d in
            let spaces = d["Spaces"] as? [[String: Any]] ?? []
            return Display(uuid: d["Display Identifier"] as? String ?? "",
                           desktops: spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }.compactMap(id),
                           spaces: spaces.compactMap(id),
                           current: id(d["Current Space"] as? [String: Any]) ?? 0)
        }
    }

    static var desktopCount: Int { displays().reduce(0) { $0 + $1.desktops.count } }

    /// The desktops of a display as Mission Control numbers them (numbers run on across displays)
    /// and the one it shows (nil on a fullscreen app's Space). A single entry ("Main") when displays
    /// share their Spaces.
    static func desktops(on uuid: String) -> (range: ClosedRange<Int>, current: Int?)? {
        let all = displays()
        var base = 0
        for d in all {
            if d.uuid == uuid || all.count == 1 {
                guard !d.desktops.isEmpty else { return nil }
                return (base + 1...base + d.desktops.count, d.desktops.firstIndex(of: d.current).map { base + $0 + 1 })
            }
            base += d.desktops.count
        }
        return nil
    }

    static func current(on uuid: String) -> Int? { desktops(on: uuid)?.current }

    /// Keys that take a display to desktop `n`: its "Switch to Desktop N" shortcut when that is on,
    /// else "Move left/right a space" as many times as it takes from desktop `from` (nil: from the
    /// Space it shows, which may be a fullscreen app's).
    static func keys(toShow n: Int, from: Int? = nil, on uuid: String) throws -> [KeyCombo] {
        guard isAvailable else { throw Failure.unavailable }
        guard n >= 1, n <= desktopCount else { throw Failure.noDesktop(n) }
        let shortcuts = SystemShortcuts.enabled()
        if let direct = shortcuts[SystemShortcuts.desktopIDs.lowerBound + n - 1], n <= 9 { return [direct] }
        let all = displays()
        var base = 0
        for d in all {
            if d.uuid == uuid || all.count == 1 {
                let desktop = { (k: Int) -> UInt64? in d.desktops.indices.contains(k - base - 1) ? d.desktops[k - base - 1] : nil }
                guard let target = desktop(n), let start = from.map(desktop) ?? d.current,
                      let i = d.spaces.firstIndex(of: start), let j = d.spaces.firstIndex(of: target),
                      let step = shortcuts[j > i ? SystemShortcuts.moveRight : SystemShortcuts.moveLeft] else { break }
                return Array(repeating: step, count: abs(j - i))
            }
            base += d.desktops.count
        }
        throw Failure.shortcutOff(n)
    }

    /// Adds a desktop to a display the way a person does: opens Mission Control and clicks its "+"
    /// at the top right of the display. The private call for it needs SIP off, and Mission Control
    /// shows nothing of itself through accessibility (macOS 27), so the click goes by position. It
    /// waits on the Dock, so it runs off the main thread; `done` gets the error back on it.
    static func addDesktop(on display: CGRect, done: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try addDesktopNow(on: display) } catch { failure = error }
            DispatchQueue.main.async { done(failure) }
        }
    }

    private static func addDesktopNow(on display: CGRect) throws {
        guard dockNotify != nil,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { throw Failure.cannotAdd }
        let dock = AXUIElementCreateApplication(pid)
        let start = desktopCount
        let back = CGEvent(source: nil)?.location
        toggleMissionControl()
        defer {
            if missionControl(dock) != nil { toggleMissionControl() }
            if let back { click(at: back, press: false) }
            // The next switch has to wait for Mission Control to be gone, or the Dock drops it.
            _ = waitFor(2) { missionControl(dock) == nil ? true : nil }
            Thread.sleep(forTimeInterval: 0.3)
        }
        guard waitFor(2, { missionControl(dock) }) != nil else { throw Failure.cannotAdd }
        Thread.sleep(forTimeInterval: 0.5)   // its opening animation
        // Collapsed, "+" sits at the top right; under the pointer the bar grows (with an
        // animation) and it moves down to the middle of the thumbnails.
        click(at: CGPoint(x: display.maxX - 26, y: display.minY + 20), press: false)
        Thread.sleep(forTimeInterval: 0.6)
        click(at: CGPoint(x: display.maxX - 28, y: display.minY + display.height * 0.087), press: true)
        guard waitFor(1.5, { desktopCount > start ? true : nil }) != nil else { throw Failure.cannotAdd }
    }

    /// The pointer to `p` and, with `press`, a click there.
    private static func click(at p: CGPoint, press: Bool) {
        let types: [CGEventType] = press ? [.mouseMoved, .leftMouseDown, .leftMouseUp] : [.mouseMoved]
        for t in types {
            CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    /// What Mission Control.app does (opening the app again while it is still running does nothing).
    private static func toggleMissionControl() {
        if let send = dockNotify { _ = send("com.apple.expose.awake" as CFString, 0) }
    }

    private static func waitFor<T>(_ seconds: TimeInterval, _ probe: () -> T?) -> T? {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let found = probe() { return found }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < end
        return nil
    }

    /// Mission Control is open while the Dock shows its (otherwise empty) "mc" group.
    private static func missionControl(_ dock: AXUIElement) -> AXUIElement? {
        (AX.copy(dock, kAXChildrenAttribute) as? [AXUIElement])?.first { AX.copy($0, kAXIdentifierAttribute) as? String == "mc" }
    }
}
#endif
