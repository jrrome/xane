#if os(macOS)
import AppKit
import Carbon.HIToolbox
import os
import XaneCore

enum Log {
    // App names and frames are logged as private: they only show with `log config --mode private_data:on`.
    static let main = Logger(subsystem: "dev.xanewm", category: "main")
    static let tiling = Logger(subsystem: "dev.xanewm", category: "tiling")
    static let events = Logger(subsystem: "dev.xanewm", category: "events")
    static let input = Logger(subsystem: "dev.xanewm", category: "input")
}

/// Global key bindings via Carbon's RegisterEventHotKey: no Input Monitoring permission, no event
/// tap in the input path, and the keystroke is consumed so it never reaches the focused app.
final class HotKeys {
    var onPress: ((KeyCombo) -> Void)?
    private var refs: [KeyCombo: EventHotKeyRef] = [:]
    private var byID: [UInt32: KeyCombo] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private(set) var failed: [KeyCombo: OSStatus] = [:]
    static let signature: OSType = 0x58414E45   // 'XANE'

    @discardableResult
    func install() -> Bool {
        guard handler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr, hk.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue().fire(hk.id)
            return noErr
        }, 1, &spec, me, &handler)
        if status != noErr {
            Log.input.error("Could not receive keyboard shortcuts (status \(status, privacy: .public))")
        }
        return status == noErr
    }

    private func fire(_ id: UInt32) {
        guard let combo = byID[id] else { return }
        onPress?(combo)
    }

    /// Makes the registered set equal to `wanted`.
    func sync(_ wanted: Set<KeyCombo>) {
        for combo in Array(refs.keys) where !wanted.contains(combo) { unregister(combo) }
        failed = failed.filter { wanted.contains($0.key) }
        // Combos that failed (taken by another app) are only retried by retryFailed().
        for combo in wanted where refs[combo] == nil && failed[combo] == nil { register(combo) }
    }

    /// Retries the ones another app was holding.
    func retryFailed() { for combo in Array(failed.keys) { register(combo) } }

    private func register(_ combo: KeyCombo) {
        var ref: EventHotKeyRef?
        let id = nextID
        nextID &+= 1
        let status = RegisterEventHotKey(combo.keyCode, Self.carbonModifiers(combo.modifiers),
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[combo] = ref
            byID[id] = combo
            failed[combo] = nil
        } else {
            failed[combo] = status
            Log.input.error("Could not bind \(combo.description, privacy: .public) (status \(status, privacy: .public)); another app may be using it")
        }
    }

    private func unregister(_ combo: KeyCombo) {
        if let ref = refs.removeValue(forKey: combo) { _ = UnregisterEventHotKey(ref) }
        byID = byID.filter { $0.value != combo }
    }

    static func carbonModifiers(_ m: Modifiers) -> UInt32 {
        var r: UInt32 = 0
        if m.contains(.cmd) { r |= UInt32(cmdKey) }
        if m.contains(.shift) { r |= UInt32(shiftKey) }
        if m.contains(.alt) { r |= UInt32(optionKey) }
        if m.contains(.ctrl) { r |= UInt32(controlKey) }
        return r
    }
}

/// macOS's own shortcuts (System Settings → Keyboard → Keyboard Shortcuts) win over
/// RegisterEventHotKey without any error, so a binding they share silently never fires.
enum SystemShortcuts {
    /// "Switch to Desktop 1…9" and "Move left/right a space" in the Mission Control section.
    static let desktopIDs = 118...126
    static let moveLeft = 79, moveRight = 81

    /// Enabled system shortcuts by symbolic hot key id.
    static func enabled() -> [Int: KeyCombo] {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] else { return [:] }
        var out: [Int: KeyCombo] = [:]
        for case let (key, entry as [String: Any]) in all {
            guard let id = Int(key), entry["enabled"] as? Bool == true else { continue }
            if let value = entry["value"] as? [String: Any], let params = value["parameters"] as? [Int], params.count == 3 {
                guard params[1] != 0xFFFF else { continue }
                out[id] = KeyCombo(keyCode: UInt32(params[1]), modifiers: modifiers(params[2]))
            } else if let key = defaults[id] {
                // Turned on but never edited.
                out[id] = key
            }
        }
        return out
    }

    /// Enabled system shortcuts that use the same keys as one of `combos`, with their ids.
    static func conflicts(with combos: Set<KeyCombo>) -> [(combo: KeyCombo, id: Int)] {
        enabled().filter { combos.contains($0.value) }.map { (combo: $0.value, id: $0.key) }
            .sorted { $0.combo.description < $1.combo.description }
    }

    /// What macOS uses when a shortcut was never edited: ctrl+N and ctrl+arrows.
    private static let defaults: [Int: KeyCombo] = {
        var d = [moveLeft: KeyCombo(keyCode: 0x7B, modifiers: .ctrl), moveRight: KeyCombo(keyCode: 0x7C, modifiers: .ctrl)]
        for id in desktopIDs { if let code = Keys.code(for: String(id - 117)) { d[id] = KeyCombo(keyCode: code, modifiers: .ctrl) } }
        return d
    }()

    /// Types a shortcut as if from the keyboard, so the system (here, the Dock) acts on it.
    static func press(_ combo: KeyCombo) {
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.ctrl) { flags.insert(.maskControl) }
        if combo.modifiers.contains(.alt) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.cmd) { flags.insert(.maskCommand) }
        // Arrow keys carry fn and keypad flags, and system shortcuts on them only match with those.
        if (0x7B...0x7E).contains(combo.keyCode) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    /// NSEvent.ModifierFlags raw values, as stored in the preferences.
    private static func modifiers(_ flags: Int) -> Modifiers {
        var m: Modifiers = []
        if flags & 0x20000 != 0 { m.insert(.shift) }
        if flags & 0x40000 != 0 { m.insert(.ctrl) }
        if flags & 0x80000 != 0 { m.insert(.alt) }
        if flags & 0x100000 != 0 { m.insert(.cmd) }
        return m
    }
}

/// Pointer state. A pressed left button is the "grab" of Wayland's interactive move/resize: while it
/// is held the compositor does not fight the user; on release it interprets what happened.
final class MouseMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onMove: (() -> Void)?
    private var buttonMonitors: [Any] = []
    private var moveTap: CFMachPort?
    private var moveSource: CFRunLoopSource?
    private var moveMonitor: Any?

    func start() {
        guard buttonMonitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.onDown?() }) {
            buttonMonitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in self?.onUp?() }) {
            buttonMonitors.append(m)
        }
    }

    /// Mouse-move tracking only while focus-follows-mouse is on (it wakes the process a lot).
    /// A listen-only event tap sees every move; a global NSEvent monitor misses the ones that go
    /// to XaneWM itself (when it is the active app), so it is only the fallback.
    func trackMoves(_ on: Bool) {
        if on, moveTap == nil, moveMonitor == nil {
            let me = Unmanaged.passUnretained(self).toOpaque()
            let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MouseMonitor>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = monitor.moveTap { CGEvent.tapEnable(tap: t, enable: true) }
                } else {
                    monitor.onMove?()
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: me) {
                moveTap = tap
                moveSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), moveSource, .commonModes)
            } else {
                moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in self?.onMove?() })
            }
        } else if !on {
            if let tap = moveTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                if let src = moveSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
                CFMachPortInvalidate(tap)
                moveTap = nil
                moveSource = nil
            }
            if let m = moveMonitor { NSEvent.removeMonitor(m); moveMonitor = nil }
        }
    }

    static var isLeftButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
}
#endif
