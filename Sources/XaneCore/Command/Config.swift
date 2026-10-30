import Foundation

/// The config file is just a list of commands, one per line, run in order at start-up and on
/// `reload` — the same commands `xanectl` sends and key bindings run (like river's init or sway's
/// config). `#` starts a comment line.
public enum Config {
    public static func path(environment: [String: String], home: String) -> String {
        if let p = environment["XANEWM_CONFIG"], !p.isEmpty { return p }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        return base + "/xanewm/config"
    }

    public struct Problem: Equatable, CustomStringConvertible {
        public var line: Int
        public var error: CommandError
        public var description: String { "line \(line): \(error)" }
    }

    public static func parse(_ text: String) -> (commands: [Command], problems: [Problem]) {
        var cmds: [Command] = []
        var problems: [Problem] = []
        var buffer = ""
        var startLine = 0
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw
            if buffer.isEmpty { startLine = n + 1 }
            // Trailing backslash continues the command on the next line.
            if line.hasSuffix("\\") {
                line.removeLast()
                buffer += line + " "
                continue
            }
            buffer += line
            defer { buffer = "" }
            for r in CommandParser.parseLine(buffer) {
                switch r {
                case .success(let c): cmds.append(c)
                case .failure(let e): problems.append(Problem(line: startLine, error: e))
                }
            }
        }
        return (cmds, problems)
    }

    public static let defaultText = #"""
# xanewm — configuration
#
# Every line is a command: the same language used by key bindings and by `xanectl`.
# Changes apply with `xanectl reload` (or ctrl+alt+shift+r).
# Desktops are the macOS ones (Mission Control): each one tiles its own windows.

# ── Appearance ────────────────────────────────────────────────────────────────
set gap-inner 8
set gap-outer 8
set border on
set border-width 3
set border-color accent
set border-radius auto            # auto = follow each window's corners, or a number

# ── Behaviour ─────────────────────────────────────────────────────────────────
set default-layout dwindle
set main-ratio 0.55
set attach after-focused          # top | bottom | after-focused
set overflow stack                # stack | float  (windows that don't fit)
set new-window-output pointer     # pointer | focused | app
set focus-follows-mouse on        # the window under the pointer gets focus
set focus-follows-mouse-delay 0   # 0 = instant; >0 = only once the pointer rests that long (s)
set mouse-follows-focus off
set desktop-back-and-forth on     # ctrl+N on the desktop shown goes back to the one before…
set desktop-back-and-forth-cooldown 0.75  # …once you have been there this long (s)
set enforce-layout on             # put tiled windows back if an app moves them by itself
# set edges 0 0 0 0               # reserve space for other bars: top right bottom left

# ── Rules (later rules win) ───────────────────────────────────────────────────
rule float app-id com.apple.calculator
rule float app-id com.apple.systempreferences
rule float app-id com.apple.SystemPreferences
rule float app-id com.apple.ScreenContinuity
rule float app-id com.apple.iphonesimulator
rule float app-id com.apple.Stickies
rule float app-id com.apple.PhotoBooth
rule float app-id com.apple.QuickTimePlayerX
rule float app-id com.apple.DigitalColorMeter
rule float app-id com.apple.screenshot.launcher
rule float app-id com.apple.archiveutility
rule float app-id com.apple.installer
rule float app-id com.apple.MigrateAssistant
rule float app-id com.apple.CaptiveNetworkAssistant
rule float app-id com.apple.ProblemReporter
rule float app-id com.apple.Magnifier
rule float title "^Picture[ -]in[ -]Picture$"
# rule output 2 app-id com.apple.mail

# ── Key bindings (ctrl+alt is the prefix; hyper = ctrl+alt+shift+cmd) ──────────
bind ctrl+alt+h focus left
bind ctrl+alt+j focus down
bind ctrl+alt+k focus up
bind ctrl+alt+l focus right
bind ctrl+alt+n focus next
bind ctrl+alt+p focus prev
bind ctrl+alt+shift+h swap left
bind ctrl+alt+shift+j swap down
bind ctrl+alt+shift+k swap up
bind ctrl+alt+shift+l swap right
bind ctrl+alt+return zoom
bind ctrl+alt+shift+space toggle-float   # (ctrl+alt+space is the input-source switch)
bind ctrl+alt+f toggle-fullscreen
bind ctrl+alt+shift+c close

bind ctrl+alt+d layout dwindle
bind ctrl+alt+t layout tile
bind ctrl+alt+c layout columns
bind ctrl+alt+g layout grid
bind ctrl+alt+m layout monocle
bind ctrl+alt+backslash layout next
bind ctrl+alt+period resize grow
bind ctrl+alt+comma resize shrink
bind ctrl+alt+equal main-count +1
bind ctrl+alt+minus main-count -1
bind ctrl+alt+o orientation next
bind ctrl+alt+0 reset-layout

# Desktops (macOS Spaces): ctrl+N shows desktop N, ctrl+shift+N carries the focused window there.
# With "Switch to Desktop N" on (System Settings → Keyboard → Keyboard Shortcuts → Mission
# Control) macOS jumps straight there; otherwise XaneWM steps with "Move left/right a space".
# ctrl+N for the desktop after the last one asks you to press it again, and then creates it.
bind ctrl+1 desktop 1
bind ctrl+2 desktop 2
bind ctrl+3 desktop 3
bind ctrl+4 desktop 4
bind ctrl+5 desktop 5
bind ctrl+6 desktop 6
bind ctrl+7 desktop 7
bind ctrl+8 desktop 8
bind ctrl+9 desktop 9
bind ctrl+shift+1 move-to-desktop 1
bind ctrl+shift+2 move-to-desktop 2
bind ctrl+shift+3 move-to-desktop 3
bind ctrl+shift+4 move-to-desktop 4
bind ctrl+shift+5 move-to-desktop 5
bind ctrl+shift+6 move-to-desktop 6
bind ctrl+shift+7 move-to-desktop 7
bind ctrl+shift+8 move-to-desktop 8
bind ctrl+shift+9 move-to-desktop 9
bind ctrl+alt+tab desktop back

bind ctrl+alt+leftbracket focus-output prev
bind ctrl+alt+rightbracket focus-output next
bind ctrl+alt+shift+leftbracket send-to-output prev
bind ctrl+alt+shift+rightbracket send-to-output next

bind ctrl+alt+r retile
bind ctrl+alt+shift+r reload
bind ctrl+alt+shift+p toggle-pause
"""#
}
