# 🗣️ Speaker Corners

> Three corners. One lightweight, fully click-through Omarchy plugin.
> Hot corners that **speak** — and a floating command center that listens.

**Speaker Corners** mashes an icon panel (bottom-left), a floating workspace switcher
(bottom-center), a smart app grid and hot-corner actions (Omarchy menu, app
dropdowns) into a single masked, click-through overlay. No window stack, no
bloat — one surface, `~1.5 KB` of attitude per corner.

![izi](https://img.shields.io/badge/omarchy-ready-blueviolet)
![hyprland](https://img.shields.io/badge/hyprland-native-2ea44f)

![preview](preview.jpg)
---

## 🎯 What it does

- **🖱️ Five hot corners** — park the cursor, let a tiny dwell timer fire: summon
  the workspace overview, toggle window modes, toggle the icon panel, toggle the
  workspace floating strip, or run your own command. Everything else stays
  fully click-through.
- **🗺️ Workspace overview (bottom-right)** — a port of the Mirador workspace
  overview (`mirador/`), summoned straight from a hot corner. It keeps its own
  full-screen overlay surface (exclusive keyboard focus while open) and dims the
  desktop behind it with the same scrim the Omarchy menu uses.
  The bottom-right corner opens a **current-workspace window viewer**: only the
  windows of the workspace you are on, no workspace cards, no workspace-number
  badge and no grid — the windows are packed like macOS **Exposé**, so all of them
  are visible at once, none overlaps another, and each keeps its real aspect
  ratio (floating windows that cover each other on the desktop are pulled apart
  here so you can always click the one you want). It is previews only (there is
  no "app icons first, then previews" flash), and clicking a window brings it to
  the top of the stack. The corner is a plain toggle: press it again to close.
  The full multi-workspace overview is still one `Super` press (or a 3-finger
  swipe up) away, and `omarchy-shell mirador toggle` opens it directly.
  It is addressed by the `mirador` corner action or `omarchy-shell mirador toggle`.
- **🌆 Floating workspace strip (bottom-center)** — one quarter of the bottom
  edge's width, centered; hover and wander between workspaces. Each card is a
  live preview whose app icons fill the cell (a single app gets the whole tile,
  macOS-Dock style), plus an urgent dot in the corner, and a `+` to mint a new
  workspace. A small triangle at the strip's base points up at the active
  workspace. Its distance to the screen bottom is set by `wsStripGap` (a `Gap`
  slider in the settings popup).
  Clicking a card switches workspaces **instantly** (`wsInstantSwitch`, on by
  default, toggled in the same popup): the strip suppresses Hyprland's
  animations just long enough for the compositor to warp the switch into
  place, so no slide plays. Every other workspace change — the touchpad
  gesture, keybinds, the `+` button — keeps the animated macOS-style
  transition configured in `~/.config/hypr/looknfeel.lua`.
  While a window on the focused monitor is fullscreen the strip steps aside
  (Hyprland fades the bar's Top layer but not the Overlay layer the strip lives
  on, so it hides itself); a pinned strip comes back when fullscreen exits.
  Workspace cards always render the actual, full-color app icons; the tile
  background/border is dropped for a bare, Dock-like look
  (`wsStripRealIcons` is always on — there is no generic glyph fallback).
  The small triangle pointing at the active workspace doubles as its close
  button: hovering turns it into an **×** and clicking closes the workspace
  (every window on it). While it points at the empty/new workspace (`+`) there
  is nothing to close, so it stays a plain triangle.
  The **apps button** at the right of the strip opens a **smart app grid** with
  a left-click and a terminal with a right-click. Its glyph is the solid 2×2
  grid `fa-th` (U+F00A) drawn from **Font Awesome 7 Free Solid** in the theme
  accent color — no card background, so it stays a bare, fully-opaque icon that
  tracks the current theme (a previous `nf-md-apps`/U+F0192 attempt fell back to
  a clipboard glyph because the installed Nerd Font does not carry it).
- **🧲 Smart app grid** — left-clicking the apps button no longer borrows the
  Omarchy menu; it opens a launcher of its own, built from the exact same app
  library so it lists every app the menu lists. Six square cells per row with
  big icons and the name underneath; the grid's bottom is parked just above the
  strip. It shows a single row by default; raise `appMenuRows` (1–6) for a
  taller grid, which grows upward so it never covers the strip.
  **The apps you actually use float to the front**: the most recently opened
  app comes first, ties break by how often you have opened it, and apps you have
  never opened follow alphabetically. Typing filters the grid with the same fuzzy
  search the Omarchy menu uses (ranking is left alone while you type, so the
  matches read like the menu's). Arrows move (and wrap), `Enter` launches,
  `Esc` clears the search and then closes, `PageUp`/`PageDown`/`Home`/`End`
  scroll, the wheel scrolls, and clicking outside dismisses it.
  The ranking is remembered across reboots in
  `${XDG_STATE_HOME:-~/.local/state}/speakercorners/app-usage.json` (max 400
  apps). Bind it to a key with `omarchy-shell speakercorners-apps toggle`.
- **🧊 Icon panel (bottom-left)** — a compact card nerd-friendly enough to live on:
  - **🕐 A clock** that opens the real menu-bar calendar when clicked.
  - **🔋 Smart icons** — battery (with plug/AC state), Wi-Fi (signal strength),
    Bluetooth (off / on / connected) — mirroring the menu bar, live.
  - **✨ Live indicators** — night light, do-not-disturb, reminders,
    stay-awake, screen recording — with accent highlighting and click-to-toggle.
  - **🚀 Launcher actions** — 🌍 browser, 🖥️ terminal and 📁 file manager use
    your system defaults via the `uwsm` session (`uwsm-app`); the browser opens
    in **normal mode** through its `.desktop` entry (`gtk-launch`). 📄 the text
    editor opens floating FeatherPad through Hyprland's own executor.
  - **🧲 Draggable grid** — drag any tile to reorder it; the layout is persisted
    to your `shell.json` and comes back exactly where you left it.
  - **🧘 Toggle button** — show/hide the menu bar itself.

---

## 📦 Installation

omarchy plugin add https://github.com/nagualcode/omarchy-speakercorners.git --enable


```sh
omarchy restart shell
```

## Removal
omarchy plugin remove nagualcode.speakercorners

## ⚙️ Configuration

Settings live in a `plugins` entry in `~/.config/omarchy/shell.json`
(`"id": "speakercorners"` — the plugin only reads the entry whose id matches
that exact string). Every key is optional and falls back to a default, so the
minimum entry is just `{ "id": "speakercorners" }`. The full form, for
example:

```jsonc
{
  "id": "speakercorners",
  "enabled": true,
  "dwellMs": 139,          // how long the pointer must rest to fire (120–3000)
  "targetSize": 8,         // hot-corner hitbox, in px
  "animations": true,      // false to disable the icon-panel / workspace-strip slide
  "clockFormat": "dddd HH:mm",
  "cardWidth": "auto",     // or a fixed px width
  "topLeftAction": "cascade-floats",
  "topLeftCommand": "",
  "topRightAction": "toggle-window-modes",
  "topRightCommand": "",
  "bottomLeftAction": "toggle-hide-chrome",
  "bottomLeftCommand": "",
  "bottomRightAction": "mirador",
  "bottomRightCommand": "",
  "bottomCenterAction": "command",
  "bottomCenterCommand": "omarchy-shell workspace-overview toggle",
  "wsScale": 0.5,           // workspace strip scale (height multiplier)
  "wsStripGap": 21,         // gap between the strip and the screen bottom
  "appMenuRows": 1,         // rows of icons in the smart app grid (1–6)
  "wsStripRealIcons": true, // always real, full-color app icons in the cards
  "wsInstantSwitch": true,  // card clicks switch workspace with no animation
  "floatGridOrder": [
    "action:browser",
    "action:terminal",
    "action:text",
    "action:folder",
    "toggle:toggle",
    "indicator:NightLight",
    "indicator:Dnd",
    "indicator:Reminder",
    "indicator:StayAwake",
    "indicator:ScreenRecording",
    "widget:omarchy.bluetooth",
    "widget:omarchy.network",
    "widget:omarchy.audio",
    "widget:omarchy.monitor",
    "widget:omarchy.power"
  ]
}
```

### Launcher actions (hardcoded)

The float-bar launcher grid ships with four buttons. All of them are attached
to the `uwsm` Wayland session via `uwsm-app` so they reliably surface a window.
The browser is launched through its `.desktop` entry with `gtk-launch`, which
opens the system default browser in **normal mode** (Omarchy's
`omarchy launch browser` forces incognito, so it's skipped). The text editor
is dispatched by Hyprland itself so FeatherPad always opens as a floating
window:

| Icon | Label | Command |
| ---- | ----- | ------- |
| 🌍 | Browser | `uwsm-app -- gtk-launch <default browser>.desktop` (normal mode) |
| 🖥️ | Terminal | `omarchy launch terminal` (system default terminal) |
| 📄 | Text | `hyprctl eval 'hl.dispatch(hl.dsp.exec_cmd("featherpad", { float = true }))'` |
| 📁 | Folder | `omarchy launch nautilus` (system default file manager) |

Edit `actionEntries` to change them.

### Corner actions

| Key                 | values                                              |
| ------------------- | --------------------------------------------------- |
| `topLeftAction`     | `command` / `cascade-floats` / `toggle-window-modes` / `none` — cascade-floats by default |
| `topRightAction`    | `command` / `toggle-window-modes` / `none` — window-mode toggle by default |
| `bottomLeftAction`  | `command` / `toggle-hide-chrome` / `none` — hide-chrome toggle by default |
| `bottomRightAction` | `command` / `mirador` / `none` — workspace overview by default |
| `bottomCenterAction`| `command` / `none` — workspace strip by default     |

`toggle-window-modes` arranges the active workspace by majority instead of
blindly flipping: if every window floats it goes tiled, if every window is tiled
it goes floating, and a mixed workspace follows the majority (the minority
windows are converted; a tie resolves to tiled). When going tiled it also
understands that a fullscreen/maximized window would keep swallowing the split:
with more than one window on the workspace it pulls such a window back out of
fullscreen so the screen genuinely divides between the apps.
`cascade-floats` pulls every mapped window on the active workspace out of
tiling (and out of fullscreen/maximize) and lays them out as a **heuristic
cascade**: each one floats at 700×500 and slides one step right-and-down from
the window before it. The two steps adapt to how crowded the workspace is
(40–110px horizontal, 30–80px vertical) and wrap modulo the free space, so once
the diagonal runs off an edge it continues from a shifted row; because the
steps are always coprime with the free extents, no two windows ever land on the
exact same corner, so a covered window always keeps a visible sliver under the
one on top. The layout is idempotent: re-dwelling the corner just re-runs it.
`toggle-hide-chrome` hides the
workspace strip, bar and panel layer (bottom-left corner); both can also be
triggered over IPC with `omarchy-shell speakercorners triggeraction <name>`.

Each `*Command` runs via `bash -lc`, so `omarchy-*` helpers and your shell
niceties are all fair game.

### Drag order

`floatGridOrder` is written automatically when you drag tiles, so you usually
never touch it by hand. New launcher actions appear at the front until you pin
them somewhere.

---

## 🦾 Requirements

- **Omarchy** (shell + `omarchy-shell` IPC)
- **Hyprland** (native `WlrLayershell` + Hyprland IPC)
- A **Nerd Font** on the system (default: `JetBrainsMono Nerd Font`) for the
  advanced glyphs
- **Font Awesome 7 Free** (shipped with Omarchy) for the app-grid launcher icon

## 🧱 Roof tiles

- `Speakercorners.qml` — the whole single-surface overlay
- `AppLauncherMenu.qml` — the smart app grid (search, square cells, keynav)
- `AppUsage.js` — app ranking model (most recent first) + JSON persistence
- `IconModel.js` — app icon resolution for the workspace cards (a faithful
  subset of Omarchy's HUD model)
- `Workspaces.js` — Hyprland → plain-JS workspace model builder

## 🚗 License

MIT — go ahead, remix the corners. 🛹
