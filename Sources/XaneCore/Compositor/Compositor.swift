import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the compositor wants a window to be.
public enum Placement: Equatable, Sendable {
    /// A frame chosen by the compositor (tile, compositor fullscreen, overflow, restored float).
    case frame(CGRect)
    /// Visible floating window: the client owns its geometry.
    case untouched
}

/// One geometry request to a client, like xdg_surface.configure. The client "acks" by reporting
/// the frame it actually took, tagged with the same serial.
public struct Configure: Equatable, Sendable {
    public var window: WindowID
    public var pid: Int32
    public var serial: UInt64
    public var frame: CGRect
}

public struct OutputLayout: Equatable, Sendable {
    public var output: OutputID
    public var kind: LayoutKind
    public var tiles: Int
    public var ratioKey: String
    public var tiled: [WindowID]
    public var splits: [ResolvedSplit]
    public var area: CGRect
}

/// The result of a commit: everything that has to change on screen, computed atomically.
public struct Transaction: Sendable {
    public var configures: [Configure] = []
    /// Windows that must be raised after configuring (compositor fullscreen).
    public var raise: [WindowID] = []
    public var tiled = 0
    public var floating = 0
    public var isEmpty: Bool { configures.isEmpty && raise.isEmpty }
}

/// Side effects a command asks the platform layer to perform.
public enum Effect: Equatable, Sendable {
    case focus(WindowID)
    case close(WindowID)
    case warp(CGPoint)
    case exec(String)
    case reload
    case quit
    case reply(String)
    case subscribe
    case retile
    case openSettings
    /// Show a macOS desktop (Space).
    case showDesktop(DesktopTarget)
    /// Carry a window to a macOS desktop.
    case moveToDesktop(WindowID, DesktopTarget)
}

public enum AckOutcome: Equatable, Sendable {
    /// Not the latest configure for that window; only the frame fact was recorded.
    case stale
    case settled
    /// The client came out bigger than asked: probably its minimum size.
    case tooBig(asked: CGRect)
}

public enum Observation: Equatable, Sendable {
    /// Caused by us (or matches what we want).
    case echo
    /// Someone else moved/resized the window: the user (if a mouse grab is active) or the app.
    case external
}

public enum LearnOutcome: Equatable, Sendable { case saved, sessionOnly, unchanged }

public final class Compositor {
    public private(set) var current = State()
    /// Requests accumulate here until `commit()`.
    public var pending = State()
    public private(set) var placements: [WindowID: Placement] = [:]
    public private(set) var layouts: [OutputID: OutputLayout] = [:]
    public var minimumSizes = MinimumSizeStore()
    public private(set) var outputSettings: [String: OutputSettings] = [:]
    /// Float state and display of windows from a previous run, so a restart of the compositor does
    /// not shuffle everything. Keyed by window id, validated by pid.
    public var restoredWindows: [WindowID: PersistedWindow] = [:]

    struct Inflight { var serial: UInt64; var frame: CGRect; var sentAt: TimeInterval }
    private var inflight: [WindowID: Inflight] = [:]
    /// Floating windows that need their floating frame applied on the next commit.
    var placeFloating: Set<WindowID> = []
    private var serial: UInt64 = 0
    public let inflightTTL: TimeInterval = 1.5

    public init() {}

    // MARK: - Facts (reported by the system; applied to both buffers, they are not requests)

    private func fact(_ id: WindowID, _ f: (inout Window) -> Void) {
        if var w = pending.windows[id] { f(&w); pending.windows[id] = w }
        if var w = current.windows[id] { f(&w); current.windows[id] = w }
    }

    public func minimum(for w: Window) -> CGSize {
        let learned = minimumSizes.minimum(for: w.minimumSizeKey)
        return CGSize(width: max(learned.width, w.sessionMinimum.width),
                      height: max(learned.height, w.sessionMinimum.height))
    }

    // MARK: - Outputs

