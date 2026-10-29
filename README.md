# XaneWM

A native Swift tiling window manager for macOS, built on the philosophy of a Wayland compositor
(sway, river, Hyprland). It builds on the study of Shoji 1.2.3 (`../rea-shoji/pseudocodigo`) and
implements the proposals in `MEJORAS.md`.

```
xanectl layout tile          xanectl "view 2; focus main"          xanectl query windows | jq
```

## Philosophy: a Wayland compositor on top of macOS

macOS does not let you replace the compositor, but its principles can still be applied on top of Accessibility:

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

## Architecture

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

- **`Sources/XaneCore`** (pure, cross-platform, tested):
  - `Layout/`: binary split tree with an exact minimum-size solver, generators and "fit as many windows as possible".
  - `Compositor/`: state, commit, configure/ack, navigation, persistence and minimum-size learning.
  - `Command/`: parser and config.
  - `IPC/`: protocol and socket server.
- **`Sources/XaneWM`** (macOS):
  - `Platform/AppWorker.swift`: one thread with a run loop per app.
  - `Platform/AX.swift`: AX helpers.
  - `Platform/System.swift`: windows, displays, permissions and persistence.
  - `Platform/Input.swift`: hotkeys, mouse and logging.
  - `Platform/Chrome.swift`: border and menu bar item.
  - `Server.swift`: the orchestrator.
- **`Sources/xanectl`**: IPC client.

### Layout engine

Every layout is a binary split tree. Since the axes are fixed before solving, the minimums of each
subtree propagate exactly and every split is solved in closed form:

```
first = clamp(ratio · available, minFirst, available − minSecond)
```

There is no bisection (Shoji runs 12 iterations per layout): every attempt is exact. If the
minimums do not fit, it retries with one tile fewer and the leftover windows are stacked in the
focused tile (or float, with `set overflow float`). It takes microseconds.

| Layout | Description |
|---|---|
| `dwindle` | BSP that always splits the longer side of the remaining area. Adapts on its own to vertical, ultrawide and in-between monitors (MEJORAS §7). |
| `tile` | Main + stack. Adjustable `left/right/top/bottom` orientation and `main-count`. |
| `columns` / `rows` | Exact linear split, with gaps accounted for. |
| `grid` | Grid adapted to the display's aspect ratio. |
| `monocle` | Every window fills the whole area. |

Resizing with the mouse or with `resize grow|shrink` moves the split that touches that window.
Ratios are stored per **(display, layout, tile count)** (MEJORAS §8), so resizing `tile` with
3 windows does not distort `grid` with 4.

## What was taken from Shoji and what changes (MEJORAS.md)

| # | Proposal | Status |
|---|---|---|
| 1 | AX off the main thread and in parallel per app | ✅ `AppWorker`: one thread per app and coalesced requests (only the latest one per window is applied) |
| 2 | `AXMoved`/`AXResized` and incremental inventory | ✅ per-window events, full inventory only as a fallback (Space change, wake) |
| 3 | Minimums per window kind | ✅ `bundleID` + `AXIdentifier` (or subrole) key |
| 4 | Robust hiding spot for workspaces | ✅ corner chosen by geometry (no neighbouring display), verified and retried |
| 5 | Private logs | ✅ `os.Logger` with `privacy: .private` for app names; titles are never logged |
| 6 | Closed-form ratio | ✅ exact solver (see above) |
| 7 | Aspect-aware grid | ✅ `dwindle` and `grid` |
| 8 | Ratios per (display, layout, n) | ✅ |
| 9 | Permission via notification | ✅ `com.apple.accessibility.api`, polling only while the permission is missing |
| 10 | VoiceOver and `AXEnhancedUserInterface` | ✅ once per batch and app, and never with VoiceOver running |
| 11 | Migrate minimums instead of deleting them | ✅ they become "suspect" and are confirmed on first use |
| 12 | Split up the large objects | ✅ separate pure core and typed commands instead of dozens of closures |
| 13 | Independent outer gap | ✅ `gap-inner` / `gap-outer` |

Also kept from the original:

- the size/position step order, so screen edges do not clip the window;
- verifying the frame after moving;
- the double check before learning a minimum, and keeping near-full-screen minimums for the session only;
- the 400×300 minimum usable area;
- pausing during Stage Manager, screen lock and sleep;
- the 28 pt cascade for whatever does not fit.

## Robustness

- **Never loses windows.** On quit (menu, `xanectl quit`, `SIGTERM`) parked windows are brought back into view. After a crash, any off-screen window is recovered on startup, and each window's tags are restored from `~/Library/Application Support/xanewm/state.json`.
- **Hung apps.** AX calls time out after 0.25 s per window and 0.5 s per app. An unresponsive app only blocks its own thread, and its windows are kept.
- **Lost requests.** Every configure expires after 1.5 s. If reality does not match the request, the next commit resends it.
- **Apps that fight back.** If a window is repositioned more than 4 times in 3 s, it is left alone for a while.
- **Half-created windows.** They are re-examined after 0.2 s and 0.8 s, and again if they change size.
- **Native Spaces.** Only the current Space is managed. Windows on other Spaces keep their place in the model and are laid out again when you return. Native tabs just work: only the visible tab takes a tile.
- **Single instance** per socket. With `make autostart`, launchd restarts it if it crashes (not if you quit it).

