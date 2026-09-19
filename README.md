# 🗣️ Speaker Corners

> Three corners. One lightweight, fully click-through Omarchy plugin.
> Hot corners that **speak** — and a floating command center that listens.

**Speaker Corners** mashes an icon panel (bottom-left), a floating workspace switcher
(bottom-center) and hot-corner actions (Omarchy menu, app dropdowns) into a
single masked, click-through overlay. No window stack, no bloat — one surface,
`~1.5 KB` of attitude per corner.

![izi](https://img.shields.io/badge/omarchy-ready-blueviolet)
![hyprland](https://img.shields.io/badge/hyprland-native-2ea44f)

![preview](preview.jpg)
---

## 🎯 What it does

- **🖱️ Five hot corners** — park the cursor, let a tiny dwell timer fire: summon
  the Omarchy menu, toggle the icon panel, toggle the workspace floating strip,
  toggle the WhatsApp dropdown, or run your own command. Everything else stays
  fully click-through.
- **🌆 Floating workspace strip (bottom-center)** — one quarter of the bottom
  edge's width, centered; hover and wander between workspaces. Each card is a
  live preview whose app icons fill the cell (a single app gets the whole tile,
  macOS-Dock style), plus an urgent dot in the corner, and a `+` to mint a new
  workspace. A small triangle at the strip's base points up at the active
  workspace. Its distance to the screen bottom is set by `wsStripGap` (a `Gap`
  slider in the settings popup).
  By default the icons are drawn as flat, theme-colored glyphs; flip
  `wsStripRealIcons` (or the **Real icons** toggle in the settings popup) to
  render the actual, full-color app icons instead — which also drops the tile
  background/border for a bare, Dock-like look.
  The small triangle pointing at the active workspace doubles as its close
  button: hovering turns it into an **×** and clicking closes the workspace
  (every window on it). While it points at the empty/new workspace (`+`) there
  is nothing to close, so it stays a plain triangle.
  The **apps button** at the right of the strip opens the Omarchy menu
  straight into the applications list with a left-click and a terminal with a
  right-click. Its glyph is the solid 2×2 grid `fa-th` (U+F00A) drawn from
  **Font Awesome 7 Free Solid** in the theme accent color — no card
  background, so it stays a bare, fully-opaque icon that tracks the current
  theme (a previous `nf-md-apps`/U+F0192 attempt fell back to a clipboard
  glyph because the installed Nerd Font does not carry it).
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

Settings live in the `speakercorners` entry of
`~/.config/omarchy/shell.json`, for example:

```jsonc
{
  "id": "nagualcode.speakercorners",
  "enabled": true,
  "dwellMs": 139,          // how long the pointer must rest to fire (120–3000)
  "targetSize": 8,         // hot-corner hitbox, in px
  "animations": true,      // false to disable the icon-panel / workspace-strip slide
  "clockFormat": "dddd HH:mm",
  "cardWidth": "auto",     // or a fixed px width
  "topLeftAction": "command",
  "topLeftCommand": "omarchy menu",
  "topRightAction": "toggle-window-modes",
  "topRightCommand": "",
  "bottomLeftAction": "toggle-hide-chrome",
  "bottomLeftCommand": "",
  "bottomRightAction": "command",
  "bottomRightCommand": "omarchy-shell io.github.moizibnyousaf.omawhatsapp toggleDropdown '{}'",
  "bottomCenterAction": "command",
  "bottomCenterCommand": "omarchy-shell workspace-overview toggle",
  "wsScale": 0.5,           // workspace strip scale (height multiplier)
  "wsStripGap": 21,         // gap between the strip and the screen bottom
  "wsStripRealIcons": false, // true = real, full-color app icons in the cards
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
| `topLeftAction`     | `command` / `none` — Omarchy menu toggle by default     |
| `topRightAction`    | `command` / `toggle-window-modes` / `none` — window-mode toggle by default |
| `bottomLeftAction`  | `command` / `toggle-hide-chrome` / `none` — hide-chrome toggle by default |
| `bottomRightAction` | `command` / `none` — WhatsApp dropdown by default   |
| `bottomCenterAction`| `command` / `none` — workspace strip by default     |

`toggle-window-modes` cycles the active workspace between everything-tiled
and everything-floating. When going tiled it also understands that a
fullscreen/maximized window would keep swallowing the split: with more than
one window on the workspace it pulls such a window back out of fullscreen so
the screen genuinely divides between the apps. `toggle-hide-chrome` hides the
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
- `IconModel.js` — app icon resolution for the workspace cards (a faithful
  subset of Omarchy's HUD model)
- `Workspaces.js` — Hyprland → plain-JS workspace model builder

## 🚗 License

MIT — go ahead, remix the corners. 🛹
