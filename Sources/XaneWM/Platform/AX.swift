#if os(macOS)
import AppKit
import ApplicationServices
import XaneCore

/// Maps an AX window element to its window-server id (CGWindowID). Private but stable since
/// 10.x and used by every serious macOS window manager (yabai, AeroSpace, Amethyst, Rectangle).
/// It gives windows a stable identity shared with CGWindowList.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    var windowID: WindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(self, &id) == .success, id != 0 else { return nil }
        return id
    }
}

/// Hashable wrapper: AX elements compare with CFEqual (same pid + same remote token), which keeps
/// working after the window is destroyed — needed to map AXUIElementDestroyed back to an id.
struct AXKey: Hashable {
    let element: AXUIElement
    func hash(into h: inout Hasher) { h.combine(CFHash(element)) }
    static func == (a: AXKey, b: AXKey) -> Bool { CFEqual(a.element, b.element) }
}

enum AX {
    static func copy(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let v = value else { return nil }
        return unwrap(v)
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = copy(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? { copy(el, name) as? Bool }

    /// Values in a multiple-attribute result that failed come back as AXValue of type .axError.
    static func unwrap(_ v: AnyObject) -> AnyObject? {
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
        return v
    }

    static func point(_ v: AnyObject) -> CGPoint? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: AnyObject) -> CGSize? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    @discardableResult
    static func set(_ el: AXUIElement, position: CGPoint) -> AXError {
        var p = position
        guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(el, "AXPosition" as CFString, v)
    }

    @discardableResult
    static func set(_ el: AXUIElement, size: CGSize) -> AXError {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(el, "AXSize" as CFString, v)
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ flag: Bool) -> AXError {
        let value: CFBoolean = flag ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(el, name as CFString, value)
    }

    static func multiple(_ el: AXUIElement, _ names: CFArray) -> [AnyObject]? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let cf = values else { return nil }
        return (cf as NSArray) as [AnyObject]
    }

    static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }
}
#endif
