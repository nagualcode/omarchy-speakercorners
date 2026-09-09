import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Workspaces.js" as WorkspaceModel
import "IconModel.js" as IconModel

// Speaker Corners — everything the corner of the screen does, in one plugin.
//
// One always-mapped fullscreen Overlay window holds:
//   * embedded hot-corner recognition (top-left / bottom-left / bottom-right)
//   * the float bar card          (top-left, no backdrop)
//   * the floating workspace switcher strip (bottom-right)
// plus keyboard focus for the float bar. The window's `mask` only admits input
// where something interactive lives, so the desktop stays fully click-through
// everywhere else.
//
// Previously these were separate plugins (floatbar, workspaces-float) plus the
// quattro-corners service. This single masked surface replaces them all.
//
// Configuration lives in shell.json in the plugin's own entry:
//   "plugins": [
//     { "id": "speakercorners",
//       "dwellMs": 139, "targetSize": 8,
//       "topLeftAction": "command",  "topLeftCommand": "omarchy-shell floatbar toggle",
//       "topRightAction": "none",    "topRightCommand": "",
//       "bottomLeftAction": "command","bottomLeftCommand": "omarchy menu",
//       "bottomRightAction": "command","bottomRightCommand": "omarchy-shell workspace-overview toggle" }
//   ]
Item {
  id: root

  // Injected by the shell panel loader.
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property string omarchyPath: ""

  // ---- Per-surface open state -------------------------------------------
  property bool floatbarOpened: false
  property bool workspacesOpened: false

  readonly property bool anyOpen: root.floatbarOpened || root.workspacesOpened
  // The shell's isPluginOpen() reads `opened` off the loaded item; keep it in
  // sync so `omarchy-shell shell toggle speakercorners` round-trips cleanly.
  readonly property bool opened: root.anyOpen
  // The float bar takes full-screen keyboard focus; the workspace strip only
  // swallows clicks through the mask and never needs the keyboard.
  readonly property bool keysWanted: root.floatbarOpened

  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  // ---- Hot-corner settings (read from the plugins[] entry) ---------------
  property var pluginSettings: ({})
  property bool configLoaded: false
  property int dwellMs: 139
  property int targetSize: 8
  property bool cornersEnabled: true

  // Persisted order of the float-bar grid cells (drag to reorder).
  property var gridOrder: []

  function setting(key, fallback) {
    var value = root.pluginSettings[key]
    return value === undefined || value === null ? fallback : value
  }

  function actionFor(edge) {
    if (edge === "top-left") return String(setting("topLeftAction", "command"))
    if (edge === "top-right") return String(setting("topRightAction", "none"))
    if (edge === "bottom-left") return String(setting("bottomLeftAction", "command"))
    if (edge === "bottom-right") return String(setting("bottomRightAction", "command"))
    return "none"
  }

  function commandFor(edge) {
    if (edge === "top-left") return String(setting("topLeftCommand", "omarchy-shell floatbar toggle"))
    if (edge === "top-right") return String(setting("topRightCommand", ""))
    if (edge === "bottom-left") return String(setting("bottomLeftCommand", "omarchy menu"))
    if (edge === "bottom-right") return String(setting("bottomRightCommand", "omarchy-shell workspace-overview toggle"))
    return ""
  }

  function readConfig() {
    var cfg = ({})
    var list = root.userShellConfig.plugins
    if (!Array.isArray(list) && shell && shell.shellConfig && Array.isArray(shell.shellConfig.plugins))
      list = shell.shellConfig.plugins
    if (Array.isArray(list)) {
      for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].id) === "speakercorners") { cfg = list[i]; break }
      }
    }
    root.pluginSettings = cfg
    var order = root.setting("floatGridOrder", [])
    root.gridOrder = Array.isArray(order) ? order.slice() : []
    root.dwellMs = Math.max(120, Math.min(3000, Number(setting("dwellMs", 139) || 139)))
    root.targetSize = Math.max(4, Math.min(120, Number(setting("targetSize", 8) || 8)))
    root.cornersEnabled = setting("enabled", true) !== false
    root.configLoaded = true
  }

  // Reads the plugin's own entry straight from ~/.config/omarchy/shell.json.
  // The injected shell facade has no shell.shellConfig, so without this the
  // plugin would only ever see defaults.
  readonly property string userConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  property var userShellConfig: ({})
  function parseUserConfig(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      return Util.isPlainObject(parsed) ? parsed : ({})
    } catch (e) { return ({}) }
  }
  FileView {
    id: userShellFile
    path: root.userConfigPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var str = String(text() || "")
      // Ignore the echo of our own persistGridOrder write: the drag already
      // applied the new order in-memory, and a stale re-read would revert it.
      if (str !== "" && str === root.lastWrittenShellText) return
      root.userShellConfig = root.parseUserConfig(str)
      if (root.configLoaded) {
        root.readConfig()
        if (root.floatbarOpened) root.refreshWidgetEntries()
      }
    }
    onLoadFailed: root.userShellConfig = ({})
  }
  // Content we last pushed via persistGridOrder (see the onLoaded guard).
  property string lastWrittenShellText: ""

  // Notification history toggle state (reused by the "notifications" action).
  property bool historyShown: false
  Timer {
    id: historyReset
    interval: 12000
    repeat: false
    onTriggered: root.historyShown = false
  }

  // Run a corner action. Commands that target this plugin's own surfaces are
  // dispatched straight to the matching toggle (no subprocess); everything
  // else falls back to `sh -lc`.
  function run(cmd) {
    var text = String(cmd || "").trim()
    if (text.length === 0) return
    if (root.internalCommand(text)) return
    Quickshell.execDetached(["sh", "-lc", text])
  }

  function internalCommand(cmd) {
    var tokens = String(cmd || "").split(/\s+/)
    if (tokens[0] !== "omarchy-shell") return false
    var target = tokens[1]
    var method = tokens[2]
    if (target === "floatbar") {
      if (method === "toggle") { root.toggleFloatbar() } else if (method === "open") { root.openFloatbar("") } else if (method === "close") { root.closeFloatbar() } else return false
      return true
    }
    if (target === "workspace-overview") {
      if (method === "toggle") { root.toggleWorkspaces() } else if (method === "open") { root.showWorkspaces() } else if (method === "close") { root.hideWorkspaces() } else return false
      return true
    }
    if (target === "speakercorners") {
      switch (method) {
      case "toggle": root.toggle(); break
      case "open": root.open(""); break
      case "close": root.close(); break
      default: return false
      }
      return true
    }
    return false
  }

  function trigger(action, command, edge) {
    switch (String(action)) {
    case "menu":
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.menu", '{"menu":"root"}'])
      break
    case "notifications":
      if (root.historyShown) {
        Quickshell.execDetached(["omarchy-shell", "notifications", "dismissAll"])
        root.historyShown = false
        historyReset.stop()
      } else {
        Quickshell.execDetached(["omarchy-shell", "notifications", "showHistory"])
        root.historyShown = true
        historyReset.restart()
      }
      break
    case "dnd":
      Quickshell.execDetached(["omarchy-shell", "notifications", "toggleDnd"])
      break
    case "clipboard":
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.clipboard", "{}"])
      break
    case "emojis":
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.emojis", "{}"])
      break
    case "lock":
      Quickshell.execDetached(["omarchy-shell", "lock", "lock"])
      break
    case "screen-off":
      Quickshell.execDetached(["sh", "-lc",
        "hyprctl dispatch 'hl.dsp.dpms({ state = \"off\" })' >/dev/null 2>&1"
        + " || hyprctl dispatch dpms off"])
      break
    case "command":
      root.run(command)
      break
    case "none":
    default:
      break
    }
  }

  function triggerCorner(edge) {
    root.readConfig()
    if (!root.cornersEnabled) return
    root.trigger(root.actionFor(edge), root.commandFor(edge), edge)
  }

  // ---- Shared look tokens -------------------------------------------------
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.family

  // Reactive: focused monitor for the window.
  readonly property var activeScreen: {
    var mon = Hyprland.focusedMonitor
    var name = mon ? String(mon.name || "") : ""
    var screens = Quickshell.screens
    if (name.length > 0) {
      for (var i = 0; i < screens.length; i++) {
        if (String(screens[i].name || "") === name) return screens[i]
      }
    }
    return screens.length > 0 ? screens[0] : null
  }

  // ========================================================================
  //  FLOATING BAR (top-left)
  // ========================================================================
  readonly property color cardColor: "#000000"
  readonly property color cardBorder: Color.accent
  readonly property color cardText: Color.popups.text

  // ---- Widgets that never appear in the floatbar ----
  readonly property var removedWidgetIds: [
    "omarchy.keyboard-layout",
    "omarchy.agents",
    "omarchy.tray",
    "omarchy.indicators"
  ]

  // ---- Widgets rendered live inside the floatbar instead of an icon button ----
  // The clock is drawn by our own ClockRow (click opens the bar's calendar via
  // the omarchy.clock IPC target, so the popup anchors exactly like the bar).
  readonly property bool hasClockWidget: {
    for (var i = 0; i < root.widgetEntries.length; i++)
      if (String(root.widgetEntries[i].id) === "omarchy.clock") return true
    return false
  }

  // Latest "omarchy-update-available" verdict: pending updates show an extra
  // grid button (system-update), mirroring the menu bar behaviour.
  property bool systemUpdateAvailable: false
  function checkSystemUpdate() {
    if (root.systemUpdateProc && !root.systemUpdateProc.running) root.systemUpdateProc.running = true
  }
  Process {
    id: systemUpdateProc
    command: ["omarchy-update-available"]
    onExited: function(exitCode) {
      var next = exitCode === 0
      if (next !== root.systemUpdateAvailable) {
        root.systemUpdateAvailable = next
        if (root.floatbarOpened) root.refreshWidgetEntries()
      }
    }
  }
  Timer {
    interval: 21600000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkSystemUpdate()
  }

  // One combined poll for every live indicator; each line below is one output.
  Process {
    id: indicatorsQuery
    command: ["bash", "-lc",
      "p() { \"$@\" 2>/dev/null; }; "
      + "printf '%s\\n' \"$(p omarchy-shell nightlight status)\"; "
      + "printf '%s\\n' \"$(p omarchy-shell notifications dndState)\"; "
      + "printf '%s\\n' \"$(p omarchy-shell idle status)\"; "
      + "printf '%s\\n' \"$(p omarchy-reminder show --json)\"; "
      + "if pgrep --quiet -f '^gpu-screen-recorder'; then echo 1; else echo 0; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyIndicatorPoll(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.applyIndicatorPoll("")
    }
  }

  Timer {
    id: indicatorRefreshTimer
    interval: 300
    repeat: false
    onTriggered: root.pollIndicators()
  }

  // Keeps indicator highlights live while the float bar is open.
  Timer {
    interval: 5000
    running: root.floatbarOpened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollIndicators()
  }

  // Closes/opens the menu-bar calendar like a click on the bar's own clock.
  function toggleCalendar() {
    Quickshell.execDetached(["omarchy-shell", "omarchy.clock", "toggle"])
  }

  // Live system mirrors, so the floatbar icons behave like the bar icons:
  // no polling — the service singletons notify and the bindings re-evaluate.
  readonly property bool batteryPresent: {
    var d = UPower.displayDevice
    return !!(d && d.isPresent)
  }

  readonly property var indicatorEntries: [
    { id: "NightLight", glyph: "󰔎" },
    { id: "Dnd", glyph: "󰂛" },
    { id: "Reminder", glyph: "󰢌" },
    { id: "StayAwake", glyph: "󰅶" },
    { id: "ScreenRecording", glyph: "󰻂" }
  ]

  property var widgetEntries: []
  property var buttonEntries: []

  // App-launcher actions shown in the grid (draggable like everything else).
  // Browser/terminal/folder go through Omarchy's default-app launchers or the
  // uwsm-app-attached desktop entry (gtk-launch), so a bare binary spawn from
  // this overlay never surfaces a window. The browser is launched through its
  // .desktop entry on purpose — this skips omarchy-launch-browser's forced
  // incognito mode and opens the system default browser normally. The text
  // editor is dispatched by Hyprland itself so it always opens floating.
  readonly property var actionEntries: [
    { id: "browser", glyph: "\uf0ac", label: "Browser", command: ["sh", "-lc", "b=\"$(env -u BROWSER xdg-settings get default-web-browser 2>/dev/null)\"; [ -z \"$b\" ] && b=\"$(xdg-mime query default x-scheme-handler/https)\"; setsid uwsm-app -- gtk-launch \"$b\""] },
    { id: "terminal", glyph: "\uf120", label: "Terminal", command: ["omarchy-launch-terminal"] },
    { id: "text", glyph: "\uf15c", label: "Text", command: ["hyprctl", "eval", "hl.dispatch(hl.dsp.exec_cmd(\"featherpad\", { float = true }))"] },
    { id: "folder", glyph: "\uf07b", label: "Folder", command: ["omarchy-launch-nautilus"] }
  ]

  readonly property int buttonTileSize: Math.max(Style.space(46), Style.font.iconLarge + Style.space(18))
  readonly property int cellSpacing: Style.space(10)

  // Every cell of the single icon grid: indicators, launcher actions, widget
  // buttons, then the bar-toggle button. Built in refreshWidgetEntries().
  property var gridCells: []

  readonly property int gridCols: {
    var n = root.gridCells.length
    return n <= 0 ? 1 : Math.ceil(Math.sqrt(n))
  }

  readonly property int computedContentWidth: {
    var grid = root.gridCols * root.buttonTileSize + Math.max(0, root.gridCols - 1) * root.cellSpacing
    return Math.max(Style.space(240), grid)
  }

  readonly property int gridRows: {
    var n = root.gridCells.length
    return n <= 0 ? 0 : Math.ceil(n / root.gridCols)
  }

  readonly property int computedGridHeight: {
    return root.gridRows * root.buttonTileSize + Math.max(0, root.gridRows - 1) * root.cellSpacing
  }

  readonly property int computedContentHeight: {
    var h = 0
    if (clockCell.visible) h += clockCell.implicitHeight
    var hasTop = clockCell.visible
    var hasGrid = root.gridCells.length > 0
    if (hasGrid) {
      if (hasTop) h += Style.space(14)
      h += root.computedGridHeight
    }
    return Math.max(Style.space(64), h)
  }

  function entrySettings(entry) {
    if (!entry || typeof entry !== "object") return ({})
    var copy = ({})
    for (var key in entry) if (key !== "id") copy[key] = entry[key]
    return copy
  }

  // The panel facade's shell.barConfig may not be populated on a cold start
  // (it is copied once from the shell while the plugins load). Reading the bar
  // layout straight from the user's shell.json instead is always correct.
  function liveBarLayout() {
    var u = root.userShellConfig
    if (u && Util.isPlainObject(u.bar) && u.bar.layout) return u.bar.layout
    if (shell && shell.barConfig && shell.barConfig.layout) return shell.barConfig.layout
    return null
  }

  function refreshWidgetEntries() {
    var entries = []
    var layout = root.liveBarLayout()
    var sections = layout ? [layout.left, layout.center, layout.right] : []
    for (var s = 0; s < sections.length; s++) {
      var arr = sections[s]
      if (!Array.isArray(arr)) continue
      for (var i = 0; i < arr.length; i++) {
        var it = arr[i]
        var id = it && it.id ? String(it.id) : ""
        if (!id) continue
        if (id === "omarchy.workspaces") continue
        if (root.removedWidgetIds.indexOf(id) !== -1) continue
        var dup = false
        for (var j = 0; j < entries.length; j++) {
          if (entries[j].id === id) { dup = true; break }
        }
        if (dup) continue
        entries.push({ id: id, settings: root.entrySettings(it) })
      }
    }
    root.widgetEntries = entries

    var btns = []
    for (var e = 0; e < entries.length; e++) {
      if (String(entries[e].id) === "omarchy.clock") continue
      btns.push(entries[e])
    }
    root.buttonEntries = btns

    // Cells in default order; drag-and-drop afterwards can reorder them and
    // the result is persisted as floatGridOrder in the plugins[] entry.
    var cells = []
    for (var ind = 0; ind < root.indicatorEntries.length; ind++) {
      var ie = root.indicatorEntries[ind]
      cells.push({ kind: "indicator", id: String(ie.id), glyph: String(ie.glyph || "") })
    }
    for (var a = 0; a < root.actionEntries.length; a++) {
      var ae = root.actionEntries[a]
      cells.push({ kind: "action", id: String(ae.id), glyph: String(ae.glyph || ""),
        label: String(ae.label || ""), command: ae.command || [] })
    }
    for (var b = 0; b < btns.length; b++) {
      if (String(btns[b].id) === "omarchy.menu") continue
      if (String(btns[b].id) === "omarchy.system-update" && !root.systemUpdateAvailable) continue
      if (String(btns[b].id) === "omarchy.power" && !root.batteryPresent) continue
      cells.push({ kind: "widget", id: String(btns[b].id), settings: btns[b].settings })
    }
    cells.push({ kind: "toggle" })
    for (var c = 0; c < cells.length; c++) cells[c].key = root.cellKeyFor(cells[c])
    root.gridCells = root.applyGridOrder(cells)
  }

  function cellKeyFor(cell) {
    return cell
      ? String(cell.kind) + ":" + (cell.id ? String(cell.id) : String(cell.kind))
      : ""
  }

  function cellGlyph(cell) {
    if (!cell) return "\uf111"
    if (cell.kind === "indicator") return root.indicatorGlyph(cell.id)
    if (cell.kind === "widget") return root.glyphFor(cell.id)
    if (cell.kind === "action") return String(cell.glyph || "\uf111")
    if (cell.kind === "toggle") return "\ue900"
    return "\uf111"
  }

  function cellGlyphFont(cell) {
    if (!cell) return root.fontFamily
    if (cell.kind === "toggle") return "omarchy"
    if (cell.kind === "widget") return root.glyphFontFor(cell.id)
    return root.fontFamily
  }

  function cellLabel(cell) {
    if (!cell) return ""
    if (cell.kind === "action") return String(cell.label || cell.id || "")
    return root.labelFor(cell.id)
  }

  function cellActive(cell) {
    if (!cell || cell.kind !== "indicator") return false
    var s = root.liveIndicatorStates
    if (cell.id === "NightLight") return s.nightLight === true
    if (cell.id === "Dnd") return s.dnd === true
    if (cell.id === "Reminder") return Number(s.reminderCount) > 0
    if (cell.id === "StayAwake") return s.stayAwake === true
    if (cell.id === "ScreenRecording") return s.screenRecording === true
    return false
  }

  function indexOfCellKey(key) {
    for (var i = 0; i < root.gridCells.length; i++) {
      if (root.gridCells[i].key === key) return i
    }
    return -1
  }

  // Reorders a freshly built cell list with the persisted order; unknown keys
  // (e.g. after a widget was removed) keep their relative default position.
  // Launcher actions not yet pinned by a drag sit at the front so the new
  // browser/terminal buttons are reachable out of the box.
  function applyGridOrder(cells) {
    if (!Array.isArray(root.gridOrder) || root.gridOrder.length === 0) return cells
    var front = []
    var ordered = []
    var rest = []
    var byKey = {}
    var used = {}
    for (var i = 0; i < cells.length; i++) byKey[cells[i].key] = cells[i]
    for (var j = 0; j < root.gridOrder.length; j++) {
      var key = String(root.gridOrder[j] || "")
      if (!byKey[key] || used[key]) continue
      ordered.push(byKey[key])
      used[key] = true
    }
    for (var k = 0; k < cells.length; k++) {
      if (used[cells[k].key]) continue
      if (String(cells[k].key).slice(0, 7) === "action:") front.push(cells[k])
      else rest.push(cells[k])
    }
    var out = front.concat(ordered).concat(rest)
    return out
  }

  // ---- Grid drag-and-drop reordering ------------------------------------
  readonly property real dragThresholdSq: Math.pow(Math.max(8, Style.space(6)), 2)
  property bool draggingGrid: false
  property string dragGridKey: ""
  property int dragGridFrom: -1
  property int dragGridTarget: -1
  // The cell currently highlighted as the drop target ("" while none). Kept as
  // an own property so GridCell can bind to it declaratively — the gridCells
  // objects are plain JS and would never notify on in-place mutation.
  property string dragHighlightKey: ""

  function beginGridDrag(key, scenePt) {
    var idx = root.indexOfCellKey(key)
    if (idx < 0) return
    root.dragGridKey = key
    root.dragGridFrom = idx
    root.dragGridTarget = idx
    root.dragHighlightKey = ""
    root.draggingGrid = true
    dragPreview.showFor(key, scenePt)
  }

  function updateGridDrag(scenePt) {
    if (!root.draggingGrid) return
    dragPreview.followScene(scenePt)
    var t = root.targetIndexForScene(scenePt)
    if (t >= 0 && t !== root.dragGridTarget) {
      root.dragGridTarget = t
    }
    root.dragHighlightKey = (t >= 0 && t !== root.dragGridFrom)
      ? String(root.gridCells[t].key)
      : ""
  }

  function endGridDrag(scenePt) {
    if (!root.draggingGrid) return
    updateGridDrag(scenePt)
    var from = root.dragGridFrom
    var to = root.dragGridTarget
    root.dragHighlightKey = ""
    root.draggingGrid = false
    dragPreview.reset()
    root.dragGridKey = ""
    root.dragGridFrom = -1
    root.dragGridTarget = -1
    if (to >= 0 && to !== from) {
      var cells = root.gridCells.slice()
      var moved = cells.splice(from, 1)[0]
      cells.splice(to, 0, moved)
      root.gridCells = cells
      root.persistGridOrder(cells)
    }
  }

  function targetIndexForScene(scenePt) {
    var n = root.gridCells.length
    if (n <= 0) return -1
    var origin = widgetGrid.mapToItem(null, 0, 0)
    var step = root.buttonTileSize + root.cellSpacing
    var col = Math.floor((scenePt.x - origin.x) / step)
    var row = Math.floor((scenePt.y - origin.y) / step)
    var effW = widgetGrid.width
    var effH = widgetGrid.height
    var pad = root.buttonTileSize * 0.4
    if (scenePt.x < origin.x - pad || scenePt.x > origin.x + effW + pad
        || scenePt.y < origin.y - pad || scenePt.y > origin.y + effH + pad) return -1
    if (col < 0) col = 0
    if (row < 0) row = 0
    var cols = root.gridCols
    var idx = col + row * cols
    if (idx >= n) idx = n - 1
    return idx
  }

  function persistGridOrder(cells) {
    var order = []
    for (var i = 0; i < cells.length; i++) order.push(cells[i].key)
    // Apply in-memory too, so the grid keeps the dragged order even though the
    // FileView echo of this write is ignored (see userShellFile.onLoaded).
    root.gridOrder = order.slice()
    var payload = JSON.stringify(root.withGridOrder(order), null, 2) + "\n"
    root.lastWrittenShellText = payload
    userShellFile.setText(payload)
  }

  function withGridOrder(order) {
    var cfg = root.parseUserConfig(userShellFile.text())
    if (!Array.isArray(cfg.plugins)) cfg.plugins = []
    var found = false
    for (var i = 0; i < cfg.plugins.length; i++) {
      if (cfg.plugins[i] && String(cfg.plugins[i].id) === "speakercorners") {
        cfg.plugins[i].floatGridOrder = order
        found = true
      }
    }
    if (!found) cfg.plugins.push({ id: "speakercorners", floatGridOrder: order })
    return cfg
  }

  function labelFor(id) {
    var meta = barWidgetRegistry ? barWidgetRegistry.metadataFor(id) : null
    if (meta && meta.displayName && String(meta.displayName).trim().length > 0)
      return String(meta.displayName)
    var short = String(id)
    var dot = short.lastIndexOf(".")
    if (dot >= 0) short = short.substr(dot + 1)
    return short.charAt(0).toUpperCase() + short.slice(1).replace(/[-_]/g, " ")
  }

  function glyphFor(id) {
    var map = {
      "omarchy.system-update": "\uf021",
      "omarchy.bluetooth": "\uf294",
      "omarchy.network": "\uf1eb",
      "omarchy.audio": "\uf028",
      "omarchy.monitor": "\uf108",
      "omarchy.power": "\uf011"
    }
    return map[id] !== undefined ? map[id] : "\uf111"
  }

  function glyphFontFor(id) {
    return id === "omarchy.menu" ? "omarchy" : root.fontFamily
  }

  function indicatorGlyph(id) {
    for (var i = 0; i < root.indicatorEntries.length; i++) {
      if (String(root.indicatorEntries[i].id) === id) return String(root.indicatorEntries[i].glyph || "\uf111")
    }
    return "\uf111"
  }

  function activateWidget(id) {
    if (id) Quickshell.execDetached(["omarchy-shell", "shell", "toggle", String(id), "{}"])
    Qt.callLater(function() { root.closeFloatbar() })
  }

  // Toggle a live indicator through its owning service's IPC and re-poll its
  // state a moment later so the highlight follows the click.
  function activateIndicator(id) {
    if (id === "NightLight") {
      Quickshell.execDetached(["omarchy-shell", "nightlight", "toggle"])
    } else if (id === "Dnd") {
      Quickshell.execDetached(["omarchy-shell", "notifications", "toggleDnd"])
    } else if (id === "StayAwake") {
      var stayAwake = root.liveIndicatorStates.stayAwake === true
      Quickshell.execDetached(["omarchy-shell", "idle", stayAwake ? "enable" : "disable"])
    } else if (id === "Reminder") {
      if (root.liveIndicatorStates.reminderCount > 0) Quickshell.execDetached(["omarchy-reminder", "show"])
      else Quickshell.execDetached(["omarchy-reminder", "-i"])
    } else if (id === "ScreenRecording") {
      var recording = root.liveIndicatorStates.screenRecording === true
      if (recording) Quickshell.execDetached(["omarchy-capture-screenrecording", "--stop-recording"])
      else Quickshell.execDetached(["omarchy-menu", "toggle", "trigger.capture.screenrecord"])
    }
    root.scheduleIndicatorRefresh(300)
  }

  // ---- Live indicator state (polled over IPC) ---------------------------
  property var liveIndicatorStates: ({
    nightLight: false, dnd: false, reminderCount: 0, reminderTooltip: "", stayAwake: false, screenRecording: false
  })

  function pollIndicators() {
    if (!indicatorsQuery.running) indicatorsQuery.running = true
  }
  function scheduleIndicatorRefresh(ms) {
    indicatorRefreshTimer.interval = Math.max(150, Number(ms || 250))
    indicatorRefreshTimer.restart()
  }
  function parseJsonSafe(text) {
    try {
      var v = JSON.parse(String(text || ""))
      return v && typeof v === "object" ? v : ({})
    } catch (e) { return ({}) }
  }
  function applyIndicatorPoll(output) {
    var lines = String(output || "").split("\n")
    var nl = root.parseJsonSafe(lines[0])
    var idl = root.parseJsonSafe(lines[2])
    var rem = root.parseJsonSafe(lines[3])
    root.liveIndicatorStates = {
      nightLight: nl.enabled === true,
      dnd: String(lines[1] || "").trim().toLowerCase() === "on",
      reminderCount: Number(rem.count || 0),
      reminderTooltip: String(rem.tooltip || ""),
      stayAwake: idl.stayAwake === true,
      screenRecording: String(lines[4] || "").trim() === "1"
    }
  }

  function toggleBar() {
    Quickshell.execDetached(["omarchy", "toggle", "bar"])
    Qt.callLater(function() { root.closeFloatbar() })
  }

  function runSystemUpdate() {
    root.closeFloatbar()
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"])
  }

  function openFloatbar(payloadJson) {
    root.readConfig()
    root.refreshWidgetEntries()
    root.pollIndicators()
    root.checkSystemUpdate()
    root.floatbarOpened = true
  }
  function closeFloatbar() { root.floatbarOpened = false }
  function toggleFloatbar() { root.floatbarOpened ? root.closeFloatbar() : root.openFloatbar("{}") }

  // ========================================================================
  //  WORKSPACES FLOAT STRIP (bottom-right)
  // ========================================================================
  property int wsDuration: 1300
  property int wsCardWidth: Style.space(112)
  property int wsCardGap: Style.space(10)
  property int wsOuterPad: Style.space(10)
  property int wsPanelMargin: Style.space(44)
  property bool wsEdgeEnabled: false
  property int wsEdgeHeight: Style.space(6)
  property var workspaces: []
  property bool ready: false
  property bool modelDirty: true
  property bool geometryRefreshPending: false
  property bool geometryRefreshInFlight: false
  property var desktopEntries: []

  readonly property int effectiveWsCardWidth: {
    var n = Math.max(1, root.workspaces.length + (root.workspaces.length > 0 ? 1 : 0))
    var screen = root.activeScreen
    var avail = screen ? screen.width : 1920
    var maxW = Math.floor((avail - root.wsPanelMargin * 2 - root.wsCardGap * (n - 1) - root.wsOuterPad * 2 - 4) / n)
    return Math.max(64, Math.min(root.wsCardWidth, maxW))
  }

  // The strip always sits centered at the bottom of the focused screen.
  readonly property int wsBorderWidth: Math.max(1, Style.space(2))
  readonly property int stripW: {
    var n = root.workspaces.length
    var cards = Math.max(1, n) + (n > 0 ? 1 : 0)
    var gaps = Math.max(0, cards - 1)
    return root.effectiveWsCardWidth * cards
      + root.wsCardGap * gaps
      + root.wsOuterPad * 2 + root.wsBorderWidth * 2
  }
  readonly property int stripH: {
    return root.wsCardPreviewH + root.wsCardLabelH + root.wsOuterPad * 2 + root.wsBorderWidth * 2
  }
  readonly property int wsCardPreviewH: Math.round(root.effectiveWsCardWidth * 9 / 16)
  readonly property int wsCardLabelH: Math.max(Style.space(12), Style.font.caption + Style.space(4))
  readonly property int stripX: Math.max(0, Math.floor((panel.width - root.stripW) / 2))
  readonly property int stripY: Math.max(0, panel.height - root.stripH - root.cardBottomMargin)

  // Bar-aware bottom margin so the strip never sits under a bottom bar.
  readonly property real cardBottomMargin: {
    var bar = shell ? shell.bar : null
    if (bar && bar.position === "bottom" && !bar.barHidden) {
      return wsPanelMargin + Number(bar.barSize || 0)
    }
    return wsPanelMargin
  }

  Timer {
    id: readyTimer
    interval: 1500
    onTriggered: root.ready = true
  }

  Component.onCompleted: {
    root.readyTimerStart()
    root.readConfig()
    root.refreshDesktopEntries()
    Qt.callLater(function() { root.refreshWidgetEntries() })
  }
  function readyTimerStart() { readyTimer.start() }

  function showWorkspaces() {
    var rebuilt = root.modelDirty
    root.ready = true
    if (rebuilt) root.refreshMainModel()
    if (root.workspaces.length === 0) {
      if (root.workspacesOpened) root.hideWorkspaces()
      return
    }
    root.workspacesOpened = true
    root.restartWorkspacesHideTimer()
  }

  function hideWorkspaces() {
    wsHideTimer.stop()
    wsSettleTimer.stop()
    root.workspacesOpened = false
  }

  function toggleWorkspaces() { root.workspacesOpened ? root.hideWorkspaces() : root.showWorkspaces() }

  function refreshDesktopEntries() {
    var next = []
    try {
      var values = DesktopEntries.applications.values || []
      for (var i = 0; i < values.length; i++) {
        if (values[i]) next.push(values[i])
      }
    } catch (error) {}
    root.desktopEntries = next
  }

  function refreshMainModel() {
    root.workspaces = WorkspaceModel.buildWorkspaces()
    root.modelDirty = false
    if (root.workspacesOpened && root.workspaces.length === 0) root.hideWorkspaces()
  }

  function requestGeometryRefresh() {
    root.geometryRefreshPending = true
    if (root.geometryRefreshInFlight) return
    root.geometryRefreshInFlight = true
    Hyprland.refreshToplevels()
    wsGeometryTimer.restart()
  }

  function restartWorkspacesHideTimer() {
    if (stripHover.hovered) wsHideTimer.stop()
    else wsHideTimer.restart()
  }

  // Escape a value as a single-line Lua string literal so it can be embedded
  // in a hyprctl Lua dispatcher expression.
  function luaStringLiteral(value) {
    return String(value || "").replace(/[\\"\x00-\x1f\x7f]/g, function(ch) {
      if (ch === "\\") return "\\\\"
      if (ch === '"') return '\\"'
      var decimal = ch.charCodeAt(0).toString()
      return "\\" + ("000" + decimal).slice(-3)
    })
  }

  // Switch to the workspace behind a clicked card. Omarchy runs Hyprland in
  // Lua mode, so workspace focus goes through the Lua dispatcher expression
  // rather than the plain "workspace <id>" dispatcher (which errors under
  // hl.dispatch wrap).
  function focusWorkspace(ws) {
    if (!ws) return
    var target = (ws.name && String(ws.name).length > 0) ? String(ws.name) : String(ws.id)
    var expr = 'hl.dsp.focus({ workspace = "' + root.luaStringLiteral(target) + '" })'
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
  }

  // Open the first empty workspace after the last used one. "Used" means a
  // workspace that has at least one window. The new workspace gets the first
  // free numeric ID above the highest occupied one.
  function openNewWorkspace() {
    var maxUsed = 0
    for (var i = 0; i < root.workspaces.length; i++) {
      var w = root.workspaces[i]
      if (w && w.windowCount > 0) {
        var id = Number(w.id)
        if (isFinite(id) && id > maxUsed) maxUsed = id
      }
    }
    var target = maxUsed + 1
    var expr = 'hl.dsp.focus({ workspace = "' + root.luaStringLiteral(String(target)) + '" })'
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
    root.hideWorkspaces()
  }

  Timer {
    id: wsHideTimer
    interval: root.wsDuration
    onTriggered: root.hideWorkspaces()
  }

  Timer {
    id: wsGeometryTimer
    interval: 100
    onTriggered: {
      root.geometryRefreshInFlight = false
      if (!root.geometryRefreshPending) return
      root.geometryRefreshPending = false
      root.refreshMainModel()
      if (root.workspaces.length === 0) return
      if (root.workspacesOpened) root.restartWorkspacesHideTimer()
    }
  }

  Timer {
    id: wsSettleTimer
    interval: 40
    onTriggered: root.showWorkspaces()
  }

  Connections {
    target: Hyprland

    function onFocusedWorkspaceChanged() {
      if (root.ready) root.showWorkspaces()
    }

    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (!root.ready) return
      var geometryEvent = ["movewindow", "moveworkspace", "openwindow", "closewindow", "changefloatingmode", "fullscreen", "pin", "minimize"].indexOf(name) !== -1
      var modelEvent = geometryEvent || name === "renameworkspace" || name === "urgent"
      if (!modelEvent) return

      root.modelDirty = true
      if (geometryEvent) root.requestGeometryRefresh()
      else if (root.workspacesOpened) wsSettleTimer.restart()
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.refreshDesktopEntries() }
  }

  readonly property var focusedWorkspaceId: {
    var ws = Hyprland.focusedWorkspace
    return ws ? ws.id : null
  }

  // ========================================================================
  //  Shell panel contract + legacy IPC targets
  // ========================================================================
  function open(payloadJson) {
    // Generic summon defaults to the top-left (floatbar) surface.
    root.openFloatbar(payloadJson)
    return "ok"
  }
  function close() {
    root.closeFloatbar()
    root.hideWorkspaces()
    return "ok"
  }
  function toggle() { root.anyOpen ? root.close() : root.open("") }
  function refresh() { root.readConfig(); root.refreshWidgetEntries(); return "ok" }
  function ping() { return "ok" }

  function stateString() {
    return (root.anyOpen ? "open" : "closed")
      + " float=" + (root.floatbarOpened ? "1" : "0")
      + " ws=" + (root.workspacesOpened ? "1" : "0")
  }

  IpcHandler {
    target: "speakercorners"
    function open(): string { root.open(""); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function state(): string { return root.stateString() }
  }

  // Legacy targets so existing commands/scripts keep working even though the
  // old floatbar and workspaces-float plugins are gone.
  IpcHandler {
    target: "floatbar"
    function open(): string { root.openFloatbar(""); return "ok" }
    function close(): string { root.closeFloatbar(); return "ok" }
    function toggle(): string { root.toggleFloatbar(); return "ok" }
    function state(): string { return root.floatbarOpened ? "open" : "closed" }
  }

  IpcHandler {
    target: "workspace-overview"
    function open(): string { root.showWorkspaces(); return "ok" }
    function close(): string { root.hideWorkspaces(); return "ok" }
    function toggle(): string { root.toggleWorkspaces(); return "ok" }
    function state(): string { return root.workspacesOpened ? "open" : "closed" }
  }

  // ========================================================================
  //  Component: one hot-corner recognition zone
  // ========================================================================
  component CornerZone: Item {
    id: zone
    required property string edge

    readonly property bool armed: root.cornersEnabled
    // Fired latches until the pointer leaves, so resting in the corner opens
    // once instead of hammering the toggle on every dwell pass.
    property bool fired: false

    width: root.targetSize
    height: root.targetSize
    visible: root.cornersEnabled

    Timer {
      id: dwell
      interval: root.dwellMs
      repeat: false
      onTriggered: {
        root.triggerCorner(zone.edge)
        zone.fired = true
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onEntered: {
        zone.fired = false
        if (zone.armed) dwell.restart()
      }
      onExited: {
        dwell.stop()
        zone.fired = false
      }
    }
  }

  // ========================================================================
  //  The single masked window
  // ========================================================================
  PanelWindow {
    id: panel
    screen: root.activeScreen
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-speakercorners"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.keysWanted ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Input is restricted to what is actually interactive, so everything else
    // on screen keeps receiving the pointer. Always-on: the four corner hot
    // zones. While the float bar is up the whole screen belongs to it (to
    // swallow outside clicks), and the workspace strip keeps its clicks while
    // showing.
    mask: Region {
      // four corner squares
      Region { x: 0; y: 0; width: root.cornersEnabled ? root.targetSize : 0; height: root.targetSize }
      Region { x: panel.width - root.targetSize; y: 0; width: root.cornersEnabled ? root.targetSize : 0; height: root.targetSize }
      Region { x: 0; y: panel.height - root.targetSize; width: root.cornersEnabled ? root.targetSize : 0; height: root.targetSize }
      Region { x: panel.width - root.targetSize; y: panel.height - root.targetSize; width: root.cornersEnabled ? root.targetSize : 0; height: root.targetSize }
      // fullscreen block while the float bar is up
      Region { x: 0; y: 0; width: root.keysWanted ? panel.width : 0; height: root.keysWanted ? panel.height : 0 }
      // workspace strip clicks (and null while it is hidden)
      Region { x: root.stripX; y: root.stripY; width: root.workspacesOpened ? root.stripW : 0; height: root.workspacesOpened ? root.stripH : 0 }
      // optional bottom edge (opt-in)
      Region { x: 0; y: root.wsEdgeEnabled ? panel.height - root.wsEdgeHeight : panel.height; width: root.wsEdgeEnabled ? panel.width : 0; height: root.wsEdgeEnabled ? root.wsEdgeHeight : 0 }
    }

    // Transparent click-catcher: closing the float bar on any outside click.
    // No fill color at all — the float bar stays backdrop-free.
    MouseArea {
      anchors.fill: parent
      z: 1
      visible: root.floatbarOpened
      onClicked: root.closeFloatbar()
    }

    // ---- Float bar card (top-left) ----
    BorderSurface {
      z: 2
      visible: root.floatbarOpened
      radius: root.cornerRadius
      color: root.cardColor
      borderSpec: Border.flat(root.cardBorder, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      width: {
        var cfg = root.setting("cardWidth", "auto")
        if (String(cfg) !== "auto") {
          var explicit = parseInt(cfg, 10)
          if (isFinite(explicit) && explicit > 0) return Math.min(explicit, panel.width - Style.gapsOut * 2)
        }
        return Math.min(root.computedContentWidth + contentLeftInset + contentRightInset, panel.width - Style.gapsOut * 2)
      }
      implicitHeight: root.computedContentHeight + contentTopInset + contentBottomInset

      x: root.cornerMargin
      y: root.cornerMargin

      // Swallow clicks on the card so they don't reach the backdrop catcher.
      MouseArea { anchors.fill: parent; onClicked: { } }

      Item {
        x: parent.contentLeftInset
        y: parent.contentTopInset
        width: parent.width - parent.contentLeftInset - parent.contentRightInset
        implicitWidth: column.implicitWidth
        implicitHeight: column.implicitHeight

        Column {
          id: column
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(14)

          ClockRow {
            id: clockCell
            visible: root.hasClockWidget
            width: parent.width
          }

          Grid {
            id: widgetGrid
            visible: root.gridCells.length > 0
            width: root.gridCols * root.buttonTileSize + Math.max(0, root.gridCols - 1) * root.cellSpacing
            anchors.horizontalCenter: parent.horizontalCenter
            columns: root.gridCols
            columnSpacing: root.cellSpacing
            rowSpacing: root.cellSpacing
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter

            Repeater {
              model: root.gridCells

              delegate: GridCell {
                required property var modelData
                cellData: modelData
              }
            }
          }
        }
      }
    }

    // ---- Workspaces float strip (bottom-right) ----
    BorderSurface {
      id: strip
      z: 4
      visible: root.workspacesOpened
      x: root.stripX
      y: root.stripY
      width: root.stripW
      height: root.stripH
      radius: root.cornerRadius
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      Behavior on opacity {
        NumberAnimation { duration: root.cornerRadius > 0 ? 120 : 0; easing.type: Easing.OutCubic }
      }

      // Keep the overview open while the pointer is over it, so a click can
      // land; the auto-hide countdown resumes once the pointer leaves.
      HoverHandler {
        id: stripHover
        onHoveredChanged: {
          if (hovered) wsHideTimer.stop()
          else if (root.workspacesOpened) wsHideTimer.restart()
        }
      }

      Row {
        anchors.top: parent.top
        anchors.topMargin: root.wsOuterPad
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: root.wsCardGap

        Repeater {
          model: root.workspaces

          WorkspaceCard {
            required property var modelData

            width: root.effectiveWsCardWidth

            ws: modelData
            shell: root.shell
            desktopEntries: root.desktopEntries
            focused: root.focusedWorkspaceId !== null
              && Number(root.focusedWorkspaceId) === Number(modelData.id)
            onActivate: function(ws) { root.focusWorkspace(ws) }
          }
        }

        Item {
          width: root.effectiveWsCardWidth
          height: root.wsCardPreviewH + root.wsCardLabelH
          visible: root.workspaces.length > 0

          Rectangle {
            anchors.centerIn: parent
            width: root.effectiveWsCardWidth
            height: root.wsCardPreviewH
            radius: root.cornerRadius
            color: newWorkspaceArea.containsMouse
              ? Util.alpha(Color.popups.text, 0.12)
              : Util.alpha(Color.popups.text, 0.06)
            border.width: Math.max(1, Style.space(1))
            border.color: Util.alpha(Color.popups.text, 0.15)

            Text {
              anchors.centerIn: parent
              text: "+"
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              color: Util.alpha(Color.popups.text, 0.5)
            }

            MouseArea {
              id: newWorkspaceArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openNewWorkspace()
            }
          }
        }
      }
    }

    // ---- Optional bottom edge (opt-in) ----
    Item {
      visible: root.wsEdgeEnabled
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: root.wsEdgeHeight
      HoverHandler {
        onHoveredChanged: if (hovered && root.ready) root.showWorkspaces()
      }
    }

    // ---- Hot-corner recognition zones ----
    CornerZone {
      z: 10
      anchors.top: parent.top
      anchors.left: parent.left
      edge: "top-left"
    }
    CornerZone {
      z: 10
      anchors.top: parent.top
      anchors.right: parent.right
      edge: "top-right"
    }
    CornerZone {
      z: 10
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      edge: "bottom-left"
    }
    CornerZone {
      z: 10
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      edge: "bottom-right"
    }

    // ---- Keyboard routing (float bar only) ----
    Item {
      id: keyRouter
      anchors.fill: parent
      focus: root.keysWanted
      enabled: root.keysWanted
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.floatbarOpened && event.key === Qt.Key_Escape) {
          root.closeFloatbar()
          event.accepted = true
        }
      }
    }

    // ---- Drag-and-drop layer: renders the tile being dragged, following the
    // pointer while a grid reorder is in progress. ----
    Item {
      id: dragLayer
      z: 100
      anchors.fill: parent
      visible: root.draggingGrid

      Item {
        id: dragPreview
        visible: false
        width: root.buttonTileSize
        height: root.buttonTileSize
        x: -1000
        y: -1000
        opacity: 0.92
        scale: 1.06

        Rectangle {
          anchors.fill: parent
          radius: root.cornerRadius
          color: dragPreview.dataFill
          border.width: Math.max(1, Style.space(1))
          border.color: Util.alpha(Color.accent, 0.9)
        }
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: dragPreview.glyph
          color: dragPreview.glyphColor
          font.family: dragPreview.glyphFont
          font.pixelSize: Style.font.iconLarge
          renderType: Text.NativeRendering
        }

        property string glyph: "\uf111"
        property string glyphFont: root.fontFamily
        property color glyphColor: root.cardText
        property color dataFill: Util.alpha(root.cardText, 0.06)

        function showFor(key, scenePt) {
          var idx = root.indexOfCellKey(key)
          var cd = idx >= 0 ? root.gridCells[idx] : null
          if (!cd) return
          glyph = root.cellGlyph(cd)
          glyphFont = root.cellGlyphFont(cd)
          var on = root.cellActive(cd)
          glyphColor = on ? Color.accent : Util.alpha(root.cardText, 0.82)
          dataFill = on ? Util.alpha(Color.accent, 0.32) : Util.alpha(root.cardText, 0.06)
          visible = true
          if (scenePt) followScene(scenePt)
        }
        function followScene(scenePt) {
          if (!scenePt) return
          x = scenePt.x - width / 2
          y = scenePt.y - height / 2
        }
        function reset() { visible = false }
      }
    }
  }

  readonly property int cornerMargin: Math.max(Style.gapsOut + Style.space(12), Style.space(24))

  // ========================================================================
  //  Reused float-bar components
  // ========================================================================
  // The clock row drawn by the floatbar itself. Clicking it toggles the
  // menu-bar calendar (omarchy.clock IPC target), so the popup appears exactly
  // as if the bar's own clock had been clicked.
  component ClockRow: Item {
    id: cRow

    readonly property string format: String(root.setting("clockFormat", "dddd HH:mm"))
    property date now: new Date()

    Timer {
      interval: 1000
      repeat: true
      triggeredOnStart: true
      onTriggered: cRow.now = new Date()
    }

    implicitHeight: Style.space(40)

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: Qt.formatDateTime(cRow.now, cRow.format)
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      color: cRowHover.containsMouse
        ? root.cardText
        : Util.alpha(root.cardText, 0.88)
    }

    MouseArea {
      id: cRowHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleCalendar()
    }
  }

  // Power / battery tile mirroring the menu-bar battery: live charge level and
  // charging/plug/AC state straight from UPower (no IPC polling required).
  component SmartBatteryButton: FloatButton {
    id: batt

    readonly property var device: UPower.displayDevice
    readonly property bool hasDevice: !!(batt.device && batt.device.isPresent)
    readonly property bool onBattery: hasDevice && UPower.onBattery
    readonly property real fraction: batt.hasDevice
      ? Math.max(0, Math.min(1, Number(batt.device.percentage || 0)))
      : 0

    readonly property bool chargeThresholdActive: {
      var d = batt.device
      var s = UPowerDeviceState
      if (!batt.hasDevice || !batt.onBattery) return false
      if (batt.fraction >= 0.99) return false
      if (d.state === s.Discharging) return false
      if (d.state === s.PendingCharge) return true
      if (d.state === s.FullyCharged && batt.fraction < 0.99) return true
      if (d.state !== s.Charging) return false
      return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
    }
    readonly property bool charging: batt.hasDevice
      && !batt.onBattery && !batt.chargeThresholdActive

    function batteryIcon() {
      if (!batt.hasDevice) return ""
      var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
      var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
      var index = Math.max(0, Math.min(9, Math.floor(batt.fraction * 10)))
      if (batt.chargeThresholdActive) return defaultIcons[index]
      if (batt.device.state === UPowerDeviceState.FullyCharged) return "󰂅"
      if (!batt.onBattery) return chargingIcons[index]
      return defaultIcons[index]
    }

    function modeLabel() {
      var pct = Math.round(batt.fraction * 100)
      if (batt.chargeThresholdActive) return "Battery " + pct + "% · threshold"
      if (batt.onBattery) return "Battery " + pct + "% · on battery"
      if (!batt.onBattery && batt.fraction >= 1) return "Battery " + pct + "% · fully charged"
      return "Battery " + pct + "% · charging"
    }

    text: batt.batteryIcon()
    tooltip: batt.modeLabel()
    visible: batt.hasDevice
    onClicked: root.activateWidget("omarchy.power")
  }

  // Bluetooth tile mirroring the menu-bar icon: off / on / connected.
  component SmartBluetoothButton: FloatButton {
    id: btb

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
    readonly property bool enabled: !!(btb.adapter && btb.adapter.enabled)

    function connectedCount() {
      var n = 0
      for (var i = 0; i < btb.devices.length; i++)
        if (btb.devices[i] && btb.devices[i].connected) n++
      return n
    }

    readonly property string smartIcon: {
      if (!btb.enabled) return "󰂲"
      if (btb.connectedCount() > 0) return "󰂱"
      return "󰂯"
    }

    text: btb.smartIcon
    tooltip: btb.enabled
      ? ("Bluetooth · " + (btb.connectedCount() > 0
        ? btb.connectedCount() + " connected"
        : "On"))
      : "Bluetooth · Off"
    onClicked: root.activateWidget("omarchy.bluetooth")
  }

  // Network tile mirroring the menu-bar icon: signal strength on Wi-Fi,
  // wired, or disconnected — all live off the NetworkManager service.
  component SmartNetworkButton: FloatButton {
    id: nb

    readonly property var devices: Networking.devices ? Networking.devices.values : []
    function findDevice(type) {
      var fallback = null
      for (var i = 0; i < nb.devices.length; i++) {
        var d = nb.devices[i]
        if (!d || d.type !== type) continue
        if (d.connected) return d
        if (!fallback) fallback = d
      }
      return fallback
    }
    readonly property var wifiDevice: nb.findDevice(DeviceType.Wifi)
    readonly property var wifiNetworks: nb.wifiDevice && nb.wifiDevice.networks
      ? nb.wifiDevice.networks.values : []
    function connectedWifi() {
      for (var i = 0; i < nb.wifiNetworks.length; i++)
        if (nb.wifiNetworks[i] && nb.wifiNetworks[i].connected) return nb.wifiNetworks[i]
      return null
    }
    readonly property var wiredDevice: nb.findDevice(DeviceType.Wired)

    readonly property string smartKind: {
      if (nb.wiredDevice && nb.wiredDevice.connected) return "ethernet"
      if (nb.connectedWifi()) return "wifi"
      return "disconnected"
    }
    readonly property int smartSignal: nb.connectedWifi()
      ? Math.round((nb.connectedWifi().signalStrength || 0) * 100)
      : -1

    function wifiIconFor(strength) {
      var icons = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
      var index = Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))
      return icons[index]
    }
    readonly property string smartIcon: {
      if (nb.smartKind === "wifi") return nb.wifiIconFor(nb.smartSignal)
      if (nb.smartKind === "ethernet") return "󰈀"
      return "󰤮"
    }

    text: nb.smartIcon
    tooltip: nb.smartKind === "wifi"
      ? "Wi-Fi · " + (nb.smartSignal >= 0 ? nb.smartSignal + "%" : "connected")
      : (nb.smartKind === "ethernet" ? "Wired connection" : "No connection")
    onClicked: root.activateWidget("omarchy.network")
  }

  component FloatButton: Item {
    id: tile
    signal clicked
    property string text: ""
    property string fontFamily: root.fontFamily
    property int fontPixelSize: Style.font.iconLarge
    property color foreground: root.cardText
    property string tooltip: ""
    property bool active: false

    // Drag-to-reorder support (opt-in per tile).
    property bool reorderable: false
    property string reorderKey: ""
    signal dragRequested(string key)
    signal dragMoved(real sceneX, real sceneY)
    signal dragDropped(real sceneX, real sceneY)
    property bool _dragFired: false
    property point _press: Qt.point(0, 0)

    readonly property bool hovered: tileArea.containsMouse
    readonly property color hotFill: Util.alpha(tile.foreground, tile.active ? 0.3 : 0.16)
    readonly property color activeFill: Util.alpha(Color.accent, 0.32)
    readonly property color displayColor: tile.active ? Color.accent : Util.alpha(tile.foreground, 0.82)
    readonly property color hoverOutline: Util.alpha(tile.foreground, 0.55)
    readonly property int tileSize: Math.max(Style.space(46), fontPixelSize + Style.space(18))

    width: tileSize
    height: tileSize

    Rectangle {
      anchors.fill: parent
      radius: root.cornerRadius > 0 ? Math.max(2, root.cornerRadius / 2) : Style.space(6)
      color: tileArea.containsMouse
        ? tile.hotFill
        : (tile.active ? tile.activeFill : "transparent")
      border.width: (tileArea.containsMouse || tile.active) ? Math.max(1, Style.space(1)) : 0
      border.color: tile.active
        ? Util.alpha(Color.accent, 0.9)
        : (tileArea.containsMouse ? tile.hoverOutline : "transparent")

      Behavior on color {
        ColorAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
      Behavior on border.color {
        ColorAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tile.text
      color: tile.displayColor
      font.family: tile.fontFamily
      font.pixelSize: tile.fontPixelSize
      renderType: Text.NativeRendering

      Behavior on color {
        ColorAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
    }

    MouseArea {
      id: tileArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onPressed: function(m) {
        tile._press = Qt.point(m.x, m.y)
        tile._dragFired = false
      }
      onPositionChanged: function(m) {
        if (!pressed) return
        if (!tile._dragFired && tile.reorderable && tile.reorderKey !== "") {
          var dx = m.x - tile._press.x
          var dy = m.y - tile._press.y
          if (dx * dx + dy * dy >= root.dragThresholdSq) {
            tile._dragFired = true
            var sc = tile.mapToItem(null, m.x, m.y)
            tile.dragRequested(tile.reorderKey)
            tile.dragMoved(sc.x, sc.y)
            return
          }
        }
        if (tile._dragFired) {
          var p = tile.mapToItem(null, m.x, m.y)
          tile.dragMoved(p.x, p.y)
        }
      }
      onReleased: function(m) {
        if (tile._dragFired) {
          tile._dragFired = false
          var q = tile.mapToItem(null, m.x, m.y)
          tile.dragDropped(q.x, q.y)
          return
        }
        tile.clicked()
      }
      onCanceled: function() { tile._dragFired = false }
    }

    PanelToolTip {
      visible: tileArea.containsMouse && tile.tooltip !== ""
      text: tile.tooltip
      fontFamily: tile.fontFamily
    }
  }

  // A grid tile that mirrors one of the bar's live indicators. State is polled
  // over IPC (see applyIndicatorPoll) because this plugin has no direct access
  // to the owning services.
  component LiveIndicator: FloatButton {
    id: live
    required property string indicatorId

    readonly property bool on: {
      switch (live.indicatorId) {
      case "NightLight": return root.liveIndicatorStates.nightLight === true
      case "Dnd": return root.liveIndicatorStates.dnd === true
      case "Reminder": return Number(root.liveIndicatorStates.reminderCount) > 0
      case "StayAwake": return root.liveIndicatorStates.stayAwake === true
      case "ScreenRecording": return root.liveIndicatorStates.screenRecording === true
      }
      return false
    }

    function tooltipForState() {
      if (live.indicatorId === "NightLight")
        return live.on ? "Night Light — click to disable" : "Night Light — click to enable"
      if (live.indicatorId === "Dnd")
        return live.on ? "Silence Notifications — click to allow" : "Silence Notifications — click to disable"
      if (live.indicatorId === "Reminder") {
        var t = String(root.liveIndicatorStates.reminderTooltip || "").trim()
        return t.length > 0 ? t : (live.on ? "Reminders due — click to show" : "Reminders — click to add")
      }
      if (live.indicatorId === "StayAwake")
        return live.on ? "Stay Awake — click to allow idle" : "Stay Awake — click to enable"
      if (live.indicatorId === "ScreenRecording")
        return live.on ? "Stop recording" : "Screen Recording — click to record"
      return live.indicatorId
    }

    text: root.indicatorGlyph(live.indicatorId)
    active: live.on
    tooltip: live.tooltipForState()

    onHoveredChanged: if (hovered) root.pollIndicators()
    onClicked: root.activateIndicator(live.indicatorId)
  }

component GridCell: Item {
    id: gcell
    required property var cellData

    readonly property string kind: cellData && cellData.kind ? String(cellData.kind) : ""
    readonly property string cellId: cellData && cellData.id ? String(cellData.id) : ""
    readonly property string cellKey: cellData && cellData.key ? String(cellData.key) : ""
    readonly property bool dropActive: root.dragHighlightKey !== ""
      && gcell.cellKey === root.dragHighlightKey
      && gcell.cellKey !== root.dragGridKey

    width: root.buttonTileSize
    height: root.buttonTileSize

    // Drop-target highlight while dragging another cell over this one.
    Rectangle {
      z: 2
      anchors.fill: parent
      visible: gcell.dropActive && gcell.cellKey !== root.dragGridKey
      radius: root.cornerRadius
      color: Util.alpha(Color.accent, 0.16)
      border.width: Math.max(2, Style.space(1))
      border.color: Util.alpha(Color.accent, 0.9)
    }

    Item {
      id: gridTiles
      anchors.fill: parent

      LiveIndicator {
        anchors.fill: parent
        visible: gcell.kind === "indicator"
        indicatorId: gcell.cellId
        reorderable: true
        reorderKey: gcell.cellKey
      }

      SmartBatteryButton {
        anchors.fill: parent
        visible: gcell.kind === "widget" && gcell.cellId === "omarchy.power"
        reorderable: true
        reorderKey: gcell.cellKey
      }

      SmartBluetoothButton {
        anchors.fill: parent
        visible: gcell.kind === "widget" && gcell.cellId === "omarchy.bluetooth"
        reorderable: true
        reorderKey: gcell.cellKey
      }

      SmartNetworkButton {
        anchors.fill: parent
        visible: gcell.kind === "widget" && gcell.cellId === "omarchy.network"
        reorderable: true
        reorderKey: gcell.cellKey
      }

      FloatButton {
        anchors.fill: parent
        visible: gcell.kind === "widget"
          && gcell.cellId !== "omarchy.power"
          && gcell.cellId !== "omarchy.bluetooth"
          && gcell.cellId !== "omarchy.network"
        text: root.glyphFor(gcell.cellId)
        fontFamily: root.glyphFontFor(gcell.cellId)
        tooltip: root.labelFor(gcell.cellId)
        reorderable: true
        reorderKey: gcell.cellKey
        onClicked: {
          if (gcell.cellId === "omarchy.system-update") root.runSystemUpdate()
          else root.activateWidget(gcell.cellId)
        }
      }

      // App-launcher actions (browser, terminal, ...) run a fixed command.
      FloatButton {
        anchors.fill: parent
        visible: gcell.kind === "action"
        text: root.cellGlyph(gcell.cellData)
        fontFamily: root.fontFamily
        tooltip: root.cellLabel(gcell.cellData)
        reorderable: true
        reorderKey: gcell.cellKey
        onClicked: {
          var cmd = gcell.cellData && Array.isArray(gcell.cellData.command)
            ? gcell.cellData.command
            : []
          if (cmd.length > 0)
            Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "speakercorners-action"].concat(cmd))
          root.closeFloatbar()
        }
      }

      FloatButton {
        anchors.fill: parent
        visible: gcell.kind === "toggle"
        text: "\ue900"
        fontFamily: "omarchy"
        tooltip: "Toggle Bar"
        reorderable: true
        reorderKey: gcell.cellKey
        onClicked: root.toggleBar()
      }
    }

    Component.onCompleted: function() {
      // Any reorderable tile inside this cell participates in grid dragging.
      for (var i = 0; i < gridTiles.children.length; i++) {
        var t = gridTiles.children[i]
        if (!t || !t.reorderable || t.reorderKey === "") continue
        t.dragRequested.connect(function() {
          root.beginGridDrag(gcell.cellKey)
        })
        t.dragMoved.connect(function(x, y) {
          root.updateGridDrag(Qt.point(x, y))
        })
        t.dragDropped.connect(function(x, y) {
          root.endGridDrag(Qt.point(x, y))
        })
      }
    }
  }

  component WorkspaceCard: Item {
    id: wcard

    required property var ws
    property var shell: null
    property var desktopEntries: []
    property bool focused: false

    signal activate(var ws)

    readonly property real previewHeight: Math.round(wcard.width * 9 / 16)
    readonly property real labelHeight: Math.max(Style.space(12), Style.font.caption + Style.space(4))

    readonly property color focusedBorder: Color.accent
    readonly property color idleBorder: "transparent"
    readonly property color borderColor: wcard.focused ? focusedBorder : idleBorder
    readonly property int borderWidth: Math.max(2, Style.space(2))

    readonly property string label: wcard.ws ? String(wcard.ws.label || wcard.ws.id) : ""

    readonly property color previewBackground: wcard.focused ? Color.foreground : Color.background
    readonly property color previewForeground: wcard.focused ? Color.background : Color.popups.text
    readonly property color imageTint: {
      var tint = IconModel.fallbackIconTint(wcard.previewForeground, wcard.previewBackground)
      return Qt.rgba(tint.r, tint.g, tint.b, tint.a)
    }

    readonly property int iconMaxSize: Style.space(24)
    readonly property int iconGap: Style.space(4)
    readonly property int iconPad: Style.space(5)

    readonly property var appList: wcard.buildAppList(wcard.ws)
    readonly property int appCount: wcard.appList.length

    readonly property int iconColumns: {
      var n = wcard.appCount
      if (n <= 0) return 1
      var w = Math.max(1, wcardPreview.width - wcard.iconPad * 2)
      var h = Math.max(1, wcardPreview.height - wcard.iconPad * 2)
      return Math.max(1, Math.ceil(Math.sqrt(n * (w / h))))
    }

    readonly property int iconSize: {
      var n = wcard.appCount
      if (n <= 0) return 0
      var w = Math.max(1, wcardPreview.width - wcard.iconPad * 2)
      var h = Math.max(1, wcardPreview.height - wcard.iconPad * 2)
      var cols = wcard.iconColumns
      var rows = Math.max(1, Math.ceil(n / cols))
      var size = Math.floor(Math.min(
        (w - (cols - 1) * wcard.iconGap) / cols,
        (h - (rows - 1) * wcard.iconGap) / rows
      ))
      return Math.max(10, Math.min(wcard.iconMaxSize, size))
    }

    function buildAppList(ws) {
      var out = []
      var seen = {}
      if (!ws || !ws.windows) return out

      for (var i = 0; i < ws.windows.length; i++) {
        var w = ws.windows[i]
        if (!w) continue
        var id = (typeof w.appId === "string") ? w.appId.trim() : ""
        if (id.length === 0 && w.wayland && typeof w.wayland.appId === "string") {
          id = w.wayland.appId.trim()
        }

        var key = id.toLowerCase()
        if (seen[key]) continue
        seen[key] = true

        out.push({
          appId: id,
          member: {
            title: typeof w.title === "string" ? w.title : "",
            initialTitle: typeof w.title === "string" ? w.title : "",
            className: id,
            initialClass: id,
            iconCandidates: id.length > 0 ? [id] : []
          }
        })
      }
      return out
    }

    function genericIconSource() {
      return String(Quickshell.iconPath("application-x-executable", true) || "")
    }

    function desktopEntry(member) {
      var entry = IconModel.matchDesktopEntry(member, wcard.desktopEntries)
      var candidates = member && Array.isArray(member.iconCandidates)
        ? member.iconCandidates
        : []

      if (!entry) {
        for (var i = 0; i < candidates.length && !entry; i++) {
          var candidate = String(candidates[i] || "").trim()
          if (!candidate) continue

          try {
            entry = DesktopEntries.byId(candidate)
              || DesktopEntries.byId(candidate + ".desktop")
              || DesktopEntries.heuristicLookup(candidate)
          } catch (error) {}
        }
      }

      return entry
    }

    function actualIcon(source, genericSource) {
      var value = String(source || "")
      return value.length > 0 && value !== genericSource ? source : ""
    }

    function iconSource(member, entry) {
      if (entry === undefined) entry = wcard.desktopEntry(member)
      var candidates = member && Array.isArray(member.iconCandidates)
        ? member.iconCandidates
        : []
      var genericSource = wcard.genericIconSource()

      if (entry && entry.icon) {
        if (wcard.shell && wcard.shell.appLibrary
            && typeof wcard.shell.appLibrary.iconSource === "function") {
          var libraryIcon = wcard.actualIcon(
            wcard.shell.appLibrary.iconSource(entry.icon),
            genericSource
          )
          if (libraryIcon) return libraryIcon
        }

        var entryIcon = wcard.actualIcon(Quickshell.iconPath(String(entry.icon), true), genericSource)
        if (entryIcon) return entryIcon
      }

      for (var j = 0; j < candidates.length; j++) {
        var classIconCandidate = String(candidates[j] || "").trim()
        if (!classIconCandidate) continue
        var classIcon = wcard.actualIcon(Quickshell.iconPath(classIconCandidate, true), genericSource)
        if (classIcon) return classIcon
      }

      return ""
    }

    implicitHeight: wcard.previewHeight + wcard.labelHeight + wcard.borderWidth * 2
    implicitWidth: wcard.width

    BorderSurface {
      id: wcardBorder
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      width: wcard.width
      height: wcard.previewHeight + wcard.labelHeight + wcard.borderWidth * 2
      radius: Style.cornerRadius
      color: Util.alpha(Color.background, 0.6)
      borderSpec: Border.flat(wcard.borderColor, wcard.borderWidth)
      clip: true

      Item {
        id: wcardPreview
        anchors.top: parent.top
        anchors.topMargin: wcardBorder.contentTopInset
        anchors.left: parent.left
        anchors.leftMargin: wcardBorder.contentLeftInset
        width: wcardBorder.width - wcardBorder.contentLeftInset - wcardBorder.contentRightInset
        height: wcard.previewHeight
        clip: true

        Rectangle {
          anchors.fill: parent
          color: wcard.previewBackground
        }

        GridLayout {
          anchors.centerIn: parent
          columns: wcard.iconColumns
          columnSpacing: wcard.iconGap
          rowSpacing: wcard.iconGap

          Repeater {
            model: wcard.appList

            delegate: Item {
              id: appIcon
              required property var modelData
              readonly property var member: modelData.member
              readonly property var entry: wcard.desktopEntry(member)
              readonly property string mappedGlyph: IconModel.appGlyph(member, entry)
              readonly property var imageSource: mappedGlyph.length === 0
                ? wcard.iconSource(member, entry)
                : ""
              readonly property bool imageUnavailable: mappedGlyph.length === 0
                && (String(imageSource).length === 0 || appImage.status === Image.Error)
              readonly property string glyph: mappedGlyph.length > 0
                ? mappedGlyph
                : (imageUnavailable ? IconModel.genericAppGlyph() : "")
              readonly property int iconPixelRatio: Math.max(1, Math.round(Screen.devicePixelRatio))

              width: wcard.iconSize
              height: wcard.iconSize

              OpticalGlyph {
                anchors.centerIn: parent
                width: parent.width
                height: parent.height
                visible: appIcon.glyph.length > 0
                text: appIcon.glyph
                color: wcard.previewForeground
                fontFamily: "JetBrainsMono Nerd Font"
                fontSize: appIcon.height
              }

              Image {
                id: appImage
                anchors.fill: parent
                visible: appIcon.glyph.length === 0
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Math.max(1, Math.round(width * appIcon.iconPixelRatio))
                sourceSize.height: Math.max(1, Math.round(height * appIcon.iconPixelRatio))
                asynchronous: true
                smooth: true
                source: appIcon.imageSource
                layer.enabled: visible
                layer.effect: MultiEffect {
                  colorization: 1.0
                  colorizationColor: wcard.imageTint
                }
              }
            }
          }
        }
      }

      RowLayout {
        anchors.top: wcardPreview.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: Style.space(1)
        spacing: Style.space(4)

        Text {
          text: wcard.label
          textFormat: Text.PlainText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: wcard.focused
          color: wcard.focused ? Color.accent : Util.alpha(Color.popups.text, 0.7)
        }

        Rectangle {
          visible: wcard.ws && wcard.ws.urgent
          width: Style.space(5)
          height: Style.space(5)
          radius: width / 2
          color: Color.urgent
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: wcard.activate(wcard.ws)
      }
    }
  }
}