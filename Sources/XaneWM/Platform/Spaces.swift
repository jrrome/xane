#if os(macOS)
import AppKit
import XaneCore

/// macOS Spaces, for `set desktops spaces`. Reading them needs SkyLight (private, read-only, the
/// same calls yabai and Hammerspoon use); switching goes through the user's own "Switch to
/// Desktop N" shortcuts, so the Dock stays in charge of Spaces (and of their animation).
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
                return "turn on “Switch to Desktop \(n)” in System Settings → Keyboard → Keyboard Shortcuts → Mission Control"
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

    /// Desktop number shown on a display. Numbers run on across displays, like Mission Control's
    /// shortcuts. Nil on a fullscreen app's Space.
    static func current(on uuid: String) -> Int? {
        let all = displays()
        var base = 0
        for d in all {
            // A single entry ("Main") when displays share their Spaces.
            if d.uuid == uuid || all.count == 1 {
                return d.desktops.firstIndex(of: d.current).map { base + $0 + 1 }
            }
            base += d.desktops.count
        }
        return nil
    }

    /// The shortcut that shows desktop `n`, or why it can't be shown.
    static func shortcut(for n: Int) throws -> KeyCombo {
        guard isAvailable else { throw Failure.unavailable }
        guard n >= 1, n <= desktopCount else { throw Failure.noDesktop(n) }
        guard let combo = SystemShortcuts.desktop(n) else { throw Failure.shortcutOff(n) }
        return combo
    }
}
#endif