    public func setOutputs(_ list: [Output]) {
        var next: [OutputID: Output] = [:]
        for var o in list {
            if let old = pending.outputs[o.id], old.uuid == o.uuid {
                o.layout = old.layout; o.params = old.params
            } else if let s = outputSettings[o.uuid] {
                o.layout = s.layout; o.params = s.params
            } else {
                o.layout = pending.options.defaultLayout
                o.params = LayoutParams(mainRatio: pending.options.mainRatio)
            }
            next[o.id] = o
        }
        pending.outputs = next
        normalize()
    }

    // MARK: - Windows

    /// Adds a window reported by the AX layer. Returns false if it was already known.
    @discardableResult
    public func addWindow(_ s: WindowSnapshot, classification c: Classification, pointer: CGPoint?) -> Bool {
        guard pending.windows[s.id] == nil, c.management != .ignore, !pending.outputs.isEmpty else { return false }
        let restored = restoredWindows.removeValue(forKey: s.id).flatMap { $0.pid == s.pid ? $0 : nil }
        let floating = restored?.floating ?? (c.management == .float)

        let onScreen = pending.outputs.values.contains { $0.visibleFrame.intersects(s.frame.insetBy(dx: 2, dy: 2)) }
        var oid: OutputID?
        if let r = restored, let o = pending.outputs.values.first(where: { $0.uuid == r.outputUUID }) { oid = o.id }
        if oid == nil, let i = c.outputIndex {
            let order = pending.outputOrder
            if i - 1 < order.count { oid = order[i - 1] }
        }
        if oid == nil {
            if !floating && onScreen {
                switch pending.options.newWindowOutput {
                case .pointer: oid = pointer.flatMap { pending.output(at: $0) }
                case .focused: oid = pending.focusedOutput
                case .app: break
                }
            }
            if oid == nil { oid = onScreen ? pending.output(for: s.frame) : (pending.focusedOutput ?? pending.outputOrder.first) }
        }
        guard let output = oid ?? pending.outputOrder.first, let o = pending.outputs[output] else { return false }

        var w = Window(id: s.id, pid: s.pid, bundleID: s.bundleID, appName: s.appName, title: s.title,
                       subrole: s.subrole, minimumSizeKey: s.minimumSizeKey, output: output,
                       floating: floating, frame: s.frame)
        w.minimized = s.isMinimized
        w.nativeFullscreen = s.isNativeFullscreen
        w.canResize = s.isSizeSettable
        w.cornerRadius = s.cornerRadius
        pending.windows[s.id] = w

        // Attach position in the tiling order.
        switch pending.options.attach {
        case .bottom:
            pending.order.append(s.id)
        case .top:
            if let first = pending.order.firstIndex(where: { pending.windows[$0]?.output == output }) {
                pending.order.insert(s.id, at: first)
            } else { pending.order.insert(s.id, at: 0) }
        case .afterFocused:
            if let f = pending.focused, pending.windows[f]?.output == output, let i = pending.order.firstIndex(of: f) {
                pending.order.insert(s.id, at: i + 1)
            } else { pending.order.append(s.id) }
        }
        // A floating window off every screen (e.g. hidden by an older version that crashed) is
        // brought back to the middle of its display. Tiled ones get their tile anyway.
        if !onScreen && floating {
            pending.windows[s.id]?.floatingFrame = centered(size: s.frame.size, on: o)
            placeFloating.insert(s.id)
        }
        return true
    }

    public func removeWindow(_ id: WindowID) {
        pending.windows[id] = nil
        current.windows[id] = nil
        pending.order.removeAll { $0 == id }
        pending.focusHistory.removeAll { $0 == id }
        if pending.focused == id { pending.focused = nil }
        inflight[id] = nil
        placeFloating.remove(id)
        placements[id] = nil
    }

    public var windowIDs: Set<WindowID> { Set(pending.windows.keys) }

