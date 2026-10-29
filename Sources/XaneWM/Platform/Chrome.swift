#if os(macOS)
import AppKit
import QuartzCore
import XaneCore

/// Focus indicator: a transparent, click-through window ordered *directly below* the focused
/// window and slightly larger than it, so the outline lives in the gap and never covers content.
final class BorderOverlay {
    private var window: NSWindow?
    private var shape: CALayer?
    private(set) var isVisible = false

    func show(around frame: CGRect, below windowID: WindowID, width: CGFloat, radius: CGFloat, color: NSColor) {
        guard width > 0 else { hide(); return }
        let w = window ?? makeWindow()
        let outer = frame.insetBy(dx: -width, dy: -width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape?.borderWidth = width
        shape?.cornerRadius = radius + width
        shape?.borderColor = color.cgColor
        CATransaction.commit()
        w.setFrame(Displays.toCocoa(outer), display: false)
        w.order(.below, relativeTo: Int(windowID))
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        window?.orderOut(nil)
        isVisible = false
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.animationBehavior = .none
        w.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        // Layer-hosting view: its root layer *is* the outline and follows the window's size.
        let layer = CALayer()
        layer.cornerCurve = .continuous
        layer.backgroundColor = NSColor.clear.cgColor
        let view = NSView(frame: .zero)
        view.layer = layer
        view.wantsLayer = true
        w.contentView = view
        window = w
        shape = layer
        return w
    }

    static func color(_ spec: String) -> NSColor {
        if spec != "accent", let c = Options.parseHexColor(spec) {
            return NSColor(srgbRed: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: CGFloat(c.3))
        }
        return .controlAccentColor
    }
}

/// Menu bar item: focused desktop and layout at a glance, quick switches and the settings window.
final class StatusBar: NSObject, NSMenuDelegate {
    /// What the menu shows checked, read each time it opens.
    struct State {
        var layout: LayoutKind?
        var desktop: Int?
        var focusFollowsMouse = false
        var border = false
    }

    var onCommand: ((String) -> Void)?
    var onSetOption: ((String, [String]) -> Void)?
    var onSettings: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onAccessibility: (() -> Void)?
    var state: (() -> State)?
    private var item: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let problemsLine = NSMenuItem(title: "", action: #selector(StatusBar.settings), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(StatusBar.togglePause), keyEquivalent: "")
    private let layoutMenu = NSMenu()
    private let desktopMenu = NSMenu()
    private let followItem = NSMenuItem(title: "Focus Follows Pointer", action: #selector(StatusBar.toggleFollow), keyEquivalent: "")
    private let borderItem = NSMenuItem(title: "Window Border", action: #selector(StatusBar.toggleBorder), keyEquivalent: "")
    private var lastTitle = ""

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        problemsLine.target = self
        problemsLine.isHidden = true
        menu.addItem(statusLine)
        menu.addItem(problemsLine)
        menu.addItem(.separator())
        for k in LayoutKind.allCases {
            let i = NSMenuItem(title: "\(Self.glyph(k))  \(k.rawValue.capitalized)", action: #selector(layout(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = k.rawValue
            layoutMenu.addItem(i)
        }
        let layouts = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        layouts.submenu = layoutMenu
        menu.addItem(layouts)
        for n in 1...9 {
            let i = NSMenuItem(title: "Desktop \(n)", action: #selector(view(_:)), keyEquivalent: "")
            i.target = self
            i.tag = n
            desktopMenu.addItem(i)
        }
        let desktops = NSMenuItem(title: "Desktop", action: nil, keyEquivalent: "")
        desktops.submenu = desktopMenu
        menu.addItem(desktops)
        menu.addItem(entry("Retile", #selector(retile)))
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        followItem.target = self
        borderItem.target = self
        menu.addItem(followItem)
        menu.addItem(borderItem)
        menu.addItem(.separator())
        let settings = entry("Settings…", #selector(settings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(entry("Open Config File…", #selector(openConfig)))
        menu.addItem(entry("Reload Config", #selector(reload)))
        menu.addItem(.separator())
        menu.addItem(entry("Accessibility Settings…", #selector(accessibility)))
        menu.addItem(entry("Quit XaneWM", #selector(quit)))
        item.menu = menu
        self.item = item
        set(title: "◰", status: "Starting…")
    }

    private func entry(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func set(title: String, status: String, paused: Bool = false) {
        if title != lastTitle { item?.button?.title = title; lastTitle = title }
        statusLine.title = status
        pauseItem.title = paused ? "Resume" : "Pause"
    }

    func set(problems: [String]) {
        problemsLine.isHidden = problems.isEmpty
        problemsLine.title = problems.isEmpty ? "" : "⚠︎ Config: \(problems.count) problem(s) — first: \(problems[0])"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let s = state?() else { return }
        for i in layoutMenu.items { i.state = (i.representedObject as? String) == s.layout?.rawValue ? .on : .off }
        for i in desktopMenu.items { i.state = i.tag == s.desktop ? .on : .off }
        followItem.state = s.focusFollowsMouse ? .on : .off
        borderItem.state = s.border ? .on : .off
    }

    static func glyph(_ k: LayoutKind) -> String {
        switch k {
        case .dwindle: return "◰"
        case .tile: return "◧"
        case .columns: return "▥"
        case .rows: return "▤"
        case .grid: return "▦"
        case .monocle: return "□"
        }
    }

    @objc private func layout(_ sender: NSMenuItem) { onCommand?("layout \(sender.representedObject as? String ?? "next")") }
    @objc private func view(_ sender: NSMenuItem) { onCommand?("view \(sender.tag)") }
    @objc private func toggleFollow() { onSetOption?("focus-follows-mouse", [followItem.state == .on ? "off" : "on"]) }
    @objc private func toggleBorder() { onSetOption?("border", [borderItem.state == .on ? "off" : "on"]) }
    @objc private func settings() { onSettings?() }
    @objc private func retile() { onCommand?("retile") }
    @objc private func togglePause() { onCommand?("toggle-pause") }
    @objc private func reload() { onCommand?("reload") }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func accessibility() { onAccessibility?() }
    @objc private func quit() { onCommand?("quit") }
}
#endif
