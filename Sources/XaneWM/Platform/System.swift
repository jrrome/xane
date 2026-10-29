#if os(macOS)
import AppKit
import ApplicationServices
import XaneCore

/// Window-server view of the world (CGWindowList): which windows exist and which are on the
/// current Space. Public API, no AX round-trips, a couple of milliseconds.
enum WindowServer {
    struct Snapshot {
        var onScreen = Set<WindowID>()
        var all = Set<WindowID>()
    }

    static func snapshot() -> Snapshot {
        var s = Snapshot()
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return s }
        for info in list {
            guard let n = info[kCGWindowNumber as String] as? NSNumber,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            s.all.insert(n.uint32Value)
            if (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true { s.onScreen.insert(n.uint32Value) }
        }
        return s
    }

    /// Topmost normal window under a point, or nil when something above normal level (a menu,
    /// the Dock, a popover, Notification Center…) covers it.
    static func topWindow(at p: CGPoint, excluding pid: pid_t) -> WindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bounds as CFDictionary), r.contains(p) else { continue }
            let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if owner == pid { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha <= 0.01 { continue }
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }
}

/// Displays in window-server coordinates (origin top-left of the primary display, y down).
enum Displays {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func outputs() -> [Output] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let h = primary.frame.maxY
        return screens.compactMap { s in
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(num.uint32Value)
            var uuid = "display-\(id)"
            if let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), let str = CFUUIDCreateString(nil, u) {
                uuid = str as String
            }
            return Output(id: id, uuid: uuid, name: s.localizedName, frame: flip(s.frame, h), visibleFrame: flip(s.visibleFrame, h))
        }
    }

    /// Cocoa (bottom-left origin) ⇄ window server (top-left origin). The transform is its own inverse.
    static func flip(_ r: CGRect, _ h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func toCocoa(_ r: CGRect) -> NSRect { flip(r, primaryHeight) }

    static func pointer() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

/// Accessibility permission. Waits for it with the distributed notification macOS posts when the
/// list changes, polling only as a fallback while access is missing.
final class Permissions {
    private var timer: Timer?
    private var token: NSObjectProtocol?
    private var onGranted: (() -> Void)?

    var isTrusted: Bool { AXIsProcessTrusted() }

    func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func waitForTrust(_ granted: @escaping () -> Void) {
        onGranted = granted
        token = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            // The flag flips a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.check() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        guard isTrusted, let cb = onGranted else { return }
        onGranted = nil
        timer?.invalidate(); timer = nil
        if let t = token { DistributedNotificationCenter.default().removeObserver(t) }
        token = nil
        cb()
    }
}

/// Persistent state (ratios, per-display settings, learned minimum sizes, window tags).
/// The config file is the user's; this file is ours.
final class Store {
    let url: URL
    private var pending: DispatchWorkItem?
    private var last: Data?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("xanewm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("state.json")
    }

    func load() -> PersistedState? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: d)
    }

    func scheduleSave(_ make: @escaping () -> PersistedState) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(make()) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func save(_ p: PersistedState) {
        pending?.cancel()
        pending = nil
        guard let d = try? encoder.encode(p), d != last else { return }
        do { try d.write(to: url, options: .atomic); last = d } catch {
            Log.main.error("Could not save state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