    public func setMinimized(_ id: WindowID, _ v: Bool) { fact(id) { $0.minimized = v } }
    public func setNativeFullscreen(_ id: WindowID, _ v: Bool) { fact(id) { $0.nativeFullscreen = v } }
    public func setTitle(_ id: WindowID, _ t: String) { fact(id) { $0.title = t } }
    public func setCornerRadius(_ id: WindowID, _ r: CGFloat?) { fact(id) { $0.cornerRadius = r } }

    public func setAppHidden(pid: Int32, _ v: Bool) {
        let ids = pending.windows.values.filter { $0.pid == pid }.map(\.id)
        for id in ids { fact(id) { $0.appHidden = v } }
    }

    /// Updates which windows are on the current macOS Space (from the window server's list).
    /// Windows the server does not know yet (just created) are considered present.
    public func setSpacePresence(onScreen: Set<WindowID>, known: Set<WindowID>) {
        let changes = pending.windows.values.compactMap { w -> (WindowID, Bool)? in
            let present = onScreen.contains(w.id) || !known.contains(w.id)
            return w.onCurrentSpace != present ? (w.id, present) : nil
        }
        for (id, present) in changes { fact(id) { $0.onCurrentSpace = present } }
    }

    /// The system reports a focus change.
    public func systemFocused(_ id: WindowID?) {
        guard let id, let w = pending.windows[id] else {
            pending.focused = nil
            return
        }
        pending.focused = id
        pending.focusHistory.removeAll { $0 == id }
        pending.focusHistory.insert(id, at: 0)
        if pending.focusHistory.count > 64 { pending.focusHistory.removeLast() }
        pending.focusedOutput = w.output
        current.focused = id
        current.focusedOutput = w.output
    }

    // MARK: - Commit

    private func normalize() {
        let ids = Set(pending.windows.keys)
        pending.order = pending.order.filter(ids.contains)
        if pending.order.count != ids.count {
            let inOrder = Set(pending.order)
            let missing = pending.windows.keys.filter { !inOrder.contains($0) }.sorted()
            pending.order += missing
        }
        if !pending.outputs.isEmpty {
            let orphans = pending.windows.values.filter { pending.outputs[$0.output] == nil }
            for w in orphans {
                let oid = pending.output(for: w.frame) ?? pending.outputOrder[0]
                pending.windows[w.id]?.output = oid
                if w.floating { placeFloating.insert(w.id) }
            }
            if pending.focusedOutput.map({ pending.outputs[$0] == nil }) ?? true {
                pending.focusedOutput = pending.outputOrder.first
            }
        }
        if let f = pending.focused, pending.windows[f] == nil { pending.focused = nil }
        pending.focusHistory = pending.focusHistory.filter(ids.contains)
    }

