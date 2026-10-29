import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What the AX layer reports about a window. Plain data, produced off the main thread.
public struct WindowSnapshot: Equatable, Sendable {
    public var id: WindowID
    public var pid: Int32
    public var bundleID: String
    public var appName: String
    public var title: String
    public var role: String
    public var subrole: String
    /// `AXIdentifier` (NSWindow identifier / autosave name) when the app sets one. Used to tell
    /// window kinds of the same app apart for minimum-size learning.
    public var identifier: String
    public var frame: CGRect
    public var isMinimized: Bool
    public var isNativeFullscreen: Bool
    public var isSizeSettable: Bool
    public var isPositionSettable: Bool
    public var hasMinimizeButton: Bool
    public var hasFullscreenButton: Bool
    public var hasCloseButton: Bool
    public var isModal: Bool
    public var hasDialogButtons: Bool
    public var hasDocument: Bool

    public init(id: WindowID, pid: Int32, bundleID: String = "", appName: String = "", title: String = "",
                role: String = "AXWindow", subrole: String = "AXStandardWindow", identifier: String = "",
                frame: CGRect = .zero, isMinimized: Bool = false, isNativeFullscreen: Bool = false,
                isSizeSettable: Bool = true, isPositionSettable: Bool = true, hasMinimizeButton: Bool = true,
                hasFullscreenButton: Bool = true, hasCloseButton: Bool = true, isModal: Bool = false,
                hasDialogButtons: Bool = false, hasDocument: Bool = false) {
        self.id = id; self.pid = pid; self.bundleID = bundleID; self.appName = appName; self.title = title
        self.role = role; self.subrole = subrole; self.identifier = identifier; self.frame = frame
        self.isMinimized = isMinimized; self.isNativeFullscreen = isNativeFullscreen
        self.isSizeSettable = isSizeSettable; self.isPositionSettable = isPositionSettable
        self.hasMinimizeButton = hasMinimizeButton; self.hasFullscreenButton = hasFullscreenButton
        self.hasCloseButton = hasCloseButton; self.isModal = isModal
        self.hasDialogButtons = hasDialogButtons; self.hasDocument = hasDocument
    }

    /// Key for learned minimum sizes: per app *and* window kind, so a narrow compose window does not
    /// inherit the minimum of the app's wide main window.
    public var minimumSizeKey: String {
        bundleID + "|" + (identifier.isEmpty ? subrole : identifier)
    }
}

public enum Management: String, Codable, Sendable {
    case tile, float, ignore
}

public struct Window: Equatable, Sendable {
    public let id: WindowID
    public let pid: Int32
    public var bundleID: String
    public var appName: String
    public var title: String
    public var subrole: String
    public var minimumSizeKey: String

    public var output: OutputID
    public var floating: Bool
    /// Compositor-level fullscreen: fills the output's usable area, above the layout. (Native
    /// macOS fullscreen moves the window to its own Space and is tracked by `nativeFullscreen`.)
    public var fullscreen: Bool = false

    // Facts reported by the system.
    public var frame: CGRect
    public var minimized: Bool = false
    public var appHidden: Bool = false
    public var nativeFullscreen: Bool = false
    /// On the current macOS Space (the window server lists it on screen).
    public var onCurrentSpace: Bool = true
    public var canResize: Bool = true

    /// Where a floating window lives when it is visible.
    public var floatingFrame: CGRect?
    /// Minimum size learned this session for this exact window (not persisted).
    public var sessionMinimum: CGSize = .zero

    public init(id: WindowID, pid: Int32, bundleID: String, appName: String, title: String,
                subrole: String, minimumSizeKey: String, output: OutputID, floating: Bool, frame: CGRect) {
        self.id = id; self.pid = pid; self.bundleID = bundleID; self.appName = appName; self.title = title
        self.subrole = subrole; self.minimumSizeKey = minimumSizeKey; self.output = output
        self.floating = floating; self.frame = frame
    }

    /// The window exists on the current Space and is not minimized/hidden/native-fullscreen.
    public var isPresent: Bool { !minimized && !appHidden && !nativeFullscreen && onCurrentSpace }
}

public struct Output: Equatable, Sendable {
    public let id: OutputID
    public var uuid: String
    public var name: String
    /// Full frame of the display.
    public var frame: CGRect
    /// Frame minus menu bar and Dock (NSScreen.visibleFrame), in window-server coordinates.
    public var visibleFrame: CGRect
    public var layout: LayoutKind
    public var params: LayoutParams

    public init(id: OutputID, uuid: String, name: String, frame: CGRect, visibleFrame: CGRect,
                layout: LayoutKind = .dwindle, params: LayoutParams = .init()) {
        self.id = id; self.uuid = uuid; self.name = name; self.frame = frame; self.visibleFrame = visibleFrame
        self.layout = layout; self.params = params
    }
}

/// Per-display settings that survive restarts and reconnections (keyed by display UUID).
public struct OutputSettings: Codable, Equatable, Sendable {
    public var layout: LayoutKind
    public var params: LayoutParams
}
