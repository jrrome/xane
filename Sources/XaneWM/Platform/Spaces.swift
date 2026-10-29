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
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection = skyLight.flatMap { dlsym($0, "SLSMainConnectionID") }
        .map { unsafeBitCast($0, to: ConnectionFn.self) }
    private static let copySpaces = skyLight.flatMap { dlsym($0, "SLSCopyManagedDisplaySpaces") }
        .map { unsafeBitCast($0, to: CopySpacesFn.self) }

    static var isAvailable: Bool { connection != nil && copySpaces != nil }

    static func displays() -> [Display] {
        guard let connection, let copySpaces,
              let list = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        func id(_ space: [String: Any]?) -> UInt64? { (space?["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        return list.map { d in
            let spaces = d["Spaces"] as? [[String: Any]] ?? []
            return Display(uuid: d["Display Identifier"] as? String ?? "",
                           desktops: spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }.compactMap(id),
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
    /// else "Move left/right a space" as many times as it takes.
    static func keys(toShow n: Int, on uuid: String) throws -> [KeyCombo] {
        guard isAvailable else { throw Failure.unavailable }
        guard n >= 1, n <= desktopCount else { throw Failure.noDesktop(n) }
        let shortcuts = SystemShortcuts.enabled()
        if let direct = shortcuts[SystemShortcuts.desktopIDs.lowerBound + n - 1], n <= 9 { return [direct] }
        guard let here = desktops(on: uuid), let cur = here.current, here.range.contains(n),
              let step = shortcuts[n > cur ? SystemShortcuts.moveRight : SystemShortcuts.moveLeft] else {
            throw Failure.shortcutOff(n)
        }
        return Array(repeating: step, count: abs(n - cur))
    }
}
#endif
