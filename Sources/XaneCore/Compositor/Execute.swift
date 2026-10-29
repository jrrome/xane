import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Compositor {
    /// Applies a command to `pending` and returns the side effects the platform must perform
    /// (after committing). Throws for commands that cannot apply.
    public func execute(_ cmd: Command) throws -> [Effect] {
        switch cmd {
        // MARK: focus & order
        case .focus(let t):
            guard let target = try resolve(t, tiledOnly: false) else { return [] }
            return focus(target)

        case .swap(let t):
            guard let me = pending.subject, let w = pending.windows[me], !w.floating else {
                throw CommandError.nothingToActOn
            }
            guard let other = try resolve(t, tiledOnly: true), other != me else { return [] }
            swapWindows(me, other)
            if pending.windows[me]?.output != w.output { pending.focusedOutput = pending.windows[me]?.output }
            return [.focus(me)]

        case .zoom:
            guard let me = pending.subject, let w = pending.windows[me], !w.floating else {
                throw CommandError.nothingToActOn
            }
            let tiled = pending.tiled(on: w.output)
            guard tiled.count > 1, let first = tiled.first else { return [] }
            if first == me { swapWindows(me, tiled[1]); return [.focus(tiled[1])] }
            pending.order.removeAll { $0 == me }
            let at = pending.order.firstIndex(of: first) ?? 0
            pending.order.insert(me, at: at)
            return [.focus(me)]

        case .float(let t):
            guard let me = pending.subject, var w = pending.windows[me] else { throw CommandError.nothingToActOn }
            let on: Bool
            switch t { case .toggle: on = !w.floating; case .on: on = true; case .off: on = false }
            guard on != w.floating else { return [] }
            w.floating = on
            w.fullscreen = false
            if on, let o = pending.outputs[w.output] {
                let a = pending.usableArea(of: o)
                let size = CGSize(width: min(w.frame.width, a.width * 0.7), height: min(w.frame.height, a.height * 0.7))
                w.floatingFrame = CGRect(x: a.midX - size.width / 2, y: a.midY - size.height / 2,
                                         width: size.width, height: size.height).snappedInward
                requestFloatingPlacement(me)
            } else {
                w.floatingFrame = nil
            }
            pending.windows[me] = w
            return [.focus(me)]

        case .fullscreen(let t):
            guard let me = pending.subject, var w = pending.windows[me] else { throw CommandError.nothingToActOn }
            let on: Bool
            switch t { case .toggle: on = !w.fullscreen; case .on: on = true; case .off: on = false }
            guard on != w.fullscreen else { return [] }
            w.fullscreen = on
            if !on && w.floating { requestFloatingPlacement(me) }
            pending.windows[me] = w
            return [.focus(me)]

        case .close:
            guard let me = pending.subject else { throw CommandError.nothingToActOn }
            return [.close(me)]

        // MARK: layout
        case .layout(let choice):
            guard let oid = pending.subjectOutput, var o = pending.outputs[oid] else { return [] }
            let all = LayoutKind.allCases
            switch choice {
            case .kind(let k): o.layout = k
            case .next: o.layout = all[(all.firstIndex(of: o.layout)! + 1) % all.count]
            case .previous: o.layout = all[(all.firstIndex(of: o.layout)! + all.count - 1) % all.count]
            }
            pending.outputs[oid] = o
            return []

        case .mainRatio(let adj):
            guard let oid = pending.subjectOutput, var o = pending.outputs[oid] else { return [] }
            o.params.mainRatio = min(max(adj.apply(to: o.params.mainRatio), ratioRange.lowerBound), ratioRange.upperBound)
            pending.outputs[oid] = o
            // The main split is slot 0 in tile and dwindle: drop stored overrides so the new
            // ratio shows everywhere.
            for k in Array(pending.ratios.keys) where k.hasPrefix("\(o.uuid)|tile|") || k.hasPrefix("\(o.uuid)|dwindle|") {
                if var r = pending.ratios[k], !r.isEmpty { r[0] = 0; pending.ratios[k] = r }
            }
            return []

        case .mainCount(let adj):
            guard let oid = pending.subjectOutput, var o = pending.outputs[oid] else { return [] }
            o.params.mainCount = Int(min(max(adj.apply(to: Double(o.params.mainCount)).rounded(), 0), 16))
            pending.outputs[oid] = o
            return []

        case .orientation(let or):
            guard let oid = pending.subjectOutput, var o = pending.outputs[oid] else { return [] }
            if let or { o.params.orientation = or } else {
                let cycle: [Orientation] = [.left, .top, .right, .bottom]
                o.params.orientation = cycle[((cycle.firstIndex(of: o.params.orientation) ?? 0) + 1) % 4]
            }
            pending.outputs[oid] = o
            return []

        case .resize(let delta, let axis):
            guard let me = pending.subject, let w = pending.windows[me], !w.floating,
                  let lay = layouts[w.output], let idx = lay.tiled.firstIndex(of: me) else {
                throw CommandError.nothingToActOn
            }
            if let r = ratiosAfterGrow(pending.ratios[lay.ratioKey] ?? [], splits: lay.splits, index: idx,
                                       delta: delta, axis: axis) {
                pending.ratios[lay.ratioKey] = r
            }
            return []

        case .resetLayout:
            guard let oid = pending.subjectOutput, var o = pending.outputs[oid] else { return [] }
            for k in Array(pending.ratios.keys) where k.hasPrefix("\(o.uuid)|") { pending.ratios[k] = nil }
            o.params = LayoutParams(mainRatio: pending.options.mainRatio)
            pending.outputs[oid] = o
            return []

        // MARK: desktops (macOS Spaces: the platform layer switches them)
        case .desktop(let t):
            return [.showDesktop(t)]

        case .moveToDesktop(let t):
            guard let me = pending.subject else { throw CommandError.nothingToActOn }
            return [.moveToDesktop(me, t)]

        // MARK: outputs
        case .focusOutput(let t):
            guard let from = pending.subjectOutput, let to = resolveOutput(t, from: from), to != from else { return [] }
            pending.focusedOutput = to
            if let c = pending.focusCandidate(on: to) { return focus(c) }
            guard let o = pending.outputs[to] else { return [] }
            pending.focused = nil
            return [.warp(pending.usableArea(of: o).center)]

        case .sendToOutput(let t):
            guard let me = pending.subject, let w = pending.windows[me],
                  let to = resolveOutput(t, from: w.output), to != w.output,
                  let src = pending.outputs[w.output], let dst = pending.outputs[to] else { return [] }
            var nw = w
            nw.output = to
            if w.floating {
                // Keep the same relative position on the new display.
                let f = w.floatingFrame ?? w.frame
                let a = src.visibleFrame, b = dst.visibleFrame
                let rx = a.width > f.width ? (f.minX - a.minX) / (a.width - f.width) : 0.5
                let ry = a.height > f.height ? (f.minY - a.minY) / (a.height - f.height) : 0.5
                let size = CGSize(width: min(f.width, b.width), height: min(f.height, b.height))
                nw.floatingFrame = CGRect(x: b.minX + max(0, min(1, rx)) * (b.width - size.width),
                                          y: b.minY + max(0, min(1, ry)) * (b.height - size.height),
                                          width: size.width, height: size.height).snappedInward
                requestFloatingPlacement(me)
            }
            pending.windows[me] = nw
            pending.order.removeAll { $0 == me }
            pending.order.append(me)
            pending.focusedOutput = to
            return [.focus(me)]

        // MARK: lifecycle
        case .retile: return [.retile]
        case .reload: return [.reload]
        case .pause: pending.paused = true; return []
        case .resume: pending.paused = false; return [.retile]
        case .togglePause: pending.paused.toggle(); return pending.paused ? [] : [.retile]
        case .quit: return [.quit]
        case .settings: return [.openSettings]

        case .set(let name, let values):
            do { try pending.options.set(name, values) } catch { throw CommandError.invalidArgument("\(error)") }
            if name == "main-ratio" || name == "default-layout" {
                // Applies to displays that have not been customised yet (saved settings win, also
                // at start-up when the config runs before the first commit).
                // Read everything first: a write to `pending` must not read `pending` in the same
                // statement (Swift exclusivity).
                let layout = pending.options.defaultLayout, ratio = pending.options.mainRatio
                let outputs = pending.outputs
                for (oid, o) in outputs where outputSettings[o.uuid] == nil {
                    var updated = o
                    updated.layout = layout
                    updated.params.mainRatio = ratio
                    pending.outputs[oid] = updated
                }
            }
            return []

        case .rule(let r): pending.rules.append(r); return []
        case .ruleClear: pending.rules.removeAll(); return []
        case .bind(let combo, let command): pending.bindings[combo] = command; return []
        case .unbind(let combo):
            if let combo { pending.bindings[combo] = nil } else { pending.bindings.removeAll() }
            return []

        case .query(let what): return [.reply(query(what))]
        case .subscribe: return [.subscribe]
        case .exec(let c): return [.exec(c)]
        }
    }

    private func requestFloatingPlacement(_ id: WindowID) {
        placeFloating.insert(id)
    }

    /// Focus a window (and remember it optimistically so the next command in the same batch acts
    /// on it, before the system confirms).
    func focus(_ id: WindowID) -> [Effect] {
        guard let w = pending.windows[id] else { return [] }
        pending.focused = id
        pending.focusedOutput = w.output
        pending.focusHistory.removeAll { $0 == id }
        pending.focusHistory.insert(id, at: 0)
        return [.focus(id)]
    }

    func resolve(_ t: Target, tiledOnly: Bool) throws -> WindowID? {
        guard let me = pending.subject ?? pending.focusedOutput.flatMap({ pending.focusCandidate(on: $0) }) else {
            throw CommandError.nothingToActOn
        }
        guard let w = pending.windows[me] else { throw CommandError.nothingToActOn }
        let list = tiledOnly ? pending.tiled(on: w.output) : pending.visible(on: w.output)
        switch t {
        case .direction(let d):
            // Directional moves cross displays: candidates are all visible windows.
            var all: [WindowID] = []
            for oid in pending.outputOrder {
                all += tiledOnly ? pending.tiled(on: oid) : pending.visible(on: oid)
            }
            if pending.subject == nil { return me }
            return neighbor(of: me, d, among: all)
        case .next, .previous:
            guard !list.isEmpty else { return nil }
            guard let i = list.firstIndex(of: me) else { return list.first }
            let step = t == .next ? 1 : list.count - 1
            return list[(i + step) % list.count]
        case .main:
            return pending.tiled(on: w.output).first
        case .recent:
            return pending.focusHistory.dropFirst().first(where: { pending.isVisible($0) })
        }
    }

    func resolveOutput(_ t: OutputTarget, from: OutputID) -> OutputID? {
        let order = pending.outputOrder
        guard let i = order.firstIndex(of: from), let src = pending.outputs[from] else { return order.first }
        switch t {
        case .next: return order[(i + 1) % order.count]
        case .previous: return order[(i + order.count - 1) % order.count]
        case .index(let n): return n - 1 < order.count ? order[n - 1] : nil
        case .direction(let d):
            let c = src.frame.center
            let candidates = pending.outputs.values.filter { o in
                switch d {
                case .left: return o.frame.midX < c.x && o.id != from
                case .right: return o.frame.midX > c.x && o.id != from
                case .up: return o.frame.midY < c.y && o.id != from
                case .down: return o.frame.midY > c.y && o.id != from
                }
            }
            return candidates.min { hypot($0.frame.midX - c.x, $0.frame.midY - c.y) < hypot($1.frame.midX - c.x, $1.frame.midY - c.y) }?.id
        }
    }
}
