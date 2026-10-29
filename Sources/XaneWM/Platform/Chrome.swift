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

/// Menu bar item: focused tags and layout at a glance, and a few actions.
final class StatusBar: NSObject {
    var onCommand: ((String) -> Void)?
    var onOpenConfig: (() -> Void)?
    var onAccessibility: (() -> Void)?
    private var item: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let problemsLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(StatusBar.togglePause), keyEquivalent: "")
    private var lastTitle = ""

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let menu = NSMenu()
        statusLine.isEnabled = false
        problemsLine.isEnabled = false
        problemsLine.isHidden = true
        menu.addItem(statusLine)
        menu.addItem(problemsLine)
        menu.addItem(.separator())
        menu.addItem(entry("Retile", #selector(retile)))
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(entry("Reload Config", #selector(reload)))
        menu.addItem(entry("Open Config…", #selector(openConfig)))
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

    @objc private func retile() { onCommand?("retile") }
    @objc private func togglePause() { onCommand?("toggle-pause") }
    @objc private func reload() { onCommand?("reload") }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func accessibility() { onAccessibility?() }
    @objc private func quit() { onCommand?("quit") }
}
#endif
