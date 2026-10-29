<p align="center">
  <img src="docs/assets/icon.png" width="160" alt="XaneWM icon">
</p>

<h1 align="center">XaneWM</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/layouts-5-6B5040" alt="5 layouts">
  <img src="https://img.shields.io/badge/IPC-unix%20socket-6B5040" alt="IPC over a Unix socket">
  <img src="https://img.shields.io/badge/SIP-stays%20on-2EA44F" alt="SIP stays on">
  <img src="https://img.shields.io/badge/private%20APIs-1-555555" alt="1 private API">
</p>

<p align="center">
  <b>A Wayland-style tiling window manager for macOS.</b><br>
  The compositor owns the geometry, every action is a command and desktops are tags that switch
  instantly. Native Swift on top of Accessibility, event-driven, with an exact layout solver and
  one thread per app so a hung app never freezes the rest. <b>No SIP changes required.</b>
</p>

<p align="center">
  <a href="#installation">Installation</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#commands">Commands</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#known-limitations">Known limitations</a>
</p>

```sh
xanectl layout tile
xanectl "view 2; focus main"    # one atomic commit
xanectl query windows | jq
```

## Highlights

- **Five layouts:** `dwindle`, `tile`, `columns`/`rows`, `grid` and `monocle`, solved exactly in closed form, respecting every app's minimum size.
- **Tags instead of Spaces:** `⌃1…9` switches desktops instantly, with no Mission Control animation. View several tags at once or put a window on several.
- **One command language** for the config file, the key bindings and the `xanectl` CLI, plus a JSON event stream for status bars.
- **The compositor is in charge:** apps that move or resize their tiled windows on their own are put back.
- **Built to never lose a window:** parked windows come back on quit and after a crash, and tags are restored across restarts.
- **Mouse aware:** instant focus-follows-mouse, drag a window onto another to swap them, drag an edge to resize.

## Installation

Requires macOS 13 or later and Xcode 15+ (or the Swift 5.9+ toolchain).

```sh
git clone https://github.com/jrrome/xane.git && cd xane
make install
open ~/Applications/XaneWM.app
```

| Target | What it does |
|---|---|
| `make` | Release build and `XaneWM.app` bundle |
| `make install` | Copies the app to `~/Applications` and `xanectl` to `~/.local/bin` |
| `make autostart` | Starts at login and restarts if it crashes (not if you quit it) |
| `make test` | Core unit tests (they also run on Linux) |
| `make logs` | Live log |

### Accessibility permission

On first launch XaneWM asks for **Accessibility** (System Settings → Privacy & Security →
Accessibility). macOS ties this permission to the code signature: with ad-hoc signing every rebuild
looks like a new app and the permission is lost even though the toggle stays on. That is why `make`
signs with the first "Apple Development" certificate in your keychain when there is one (override it
with `make SIGN_ID="…"`) and only falls back to ad-hoc signing when none is found.

## Usage

All default bindings use the `⌃⌥` prefix, except desktops.