    /// Computes the new layout from `pending`, diffs it against what is on screen and returns the
    /// configures needed. `pending` becomes `current`.
    public func commit(now: TimeInterval, forceAll: Bool = false, force: Set<WindowID> = []) -> Transaction {
        normalize()
        let s = pending
        var tx = Transaction()
        var next: [WindowID: Placement] = [:]
        var nextLayouts: [OutputID: OutputLayout] = [:]

        if !s.paused {
            for oid in s.outputOrder {
                guard let o = s.outputs[oid] else { continue }
                let area = s.usableArea(of: o)
                let tiled = s.tiled(on: oid)
                let mins = tiled.map { minimum(for: s.windows[$0]!) }
                let req = LayoutRequest(kind: o.layout, area: area, minimums: mins, params: o.params,
                                        innerGap: s.options.innerGap, outerGap: s.options.outerGap,
                                        maxTiled: s.options.maxTiled, overflow: s.options.overflow,
                                        stackTarget: s.focused.flatMap { tiled.firstIndex(of: $0) })
                let res = LayoutEngine.layout(req) { n in s.ratios[s.ratioKey(o, o.layout, n)] ?? [] }
                var overflow: [Int] = []
                for (i, id) in tiled.enumerated() {
                    if let f = res.frames[i] { next[id] = .frame(f); tx.tiled += 1 }
                    else { overflow.append(i) }
                }
                if !overflow.isEmpty {
                    let sizes = overflow.map { i -> CGSize in
                        let f = s.windows[tiled[i]]!.frame.size
                        return CGSize(width: max(f.width, mins[i].width), height: max(f.height, mins[i].height))
                    }
                    let frames = LayoutEngine.overflowFrames(count: overflow.count, sizes: sizes, in: area)
                    for (k, i) in overflow.enumerated() { next[tiled[i]] = .frame(frames[k]); tx.floating += 1 }
                }
                nextLayouts[oid] = OutputLayout(output: oid, kind: o.layout, tiles: res.tileCount,
                                                ratioKey: s.ratioKey(o, o.layout, res.tileCount),
                                                tiled: tiled, splits: res.splits, area: res.area)

                for id in s.visible(on: oid) {
                    guard let w = s.windows[id] else { continue }
                    if w.fullscreen {
                        next[id] = .frame(area.snappedInward)
                        tx.raise.append(id)
                    } else if w.floating {
                        tx.floating += 1
                        if placeFloating.contains(id) {
                            next[id] = .frame(w.floatingFrame ?? centered(size: w.frame.size, on: o))
                        } else {
                            next[id] = .untouched
                        }
                    }
                }
            }
        }

        // Diff against reality (last reported frames) and requests in flight.
        for id in s.order {
            guard let p = next[id], let w = s.windows[id] else { continue }
            let forced = forceAll || force.contains(id)
            switch p {
            case .untouched:
                continue
            case .frame(let f):
                if !forced, let inf = inflight[id], now - inf.sentAt < inflightTTL,
                   inf.frame.isClose(to: f, tolerance: 0.5) { continue }
                if !forced, w.frame.isClose(to: f, tolerance: 0.5) { inflight[id] = nil; continue }
                tx.configures.append(makeConfigure(w, frame: f, now: now))
                placeFloating.remove(id)
            }
        }

        // Raise compositor-fullscreen windows only when they were just (re)placed.
        let configured = Set(tx.configures.map(\.window))
        tx.raise = tx.raise.filter(configured.contains)

        placements = next
        layouts = nextLayouts
        current = pending
        rememberOutputSettings()
        return tx
    }

    private func makeConfigure(_ w: Window, frame: CGRect, now: TimeInterval) -> Configure {
        serial &+= 1
        inflight[w.id] = Inflight(serial: serial, frame: frame, sentAt: now)
        return Configure(window: w.id, pid: w.pid, serial: serial, frame: frame)
    }

    func centered(size: CGSize, on o: Output) -> CGRect {
        let a = o.visibleFrame
        let w = min(max(size.width, 300), a.width * 0.8), h = min(max(size.height, 200), a.height * 0.8)
        return CGRect(x: a.midX - w / 2, y: a.midY - h / 2, width: w, height: h).snappedInward
    }

    private func rememberOutputSettings() {
        for o in current.outputs.values {
            outputSettings[o.uuid] = OutputSettings(layout: o.layout, params: o.params)
        }
    }

    // MARK: - Acks and observations

    public func ack(_ id: WindowID, serial: UInt64, frame: CGRect) -> AckOutcome {
        fact(id) { $0.frame = frame }
        guard let inf = inflight[id], inf.serial == serial else { return .stale }
        inflight[id] = nil
        let asked = inf.frame
        if frame.width > asked.width + 2 || frame.height > asked.height + 2 { return .tooBig(asked: asked) }
        if let w = pending.windows[id] { minimumSizes.lower(w.minimumSizeKey, accepted: frame.size) }
        return .settled
    }

