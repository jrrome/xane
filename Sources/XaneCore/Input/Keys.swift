import Foundation

/// Keyboard modifiers, independent of Carbon/AppKit so bindings can be parsed and tested anywhere.
public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let cmd = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let alt = Modifiers(rawValue: 1 << 2)
    public static let ctrl = Modifiers(rawValue: 1 << 3)
    public static let hyper: Modifiers = [.cmd, .shift, .alt, .ctrl]
    public static let meh: Modifiers = [.shift, .alt, .ctrl]
}

public struct KeyCombo: Hashable, Codable, Sendable, CustomStringConvertible {
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) { self.keyCode = keyCode; self.modifiers = modifiers }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.ctrl) { parts.append("ctrl") }
        if modifiers.contains(.alt) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.cmd) { parts.append("cmd") }
        parts.append(Keys.name(for: keyCode) ?? "0x" + String(keyCode, radix: 16))
        return parts.joined(separator: "+")
    }

    /// Parses `ctrl+alt+shift+h`, `hyper+return`, `cmd+alt+0x24`…
    public static func parse(_ s: String) -> KeyCombo? {
        let parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var mods: Modifiers = []
        for m in parts.dropLast() {
            switch m {
            case "ctrl", "control", "⌃": mods.insert(.ctrl)
            case "alt", "opt", "option", "⌥": mods.insert(.alt)
            case "cmd", "command", "super", "logo", "⌘": mods.insert(.cmd)
            case "shift", "⇧": mods.insert(.shift)
            case "hyper": mods.formUnion(.hyper)
            case "meh": mods.formUnion(.meh)
            default: return nil
            }
        }
        guard let code = Keys.code(for: keyName) else { return nil }
        return KeyCombo(keyCode: code, modifiers: mods)
    }
}

/// macOS virtual key codes (ANSI layout, `kVK_*` in HIToolbox/Events.h).
public enum Keys {
    static let table: [(String, UInt32)] = [
        ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06),
        ("x", 0x07), ("c", 0x08), ("v", 0x09), ("section", 0x0A), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D),
        ("e", 0x0E), ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("1", 0x12), ("2", 0x13), ("3", 0x14),
        ("4", 0x15), ("6", 0x16), ("5", 0x17), ("equal", 0x18), ("9", 0x19), ("7", 0x1A), ("minus", 0x1B),
        ("8", 0x1C), ("0", 0x1D), ("rightbracket", 0x1E), ("o", 0x1F), ("u", 0x20), ("leftbracket", 0x21),
        ("i", 0x22), ("p", 0x23), ("return", 0x24), ("l", 0x25), ("j", 0x26), ("quote", 0x27), ("k", 0x28),
        ("semicolon", 0x29), ("backslash", 0x2A), ("comma", 0x2B), ("slash", 0x2C), ("n", 0x2D), ("m", 0x2E),
        ("period", 0x2F), ("tab", 0x30), ("space", 0x31), ("grave", 0x32), ("backspace", 0x33),
        ("escape", 0x35), ("f17", 0x40), ("f18", 0x4F), ("f19", 0x50), ("f20", 0x5A),
        ("f5", 0x60), ("f6", 0x61), ("f7", 0x62), ("f3", 0x63), ("f8", 0x64), ("f9", 0x65), ("f11", 0x67),
        ("f13", 0x69), ("f16", 0x6A), ("f14", 0x6B), ("f10", 0x6D), ("f12", 0x6F), ("f15", 0x71),
        ("home", 0x73), ("pageup", 0x74), ("delete", 0x75), ("f4", 0x76), ("end", 0x77), ("f2", 0x78),
        ("pagedown", 0x79), ("f1", 0x7A), ("left", 0x7B), ("right", 0x7C), ("down", 0x7D), ("up", 0x7E),
    ]
    static let aliases: [String: String] = [
        "=": "equal", "-": "minus", "]": "rightbracket", "[": "leftbracket", "'": "quote", ";": "semicolon",
        "\\": "backslash", ",": "comma", "/": "slash", ".": "period", "`": "grave", "enter": "return",
        "esc": "escape", "spc": "space", "bracketleft": "leftbracket", "bracketright": "rightbracket",
        "forwarddelete": "delete", "backtick": "grave", "§": "section",
    ]
    static let byName: [String: UInt32] = Dictionary(table, uniquingKeysWith: { a, _ in a })
    static let byCode: [UInt32: String] = Dictionary(table.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

    public static func code(for name: String) -> UInt32? {
        let n = name.lowercased()
        if let c = byName[aliases[n] ?? n] { return c }
        if n.hasPrefix("0x"), let v = UInt32(n.dropFirst(2), radix: 16), v < 0x80 { return v }
        return nil
    }

    public static func name(for code: UInt32) -> String? { byCode[code] }
}
