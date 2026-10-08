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
import "IconModel.js" as IconModel

// Speaker Corners — hot corners, icon panel and the live expose, in one
// plugin.
//
// One always-mapped fullscreen Overlay window holds:
//   * embedded hot-corner recognition (top-left / top-right / bottom-left /
//     bottom-right / bottom-center)
//   * the icon panel card (bottom-left, no backdrop)
// plus keyboard focus for the float bar. The window's `mask` only admits
// input where something interactive lives, so the desktop stays fully
// click-through everywhere else.
//
// The floating workspace strip, its configuration popup and the smart app
// grid moved out to their own plugin, nagualcode.nagualstrip; the two
// coordinate over IPC (see setStripChromeHidden() and internalCommand()).
//
// Configuration lives in shell.json in the plugin's own entry:
//   "plugins": [
//     { "id": "speakercorners",
//       "dwellMs": 139, "targetSize": 8,
//       "topLeftAction": "cascade-floats",
//       "topRightAction": "toggle-window-modes",
//       "bottomLeftAction": "toggle-hide-chrome",  "bottomLeftCommand": "",
//       "bottomRightAction": "mirador",
//       "bottomCenterAction": "command","bottomCenterCommand": "omarchy-shell workspace-overview toggle" }
//   ]
//
// The bottom-center corner defaults to a command that drives the strip
// plugin's legacy `workspace-overview` IPC target, so installing
// nagualcode.nagualstrip keeps that corner working unchanged.
//
// The "mirador" action runs the live expose: every window of the focused
// workspace is spread over a gap grid in place — real windows, no previews,
// no screencopy — and this panel takes the pointer over through its input
// region. Clicking a cell puts every window back exactly where it was and
// raises the clicked one; empty click, Esc or another corner dwell restores
// everything (the original geometries are also parked in a state file, so a
// shell restart mid-expose puts the desktop back too).
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
  // Kept alive during the closing slide so the descent is visible; cleared by
  // the slide-out timer once the play-out ends.
  property bool fbSliding: false

  readonly property bool anyOpen: root.floatbarOpened
  // The shell's isPluginOpen() reads `opened` off the loaded item; keep it in
  // sync so `omarchy-shell shell toggle speakercorners` round-trips cleanly.
  readonly property bool opened: root.anyOpen
  // The float bar and the live expose both take full-screen keyboard focus;
  // everything else stays click-through through the mask.
  readonly property bool keysWanted: root.floatbarOpened || root.exposeActive
  // Whether the bottom-center hot corner is armed, taken from the nagualstrip
  // plugin's shell.json entry (see readConfig()).
  property bool stripToggleEnabled: true

  readonly property var appLibrary: root.shell
    ? (root.shell.appLibrary || (typeof root.shell.n === "object" ? root.shell.n : null))
    : null

  // ---- Hot-corner settings (read from the plugins[] entry) ---------------
  property var pluginSettings: ({})
  property bool configLoaded: false
  property int dwellMs: 139
  property int targetSize: 8
  property bool cornersEnabled: true

  // Slide animation for the inline panels (icon panel + workspace strip).
  // Users can disable it via the "animations" setting in shell.json; the slide
  // drops to 0ms when off so panels pop in/out instantly.
  property bool animationsEnabled: true
  property int panelAnimMs: 120
  readonly property int effectivePanelAnimMs: root.animationsEnabled ? root.panelAnimMs : 0

  // Persisted order of the float-bar grid cells (drag to reorder).
  property var gridOrder: []

  function setting(key, fallback) {
    var value = root.pluginSettings[key]
    return value === undefined || value === null ? fallback : value
  }

  function actionFor(edge) {
    if (edge === "top-left") return String(setting("topLeftAction", "none"))
    if (edge === "top-right") return String(setting("topRightAction", "toggle-window-modes"))
    if (edge === "bottom-left") return String(setting("bottomLeftAction", "toggle-hide-chrome"))
    if (edge === "bottom-right") return String(setting("bottomRightAction", "mirador"))
    if (edge === "bottom-center") return String(setting("bottomCenterAction", "command"))
    return "none"
  }

  function commandFor(edge) {
    if (edge === "top-left") return String(setting("topLeftCommand", ""))
    if (edge === "top-right") return String(setting("topRightCommand", ""))
    if (edge === "bottom-left") return String(setting("bottomLeftCommand", ""))
    if (edge === "bottom-right") return String(setting("bottomRightCommand", ""))
    if (edge === "bottom-center") return String(setting("bottomCenterCommand", "omarchy-shell workspace-overview toggle"))
    return ""
  }

  // Same lookup the nagualstrip plugin uses, so both plugins agree on which
  // shell.json entry owns the workspace strip even before a config has been
  // migrated off the legacy "speakercorners" entry.
  function findStripSettings(list) {
    if (!Array.isArray(list)) return null
    var ids = ["nagualcode.nagualstrip", "nagualstrip", "speakercorners"]
    for (var k = 0; k < ids.length; k++) {
      for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].id) === ids[k]) return list[i]
      }
    }
    return null
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
    root.animationsEnabled = setting("animations", true) !== false
    // Whether the bottom-center corner may arm at all is decided by the strip
    // plugin's own entry: a pinned strip (wsToggleEnabled off) keeps it inert.
    var stripCfg = root.findStripSettings(list)
    root.stripToggleEnabled = !stripCfg || stripCfg.wsToggleEnabled !== false
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
    // The workspace strip moved to the nagualstrip plugin: hand these over
    // to the shell instead of handling them in-process (no sh -lc needed).
    if (target === "workspace-overview" || target === "nagualstrip"
        || target === "nagualstrip-apps" || target === "speakercorners-apps") {
      Quickshell.execDetached(["omarchy-shell", "-q", target, method || "toggle"])
      return true
    }
    if (target === "mirador" || target === "expose") {
      if (method === "toggle" || method === "cycle") { root.toggleExpose() }
      else if (method === "open" || method === "summon") { root.startExpose() }
      else if (method === "close" || method === "hide" || method === "dismiss") { root.exitExpose("") }
      else return false
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
    case "toggle-window-modes":
      root.toggleAllWindowModes()
      break
    case "cascade-floats":
      root.cascadeWorkspaceFloats()
      break
    case "mirador":
    case "expose":
      root.toggleExpose()
      break
    case "toggle-hide-chrome":
      root.toggleChromeHidden()
      break
    case "none":
    default:
      break
    }
  }

  function triggerCorner(edge) {
    root.readConfig()
    if (!root.cornersEnabled) return
    // While the expose is up only its own corner may fire (the toggle-off):
    // any other action would move windows around underneath the spread.
    if (root.exposeActive && edge !== "bottom-right") return
    root.trigger(root.actionFor(edge), root.commandFor(edge), edge)
  }

  // ---- Live expose: spread the workspace's real windows --------------------
  // The "mirador" gesture records every window of the focused workspace, floats
  // and moves the *real* windows into a gap grid (each one fully visible, no
  // overlap, aspect kept, never upscaled) and lets this panel take the pointer
  // over through its input region. Nothing is screenshotted: entering and
  // leaving cost one batch of hyprctl dispatches instead of a screencopy per
  // window.
  //
  //   toggle (corner / IPC) → spread out
  //   click a cell          → restore all originals + raise/focus that window
  //   click empty / Esc /
  //   re-dwell the corner   → restore all originals
  property bool exposeActive: false
  // Originals in grid order: {address, x, y, w, h, floating, fullscreen, fullscreenClient}
  property var exposeSaved: []
  // Cell rects in global logical coordinates: hit-testing + the hover highlight.
  property var exposeRects: []
  // Cell currently under the pointer, or null over empty space.
  property var exposeHoverRect: null
  // Global origin of the monitor the grid was computed on, so panel-local
  // pointer coordinates map back onto the grid.
  property var exposeOrigin: ({ x: 0, y: 0 })
  property int exposeWsId: -1
  property string exposeMonitorsJson: ""
  readonly property string exposeStatePath: Quickshell.env("HOME") + "/.local/state/omarchy/speakercorners-expose.json"

  function toggleExpose() {
    if (root.exposeActive) root.exitExpose("")
    else root.startExpose()
  }

  function startExpose() {
    // A second dwell while the spread is still in flight is a no-op, never a
    // half-open state.
    if (root.exposeActive || exposeMonitorsProc.running) return
    if (root.floatbarOpened) root.closeFloatbar()
    var wsId = Number(root.focusedWorkspaceId)
    if (!isFinite(wsId)) return
    root.exposeWsId = wsId
    exposeMonitorsProc.running = true
  }

  Process {
    id: exposeMonitorsProc
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.exposeMonitorsJson = String(text || "")
        exposeClientsProc.running = true
      }
    }
  }
  Process {
    id: exposeClientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyExpose(text)
    }
  }

  function applyExpose(clientsText) {
    var wsId = Number(root.exposeWsId)
    root.exposeWsId = -1
    // -1 is the "no spread in flight" sentinel left by a stale run.
    if (!isFinite(wsId) || wsId === -1) return
    var clients = []
    try { clients = JSON.parse(String(clientsText || "[]")) } catch (e) { return }
    if (!Array.isArray(clients)) return
    var monitors = []
    try { monitors = JSON.parse(String(root.exposeMonitorsJson || "[]")) } catch (e) { root.exposeMonitorsJson = ""; return }
    root.exposeMonitorsJson = ""
    if (!Array.isArray(monitors) || monitors.length === 0) return
    var m = null
    for (var j = 0; j < monitors.length; j++) if (monitors[j] && monitors[j].focused === true) { m = monitors[j]; break }
    if (!m) m = monitors[0]
    var scale = m.scale || 1
    var lw = Math.round(m.width / scale)
    var lh = Math.round(m.height / scale)
    var res = (Array.isArray(m.reserved) && m.reserved.length === 4) ? m.reserved : [0, 0, 0, 0]
    var resL = Number(res[0]) || 0
    var resR = Number(res[2]) || 0
    var resB = Number(res[3]) || 0
    // Same box the cascade and the hyprbar double-click expand use: reserved
    // strips out, 10px top inset plus a 1px border on top of it.
    var workTop = 10
    var monX = Number(m.x) || 0
    var monY = Number(m.y) || 0
    var workX = monX + resL + 1
    var workY = monY + workTop + 1
    var workW = lw - resL - resR - 2
    var workH = lh - resB - workTop - 2
    var wins = []
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      if (!c || c.mapped === false || c.hidden === true) continue
      if (!c.workspace || Number(c.workspace.id) !== wsId) continue
      var addr = String(c.address || "")
      if (!/^0x[0-9a-fA-F]+$/.test(addr)) continue
      var sz = Array.isArray(c.size) ? c.size : [0, 0]
      var at = Array.isArray(c.at) ? c.at : [0, 0]
      wins.push({
        address: addr,
        x: Number(at[0]) || 0,
        y: Number(at[1]) || 0,
        w: Math.max(1, Number(sz[0]) || 1),
        h: Math.max(1, Number(sz[1]) || 1),
        floating: c.floating === true,
        fullscreen: Number(c.fullscreen) || 0,
        fullscreenClient: Number(c.fullscreenClient) || 0
      })
    }
    // A lone window, or none at all: the workspace already reads as-is, so the
    // corner must do nothing (the old eligibility rule, minus the "at least one
    // floats" half — tiling is spread and restored just fine now).
    if (wins.length < 2) return

    var n = wins.length
    var cols = Math.ceil(Math.sqrt(n))
    var rows = Math.ceil(n / cols)
    var gap = 12
    var cellW = Math.floor((workW - gap * (cols - 1)) / cols)
    var cellH = Math.floor((workH - gap * (rows - 1)) / rows)
    var saved = []
    var rects = []
    var cmds = []
    for (var k = 0; k < n; k++) {
      var w = wins[k]
      var cellX = workX + (k % cols) * (cellW + gap)
      var cellY = workY + Math.floor(k / cols) * (cellH + gap)
      // Aspect-fit inside the cell and never upscale: a small window keeps its
      // proportions instead of being stretched across the lattice.
      var fit = Math.min(1, cellW / w.w, cellH / w.h)
      var nw = Math.max(1, Math.round(w.w * fit))
      var nh = Math.max(1, Math.round(w.h * fit))
      var px = cellX + Math.round((cellW - nw) / 2)
      var py = cellY + Math.round((cellH - nh) / 2)
      var base = 'window = "address:' + w.address + '"'
      if (w.fullscreen !== 0 || w.fullscreenClient !== 0)
        cmds.push('dispatch hl.dsp.window.fullscreen_state({ internal = 0, client = 0, ' + base + ' })')
      if (!w.floating)
        cmds.push('dispatch hl.dsp.window.float({ action = "toggle", ' + base + ' })')
      root.pushExposeGeometry(cmds, base, nw, nh, px, py)
      saved.push(w)
      rects.push({ address: w.address, x: cellX, y: cellY, w: cellW, h: cellH })
    }
    root.exposeSaved = saved
    root.exposeRects = rects
    root.exposeHoverRect = null
    root.exposeOrigin = ({ x: monX, y: monY })
    root.runExposeBatch(cmds)
    root.persistExposeState()
    root.exposeActive = true
  }

  function exitExpose(keepAddress) {
    var saved = root.exposeSaved
    root.exposeActive = false
    // Flag any spread still in flight as cancelled so its applyExpose() is a
    // no-op instead of snapping the workspace open again after we closed it.
    root.exposeWsId = -1
    root.exposeSaved = []
    root.exposeRects = []
    root.exposeHoverRect = null
    root.clearExposeState()
    root.restoreExposeList(saved, String(keepAddress || ""))
  }

  // Put a list of saved originals back (exit and crash recovery share it).
  function restoreExposeList(list, keepAddress) {
    if (!Array.isArray(list) || list.length === 0) return
    var cmds = []
    for (var i = 0; i < list.length; i++) {
      var w = list[i]
      if (!w || !w.address) continue
      var base = 'window = "address:' + w.address + '"'
      if (!w.floating) {
        // Was tiled: back into the layout, which owns its geometry again.
        cmds.push('dispatch hl.dsp.window.float({ action = "toggle", ' + base + ' })')
      } else {
        // Was floating: restore its own rectangle (a previously fullscreen
        // window gets both, so leaving fullscreen later lands where it was).
        root.pushExposeGeometry(cmds, base, Number(w.w), Number(w.h), Number(w.x), Number(w.y))
      }
      if (Number(w.fullscreen) !== 0 || Number(w.fullscreenClient) !== 0)
        cmds.push('dispatch hl.dsp.window.fullscreen_state({ internal = ' + (Number(w.fullscreen) || 0)
          + ', client = ' + (Number(w.fullscreenClient) || 0) + ', ' + base + ' })')
    }
    if (keepAddress) {
      // Everything is back in place; the picked window goes on top and takes
      // the focus.
      cmds.push('dispatch hl.dsp.window.alter_zorder({ mode = "top", window = "address:' + keepAddress + '" })')
      cmds.push('dispatch hl.dsp.focus({ window = "address:' + keepAddress + '" })')
    }
    root.runExposeBatch(cmds)
  }

  // Resize is centre-anchored in this Hyprland build, so a single resize+move
  // can land one pixel off when the centre sits on a .5 (odd exposed sizes are
  // the common case). Running the pair twice converges: the first pass settles
  // the size, the second one — from an exact position — confirms it, and the
  // trailing move pins the corner back to the requested x/y.
  function pushExposeGeometry(cmds, base, w, h, x, y) {
    cmds.push('dispatch hl.dsp.window.resize({ x = ' + w + ', y = ' + h + ', ' + base + ' })')
    cmds.push('dispatch hl.dsp.window.move({ x = ' + x + ', y = ' + y + ', ' + base + ' })')
    cmds.push('dispatch hl.dsp.window.resize({ x = ' + w + ', y = ' + h + ', ' + base + ' })')
    cmds.push('dispatch hl.dsp.window.move({ x = ' + x + ', y = ' + y + ', ' + base + ' })')
  }

  // One process for the whole sequence: the per-window dispatches are ordered
  // (unfloat before resize before move) and the desktop does not flicker
  // through a dozen racing hyprctl spawns.
  function runExposeBatch(cmds) {
    if (!Array.isArray(cmds) || cmds.length === 0) return
    Quickshell.execDetached(["hyprctl", "--batch", cmds.join("; ")])
  }

  function persistExposeState() {
    var payload = JSON.stringify({ windows: root.exposeSaved })
    Quickshell.execDetached(["bash", "-c", "printf '%s' \"$1\" > \"$0\"", root.exposeStatePath, payload])
  }

  function clearExposeState() {
    Quickshell.execDetached(["rm", "-f", root.exposeStatePath])
  }

  // Crash safety: if the shell dies while the workspace is spread out, the
  // parked originals are put back on the next start (and the file dropped).
  FileView {
    id: exposeStateFile
    path: root.exposeStatePath
    printErrors: false
    onLoaded: {
      if (root.exposeActive) return
      var str = String(text() || "")
      if (str.trim().length === 0) return
      var data = null
      try { data = JSON.parse(str) } catch (e) {}
      if (data && Array.isArray(data.windows) && data.windows.length > 0)
        root.restoreExposeList(data.windows, "")
      Quickshell.execDetached(["rm", "-f", root.exposeStatePath])
    }
  }

  // Pointer position is panel-local; the grid was computed in global logical
  // coordinates, so the monitor origin is added back before hit-testing.
  function updateExposeHover(panelX, panelY) {
    if (!root.exposeActive) return
    var x = panelX + root.exposeOrigin.x
    var y = panelY + root.exposeOrigin.y
    var hit = null
    for (var i = 0; i < root.exposeRects.length; i++) {
      var r = root.exposeRects[i]
      if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) { hit = r; break }
    }
    if (hit !== root.exposeHoverRect) root.exposeHoverRect = hit
  }

  // ---- bottom-left hot corner: hide the strip and the menu bar together ----
  // Re-dwelling the corner toggles everything back. The menu bar's hidden
  // state (flag file at ~/.local/state/omarchy/toggles/bar-off) is remembered
  // so restoring never unhides a bar the user had already hidden. The strip
  // itself belongs to the nagualstrip plugin now: this plugin only asks it to
  // step aside, and the strip keeps its own auto-hide and flash rules.
  property bool chromeHidden: false
  property bool chromeSavedBarOff: false
  property bool barOff: false
  Process {
    id: barOffProbe
    running: true
    command: ["bash", "-c", "[[ -f \"$HOME/.local/state/omarchy/toggles/bar-off\" ]] && echo yes || echo no"]
    stdout: SplitParser { onRead: function(line) { root.barOff = String(line).trim() === "yes" } }
  }
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/toggles"
    watchChanges: true
    printErrors: false
    onFileChanged: barOffProbe.running = true
  }
  function toggleChromeHidden() {
    root.chromeHidden = !root.chromeHidden
    if (root.chromeHidden) root.hideChrome()
    else root.restoreChrome()
  }
  function hideChrome() {
    root.chromeSavedBarOff = root.barOff
    root.setStripChromeHidden(true)
    if (!root.barOff) Quickshell.execDetached(["omarchy-toggle-bar", "on"])
  }
  function restoreChrome() {
    if (!root.chromeSavedBarOff) Quickshell.execDetached(["omarchy-toggle-bar", "off"])
    root.setStripChromeHidden(false)
  }
  // The strip surface is owned by nagualcode.nagualstrip, so its hidden
  // state (and the brief flash on a workspace switch) is driven over IPC.
  function setStripChromeHidden(hidden) {
    Quickshell.execDetached(["omarchy-shell", "-q", "nagualstrip", "setchrome", hidden ? "on" : "off"])
  }

  // Toggle every window on the active workspace between tiling and floating.
  // The top-right hot corner calls this. The target is not a blind flip: the
  // workspace is read first and the majority decides. All floating -> go tiled,
  // all tiled -> go floating, mixed -> the minority joins the majority (a tie
  // resolves to tiled). hl.dsp.window.float set/unset are toggles in this
  // build, so each window is only dispatched to when its state differs.
  property bool allWindowsTiled: false
  property var allTargetWsId: null
  function toggleAllWindowModes() {
    root.allTargetWsId = root.focusedWorkspaceId
    wsClientsProc.running = true
  }
  Process {
    id: wsClientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAllWindowModes(text)
    }
  }
  function applyAllWindowModes(text) {
    var wsId = Number(root.allTargetWsId)
    root.allTargetWsId = null
    if (!isFinite(wsId)) return
    var list = []
    try { list = JSON.parse(text || "[]") } catch (e) { return }
    if (!Array.isArray(list)) return
    var windows = []
    var floatingCount = 0
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (!c || c.mapped === false || c.hidden === true) continue
      if (!c.workspace || Number(c.workspace.id) !== wsId) continue
      var addr = String(c.address || "")
      if (!/^0x[0-9a-fA-F]+$/.test(addr)) continue
      var floating = c.floating === true
      if (floating) floatingCount++
      windows.push({ address: addr, floating: floating, fullscreen: Number(c.fullscreen) || 0 })
    }
    if (windows.length === 0) return
    // Unanimous workspaces flip; mixed ones follow the majority (a tie goes
    // tiled). So: nothing floats -> float everything; everything floats ->
    // tile everything; otherwise only convert when floating is the majority.
    var wantFloating
    if (floatingCount === 0) wantFloating = true
    else if (floatingCount === windows.length) wantFloating = false
    else wantFloating = floatingCount * 2 > windows.length
    root.allWindowsTiled = !wantFloating
    for (var j = 0; j < windows.length; j++) {
      var w = windows[j]
      if (w.floating !== wantFloating) {
        var expr = 'hl.dsp.window.float({ action = "toggle", window = "address:' + w.address + '" })'
        Quickshell.execDetached(["hyprctl", "dispatch", expr])
      }
      // When tiling the whole workspace, a window left in fullscreen or
      // maximized would keep swallowing the layout and hide the rest behind
      // it. Shrink it back into the tiling grid so the screen really splits
      // between every window -- but only when another window exists to share
      // the area, so an intended single-app fullscreen is left alone.
      if (!wantFloating && windows.length > 1 && w.fullscreen !== 0) {
        var fsExpr = 'hl.dsp.window.fullscreen_state({ internal = 0, client = 0, window = "address:' + w.address + '" })'
        Quickshell.execDetached(["hyprctl", "dispatch", fsExpr])
      }
    }
  }

  // ---- Cascade the workspace into floating 700x500 windows ----------------
  // Every mapped window on the active workspace becomes floating, is resized
  // to the default float size and laid out as a heuristic cascade: each window
  // slides a step right-and-down from the previous one, and once the diagonal
  // runs off an edge the offset wraps with the two steps taken modulo the free
  // space. The x and y steps share no common multiple with their respective
  // free extents, so no two windows ever land on the exact same corner — a
  // covered window always peeks out by at least one strip. (Until the lattice
  // repeats, which takes on the order of ~16k windows.)
  property int cascadeWsId: -1
  property string cascadeMonitorsJson: ""
  // Focused window at the moment the corner fires: when it is "maximized"
  // (the manual hyprbar double-click expand to the whole work area, or a real
  // fullscreen state) it is kept as is and the cascade lands on top of it.
  property string cascadeFocusAddress: ""
  function cascadeWorkspaceFloats() {
    root.cascadeWsId = Number(root.focusedWorkspaceId)
    if (!isFinite(root.cascadeWsId)) return
    var active = Hyprland.activeToplevel
    root.cascadeFocusAddress = active ? String(active.address || "").toLowerCase() : ""
    cascadeMonitorsProc.running = true
  }
  Process {
    id: cascadeMonitorsProc
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.cascadeMonitorsJson = String(text || "")
        cascadeClientsProc.running = true
      }
    }
  }
  Process {
    id: cascadeClientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyWorkspaceCascade(text)
    }
  }
  function applyWorkspaceCascade(clientsText) {
    var wsId = Number(root.cascadeWsId)
    root.cascadeWsId = -1
    if (!isFinite(wsId)) return
    var keepAddr = root.cascadeFocusAddress
    root.cascadeFocusAddress = ""
    var clients = []
    try { clients = JSON.parse(String(clientsText || "[]")) } catch (e) { return }
    if (!Array.isArray(clients)) return
    var monitors = []
    try { monitors = JSON.parse(String(root.cascadeMonitorsJson || "[]")) } catch (e) { root.cascadeMonitorsJson = ""; return }
    root.cascadeMonitorsJson = ""
    if (!Array.isArray(monitors) || monitors.length === 0) return
    var m = null
    for (var j = 0; j < monitors.length; j++) if (monitors[j] && monitors[j].focused === true) { m = monitors[j]; break }
    if (!m) m = monitors[0]
    var scale = m.scale || 1
    var lw = Math.round(m.width / scale)
    var lh = Math.round(m.height / scale)
    var res = (Array.isArray(m.reserved) && m.reserved.length === 4) ? m.reserved : [0, 0, 0, 0]
    var resL = Number(res[0]) || 0
    var resR = Number(res[2]) || 0
    var resB = Number(res[3]) || 0
    // Same box a tiled maximized window occupies: reserved strips excluded,
    // fixed 10px top inset and 1px border on top of it. It is also exactly the
    // box the hyprbar double-click expand produces (titlebar-dblclick.sh).
    var workTop = 10
    var workX = resL + 1
    var workY = workTop + 1
    var workW = lw - resL - resR - 2
    var workH = lh - resB - workTop - 2
    var wins = []
    // Focused window parked in place: it stays exactly as it is and the rest
    // of the workspace cascades on top of it. "Maximized" here is the manual
    // hyprbar double-click expand — a plain resize to (almost) the whole work
    // area with no fullscreen flag — using the same 0.85 threshold that
    // script uses to decide a window is big.
    var parkAddr = ""
    var BIG_RATIO = 0.85
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      if (!c || c.mapped === false || c.hidden === true) continue
      if (!c.workspace || Number(c.workspace.id) !== wsId) continue
      var addr = String(c.address || "")
      if (!/^0x[0-9a-fA-F]+$/.test(addr)) continue
      // `focusHistoryID === 0` is the compositor's own "most focused" mark and
      // covers the case where Hyprland.activeToplevel lagged behind the corner
      // press. `fullscreen`: 0 = none, 1 = maximize, 2 = fullscreen.
      var isFocused = (addr.toLowerCase() === keepAddr) || Number(c.focusHistoryID) === 0
      var sz = Array.isArray(c.size) ? c.size : [0, 0]
      var fillsWork = Number(sz[0]) >= BIG_RATIO * workW && Number(sz[1]) >= BIG_RATIO * workH
      if (isFocused && (fillsWork || Number(c.fullscreen) !== 0)) {
        parkAddr = addr
        continue
      }
      wins.push({ address: addr, floating: c.floating === true, fullscreen: Number(c.fullscreen) || 0 })
    }
    if (wins.length === 0) return
    var WIN_W = 700, WIN_H = 500
    var cx = Math.max(0, workW - WIN_W)
    var cy = Math.max(0, workH - WIN_H)
    var n = wins.length
    // Steps adapt to how crowded the workspace is: few windows -> generous
    // slivers, many windows -> tighter diagonal.
    var dx = Math.max(40, Math.min(110, Math.round(cx / Math.min(n, 8))))
    var dy = Math.max(30, Math.min(80, Math.round(cy / Math.min(n, 4))))
    for (var k = 0; k < wins.length; k++) {
      var w = wins[k]
      var base = ' window = "address:' + w.address + '"'
      if (w.fullscreen !== 0)
        Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.window.fullscreen_state({ internal = 0, client = 0,' + base + ' })'])
      if (!w.floating)
        Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.window.float({ action = "toggle",' + base + ' })'])
      var px = workX + ((k * dx) % (cx + 1))
      var py = workY + ((k * dy) % (cy + 1))
      Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.window.resize({ x = ' + WIN_W + ', y = ' + WIN_H + ',' + base + ' })'])
      Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.window.move({ x = ' + px + ', y = ' + py + ',' + base + ' })'])
      // A maximized window was parked: lift the freshly cascaded window above
      // it so the cascade always lands on top of the kept window.
      if (parkAddr !== "")
        Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.window.alter_zorder({ mode = "top",' + base + ' })'])
    }
  }

  // ---- Cursor-based hot-corner detection --------------------------------
  // The pointer position is read straight from Hyprland instead of relying
  // on hover on a layer window. An overlay surface that sits on top in a
  // corner (e.g. nagualcode.thetinybuttons) can therefore never swallow the
  // trigger; corners fire regardless of layer stacking or plugin load order.
  property var cornerInsideMs: ({ "top-left": 0, "top-right": 0, "bottom-left": 0, "bottom-right": 0, "bottom-center": 0 })
  property var cornerFired: ({ "top-left": false, "top-right": false, "bottom-left": false, "bottom-right": false, "bottom-center": false })
  property bool cursorSampleWanted: false

  function parseCursorPos(raw) {
    var s = String(raw || "").trim()
    var c = s.indexOf(",")
    if (c < 1) return null
    var x = parseFloat(s.substring(0, c))
    var y = parseFloat(s.substring(c + 1))
    if (!isFinite(x) || !isFinite(y)) return null
    return [x, y]
  }

  function sampleCursorPos() {
    if (cursorPosProc.running) {
      // hyprctl still busy (spawn + socket round trip is ~50ms): park a
      // request instead of dropping the tick, then re-issue on finish.
      cursorSampleWanted = true
      return
    }
    cursorPosProc.running = true
  }

  function onCursorPosition(x, y) {
    if (!root.cornersEnabled) return
    if (!panel || panel.width <= 0 || panel.height <= 0) return
    if (x < 0 || y < 0 || x > panel.width || y > panel.height) return

    var w = panel.width
    var h = panel.height
    var z = root.targetSize
    var edge = ""
    if (x >= w - z && y <= z) edge = "top-right"
    else if (x <= z && y <= z) edge = "top-left"
    else if (x <= z && y >= h - z) edge = "bottom-left"
    else if (x >= w - z && y >= h - z) edge = "bottom-right"
    // bottom-center: one quarter of the bottom edge's width, centered on its
    // midpoint (same targetSize tall as the corners).
    else if (Math.abs(x - w / 2) <= w / 8 && y >= h - z) edge = "bottom-center"
    // Disabling the bottom-center toggle makes that hot-corner inert, so the
    // strip can never disappear through it.
    if (edge === "bottom-center" && !root.stripToggleEnabled) edge = ""

    var edges = ["top-left", "top-right", "bottom-left", "bottom-right", "bottom-center"]
    for (var i = 0; i < edges.length; i++) {
      var e = edges[i]
      if (e === edge) {
        // Already fired for this entry: stay latched until the pointer
        // leaves the corner, so resting in the corner fires only once.
        if (root.cornerFired[e]) continue
        root.cornerInsideMs[e] += cursorPollTimer.interval
        if (root.cornerInsideMs[e] >= root.dwellMs) {
          root.cornerInsideMs[e] = 0
          root.cornerFired[e] = true
          // While the icon panel is up its fullscreen mask owns the pointer;
          // only the panel's own corner may fire then (the toggle-off). The
          // other corners stay latched until the pointer leaves.
          if (root.floatbarOpened && e !== "bottom-left") continue
          root.triggerCorner(e)
        }
      } else {
        root.cornerInsideMs[e] = 0
        root.cornerFired[e] = false
      }
    }
  }

  Timer {
    id: cursorPollTimer
    interval: 50
    repeat: true
    triggeredOnStart: true
    // Sampling keeps running while the icon panel is up so its hot-corner
    // trigger works as a toggle: re-dwelling the panel's own corner closes it
    // again. While the panel is open only that corner is honoured (see
    // onCursorPosition).
    running: root.cornersEnabled
    onTriggered: root.sampleCursorPos()
  }

  Process {
    id: cursorPosProc
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = root.parseCursorPos(text)
        if (p) root.onCursorPosition(p[0], p[1])
        // chained sampling: go again right away if a tick arrived meanwhile
        if (root.cursorSampleWanted) {
          root.cursorSampleWanted = false
          root.sampleCursorPos()
        }
      }
    }
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
  //  ICON PANEL (bottom-left)
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

  // QVariantList crosses the model -> delegate boundary as a QVariantList, for
  // which Array.isArray() returns false in QML even though it concats/spreads
  // like a real array. Coerce array-likes to a fresh native JS array instead of
  // trusting Array.isArray().
  function toArgv(value) {
    var out = []
    if (value && typeof value.length === "number") {
      for (var i = 0; i < value.length; i++) out.push(String(value[i]))
    }
    return out
  }

  // App-launcher actions shown in the grid (draggable like everything else).
  // Browser/terminal/folder go through Omarchy's default-app launchers or the
  // uwsm-app-attached desktop entry (gtk-launch), so a bare binary spawn from
  // this overlay never surfaces a window. The browser is launched through its
  // .desktop entry on purpose — this skips omarchy-launch-browser's forced
  // incognito mode and opens the system default browser normally.
  readonly property var actionEntries: [
    { id: "browser", glyph: "\uf0ac", label: "Browser", command: ["sh", "-lc", "b=\"$(env -u BROWSER xdg-settings get default-web-browser 2>/dev/null)\"; [ -z \"$b\" ] && b=\"$(xdg-mime query default x-scheme-handler/https)\"; setsid uwsm-app -- gtk-launch \"$b\""] },
    { id: "terminal", glyph: "\uf120", label: "Terminal", command: ["omarchy-launch-terminal"] },
    { id: "text", glyph: "\uf15c", label: "Text", command: ["featherpad"] },
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
    if (cell.kind === "toggle") return "\u22ee"
    return "\uf111"
  }

  function cellGlyphFont(cell) {
    if (!cell) return root.fontFamily
    if (cell.kind === "toggle") return root.fontFamily
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
      "omarchy.power": "\uf011",
      "quickshell.spotify": "\uf1bc",
      "io.github.moizibnyousaf.omawhatsapp": "\uf232"
    }
    return map[id] !== undefined ? map[id] : "\uf111"
  }

  // The generic fallback glyph above (\uf111) is only ever a placeholder: when
  // a bar widget is an actual app (a plugin added to the menu bar), its tile
  // should show the app's real icon instead. Identity candidates come from the
  // widget registry metadata (displayName) plus the widget id, then the same
  // desktop-entry matching the workspace cards use.
  function widgetIdentityCandidates(id) {
    var candidates = []
    var meta = root.barWidgetRegistry ? root.barWidgetRegistry.metadataFor(String(id)) : null
    var display = meta && meta.displayName ? String(meta.displayName) : ""
    function add(value) {
      var v = String(value || "").trim()
      if (v && candidates.indexOf(v) === -1) candidates.push(v)
    }
    add(display)
    add(id)
    return candidates
  }

  // A widget's glyph, unless it is only the generic placeholder.
  function nonGenericGlyph(id) {
    var g = root.glyphFor(id)
    return String(g) === "\uf111" ? "" : String(g)
  }

  function widgetDesktopEntry(id) {
    var member = {
      className: String(id || ""),
      initialClass: String(id || ""),
      iconCandidates: root.widgetIdentityCandidates(id)
    }
    var entry = IconModel.matchDesktopEntry(member, root.desktopEntries)
    if (entry) return entry
    var candidates = root.widgetIdentityCandidates(id)
    for (var i = 0; i < candidates.length; i++) {
      var c = String(candidates[i] || "").trim()
      if (!c) continue
      try {
        entry = DesktopEntries.byId(c)
          || DesktopEntries.byId(c + ".desktop")
          || DesktopEntries.heuristicLookup(c)
        if (entry) break
      } catch (error) {}
    }
    return entry
  }

  function widgetImageSourceFor(id) {
    var entry = root.widgetDesktopEntry(id)
    var candidates = root.widgetIdentityCandidates(id)
    var genericSource = String(Quickshell.iconPath("application-x-executable", true) || "")
    function actual(source) {
      var value = String(source || "")
      return value.length > 0 && value !== genericSource ? source : ""
    }
    if (entry && entry.icon) {
      if (root.appLibrary && typeof root.appLibrary.iconSource === "function") {
        var libraryIcon = actual(root.appLibrary.iconSource(entry.icon))
        if (libraryIcon) return libraryIcon
      }
      var entryIcon = actual(Quickshell.iconPath(String(entry.icon), true))
      if (entryIcon) return entryIcon
    }
    for (var j = 0; j < candidates.length; j++) {
      var classIcon = actual(Quickshell.iconPath(String(candidates[j] || ""), true))
      if (classIcon) return classIcon
    }
    return ""
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
    if (!id) return
    if (String(id) === "quickshell.spotify") {
      Quickshell.execDetached(["omarchy-shell", "-q", "quickshell.spotify.player", "toggleBarWidget"])
      Qt.callLater(function() { root.closeFloatbar() })
      return
    }
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", String(id), "{}"])
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

  Timer {
    // Cover the slide-out after close: the float bar stays visible (fbSliding)
    // for exactly the slide duration, then hides.
    id: fbSlideOutTimer
    interval: root.effectivePanelAnimMs
    onTriggered: root.fbSliding = false
  }

  function openFloatbar(payloadJson) {
    root.readConfig()
    root.refreshWidgetEntries()
    root.pollIndicators()
    root.checkSystemUpdate()
    // The two surfaces both want the full-screen mask and the keyboard; the
    // spread gives way first.
    if (root.exposeActive) root.exitExpose("")
    root.floatbarOpened = true
    // Two Overlay surfaces would otherwise fight over layer stacking and the
    // keyboard: the strip steps aside for as long as the panel is up.
    Quickshell.execDetached(["omarchy-shell", "-q", "nagualstrip", "suspend"])
  }
  function closeFloatbar() {
    root.floatbarOpened = false
    if (root.effectivePanelAnimMs > 0) fbSlideOutTimer.start()
    else root.fbSliding = false
    // Back to whatever visibility the strip had before the panel opened.
    Quickshell.execDetached(["omarchy-shell", "-q", "nagualstrip", "resume"])
  }
  function toggleFloatbar() { root.floatbarOpened ? root.closeFloatbar() : root.openFloatbar("{}") }

  // The bottom-left corner is left unassigned by default so the user can bind
  // any action to it from shell.json.

  // ========================================================================
  //  Desktop entry cache (icons of the icon panel's widget buttons)
  // ========================================================================
  property var desktopEntries: []

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

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.refreshDesktopEntries() }
  }

  readonly property var focusedWorkspaceId: {
    var ws = Hyprland.focusedWorkspace
    return ws ? ws.id : null
  }

  Component.onCompleted: {
    root.readConfig()
    root.refreshDesktopEntries()
    Qt.callLater(function() {
      // Guarded: during a hot reload the root object can be re-instantiated
      // before this delayed call runs, which used to throw "is not a function"
      // and leave the plugin's interactivity broken until a shell restart.
      if (typeof root.refreshWidgetEntries === "function") root.refreshWidgetEntries()
    })
  }

  // The workspace strip, its configuration popup and the smart app grid live
  // in the nagualcode.nagualstrip plugin; this plugin keeps the hot corners,
  // the icon panel and the live expose.

  // ========================================================================
  //  Shell panel contract + legacy IPC targets
  // ========================================================================
  function open(payloadJson) {
    // Generic summon lands on the icon panel surface.
    root.openFloatbar(payloadJson)
    return "ok"
  }
  function close() {
    root.closeFloatbar()
    return "ok"
  }
  function toggle() { root.anyOpen ? root.close() : root.open("") }
  function refresh() { root.readConfig(); root.refreshWidgetEntries(); return "ok" }
  function ping() { return "ok" }

  function stateString() {
    return (root.anyOpen ? "open" : "closed")
      + " float=" + (root.floatbarOpened ? "1" : "0")
      + " chrome=" + (root.chromeHidden ? "1" : "0")
      + " expose=" + (root.exposeActive ? "1" : "0")
  }

  IpcHandler {
    target: "speakercorners"
    function open(): string { root.open(""); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function state(): string { return root.stateString() }
    function version(): string { return "v2-lp" }
    // Run a corner action directly (same path the hot corners use). Useful
    // for keybindings: omarchy-shell speakercorners triggeraction toggle-window-modes
    function triggeraction(action: string): string {
      root.trigger(String(action || ""))
      return "ok"
    }
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

  // The "mirador" target keeps its name so existing commands and keybindings
  // (`omarchy-shell mirador toggle`) now drive the live expose.
  IpcHandler {
    target: "mirador"
    function open(payload: string): string { root.startExpose(); return "ok" }
    function close(): string { root.exitExpose(""); return "ok" }
    function toggle(): string { root.toggleExpose(); return "ok" }
    function cycle(): string { root.toggleExpose(); return "ok" }
    function summon(payload: string): string { root.startExpose(); return "ok" }
    function dismiss(): string { root.exitExpose(""); return "ok" }
    function state(): string { return root.exposeActive ? "open" : "closed" }
    function diagnose(): string {
      return (root.exposeActive ? "open" : "closed")
        + " windows=" + root.exposeSaved.length
        + " cells=" + root.exposeRects.length
        + " hover=" + (root.exposeHoverRect ? root.exposeHoverRect.address : "-")
        + " ws=" + root.exposeWsId
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
    // showing. The app menu takes the full screen too — it is a modal panel,
    // and it needs the keyboard for its search field.
    mask: Region {
      // Fullscreen block while the float bar or the live expose is up: it
      // swallows outside clicks (dismissing the bar / cancelling the spread)
      // and keeps follow_mouse from reshuffling the focus over the expose.
      // The workspace strip, its configuration popup and the app grid live in
      // the nagualstrip plugin's own window, which carries its own regions.
      Region { x: 0; y: 0; width: root.keysWanted ? panel.width : 0; height: root.keysWanted ? panel.height : 0 }
    }

    // Transparent click-catcher: closing the float bar on any outside click.
    // No fill color at all — the float bar stays backdrop-free.
    MouseArea {
      anchors.fill: parent
      z: 1
      visible: root.floatbarOpened
      onClicked: root.closeFloatbar()
    }

    // ---- Float bar card (bottom-left) ----
    BorderSurface {
      z: 2
      // Kept visible for the closing slide via fbSliding (see closeFloatbar()).
      visible: root.floatbarOpened || root.fbSliding
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
      // Slides up from below the screen edge; parked off-screen when closed.
      y: root.floatbarOpened ? panel.height - height - root.cornerMargin : panel.height
      Behavior on y {
        NumberAnimation { duration: root.effectivePanelAnimMs; easing.type: Easing.OutCubic }
      }

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

    // ---- Hot-corner detection ----
    // No hover MouseAreas here: the corners now fire from the pointer
    // position read through Hyprland (see sampleCursorPos), so an overlay
    // surface that sits on top in a corner cannot swallow the trigger.

    // ---- Keyboard routing (float bar + live expose) ----
    Item {
      id: keyRouter
      anchors.fill: parent
      focus: root.keysWanted
      enabled: root.keysWanted
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key !== Qt.Key_Escape) return
        if (root.exposeActive) {
          root.exitExpose("")
          event.accepted = true
          return
        }
        if (root.floatbarOpened) {
          root.closeFloatbar()
          event.accepted = true
        }
      }
    }

    // ---- Live expose: pointer capture + cell highlight ----
    // The input region already covers the whole screen while the expose is up
    // (see the mask above), so this area both keeps the pointer off the windows
    // — follow_mouse would otherwise reshuffle the focus mid-spread — and turns
    // a click into a pick. Empty space cancels; the picked window is restored
    // with everything else and raised.
    MouseArea {
      id: exposeMouse
      anchors.fill: parent
      z: 60
      visible: root.exposeActive
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onPositionChanged: function(m) { root.updateExposeHover(m.x, m.y) }
      onClicked: function(m) {
        if (!root.exposeActive) return
        var r = root.exposeHoverRect
        root.exitExpose(r ? r.address : "")
      }
    }

    Rectangle {
      id: exposeHighlight
      z: 61
      visible: root.exposeActive && root.exposeHoverRect !== null
      x: visible ? root.exposeHoverRect.x - root.exposeOrigin.x : 0
      y: visible ? root.exposeHoverRect.y - root.exposeOrigin.y : 0
      width: visible ? root.exposeHoverRect.w : 0
      height: visible ? root.exposeHoverRect.h : 0
      color: "transparent"
      radius: 8
      border.width: 3
      border.color: Util.alpha(Color.accent, 0.9)
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
    property string imageSource: ""
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
      visible: String(tile.imageSource || "").length === 0
      text: tile.text
      color: tile.displayColor
      font.family: tile.fontFamily
      font.pixelSize: tile.fontPixelSize
      renderType: Text.NativeRendering

      Behavior on color {
        ColorAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
    }

    // Real app icon (resolved from a desktop entry) shown whenever the tile's
    // text is just a generic placeholder. Tinted to the tile colour so it
    // matches the surrounding glyphs.
    Image {
      id: tileIcon
      anchors.centerIn: parent
      visible: String(tile.imageSource || "").length > 0
      width: Math.max(Style.space(18), Math.round(tile.tileSize * 0.52))
      height: Math.max(Style.space(18), Math.round(tile.tileSize * 0.52))
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      source: tile.imageSource
      sourceSize.width: Math.max(1, Math.round(width * Math.max(1, Math.round(Screen.devicePixelRatio))))
      sourceSize.height: Math.max(1, Math.round(height * Math.max(1, Math.round(Screen.devicePixelRatio))))
      layer.enabled: visible
      layer.effect: MultiEffect {
        colorization: 1.0
        colorizationColor: tile.displayColor
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

    // Widgets (things added to the menu bar) show their mapped glyph; when the
    // mapping is only the generic placeholder, resolve the app's real icon.
    readonly property string widgetMappedGlyph: gcell.kind === "widget"
      ? root.nonGenericGlyph(gcell.cellId)
      : ""
    readonly property string widgetImageSource: gcell.kind === "widget" && widgetMappedGlyph.length === 0
      ? root.widgetImageSourceFor(gcell.cellId)
      : ""

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
        text: gcell.widgetMappedGlyph.length > 0
          ? gcell.widgetMappedGlyph
          : (String(gcell.widgetImageSource).length > 0 ? "" : root.glyphFor(gcell.cellId))
        imageSource: gcell.widgetImageSource
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
          var cmd = root.toArgv(gcell.cellData && gcell.cellData.command)
          if (cmd.length > 0)
            Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "speakercorners-action"].concat(cmd))
          root.closeFloatbar()
        }
      }

      FloatButton {
        anchors.fill: parent
        visible: gcell.kind === "toggle"
        text: "\u22ee"
        fontFamily: root.fontFamily
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

}