    /// Records a minimum size after the client refused (twice) to be as small as asked.
    public func learnMinimum(_ id: WindowID, asked: CGRect, got: CGRect) -> LearnOutcome {
        guard let w = pending.windows[id], let o = pending.outputs[w.output] else { return .unchanged }
        let area = pending.usableArea(of: o)
        let wantW: CGFloat? = got.width > asked.width + 2 ? got.width : nil
        let wantH: CGFloat? = got.height > asked.height + 2 ? got.height : nil
        guard wantW != nil || wantH != nil else { return .unchanged }
        if (wantW ?? 0) >= area.width * 0.95 || (wantH ?? 0) >= area.height * 0.95 {
            // Nearly the whole screen: probably transient (or the app is confused). This session only.
            fact(id) { $0.sessionMinimum = CGSize(width: max($0.sessionMinimum.width, wantW ?? 0),
                                                  height: max($0.sessionMinimum.height, wantH ?? 0)) }
            return .sessionOnly
        }
        minimumSizes.record(w.minimumSizeKey, width: wantW.map(Double.init), height: wantH.map(Double.init))
        return .saved
    }

    public func isSuspectMinimum(_ id: WindowID) -> Bool {
        pending.windows[id].map { minimumSizes.isSuspect($0.minimumSizeKey) } ?? false
    }

    /// A move/resize notification arrived from the client.
    public func observe(_ id: WindowID, frame: CGRect, now: TimeInterval) -> Observation {
        guard pending.windows[id] != nil else { return .echo }
        fact(id) { $0.frame = frame }
        if let inf = inflight[id], now - inf.sentAt < inflightTTL { return .echo }
        switch placements[id] {
        case .frame(let f): return frame.isClose(to: f, tolerance: 2) ? .echo : .external
        case .untouched, .none: return .echo
        }
    }

    public func placement(of id: WindowID) -> Placement? { placements[id] }

    /// End of an interactive move/resize (mouse released) of a window whose frame the user changed.
    /// Resizes become new split ratios; moves become swaps or output changes. Returns true if a
    /// commit is needed (it always snaps the window into place).
    public func interactiveEnd(_ id: WindowID, pointer: CGPoint) -> Bool {
        guard let w = pending.windows[id] else { return false }
        if w.floating {
            if let oid = pending.output(for: w.frame), oid != w.output {
                pending.windows[id]?.output = oid
            }
            pending.windows[id]?.floatingFrame = nil
            return false
        }
        guard case .frame(let old)? = placements[id] else { return true }
        let new = w.frame
        let resized = abs(new.width - old.width) > 2 || abs(new.height - old.height) > 2
        if resized, let lay = layouts[w.output], let idx = lay.tiled.firstIndex(of: id) {
            let r = ratiosAfterResize(pending.ratios[lay.ratioKey] ?? [], splits: lay.splits, index: idx,
                                      old: old, new: new, gap: pending.options.innerGap)
            pending.ratios[lay.ratioKey] = r
            return true
        }
        if let target = tiledWindow(at: pointer, excluding: id) {
            swapWindows(id, target)
        } else if let oid = pending.output(at: pointer), oid != w.output {
            pending.windows[id]?.output = oid
            pending.order.removeAll { $0 == id }
            pending.order.append(id)
            pending.focusedOutput = oid
        }
        return true
    }

    func tiledWindow(at p: CGPoint, excluding: WindowID) -> WindowID? {
        for lay in layouts.values {
            for id in lay.tiled where id != excluding {
                if case .frame(let f)? = placements[id], f.contains(p) { return id }
            }
        }
        return nil
    }

    /// Visible managed window at a point, preferring floating and fullscreen ones (they are above).
    public func window(at p: CGPoint) -> WindowID? {
        var best: WindowID?
        for id in current.order {
            guard let w = current.windows[id], current.isVisible(w) else { continue }
            let f: CGRect
            switch placements[id] {
            case .frame(let r)?: f = r
            case .untouched?: f = w.frame
            default: continue
            }
            guard f.contains(p) else { continue }
            if w.floating || w.fullscreen { return id }
            best = best ?? id
        }
        return best
    }

    // MARK: - Ordering helpers

