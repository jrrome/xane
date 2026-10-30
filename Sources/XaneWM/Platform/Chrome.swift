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

/// A short message in the middle of a display that goes away by itself, like Chrome's
/// "Hold ⌘Q to quit". Click-through, and it never takes focus.
final class Toast {
    private var window: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var fade: DispatchWorkItem?

    /// `display` in window-server coordinates.
    func show(_ text: String, on display: CGRect, for seconds: TimeInterval) {
        let w = window ?? makeWindow()
        label.stringValue = text
        let size = label.intrinsicContentSize
        let box = CGSize(width: ceil(size.width) + 48, height: ceil(size.height) + 28)
        let frame = CGRect(x: display.midX - box.width / 2, y: display.midY - box.height / 2, width: box.width, height: box.height)
        w.setFrame(Displays.toCocoa(frame), display: true)
        label.frame = CGRect(x: 24, y: (box.height - size.height) / 2, width: ceil(size.width), height: ceil(size.height))
        if !w.isVisible { w.alphaValue = 0 }
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; w.animator().alphaValue = 1 }
        fade?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        fade?.cancel()
        fade = nil
        guard let w = window, w.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 }) {
            if w.alphaValue == 0 { w.orderOut(nil) }
        }
    }

    private func makeWindow() -> NSPanel {
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .statusBar
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        w.appearance = NSAppearance(named: .darkAqua)
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = .white
        background.addSubview(label)
        w.contentView = background
        window = w
        return w
    }
}

/// Menu bar item: focused desktop and layout at a glance, quick switches and the settings window.
final class StatusBar: NSObject, NSMenuDelegate {
    /// What the menu shows checked, read each time it opens.
    struct State {
        var layout: LayoutKind?
        /// The desktops of the focused display and the one it shows.
        var desktops: ClosedRange<Int>?
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

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon
        item.button?.imagePosition = .imageOnly
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
        set(status: "Starting…", active: false)
    }

    private func entry(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    /// The icon is always there; it dims while XaneWM is not tiling.
    func set(status: String, active: Bool, paused: Bool = false) {
        if item?.button?.appearsDisabled == active { item?.button?.appearsDisabled = !active }
        item?.button?.toolTip = "XaneWM — \(status)"
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
        desktopMenu.removeAllItems()
        for n in s.desktops ?? 1...1 {
            let i = NSMenuItem(title: "Desktop \(n)", action: #selector(view(_:)), keyEquivalent: "")
            i.target = self
            i.tag = n
            i.state = n == s.desktop ? .on : .off
            desktopMenu.addItem(i)
        }
        followItem.state = s.focusFollowsMouse ? .on : .off
        borderItem.state = s.border ? .on : .off
    }

    /// The XaneWM mark (Resources/MenuBarIcon), drawn as a template so it follows the menu bar.
    static let icon: NSImage = {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "xmark.rectangle.fill", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = "XaneWM"
        return image
    }()

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
    @objc private func view(_ sender: NSMenuItem) { onCommand?("desktop \(sender.tag)") }
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
