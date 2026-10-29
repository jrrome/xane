import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// IPC wire format. One request per line (a command line, `;`-separated commands allowed); one
/// JSON response per line: {"ok":true,"data":…} or {"ok":false,"error":"…"}. `subscribe` keeps the
/// connection open and streams one JSON event per line.
public enum Wire {
    public static let defaultSocketName = "xanewm"

    /// Socket path: $XANEWM_SOCKET, else /tmp/xanewm-<uid>.sock (short enough for sun_path).
    public static func socketPath(uid: UInt32, environment: [String: String]) -> String {
        if let p = environment["XANEWM_SOCKET"], !p.isEmpty { return p }
        return "/tmp/\(defaultSocketName)-\(uid).sock"
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static func encode<T: Encodable>(_ v: T) -> String {
        (try? encoder.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    public static func ok(data: String? = nil) -> String {
        data.map { "{\"data\":\($0),\"ok\":true}" } ?? "{\"ok\":true}"
    }

    public static func error(_ message: String) -> String {
        "{\"error\":\(encode(message)),\"ok\":false}"
    }
}

// MARK: - Query views

struct WindowView: Encodable {
    var id: UInt32
    var pid: Int32
    var app: String
    var bundle_id: String
    var title: String
    var output: UInt32
    var tags: [Int]
    var floating: Bool
    var fullscreen: Bool
    var visible: Bool
    var present: Bool
    var minimized: Bool
    var focused: Bool
    var frame: Rect
    var minimum: [Double]
}

struct OutputView: Encodable {
    var id: UInt32
    var uuid: String
    var name: String
    var index: Int
    var frame: Rect
    var usable: Rect
    var tags: [Int]
    var layout: String
    var main_ratio: Double
    var main_count: Int
    var orientation: String
    var focused: Bool
    var windows: [UInt32]
}

struct StateView: Encodable {
    var paused: Bool
    var focused: UInt32?
    var focused_output: UInt32?
    var windows: Int
    var outputs: Int
    var options: Options
}

struct BindingView: Encodable { var keys: String; var command: String }

struct TreeView: Encodable {
    struct Out: Encodable { var output: UInt32; var layout: String; var tags: [Int]; var tiled: [UInt32]; var floating: [UInt32]; var hidden: [UInt32] }
    var outputs: [Out]
}

extension Compositor {
    public func query(_ what: String) -> String {
        let s = current
        switch what {
        case "windows":
            let v = s.order.compactMap { id -> WindowView? in
                guard let w = s.windows[id] else { return nil }
                let m = minimum(for: w)
                return WindowView(id: id, pid: w.pid, app: w.appName, bundle_id: w.bundleID, title: w.title,
                                  output: w.output, tags: Tags.numbers(w.tags), floating: w.floating,
                                  fullscreen: w.fullscreen, visible: s.isVisible(w), present: w.isPresent,
                                  minimized: w.minimized, focused: s.focused == id, frame: Rect(w.frame),
                                  minimum: [Double(m.width), Double(m.height)])
            }
            return Wire.encode(v)
        case "outputs":
            let v = s.outputOrder.enumerated().compactMap { i, oid -> OutputView? in
                guard let o = s.outputs[oid] else { return nil }
                return OutputView(id: oid, uuid: o.uuid, name: o.name, index: i + 1, frame: Rect(o.frame),
                                  usable: Rect(s.usableArea(of: o)), tags: Tags.numbers(o.tags),
                                  layout: o.layout.rawValue, main_ratio: o.params.mainRatio,
                                  main_count: o.params.mainCount, orientation: o.params.orientation.rawValue,
                                  focused: s.focusedOutput == oid, windows: s.visible(on: oid))
            }
            return Wire.encode(v)
        case "bindings":
            let v = s.bindings.map { BindingView(keys: $0.key.description, command: $0.value) }
                .sorted { $0.keys < $1.keys }
            return Wire.encode(v)
        case "rules":
            return Wire.encode(s.rules.map(\.description))
        case "options":
            return Wire.encode(s.options)
        case "tree":
            let outs = s.outputOrder.compactMap { oid -> TreeView.Out? in
                guard let o = s.outputs[oid] else { return nil }
                let mine = s.order.filter { s.windows[$0]?.output == oid }
                return TreeView.Out(output: oid, layout: o.layout.rawValue, tags: Tags.numbers(o.tags),
                                    tiled: s.tiled(on: oid),
                                    floating: mine.filter { s.windows[$0]!.floating && s.isVisible($0) },
                                    hidden: mine.filter { !s.isVisible($0) })
            }
            return Wire.encode(TreeView(outputs: outs))
        default:
            return Wire.encode(StateView(paused: s.paused, focused: s.focused, focused_output: s.focusedOutput,
                                         windows: s.windows.count, outputs: s.outputs.count, options: s.options))
        }
    }

    /// Events for subscribers, derived by diffing two committed states.
    public static func events(from a: State, to b: State) -> [String] {
        var out: [String] = []
        if a.focused != b.focused {
            let w = b.focused.flatMap { b.windows[$0] }
            out.append("{\"app\":\(Wire.encode(w?.appName ?? "")),\"event\":\"focus\",\"window\":\(b.focused.map(String.init) ?? "null")}")
        }
        if a.focusedOutput != b.focusedOutput, let o = b.focusedOutput {
            out.append("{\"event\":\"output-focus\",\"output\":\(o)}")
        }
        for (oid, o) in b.outputs {
            let old = a.outputs[oid]
            if old?.tags != o.tags {
                out.append("{\"event\":\"tags\",\"output\":\(oid),\"tags\":\(Wire.encode(Tags.numbers(o.tags)))}")
            }
            if old?.layout != o.layout {
                out.append("{\"event\":\"layout\",\"layout\":\"\(o.layout.rawValue)\",\"output\":\(oid)}")
            }
        }
        if a.windows.count != b.windows.count {
            out.append("{\"count\":\(b.windows.count),\"event\":\"windows\"}")
        }
        if a.paused != b.paused { out.append("{\"event\":\"paused\",\"paused\":\(b.paused)}") }
        return out
    }
}
