# 🗣️ Speaker Corners

> Three corners. One lightweight, fully click-through Omarchy plugin.
> Hot corners that **speak** — and a floating command center that listens.

**Speaker Corners** mashes an icon panel (bottom-left), a floating workspace
overview and hot-corner actions (Omarchy menu, app dropdowns, window layout
commands) into a single masked, click-through overlay. No window stack, no
bloat — one surface, `~1.5 KB` of attitude per corner.

> 📦 **The workspace strip, its settings popup and the smart app grid moved out
> into their own plugin — [nagualstrip](https://github.com/nagualcode/omarchy-nagualstrip).**
> Install both to keep the pre-split behaviour (see
> [Migration](#-migration-from-v1-when-the-strip-lived-here)).

![izi](https://img.shields.io/badge/omarchy-ready-blueviolet)
![hyprland](https://img.shields.io/badge/hyprland-native-2ea44f)

![preview](preview.jpg)
---

## 🎯 What it does

- **🖱️ Five hot corners** — park the cursor, let a tiny dwell timer fire: summon
  the workspace overview, toggle window modes, toggle the icon panel, or run
  your own command (the bottom-center corner ships
  `omarchy-shell workspace-overview toggle`, which is how the separate
  `nagualstrip` plugin is summoned from the corners). Everything else stays
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
- **🌆 Workspace strip + app grid → nagualstrip** — the floating workspace
  strip (bottom-center), its right-click settings popup and the smart
  MRU-ranked app grid moved out to their own plugin:
  [`nagualstrip`](https://github.com/nagualcode/omarchy-nagualstrip), on their
  own Overlay window. Speaker Corners still drives them over IPC — the
  bottom-left `toggle-hide-chrome` corner fades the strip together with the bar,
  opening the icon panel suspends it, and closing the panel restores exactly
  what was on screen — but this plugin no longer draws any of it.
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

```sh
omarchy plugin add https://github.com/nagualcode/omarchy-speakercorners.git --enable
omarchy restart shell
```

### Removal

```sh
omarchy plugin remove nagualcode.speakercorners
```

## 📦 Migration from v1 (when the strip lived here)

Speaker Corners **2.0** is hot corners + icon panel + workspace overview only.
The workspace strip, its settings popup, the smart app grid and the `ws*`
config keys moved out to their own plugin,
[nagualstrip](https://github.com/nagualcode/omarchy-nagualstrip).

| Before (v1)                                                       | Now                                                                    |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `ws*`, `appMenuRows` keys in the `speakercorners` entry           | same keys in a `nagualcode.nagualstrip` entry                          |
| `.../.local/state/speakercorners/app-usage.json` (app ranking)    | `.../.local/state/nagualstrip/app-usage.json`                          |
| `~/.config/omarchy/.speakercorners-reserve`                       | `~/.config/omarchy/.nagualstrip-reserve` — `monitors.lua` must read it |
| `omarchy-shell speakercorners-apps toggle`                        | still works — legacy target kept by `nagualstrip`                      |
| `omarchy-shell workspace-overview toggle`                         | still works — legacy target kept by `nagualstrip`                      |

```sh
omarchy plugin add https://github.com/nagualcode/omarchy-nagualstrip.git --enable
# keep the app-grid ranking and the bottom reserved area
mv "${XDG_STATE_HOME:-~/.local/state}/speakercorners" \
   "${XDG_STATE_HOME:-~/.local/state}/nagualstrip" 2>/dev/null
mv ~/.config/omarchy/.speakercorners-reserve \
   ~/.config/omarchy/.nagualstrip-reserve 2>/dev/null
omarchy restart shell
```

Then point `~/.config/hypr/monitors.lua` at `.nagualstrip-reserve` — the
snippet is in the [nagualstrip README](https://github.com/nagualcode/omarchy-nagualstrip#bottom-reserved-area).
The `wsToggleEnabled` key (read from the strip plugin's entry) still gates the
bottom-center corner, so a pinned strip keeps that corner inert.

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
  "animations": true,      // false to disable the icon-panel slide
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
| `bottomCenterAction`| `command` / `none` — `omarchy-shell workspace-overview toggle` by default, i.e. the separate `nagualstrip` plugin's strip. With only this plugin installed it is just a command you can rebind; the strip itself lives in [nagualstrip](https://github.com/nagualcode/omarchy-nagualstrip) |

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
`toggle-hide-chrome` hides the bar and panel layer and, when
[nagualstrip](https://github.com/nagualcode/omarchy-nagualstrip) is installed,
fades its workspace strip together with them: it fires
`omarchy-shell nagualstrip setchrome on` over IPC, the strip hides at once and
flashes back on the next workspace switch (bottom-left corner). Any action can
also be triggered over IPC with
`omarchy-shell speakercorners triggeraction <name>`.

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
- Optional: [nagualstrip](https://github.com/nagualcode/omarchy-nagualstrip)
  for the workspace strip / app grid the bottom-center corner drives

## 🧱 Roof tiles

- `Speakercorners.qml` — the whole single-surface overlay: hot corners, the
  icon panel and the embedded workspace overview
- `IconModel.js` — app icon resolution (a faithful subset of Omarchy's HUD model)
- `mirador/` — the ported workspace overview (has its own README)

## 🚗 License

MIT — go ahead, remix the corners. 🛹
