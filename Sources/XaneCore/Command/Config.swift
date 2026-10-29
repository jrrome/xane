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
# Tags work like river/dwm workspaces: each display shows a set of tags, each window has tags.

# ── Appearance ────────────────────────────────────────────────────────────────
set gap-inner 8
set gap-outer 8
set border on
set border-width 3
set border-color accent
set border-radius 12

# ── Behaviour ─────────────────────────────────────────────────────────────────
set default-layout dwindle
set main-ratio 0.55
set attach after-focused          # top | bottom | after-focused
set overflow stack                # stack | float  (windows that don't fit)
set new-window-output pointer     # pointer | focused | app
set focus-follows-mouse off
set mouse-follows-focus off
set view-back-and-forth on
set follow-activation on          # ⌘-Tab to a window on a hidden tag shows that tag
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
# rule tags 9 app-id com.spotify.client
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

bind ctrl+alt+1 view 1
bind ctrl+alt+2 view 2
bind ctrl+alt+3 view 3
bind ctrl+alt+4 view 4
bind ctrl+alt+5 view 5
bind ctrl+alt+6 view 6
bind ctrl+alt+7 view 7
bind ctrl+alt+8 view 8
bind ctrl+alt+9 view 9
bind ctrl+alt+shift+1 tag 1
bind ctrl+alt+shift+2 tag 2
bind ctrl+alt+shift+3 tag 3
bind ctrl+alt+shift+4 tag 4
bind ctrl+alt+shift+5 tag 5
bind ctrl+alt+shift+6 tag 6
bind ctrl+alt+shift+7 tag 7
bind ctrl+alt+shift+8 tag 8
bind ctrl+alt+shift+9 tag 9
bind ctrl+alt+tab view prev

bind ctrl+alt+leftbracket focus-output prev
bind ctrl+alt+rightbracket focus-output next
bind ctrl+alt+shift+leftbracket send-to-output prev
bind ctrl+alt+shift+rightbracket send-to-output next

bind ctrl+alt+r retile
bind ctrl+alt+shift+r reload
bind ctrl+alt+shift+p toggle-pause
"""#
}
