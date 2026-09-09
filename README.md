# 🗣️ Speaker Corners

> Four corners. One lightweight, fully click-through Omarchy plugin.
> Hot corners that **speak** — and a floating command center that listens.

**Speaker Corners** mashes a float bar (top-left), a floating workspace switcher
(bottom-right) and hot-corner actions (including the Omarchy menu) into a single
masked, click-through overlay. No window stack, no bloat — one surface, `~1.5 KB`
of attitude per corner.

![izi](https://img.shields.io/badge/omarchy-ready-blueviolet)
![hyprland](https://img.shields.io/badge/hyprland-native-2ea44f)

---

## 🎯 What it does

- **🖱️ Four hot corners** — park the cursor, let a tiny dwell timer fire: open
  the float bar, summon the Omarchy menu, toggle the workspace floating strip,
  or run your own command. Everything else stays fully click-through.
- **🌆 Floating workspace strip (bottom-right)** — hover and wander between
  workspaces. Each card shows a live preview with app icons resolved straight
  from your desktop entries, an urgent dot, and a `+` to mint a new workspace.
- **🧊 Float bar (top-left)** — a compact card nerd-friendly enough to live on:
  - **🕐 A clock** that opens the real menu-bar calendar when clicked.
  - **🔋 Smart icons** — battery (with plug/AC state), Wi-Fi (signal strength),
    Bluetooth (off / on / connected) — mirroring the menu bar, live.
  - **✨ Live indicators** — night light, do-not-disturb, reminders,
    stay-awake, screen recording — with accent highlighting and click-to-toggle.
  - **🚀 Launcher actions** — 🌍 browser (`chromium`), 🖥️ terminal (`foot`),
    📄 text editor (`text`) and 📁 file manager (`nautilus`). These four
    commands are **hardcoded** in the plugin — see below.
  - **🧲 Draggable grid** — drag any tile to reorder it; the layout is persisted
    to your `shell.json` and comes back exactly where you left it.
  - **🧘 Toggle button** — show/hide the menu bar itself.

---

## 📦 Installation

```sh
git clone https://github.com/nagualcode/speakercorners \
  ~/.config/omarchy/plugins/speakercorners
```

Restart the shell (or just enjoy the hot-reload):

```sh
omarchy restart shell
```

## ⚙️ Configuration

Settings live in the `speakercorners` entry of
`~/.config/omarchy/shell.json`, for example:

```jsonc
{
  "id": "speakercorners",
  "enabled": true,
  "dwellMs": 139,          // how long the pointer must rest to fire (120–3000)
  "targetSize": 8,         // hot-corner hitbox, in px
  "clockFormat": "dddd HH:mm",
  "cardWidth": "auto",     // or a fixed px width
  "topLeftAction": "command",
  "topLeftCommand": "omarchy-shell floatbar toggle",
  "bottomLeftAction": "command",
  "bottomLeftCommand": "omarchy menu",
  "bottomRightAction": "command",
  "bottomRightCommand": "omarchy-shell workspace-overview toggle",
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

The float-bar launcher grid ships with four buttons whose commands are
**hardcoded** in `Speakercorners.qml` (the `actionEntries` array). They are
not configurable via `shell.json`:

| Icon | Label | Command |
| ---- | ----- | ------- |
| 🌍 | Browser | `chromium` |
| 🖥️ | Terminal | `foot` |
| 📄 | Text | `text` |
| 📁 | Folder | `nautilus` |

Edit `actionEntries` to change them.

### Corner actions

| Key                 | values                                              |
| ------------------- | --------------------------------------------------- |
| `topLeftAction`     | `command` / `none` — float bar toggle by default    |
| `topRightAction`    | `command` / `none` — nothing by default             |
| `bottomLeftAction`  | `command` / `none` — Omarchy menu by default        |
| `bottomRightAction` | `command` / `none` — workspace strip by default     |

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
- A **Nerd Font** on the system (default: `JetBrainsMono Nerd Font`) for all the
  fancy glyphs

## 🧱 Roof tiles

- `Speakercorners.qml` — the whole single-surface overlay
- `IconModel.js` — app icon resolution for the workspace cards (a faithful
  subset of Omarchy's HUD model)
- `Workspaces.js` — Hyprland → plain-JS workspace model builder

## 🚗 License

MIT — go ahead, remix the corners. 🛹