## Requirements and installation

macOS 13 or later, and Xcode 15+ (or the Swift 5.9+ toolchain).

```sh
cd xanewm
make test            # core tests (they also run on Linux)
make                 # build and create XaneWM.app (ad-hoc signed)
make install         # ~/Applications/XaneWM.app + ~/.local/bin/xanectl
open ~/Applications/XaneWM.app
make autostart       # optional: start at login and restart if it crashes
make logs            # live log
```

On first launch it asks for **Accessibility** (System Settings → Privacy & Security →
Accessibility). macOS ties the permission to the signature. With ad-hoc signing every rebuild looks
like a new app and the permission is lost even though the toggle stays on. That is why `make` signs
with the first "Apple Development" certificate in the keychain if there is one (or with
`make SIGN_ID="…"`). It only falls back to ad-hoc signing when none is found.

## Usage

The config lives in `~/.config/xanewm/config` and is created, commented, on first launch. Each line is a command.

| Binding (prefix ⌃⌥) | Action |
|---|---|
| `h j k l` | focus left / down / up / right (crosses displays) |
| `⇧ + h j k l` | swap in that direction |
| `n` / `p` | next / previous window |
| `↩` | zoom: the window becomes main |
| `⇧ space` / `f` | float / compositor fullscreen |
| `d t c g m` | layout dwindle / tile / columns / grid / monocle |
| `\` | next layout |
| `.` / `,` | grow / shrink |
| `=` / `-` | more / fewer main windows (`tile`) |
| `o` | rotate the orientation (`tile`) |
| `0` | reset ratios |
| `⌃ 1…9` (⌃ only, no ⌥) | view desktop (tag) N; pressing it again goes back to the previous one |
| `⌃⇧ 1…9` (no ⌥) | move the window to desktop N |
| `tab` | previous tags |
| `[` / `]` | focus the previous / next display (with `⇧`: move the window) |
| `r` / `⇧ r` | retile everything / reload config |
| `⇧ p` | pause / resume |
| `⇧ c` | close window |

With the mouse: the window under the pointer gets focus as soon as the pointer enters it
(`focus-follows-mouse`, instant with `focus-follows-mouse-delay 0`). Drag a window onto another to
swap them, or onto another display to move it there. Drag an edge to change the ratio.

### Commands

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

Options: `gap`, `gap-inner`, `gap-outer`, `default-layout`, `main-ratio`,
`attach top|bottom|after-focused`, `overflow stack|float`, `max-tiled`,
`new-window-output pointer|focused|app`, `focus-follows-mouse`, `focus-follows-mouse-delay`,
`mouse-follows-focus`, `view-back-and-forth`, `follow-activation`, `border`, `border-width`,
`border-color accent|#RRGGBB`, `border-radius`, `edges <top right bottom left>`,
`enforce-layout`.

Keys: `ctrl alt shift cmd` (or `hyper` / `meh`) + `a-z 0-9 return space tab escape left right up down
comma period slash semicolon quote leftbracket rightbracket backslash minus equal grave f1-f20`.

Scripting examples:

```sh
xanectl subscribe | while read -r ev; do echo "$ev"; done      # for a bar (SketchyBar…)
xanectl query outputs -p
xanectl rule tags 9 app-id com.spotify.client
```

## Known limitations

- **It does not move windows between native Spaces.** That requires private SkyLight APIs. Use tags and a single Space per display.
- **The native Spaces animation cannot be removed.** The Dock performs it, and skipping it requires disabling SIP (as yabai does). "Reduce motion" only swaps it for a fade. XaneWM desktops (`⌃1…9`) are tags: they switch instantly, with no animation.
- **`⌃1…9` clashes with Mission Control's "Switch to Desktop N"** if you have it enabled: macOS keeps the key. Turn it off in System Settings → Keyboard → Keyboard Shortcuts → Mission Control. XaneWM warns in its menu when it detects a clash.
- **It uses a single private call:** `_AXUIElementGetWindow`, to give each window a stable identity shared with `CGWindowList`. yabai, AeroSpace, Amethyst and Rectangle use it, and it has been stable for years. Everything else is public API and does not require disabling SIP.
- **Stage Manager:** tiling pauses while it is active, same as Shoji.
- **Native fullscreen:** the window moves to its own Space and leaves the tiling. `fullscreen` (⌃⌥F) is the compositor's alternative.
- **Carbon hotkeys:** they do not work while another app uses Secure Input (password fields). This is a system restriction.