    func swapWindows(_ a: WindowID, _ b: WindowID) {
        guard let ia = pending.order.firstIndex(of: a), let ib = pending.order.firstIndex(of: b),
              let wa = pending.windows[a], let wb = pending.windows[b] else { return }
        pending.order.swapAt(ia, ib)
        if wa.output != wb.output {
            pending.windows[a]?.output = wb.output
            pending.windows[b]?.output = wa.output
        }
    }

    /// Frame used for navigation: the compositor's target, or the real frame of a floating window.
    func navFrame(_ id: WindowID) -> CGRect? {
        switch placements[id] {
        case .frame(let f)?: return f
        case .untouched?: return current.windows[id]?.frame
        default: return nil
        }
    }

    /// Nearest window in a direction. Prefers windows that overlap on the perpendicular axis,
    /// then the closest edge, then the most recently focused (so going back and forth is stable).
    func neighbor(of id: WindowID, _ dir: Direction, among candidates: [WindowID]) -> WindowID? {
        guard let from = navFrame(id) else { return nil }
        let mru = Dictionary(pending.focusHistory.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let position = Dictionary(pending.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var best: (WindowID, (Int, Int, Int, Int, Int))?
        for c in candidates where c != id {
            guard let f = navFrame(c) else { continue }
            let edge: CGFloat, overlap: CGFloat, centerOffset: CGFloat
            switch dir {
            case .left:
                guard f.midX < from.midX, f.maxX <= from.minX + from.width / 2 else { continue }
                edge = from.minX - f.maxX
                overlap = min(f.maxY, from.maxY) - max(f.minY, from.minY)
                centerOffset = abs(f.midY - from.midY)
            case .right:
                guard f.midX > from.midX, f.minX >= from.maxX - from.width / 2 else { continue }
                edge = f.minX - from.maxX
                overlap = min(f.maxY, from.maxY) - max(f.minY, from.minY)
                centerOffset = abs(f.midY - from.midY)
            case .up:
                guard f.midY < from.midY, f.maxY <= from.minY + from.height / 2 else { continue }
                edge = from.minY - f.maxY
                overlap = min(f.maxX, from.maxX) - max(f.minX, from.minX)
                centerOffset = abs(f.midX - from.midX)
            case .down:
                guard f.midY > from.midY, f.minY >= from.maxY - from.height / 2 else { continue }
                edge = f.minY - from.maxY
                overlap = min(f.maxX, from.maxX) - max(f.minX, from.minX)
                centerOffset = abs(f.midX - from.midX)
            }
            let key = (overlap > 0 ? 0 : 1, Int(max(edge, 0) / 4), mru[c] ?? Int.max, Int(centerOffset / 16),
                       position[c] ?? Int.max)
            if best == nil || key < best!.1 { best = (c, key) }
        }
        return best?.0
    }

    // MARK: - Persistence

    public func persisted() -> PersistedState {
        var p = PersistedState()
        p.ratios = pending.ratios
        p.outputs = outputSettings
        p.minimumSizes = minimumSizes
        for (id, w) in pending.windows {
            p.windows[String(id)] = PersistedWindow(pid: w.pid, floating: w.floating,
                                                    outputUUID: pending.outputs[w.output]?.uuid ?? "")
        }
        return p
    }

    public func restore(_ p: PersistedState) {
        pending.ratios = p.ratios
        outputSettings = p.outputs
        minimumSizes = p.minimumSizes
        minimumSizes.migrateIfNeeded()
        restoredWindows = [:]
        for (k, v) in p.windows { if let id = WindowID(k) { restoredWindows[id] = v } }
    }
}

public struct PersistedWindow: Codable, Equatable, Sendable {
    public var pid: Int32
    public var floating: Bool
    public var outputUUID: String
}

public struct PersistedState: Codable, Equatable, Sendable {
    public var version = 1
    public var ratios: [String: [Double]] = [:]
    public var outputs: [String: OutputSettings] = [:]
    public var minimumSizes = MinimumSizeStore()
    public var windows: [String: PersistedWindow] = [:]
    public init() {}
}
