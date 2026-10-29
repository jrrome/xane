import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Minimum sizes learned from apps that refuse to shrink (the closest thing macOS has to
/// xdg_toplevel.set_min_size). Keyed by app + window kind. 0 on an axis means "no minimum".
public struct MinimumSizeStore: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var width: Double
        public var height: Double
        /// Entries carried over from an older format are suspects: not used as constraints, but
        /// the first time the app pushes back they are confirmed without the usual double check.
        public var confirmed: Bool
    }

    public static let currentVersion = 1
    public var version = MinimumSizeStore.currentVersion
    public var entries: [String: Entry] = [:]

    public init() {}

    /// Migrates instead of wiping: old values become suspects.
    public mutating func migrateIfNeeded() {
        guard version != Self.currentVersion else { return }
        for k in entries.keys { entries[k]?.confirmed = false }
        version = Self.currentVersion
    }

    public func minimum(for key: String) -> CGSize {
        guard let e = entries[key], e.confirmed else { return .zero }
        return CGSize(width: e.width, height: e.height)
    }

    public func isSuspect(_ key: String) -> Bool { entries[key].map { !$0.confirmed } ?? false }

    /// Records that a window of this kind came out at least `size` on the axes flagged.
    public mutating func record(_ key: String, width: Double?, height: Double?) {
        var e = entries[key] ?? Entry(width: 0, height: 0, confirmed: true)
        if !e.confirmed { e = Entry(width: 0, height: 0, confirmed: true) }
        if let w = width { e.width = max(e.width, w.rounded()) }
        if let h = height { e.height = max(e.height, h.rounded()) }
        entries[key] = e
    }

    /// The app accepted a size smaller than the recorded minimum: lower it.
    @discardableResult
    public mutating func lower(_ key: String, accepted: CGSize, tolerance: Double = 2) -> Bool {
        guard var e = entries[key], e.confirmed else { return false }
        var changed = false
        if e.width > 0, Double(accepted.width) < e.width - tolerance { e.width = Double(accepted.width).rounded(); changed = true }
        if e.height > 0, Double(accepted.height) < e.height - tolerance { e.height = Double(accepted.height).rounded(); changed = true }
        if changed {
            if e.width <= 0 && e.height <= 0 { entries[key] = nil } else { entries[key] = e }
        }
        return changed
    }
}
