import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// Speaker Corners — hot corners and the live expose, in one plugin.
//
// One always-mapped fullscreen Overlay window holds:
//   * embedded hot-corner recognition (top-left / top-right / bottom-left /
//     bottom-right / bottom-center)
//   * the live expose (bottom-right)
// The window's `mask` only admits input where something interactive lives, so
// the desktop stays fully click-through everywhere else.
//
// The floating workspace strip, its configuration popup and the smart app
// grid live in their own plugin, nagualcode.nagualstrip; the two coordinate
// over IPC (see setStripChromeHidden() and internalCommand()).
//
// Configuration lives in shell.json in the plugin's own entry:
//   "plugins": [
//     { "id": "speakercorners",
//       "dwellMs": 139, "targetSize": 8,
//       "topLeftAction": "cascade-floats",
//       "topRightAction": "toggle-window-modes",
//       "bottomLeftAction": "toggle-hide-chrome",  "bottomLeftCommand": "",
//       "bottomRightAction": "mirador",
//       "bottomCenterAction": "none" }
//   ]
//
// Corners can also be reassigned from the command line (wrapper in bin/,
// symlinked to ~/.local/bin):
//   omarchy-speakercorners-corner <corner> <expose|zen|cascade|arrange|none|command [cmd...]>
//   omarchy-speakercorners-corner reset          # back to the defaults above
// Each call writes shell.json and applies to the running corners at once.
// The bottom-center corner is inert by default; point it at nagualstrip's
// legacy `workspace-overview` IPC target to summon the workspace strip:
//   omarchy-speakercorners-corner bottom-center command "omarchy-shell workspace-overview toggle"
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
  // The live expose is the only surface left, so it is what "open" means.
  readonly property bool anyOpen: root.exposeActive
  // The shell's isPluginOpen() reads `opened` off the loaded item; keep it in
  // sync so `omarchy-shell shell toggle speakercorners` round-trips cleanly.
  readonly property bool opened: root.anyOpen
  // The live expose takes full-screen keyboard focus; everything else stays
  // click-through through the mask.
  readonly property bool keysWanted: root.exposeActive
  // Whether the bottom-center hot corner is armed, taken from the nagualstrip
  // plugin's shell.json entry (see readConfig()).
  property bool stripToggleEnabled: true

  // ---- Hot-corner settings (read from the plugins[] entry) ---------------
  property var pluginSettings: ({})
  property bool configLoaded: false
  property int dwellMs: 139
  property int targetSize: 8
  property bool cornersEnabled: true

  function setting(key, fallback) {
    var value = root.pluginSettings[key]
    return value === undefined || value === null ? fallback : value
  }

  function actionFor(edge) {
    if (edge === "top-left") return String(setting("topLeftAction", "cascade-floats"))
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
    root.dwellMs = Math.max(120, Math.min(3000, Number(setting("dwellMs", 139) || 139)))
    root.targetSize = Math.max(4, Math.min(120, Number(setting("targetSize", 8) || 8)))
    root.cornersEnabled = setting("enabled", true) !== false
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
      // Ignore the echo of our own applyCornerSettings write: the running
      // corners already picked up the new values in-memory, and a stale re-read
      // would revert them.
      if (str !== "" && str === root.lastWrittenShellText) return
      root.userShellConfig = root.parseUserConfig(str)
      if (root.configLoaded) root.readConfig()
    }
    onLoadFailed: root.userShellConfig = ({})
  }
  // Content we last pushed via applyCornerSettings (see the onLoaded guard).
  property string lastWrittenShellText: ""

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

  // The friendly names users meet everywhere (corners, IPC, README) map to
  // the internal action ids; internal ids pass through untouched, so both
  // "expose" and "mirador" work interchangeably.
  function nativeActionFor(name) {
    switch (String(name)) {
    case "expose": return "mirador"
    case "zen": return "toggle-hide-chrome"
    case "cascade": return "cascade-floats"
    case "arrange": return "toggle-window-modes"
    default: return String(name)
    }
  }

  // Canonical default for each corner: the four named gestures in their slots
  // and the bottom-center corner left inert. `corner reset` restores exactly
  // this and clears every *Command.
  function cornerDefaults() {
    return {
      "top-left":      { action: "cascade-floats",      command: "" },
      "top-right":     { action: "toggle-window-modes", command: "" },
      "bottom-left":   { action: "toggle-hide-chrome",  command: "" },
      "bottom-right":  { action: "mirador",             command: "" },
      "bottom-center": { action: "none",                command: "" }
    }
  }

  function trigger(action, command) {
    action = root.nativeActionFor(action)
    switch (String(action)) {
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
    root.trigger(root.actionFor(edge), root.commandFor(edge))
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
  // The exact exposed rectangles of the painted windows (cell + ~3px air), also
  // in global logical coordinates: the hover border hugs the window rather
  // than its whole slot, while the slots above keep a generous pick area.
  property var exposeWinRects: []
  // Exposed window currently under the pointer, or null over empty space.
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
    var wsId = Number(root.focusedWorkspaceId)
    // Only ordinary workspaces spread (ids are >= 1); 0 is the transient
    // "no workspace yet" right after the shell starts and special workspaces
    // carry negative ids, neither is a valid grid target.
    if (!isFinite(wsId) || wsId < 1) return
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
    var winRects = []
    var PAD = 3
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
      winRects.push({ address: w.address, x: px - PAD, y: py - PAD, w: nw + 2 * PAD, h: nh + 2 * PAD })
    }
    root.exposeSaved = saved
    root.exposeRects = rects
    root.exposeWinRects = winRects
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
    root.exposeWinRects = []
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
  // coordinates, so the monitor origin is added back before hit-testing. The
  // slot (ref) decides what is under the cursor, but the border follows the
  // real exposed window so it never floats in a gap the window does not fill.
  function updateExposeHover(panelX, panelY) {
    if (!root.exposeActive) return
    var x = panelX + root.exposeOrigin.x
    var y = panelY + root.exposeOrigin.y
    var hit = null
    for (var i = 0; i < root.exposeRects.length; i++) {
      var r = root.exposeRects[i]
      if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) { hit = r; break }
    }
    var win = null
    if (hit) {
      for (var w = 0; w < root.exposeWinRects.length; w++)
        if (root.exposeWinRects[w].address === hit.address) { win = root.exposeWinRects[w]; break }
    }
    if (win !== root.exposeHoverRect) root.exposeHoverRect = win
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
    // Sampling keeps running while the expose is up so re-dwelling the
    // bottom-right corner closes it again.
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

  readonly property var focusedWorkspaceId: {
    var ws = Hyprland.focusedWorkspace
    return ws ? ws.id : null
  }

  // ---- Corner functions over IPC ------------------------------------------
  // `omarchy-shell speakercorners corner <corner> <expose|zen|cascade|arrange|none|command [cmd...]>`
  // assigns a gesture to any corner, and `corner reset` puts every corner back
  // on the plugin defaults (bottom-center inert). Writes land in shell.json
  // and apply immediately, without a shell restart.

  function cornerKeysFor(edge) {
    switch (String(edge)) {
    case "top-left": return ["topLeftAction", "topLeftCommand"]
    case "top-right": return ["topRightAction", "topRightCommand"]
    case "bottom-left": return ["bottomLeftAction", "bottomLeftCommand"]
    case "bottom-right": return ["bottomRightAction", "bottomRightCommand"]
    case "bottom-center": return ["bottomCenterAction", "bottomCenterCommand"]
    default: return null
    }
  }

  function cornerCommand(payload) {
    root.readConfig()
    var text = String(payload || "").trim()
    if (text.length === 0)
      return "usage: corner <top-left|top-right|bottom-left|bottom-right|bottom-center> "
        + "<expose|zen|cascade|arrange|none|command [cmd...]> — or corner reset"
    if (text === "reset") {
      root.cornerReset()
      return "all corners back to default"
    }
    var sp = text.indexOf(" ")
    if (sp <= 0) return "unknown corner or missing function (try: corner reset)"
    var edge = text.substr(0, sp).trim()
    var rest = text.substr(sp + 1).trim()
    var keys = root.cornerKeysFor(edge)
    if (!keys) return "unknown corner: " + edge
    var sp2 = rest.indexOf(" ")
    var name = (sp2 < 0 ? rest : rest.substr(0, sp2)).trim()
    var cmdText = (sp2 < 0 ? "" : rest.substr(sp2 + 1).trim())
    var action = String(name)
    var native = ["expose", "zen", "cascade", "arrange", "none"]
    if (native.indexOf(action) === -1 && action !== "command")
      return "unknown function: " + name
      + " (expose, zen, cascade, arrange, none, command [cmd...])"
    action = root.nativeActionFor(action)
    var updates = {}
    if (action === "command") {
      if (cmdText.length === 0) return "command needs a command line to run"
      updates[keys[0]] = "command"
      updates[keys[1]] = cmdText
    } else {
      updates[keys[0]] = action
      updates[keys[1]] = ""
    }
    root.applyCornerSettings(updates)
    return edge + " -> " + (name === "command" ? "command" : name)
      + (action === "command" ? " \"" + cmdText + "\"" : "")
  }

  function cornerReset() {
    var defaults = root.cornerDefaults()
    var updates = {}
    for (var edge in defaults) {
      var keys = root.cornerKeysFor(edge)
      updates[keys[0]] = defaults[edge].action
      updates[keys[1]] = defaults[edge].command
    }
    root.applyCornerSettings(updates)
  }

  // Shared writer: update the speakercorners entry in shell.json (ignoring the
  // echo through the FileView) and slide the new values into pluginSettings so
  // the running corners react immediately.
  function applyCornerSettings(updates) {
    var cfg = root.parseUserConfig(userShellFile.text())
    if (!Array.isArray(cfg.plugins)) cfg.plugins = []
    var entry = null
    for (var i = 0; i < cfg.plugins.length; i++)
      if (cfg.plugins[i] && String(cfg.plugins[i].id) === "speakercorners") { entry = cfg.plugins[i]; break }
    if (!entry) { entry = {}; cfg.plugins.push(entry) }
    entry.id = "speakercorners"
    for (var k in updates) entry[k] = updates[k]
    var payload = JSON.stringify(cfg, null, 2) + "\n"
    root.lastWrittenShellText = payload
    userShellFile.setText(payload)
    for (var k2 in updates) root.pluginSettings[k2] = updates[k2]
  }

  // ========================================================================
  //  Shell panel contract + IPC targets
  // ========================================================================
  function open(payloadJson) {
    // The live expose is the only surface this panel owns now.
    root.startExpose()
    return "ok"
  }
  function close() {
    root.exitExpose("")
    return "ok"
  }
  function toggle() { root.anyOpen ? root.close() : root.open("") }
  function refresh() { root.readConfig(); return "ok" }
  function ping() { return "ok" }

  function stateString() {
    return (root.anyOpen ? "open" : "closed")
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
    // Assign a gesture to a corner, or reset every corner to the defaults:
    //   omarchy-shell speakercorners corner bottom-right expose
    //   omarchy-shell speakercorners corner top-right command "omarchy-shell workspace-overview toggle"
    //   omarchy-shell speakercorners corner reset
    function corner(payload: string): string { return root.cornerCommand(payload) }
    function cornerReset(): string { root.cornerReset(); return "all corners back to default" }
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
    // on screen keeps receiving the pointer. The five corner hot zones are
    // detected straight from the pointer position (see sampleCursorPos), so
    // the mask only has to admit the live expose: while it is up the whole
    // screen belongs to it, swallowing outside clicks and keeping follow_mouse
    // from reshuffling the focus over the spread. The workspace strip lives in
    // the nagualstrip plugin's own window, which carries its own regions.
    mask: Region {
      Region { x: 0; y: 0; width: root.keysWanted ? panel.width : 0; height: root.keysWanted ? panel.height : 0 }
    }

    // ---- Hot-corner detection ----
    // No hover MouseAreas here: the corners fire from the pointer position
    // read through Hyprland (see sampleCursorPos), so an overlay surface that
    // sits on top in a corner cannot swallow the trigger.

    // ---- Keyboard routing (live expose) ----
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

    // Translucent scrim over the hovered window. It carries no frame: the ring
    // always echoes the window's own rounded corners from the look-and-feel
    // (Style.cornerRadius) and tints the highlight with a 50% accent wash.
    Rectangle {
      id: exposeHighlight
      z: 61
      visible: root.exposeActive && root.exposeHoverRect !== null
      x: visible ? root.exposeHoverRect.x - root.exposeOrigin.x : 0
      y: visible ? root.exposeHoverRect.y - root.exposeOrigin.y : 0
      width: visible ? root.exposeHoverRect.w : 0
      height: visible ? root.exposeHoverRect.h : 0
      color: Util.alpha(Color.accent, 0.5)
      radius: root.cornerRadius
    }
  }

  Component.onCompleted: root.readConfig()
}