| Binding | Action |
|---|---|
| `⌃⌥ h j k l` | Focus left / down / up / right (crosses displays) |
| `⌃⌥⇧ h j k l` | Swap in that direction |
| `⌃⌥ n` / `p` | Next / previous window |
| `⌃⌥ ↩` | Zoom: the window becomes main |
| `⌃⌥⇧ space` / `⌃⌥ f` | Float / compositor fullscreen |
| `⌃⌥ d t c g m` | Layout dwindle / tile / columns / grid / monocle |
| `⌃⌥ \` | Next layout |
| `⌃⌥ .` / `,` | Grow / shrink |
| `⌃⌥ =` / `-` | More / fewer main windows (`tile`) |
| `⌃⌥ o` | Rotate the orientation (`tile`) |
| `⌃⌥ 0` | Reset ratios |
| `⌃ 1…9` | View desktop (tag) N; pressing it again goes back to the previous one |
| `⌃⇧ 1…9` | Move the window to desktop N |
| `⌃⌥ tab` | Previous tags |
| `⌃⌥ [` / `]` | Focus the previous / next display (with `⇧`: move the window) |
| `⌃⌥ r` / `⌃⌥⇧ r` | Retile everything / reload config |
| `⌃⌥⇧ p` | Pause / resume |
| `⌃⌥⇧ c` | Close window |

**With the mouse:** the window under the pointer gets focus as soon as the pointer enters it. Drag a
window onto another to swap them, or onto another display to move it there. Drag an edge to change
the ratio.

### Configuration

The config lives in `~/.config/xanewm/config` and is created, fully commented, on first launch. Every
line is a command, so anything you can bind you can also run from `xanectl`:

```sh
set gap-inner 8
set default-layout dwindle
set focus-follows-mouse on
set focus-follows-mouse-delay 0   # 0 = instant
rule float app-id com.apple.systempreferences
rule tags 9 app-id com.spotify.client
bind ctrl+alt+t layout tile
bind hyper+b exec open -a Safari
```

Reload it with `xanectl reload` or `⌃⌥⇧ r`. If one of your bindings uses the same keys as an enabled
macOS shortcut, XaneWM warns you in its menu, because macOS takes the key without reporting an error.

<details>
<summary><b>All options and keys</b></summary>

Options: `gap`, `gap-inner`, `gap-outer`, `default-layout`, `main-ratio`,
`attach top|bottom|after-focused`, `overflow stack|float`, `max-tiled`,
`new-window-output pointer|focused|app`, `focus-follows-mouse`, `focus-follows-mouse-delay`,
`mouse-follows-focus`, `view-back-and-forth`, `follow-activation`, `border`, `border-width`,
`border-color accent|#RRGGBB`, `border-radius`, `edges <top right bottom left>`,
`enforce-layout`.

Keys: `ctrl alt shift cmd` (or `hyper` / `meh`) + `a-z 0-9 return space tab escape left right up down
comma period slash semicolon quote leftbracket rightbracket backslash minus equal grave f1-f20`.

</details>

## Commands

```
focus|swap  left|right|up|down|next|prev|main|recent      zoom
float|fullscreen [toggle|on|off]                           close
layout dwindle|tile|columns|rows|grid|monocle|next|prev
main-ratio 0.6|+0.05|-0.05      main-count 2|+1|-1      orientation left|right|top|bottom|next
resize grow|shrink [0.05] [horizontal|vertical]           reset-layout
view N|1,3|all|prev   view-toggle N   tag N|all   tag-toggle N
set-focused-tags MASK   set-view-tags MASK                 (river-compatible)
focus-output next|prev|left|right|N     send-to-output next|prev|left|right|N
set <option> <value>    rule float|tile|ignore|tags N|output N  app-id X [title REGEX] [subrole S]
bind <keys> <command…>    unbind <keys>|all    rule-clear
query windows|outputs|tree|state|bindings|rules|options    subscribe
exec <shell>    retile    reload    pause|resume|toggle-pause    quit
```

Separate several commands with `;` to apply them as a single commit.

### Scripting

```sh
xanectl subscribe | while read -r ev; do echo "$ev"; done      # JSON events, e.g. for SketchyBar
xanectl query outputs -p
xanectl rule tags 9 app-id com.spotify.client
```

## How it works

### A Wayland compositor on top of macOS

macOS does not let you replace the compositor, but its principles can still be applied on top of
Accessibility:

| Wayland principle | How it applies here |
|---|---|
| **The compositor is in charge.** Clients do not decide their geometry. | The compositor's state is the source of truth and the screen is its projection. If an app moves or resizes a tiled window on its own (`AXMoved`/`AXResized` without a user drag), it is put back. If it keeps insisting, it is left alone for a while to avoid loops. |
| **Double-buffered state and atomic commit** (`wl_surface.commit`). | Commands modify `pending`. `commit()` computes the full layout, diffs it against reality and produces a `Transaction` with every change at once. `view 2; focus main` is applied in one go, with no intermediate states. |
| **configure / ack with a serial** (`xdg_surface`). | Every geometry request carries a serial. The app "acks" with the frame it actually took. Stale acks are discarded. If the window ends up larger than requested, that is its minimum size (`set_min_size`) and it is learned. |
| **Interactive grabs** (move/resize grab). | Nothing moves under the user while the button is held. On release the gesture is interpreted: resizing changes the layout ratios, and dropping onto another window swaps them or sends it to another display. |
| **Everything is an IPC command** (swaymsg, riverctl). | A single language for the config, the key bindings and `xanectl`, served over a Unix socket (`/tmp/xanewm-<uid>.sock`). `xanectl subscribe` emits JSON events. |
| **Pure layout generators** (river-layout). | `XaneCore` knows nothing about AppKit: from (area, window count, minimums, parameters) to rectangles. It can be tested on any platform. |
| **Tags instead of desktops** (river, dwm). | Each display shows a tag mask and each window has its own. You can view several tags at once and put a window on several. |
| **No polling: everything is event-driven.** | One `AXObserver` per app (create, destroy, move, resize, focus, minimize, hide), plus `NSWorkspace` and display notifications. The Accessibility permission is awaited through the system notification. |

### Architecture

```
 ┌──────────── XaneWM.app (compositor process, LSUIElement) ─────────────────────────────┐
 │                                                                                         │
 │  HotKeys (Carbon) ─┐    SocketServer (IPC thread) ─┐  MouseMonitor (grab / FFM)          │
 │                    ▼                               ▼                                     │
 │            Server.run("cmd") ──► Compositor.execute ──► pending ──► commit() ──► Transaction
 │                    ▲               (XaneCore, pure)                     │   configures    │
 │                    │ events (main queue)                                ▼   per app       │
 │   ┌────────────────┴───────────┐   ┌────────────────────────────────────────────────┐    │
 │   │ AppWorker  pid 501 (thread)│   │ AppWorker  pid 733 (thread) …  one per app      │    │
 │   │ AXObserver + all of its    │   │ in parallel; if an app hangs only its own       │    │
 │   │ AX calls, serialized       │   │ thread is blocked                               │    │
 │   └────────────────────────────┘   └────────────────────────────────────────────────┘    │
 │   WindowServer (CGWindowList: current Space) · Displays · BorderOverlay · StatusBar     │
 └─────────────────────────────────────────────────────────────────────────────────────────┘
          ▲ xanectl (CLI)
```

| Path | Contents |
|---|---|
| `Sources/XaneCore` | Pure, cross-platform and tested. `Layout/` (split tree, solver, generators), `Compositor/` (state, commit, configure/ack, navigation, persistence, minimum-size learning), `Command/` (parser and config), `IPC/` (protocol and socket server). |
| `Sources/XaneWM` | The macOS process. `Server.swift` orchestrates; `Platform/` holds the per-app `AppWorker` threads, AX helpers, windows and displays, hotkeys and mouse, and the border and menu bar item. |
| `Sources/xanectl` | The IPC client. |

### Layout engine

Every layout is a binary split tree. Since the axes are fixed before solving, the minimums of each
subtree propagate exactly and every split is solved in closed form:

```
first = clamp(ratio · available, minFirst, available − minSecond)
```

There is no bisection: every attempt is exact. If the minimums do not fit, it retries with one tile
fewer and the leftover windows are stacked in the focused tile (or float, with `set overflow float`).
It takes microseconds.

| Layout | Description |
|---|---|
| `dwindle` | BSP that always splits the longer side of the remaining area. Adapts on its own to vertical, ultrawide and in-between monitors. |
| `tile` | Main + stack. Adjustable `left/right/top/bottom` orientation and `main-count`. |
| `columns` / `rows` | Exact linear split, with gaps accounted for. |
| `grid` | Grid adapted to the display's aspect ratio. |
| `monocle` | Every window fills the whole area. |

Resizing with the mouse or with `resize grow|shrink` moves the split that touches that window.
Ratios are stored per **(display, layout, tile count)**, so resizing `tile` with 3 windows does not
distort `grid` with 4.

### Robustness

