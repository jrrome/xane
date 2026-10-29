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
        case unavailable, noDesktop(Int), shortcutOff(Int)
        var description: String {
            switch self {
            case .unavailable: return "this macOS does not expose its Spaces"
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
}
#endif