- **Never loses windows.** On quit (menu, `xanectl quit`, `SIGTERM`) parked windows are brought back into view. After a crash, any off-screen window is recovered on startup, and each window's tags are restored from `~/Library/Application Support/xanewm/state.json`.
- **Hung apps.** AX calls time out after 0.25 s per window and 0.5 s per app. An unresponsive app only blocks its own thread, and its windows are kept.
- **Lost requests.** Every configure expires after 1.5 s. If reality does not match the request, the next commit resends it.
- **Apps that fight back.** If a window is repositioned more than 4 times in 3 s, it is left alone for a while.
- **Half-created windows.** They are re-examined after 0.2 s and 0.8 s, and again if they change size.
- **Native Spaces.** Only the current Space is managed. Windows on other Spaces keep their place in the model and are laid out again when you return. Native tabs just work: only the visible tab takes a tile.
- **Single instance** per socket. With `make autostart`, launchd restarts it if it crashes.
- **Private logs.** App names are logged with `privacy: .private` and window titles are never logged.

<details>
<summary><b>Prior art: improvements over Shoji 1.2.3</b></summary>

XaneWM started from a study of Shoji 1.2.3 and addresses its weak spots:

| # | Area | XaneWM |
|---|---|---|
| 1 | AX off the main thread, in parallel per app | `AppWorker`: one thread per app and coalesced requests (only the latest one per window is applied) |
| 2 | `AXMoved`/`AXResized` and incremental inventory | Per-window events; a full inventory only as a fallback (Space change, wake) |
| 3 | Minimums per window kind | `bundleID` + `AXIdentifier` (or subrole) key |
| 4 | Robust hiding spot for parked windows | Corner chosen by geometry (no neighbouring display), verified and retried |
| 5 | Private logs | `os.Logger` with `privacy: .private` for app names; titles are never logged |
| 6 | Closed-form ratio | Exact solver instead of 12 bisection iterations per layout |
| 7 | Aspect-aware grid | `dwindle` and `grid` |
| 8 | Ratios per (display, layout, n) | ✅ |
| 9 | Permission via notification | `com.apple.accessibility.api`, polling only while the permission is missing |
| 10 | VoiceOver and `AXEnhancedUserInterface` | Once per batch and app, and never with VoiceOver running |
| 11 | Migrate minimums instead of deleting them | They become "suspect" and are confirmed on first use |
| 12 | Split up the large objects | Separate pure core and typed commands instead of dozens of closures |
| 13 | Independent outer gap | `gap-inner` / `gap-outer` |

Also kept from the original: the size/position step order so screen edges do not clip the window,
verifying the frame after moving, the double check before learning a minimum (near-full-screen
minimums only last for the session), the 400×300 minimum usable area, pausing during Stage Manager,
screen lock and sleep, and the 28 pt cascade for whatever does not fit.

</details>

## Known limitations

- **It does not move windows between native Spaces.** That requires private SkyLight APIs. Use tags and a single Space per display.
- **The native Spaces animation cannot be removed.** The Dock performs it, and skipping it requires disabling SIP (as yabai does). "Reduce motion" only swaps it for a fade. XaneWM desktops (`⌃1…9`) are tags: they switch instantly, with no animation.
- **`⌃1…9` clashes with Mission Control's "Switch to Desktop N"** if you have it enabled: macOS keeps the key. Turn it off in System Settings → Keyboard → Keyboard Shortcuts → Mission Control. XaneWM warns in its menu when it detects a clash.
- **It uses a single private call:** `_AXUIElementGetWindow`, to give each window a stable identity shared with `CGWindowList`. yabai, AeroSpace, Amethyst and Rectangle use it, and it has been stable for years. Everything else is public API and does not require disabling SIP.
- **Stage Manager:** tiling pauses while it is active.
- **Native fullscreen:** the window moves to its own Space and leaves the tiling. `fullscreen` (`⌃⌥ f`) is the compositor's alternative.
- **Carbon hotkeys:** they do not work while another app uses Secure Input (password fields). This is a system restriction.
