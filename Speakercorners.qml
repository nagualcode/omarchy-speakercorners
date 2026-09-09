import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Workspaces.js" as WorkspaceModel

// Speaker Corners — everything the corner of the screen does, in one plugin.
//
// One always-mapped fullscreen Overlay window holds:
//   * embedded hot-corner recognition (top-left / bottom-left / bottom-right)
//   * the float bar card  (top-left, no backdrop)
//   * the super-apps grid (screen-centered)
//   * the floating workspace switcher strip (bottom-center)
// plus a shared keyboard focus for the two blocking views; a visual scrim is
// only cast for super-apps.
//
// Previously these were three keepLoaded plugins (floatbar, super-apps,
// workspaces-float) plus the quattro-corners service (4 extra windows per
// screen). Here a single masked surface replaces all of them: the window's
// `mask` only admits input where something interactive lives, so the desktop
// stays fully click-through everywhere else.
//
// Configuration lives in shell.json in the plugin's own entry, using the same
// schema the quattro-corners bar entry used:
//   "plugins": [
//     { "id": "speakercorners",
//       "dwellMs": 139, "targetSize": 8,
//       "topLeftAction": "command",  "topLeftCommand": "omarchy-shell floatbar toggle",
//       "topRightAction": "none",    "topRightCommand": "",
//       "bottomLeftAction": "command","bottomLeftCommand": "omarchy-shell super-apps toggle",
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
  property bool superappsOpened: false
  property bool workspacesOpened: false

  readonly property bool anyOpen: root.floatbarOpened || root.superappsOpened || root.workspacesOpened
  // The shell's isPluginOpen() reads `opened` off the loaded item; keep it in
  // sync so `omarchy-shell shell toggle speakercorners` round-trips cleanly.
  readonly property bool opened: root.anyOpen
  // The visual backdrop only appears for super-apps (the float bar is a plain
  // floating card, no dimming behind it).
  readonly property bool scrimmed: root.superappsOpened
  // The blocking views (float bar or super-apps) still take full-screen input
  // so their widgets are interactive and desktop clicks are swallowed.
  readonly property bool keysWanted: root.floatbarOpened || root.superappsOpened

  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

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
    if (edge === "top-left") return String(setting("topLeftAction", "command"))
    if (edge === "top-right") return String(setting("topRightAction", "none"))
    if (edge === "bottom-left") return String(setting("bottomLeftAction", "command"))
    if (edge === "bottom-right") return String(setting("bottomRightAction", "command"))
    return "none"
  }

  function commandFor(edge) {
    if (edge === "top-left") return String(setting("topLeftCommand", "omarchy-shell floatbar toggle"))
    if (edge === "top-right") return String(setting("topRightCommand", ""))
    if (edge === "bottom-left") return String(setting("bottomLeftCommand", "omarchy-shell super-apps toggle"))
    if (edge === "bottom-right") return String(setting("bottomRightCommand", "omarchy-shell workspace-overview toggle"))
    return ""
  }

  function readConfig() {
    var cfg = ({})
    if (shell && shell.shellConfig && Array.isArray(shell.shellConfig.plugins)) {
      var list = shell.shellConfig.plugins
      for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].id) === "speakercorners") { cfg = list[i]; break }
      }
    }
    root.pluginSettings = cfg
    root.dwellMs = Math.max(120, Math.min(3000, Number(setting("dwellMs", 400) || 400)))
    root.targetSize = Math.max(4, Math.min(120, Number(setting("targetSize", 24) || 24)))
    root.cornersEnabled = setting("enabled", true) !== false
    root.configLoaded = true
  }

  // Notification history toggle state (reused by the "notifications" action).
  property bool historyShown: false
  Timer {
    id: historyReset
    interval: 12000
    repeat: false
    onTriggered: root.historyShown = false
  }

  // Run a corner action. Commands that target this plugin's own surfaces are
  // dispatched straight to the matching toggle (no subprocess), everything
  // else falls back to `sh -lc` exactly like quattro-corners did.
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
    if (target === "super-apps") {
      if (method === "toggle") { root.toggleSuperapps() } else if (method === "open") { root.openSuperapps("") } else if (method === "close") { root.closeSuperapps() } else return false
      return true
    }
    if (target === "workspace-overview") {
      if (method === "toggle") { root.toggleWorkspaces() } else if (method === "open") { root.showWorkspaces() } else if (method === "close") { root.hideWorkspaces() } else return false
      return true
    }
    if (target === "shell" && method === "toggle" && tokens[3] === "super-apps") {
      root.toggleSuperapps()
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
  readonly property color scrimColor: Color.menu.scrim

  // ---- Widgets that never appear in the floatbar ----
  readonly property var removedWidgetIds: [
    "omarchy.keyboard-layout",
    "omarchy.system-update",
    "omarchy.agents",
    "omarchy.tray",
    "omarchy.indicators"
  ]

  // ---- Widgets rendered live inside the floatbar instead of an icon button ----
  readonly property var embeddedWidgetIds: [ "omarchy.clock", "omarchy.power" ]

  readonly property bool hasPowerWidget: {
    for (var i = 0; i < root.embeddedWidgets.length; i++)
      if (String(root.embeddedWidgets[i].id) === "omarchy.power") return true
    return false
  }

  function embeddedWidgetSettings(id) {
    for (var i = 0; i < root.embeddedWidgets.length; i++) {
      if (String(root.embeddedWidgets[i].id) === id) return root.embeddedWidgets[i].settings || ({})
    }
    return ({})
  }

  readonly property var indicatorEntries: [
    { id: "NightLight", glyph: "󰔎" },
    { id: "Dnd", glyph: "󰂛" },
    { id: "Reminder", glyph: "󰢌" },
    { id: "StayAwake", glyph: "󰅶" },
    { id: "ScreenRecording", glyph: "󰻂" }
  ]

  property var widgetEntries: []
  property var embeddedWidgets: []
  property var buttonEntries: []

  readonly property int buttonTileSize: Math.max(Style.space(46), Style.font.iconLarge + Style.space(18))
  readonly property int cellSpacing: Style.space(10)

  // Every cell of the single icon grid: indicators, then widget buttons, then
  // the bar-toggle button. Built in refreshWidgetEntries().
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
    if (batteryCell.visible) h += batteryCell.implicitHeight
    var hasTop = clockCell.visible || batteryCell.visible
    var hasGrid = root.gridCells.length > 0
    if (hasGrid) {
      if (hasTop) h += Style.space(14) + Math.max(1, Style.space(1)) + Style.space(14)
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

  function refreshWidgetEntries() {
    var entries = []
    var layout = shell && shell.barConfig ? shell.barConfig.layout : null
    var sections = layout ? [layout.left, layout.center, layout.right] : []
    for (var s = 0; s < sections.length; s++) {
      var arr = sections[s]
      if (!Array.isArray(arr)) continue
      for (var i = 0; i < arr.length; i++) {
        var it = arr[i]
        var id = it && it.id ? String(it.id) : ""
        if (!id) continue
        if (id === "omarchy.workspaces") continue
        if (id === "andreconde.quattro-corners") continue
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

    var emb = []
    var btns = []
    for (var e = 0; e < entries.length; e++) {
      if (root.embeddedWidgetIds.indexOf(entries[e].id) !== -1) emb.push(entries[e])
      else btns.push(entries[e])
    }
    root.embeddedWidgets = emb
    root.buttonEntries = btns

    var cells = []
    for (var ind = 0; ind < root.indicatorEntries.length; ind++) {
      var ie = root.indicatorEntries[ind]
      cells.push({ kind: "indicator", id: String(ie.id), glyph: String(ie.glyph || "") })
    }
    for (var b = 0; b < btns.length; b++) {
      cells.push({ kind: "widget", id: String(btns[b].id), settings: btns[b].settings })
    }
    cells.push({ kind: "shutdown", id: "shutdown" })
    cells.push({ kind: "reboot", id: "reboot" })
    cells.push({ kind: "toggle" })
    root.gridCells = cells
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
      "omarchy.menu": "\ue900",
      "omarchy.keyboard-layout": "\uf11c",
      "omarchy.system-update": "\uf021",
      "omarchy.tray": "\uf0e0",
      "omarchy.agents": "\uf007",
      "omarchy.indicators": "\uf080",
      "omarchy.clock": "\uf017",
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
    if (!shell) return
    if (typeof shell.toggle === "function") shell.toggle(id, "{}")
    Qt.callLater(function() { root.closeFloatbar() })
  }

  function activateIndicator(id, item) {
    if (!item) return
    if (typeof item.toggle === "function") { item.toggle(); return }
    var bar = shell ? shell.bar : null
    if (id === "Dnd") {
      var notif = shell ? shell.firstPartyServiceFor("omarchy.notifications") : null
      if (notif) notif.setDoNotDisturb(!(notif.doNotDisturb === true))
    } else if (id === "Reminder") {
      if (item.reminderCount > 0) Quickshell.execDetached(["omarchy-reminder", "show"])
      else Quickshell.execDetached(["omarchy-reminder", "-i"])
    } else if (id === "Dictation") {
      if (bar) bar.run("omarchy-voxtype-config")
    } else if (id === "ScreenRecording") {
      if (bar) bar.run(item.recording ? "omarchy-capture-screenrecording --stop-recording" : "omarchy-menu toggle trigger.capture.screenrecord")
    }
  }

  function toggleBar() {
    Quickshell.execDetached(["omarchy", "toggle", "bar"])
    Qt.callLater(function() { root.closeFloatbar() })
  }

  function shutdownDevice() {
    root.closeFloatbar()
    Quickshell.execDetached(["omarchy-system-shutdown"])
  }

  function rebootDevice() {
    root.closeFloatbar()
    Quickshell.execDetached(["omarchy-system-reboot"])
  }

  function openFloatbar(payloadJson) {
    root.readConfig()
    root.refreshWidgetEntries()
    root.floatbarOpened = true
  }
  function closeFloatbar() { root.floatbarOpened = false }
  function toggleFloatbar() { root.floatbarOpened ? root.closeFloatbar() : root.openFloatbar("{}") }

  // ========================================================================
  //  SUPER-APPS GRID (bottom-left)
  // ========================================================================
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int appsCardWidth: Math.min(Style.space(640), panel.width - Style.gapsOut * 2)
  property int appsCardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
  property int cellMinWidth: Style.space(112)
  property int cellHeight: Style.space(104)
  property int iconSize: Style.space(48)
  property int columns: Math.max(1, Math.floor((appsCardWidth - contentMargin * 2) / cellMinWidth))

  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property var deleteTarget: null
  property bool deleteConfirmOpen: false

  ListModel { id: displayModel }

  function openSuperapps(payloadJson) {
    root.superappsOpened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = false
    if (root.appLibrary && typeof root.appLibrary.refreshIcons === "function") root.appLibrary.refreshIcons()
    root.rebuildDisplay()
    Qt.callLater(function() { keyRouter.forceActiveFocus() })
  }
  function closeSuperapps() { root.superappsOpened = false }
  function dismissSuperapps() {
    root.superappsOpened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "speakercorners")
  }
  function toggleSuperapps() { root.superappsOpened ? root.dismissSuperapps() : root.openSuperapps("{}") }

  // Desktop-entry names are untrusted input (see the original super-apps
  // plugin notes): force Text.PlainText everywhere, cap length and strip
  // control characters before the name enters the model.
  function sanitizeLabel(value) {
    var s = String(value || "").replace(/[\x00-\x1f\x7f]/g, " ").trim()
    var maxLength = 80
    if (s.length > maxLength) s = s.slice(0, maxLength) + "…"
    return s
  }

  function escapeMarkup(value) {
    return String(value || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function rebuildDisplay() {
    displayModel.clear()
    if (!root.appLibrary) return

    var rows = root.appLibrary.sortedEntries(root.filterText)
    for (var j = 0; j < rows.length; j++) {
      var entry = rows[j].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      displayModel.append({
        appId: appId,
        label: root.sanitizeLabel(root.appLibrary.entryName(entry)),
        appIcon: String(entry.icon || "")
      })
    }

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) appGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
    })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    appGrid.positionViewAtIndex(selectedIndex, GridView.Contain)
  }

  function selectRow(delta) {
    if (displayModel.count === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
      appGrid.positionViewAtIndex(selectedIndex, GridView.Contain)
      return
    }
    var newIndex = selectedIndex + delta * columns
    if (newIndex < 0) newIndex = 0
    if (newIndex >= displayModel.count) newIndex = displayModel.count - 1
    selectedIndex = newIndex
    appGrid.positionViewAtIndex(selectedIndex, GridView.Contain)
  }

  function selectPage(delta) {
    if (displayModel.count === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
      appGrid.positionViewAtIndex(selectedIndex, GridView.Contain)
      return
    }
    var visibleRows = Math.max(1, Math.floor(appGrid.height / root.cellHeight))
    var newIndex = selectedIndex + delta * root.columns * visibleRows
    if (newIndex < 0) newIndex = 0
    if (newIndex >= displayModel.count) newIndex = displayModel.count - 1
    selectedIndex = newIndex
    appGrid.positionViewAtIndex(selectedIndex, GridView.Contain)
  }

  function requestDeleteSelected() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    root.deleteTarget = { appId: row.appId, label: row.label }
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    Qt.callLater(function() { keyRouter.forceActiveFocus() })
  }

  function confirmDelete() {
    var target = root.deleteTarget
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    if (!target || !root.appLibrary) return
    root.appLibrary.remove(target.appId, target.label)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = nextFilter.length > 0
    root.rebuildDisplay()
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.launch(row.appId, row.label)
  }

  function launch(appId, label) {
    if (!appId || !root.appLibrary) return
    root.dismissSuperapps()
    root.appLibrary.launch(appId, label)
  }

  // Central keyboard routing. While super-apps is up it owns every key (filter
  // typing, arrows, Enter, Delete, Esc); otherwise Escape dismisses the float
  // bar. Keys never reach here while only the workspace strip is showing.
  function superappsKey(event) {
    if (root.deleteConfirmOpen) {
      if (deleteConfirm.handleKey(event)) event.accepted = true
      return
    }

    if (event.key === Qt.Key_Escape) {
      if (root.filterText) root.setFilter("")
      else root.dismissSuperapps()
      event.accepted = true
    } else if (event.key === Qt.Key_Delete) {
      root.requestDeleteSelected()
      event.accepted = true
    } else if (Util.editsFilter(event, root.filterText)) {
      root.setFilter(Util.editedFilter(event, root.filterText))
      event.accepted = true
    } else if (event.key === Qt.Key_Left) {
      root.select(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Right) {
      root.select(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      root.selectRow(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      root.selectRow(1)
      event.accepted = true
    } else if (event.key === Qt.Key_PageUp) {
      root.selectPage(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_PageDown) {
      root.selectPage(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (root.cursorActive) root.activateIndex(root.selectedIndex)
      else if (displayModel.count > 0) root.cursorActive = true
      event.accepted = true
    } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
      root.setFilter(root.filterText + event.text)
      event.accepted = true
    }
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() { if (root.superappsOpened) root.rebuildDisplay() }
  }

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

  // Switch to the workspace behind a clicked card. Omarchy runs Hyprland in
  // Lua mode, so workspace focus goes through the Lua dispatcher.
  function focusWorkspace(ws) {
    if (!ws) return
    var target = (ws.name && String(ws.name).length > 0) ? String(ws.name) : String(ws.id)
    var escaped = target.replace(/[\\"\x00-\x1f\x7f]/g, function(ch) {
      if (ch === "\\") return "\\\\"
      if (ch === '"') return '\\"'
      var decimal = ch.charCodeAt(0).toString()
      return "\\" + ("000" + decimal).slice(-3)
    })
    var expr = 'hl.dsp.focus({ workspace = "' + escaped + '" })'
    Quickshell.execDetached('hyprctl dispatch ' + Util.shellQuote(expr))
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
    Quickshell.execDetached('hyprctl dispatch workspace ' + target)
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
    root.superappsOpened = false
    root.hideWorkspaces()
    return "ok"
  }
  function toggle() { root.anyOpen ? root.close() : root.open("") }
  function refresh() { root.readConfig(); root.refreshWidgetEntries(); return "ok" }
  function ping() { return "ok" }

  function stateString() {
    return (root.anyOpen ? "open" : "closed")
      + " float=" + (root.floatbarOpened ? "1" : "0")
      + " apps=" + (root.superappsOpened ? "1" : "0")
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
  // three old plugins are gone.
  IpcHandler {
    target: "floatbar"
    function open(): string { root.openFloatbar(""); return "ok" }
    function close(): string { root.closeFloatbar(); return "ok" }
    function toggle(): string { root.toggleFloatbar(); return "ok" }
    function state(): string { return root.floatbarOpened ? "open" : "closed" }
  }

  IpcHandler {
    target: "super-apps"
    function open(): string { root.openSuperapps(""); return "ok" }
    function close(): string { root.closeSuperapps(); return "ok" }
    function toggle(): string { root.toggleSuperapps(); return "ok" }
    function state(): string { return root.superappsOpened ? "open" : "closed" }
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
    // once instead of hammering the toggle (same as quattro's dwell latch).
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
    // zones. While a blocking view is up the whole screen belongs to the
    // scrim, and while the workspace strip is showing it keeps its clicks.
    mask: Region {
      // four corner squares
      Region { x: 0; y: 0; width: root.cornersEnabled ? root.targetSize : 0; height: root.targetSize }
      Region { x: panel.width - root.targetSize; y: 0; width: root.cornersEnabled ? root.targetSize : 0; height: root.targetSize }
      Region { x: 0; y: panel.height - root.targetSize; width: root.cornersEnabled ? root.targetSize : 0; height: root.targetSize }
      Region { x: panel.width - root.targetSize; y: panel.height - root.targetSize; width: root.cornersEnabled ? root.targetSize : 0; height: root.targetSize }
      // fullscreen block while float bar or super-apps is up
      Region { x: 0; y: 0; width: root.keysWanted ? panel.width : 0; height: root.keysWanted ? panel.height : 0 }
      // workspace strip clicks (and null while it is hidden)
      Region { x: root.stripX; y: root.stripY; width: root.workspacesOpened ? root.stripW : 0; height: root.workspacesOpened ? root.stripH : 0 }
      // optional bottom edge (opt-in)
      Region { x: 0; y: root.wsEdgeEnabled ? panel.height - root.wsEdgeHeight : panel.height; width: root.wsEdgeEnabled ? panel.width : 0; height: root.wsEdgeEnabled ? root.wsEdgeHeight : 0 }
    }

    // ---- Shared scrim (super-apps only; float bar stays backdrop-free) ----
    Rectangle {
      anchors.fill: parent
      visible: root.scrimmed
      color: root.scrimColor

      Behavior on color {
        ColorAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
    }

    // Transparent click-catcher: closing the float bar on any outside click.
    // No fill color at all — the float bar stays backdrop-free.
    MouseArea {
      anchors.fill: parent
      z: 1
      visible: root.floatbarOpened
      onClicked: root.closeFloatbar()
    }

    MouseArea {
      anchors.fill: parent
      z: 1
      visible: root.scrimmed
      onClicked: {
        root.closeFloatbar()
        root.superappsOpened = false
      }
    }

    // ---- Float bar card (top-left) ----
    BorderSurface {
      id: card
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

      // Swallow clicks on the card so they don't bubble to the scrim.
      MouseArea { anchors.fill: parent; onClicked: { } }

      Item {
        id: itemsRect
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

          EmbeddedWidgetCell {
            id: clockCell
            visible: root.embeddedWidgets.length > 0
            widgetId: "omarchy.clock"
            widgetSettings: root.embeddedWidgets.length > 0 ? root.embeddedWidgets[0].settings : ({})
            fillRow: true
          }

          EmbeddedWidgetCell {
            id: batteryCell
            visible: root.hasPowerWidget
            widgetId: "omarchy.power"
            widgetSettings: root.embeddedWidgetSettings("omarchy.power")
            fillRow: true
          }

          Rectangle {
            visible: (clockCell.visible || batteryCell.visible) && widgetGrid.visible
            width: parent.width
            height: Math.max(1, Style.space(1))
            color: Util.alpha(root.cardText, 0.15)
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

    // ---- Super-apps grid card (screen-centered) ----
    BorderSurface {
      id: appsCard
      z: 3
      visible: root.superappsOpened
      width: root.appsCardWidth
      height: root.appsCardHeight
      radius: root.cornerRadius
      x: Math.max(Style.gapsOut, Math.floor((panel.width - width) / 2))
      y: Math.max(Style.gapsOut, Math.floor((panel.height - height) / 2))
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: { } }

      Column {
        anchors.fill: parent
        anchors.topMargin: appsCard.contentTopInset
        anchors.rightMargin: appsCard.contentRightInset
        anchors.bottomMargin: appsCard.contentBottomInset
        anchors.leftMargin: appsCard.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: root.filterText || "Type to search…"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          GridView {
            id: appGrid
            anchors.fill: parent
            model: displayModel
            clip: true
            cellWidth: width / root.columns
            cellHeight: root.cellHeight
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              required property int index
              required property string appId
              required property string label
              required property string appIcon

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              width: appGrid.cellWidth
              height: root.cellHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              Column {
                anchors.centerIn: parent
                spacing: Style.space(6)
                width: parent.width - Style.space(8)

                Image {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: root.iconSize
                  height: root.iconSize
                  fillMode: Image.PreserveAspectFit
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  source: root.appLibrary ? root.appLibrary.iconSource(appIcon) : ""
                  asynchronous: true
                }

                Text {
                  width: parent.width
                  text: label
                  textFormat: Text.PlainText
                  color: hasCursor ? root.selectedText : root.foreground
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  maximumLineCount: 2
                  wrapMode: Text.WordWrap
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.selectedIndex = index
                }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = index
                  root.activateIndex(index)
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              text: "No matches for “" + root.filterText + "”"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }

      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        opened: root.deleteConfirmOpen
        message: "Do you want to uninstall " + root.escapeMarkup((root.deleteTarget && root.deleteTarget.label) || "") + "?"
        confirmText: "Uninstall"
        background: root.background
        foreground: root.foreground
        scrim: root.scrimColor
        selectedBackground: root.selectedBackground
        selectedText: root.selectedText
        fontFamily: root.fontFamily
        cornerRadius: root.cornerRadius
        onCanceled: root.cancelDelete()
        onConfirmed: root.confirmDelete()
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
        id: cardsRow
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
            color: Util.alpha(Color.popups.text, 0.06)
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
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: parent.color = containsMouse
                ? Util.alpha(Color.popups.text, 0.12)
                : Util.alpha(Color.popups.text, 0.06)
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

    // ---- Hot-corner recognition zones (above the scrim) ----
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

    // ---- Shared keyboard router ----
    Item {
      id: keyRouter
      anchors.fill: parent
      focus: root.keysWanted
      enabled: root.keysWanted
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.superappsOpened) {
          root.superappsKey(event)
          return
        }
        if (root.floatbarOpened && event.key === Qt.Key_Escape) {
          root.closeFloatbar()
          event.accepted = true
        }
      }
    }
  }

  readonly property int cornerMargin: Math.max(Style.gapsOut + Style.space(12), Style.space(24))

  // ========================================================================
  //  Reused float-bar components
  // ========================================================================
  component EmbeddedWidgetCell: Rectangle {
    id: cell
    required property string widgetId
    property var widgetSettings: ({})
    property bool fillRow: false

    readonly property int cellWidth: Style.space(240)
    readonly property int cellPad: Style.space(14)

    readonly property real widgetW: loader.item ? loader.item.implicitWidth : 0
    readonly property real widgetH: loader.item ? loader.item.implicitHeight : 0

    readonly property var widgetComponent: {
      var reg = root.barWidgetRegistry
      var w = reg && reg.widgets ? reg.widgets[cell.widgetId] : null
      return w ? w.component : null
    }

    width: cell.fillRow
      ? (parent ? parent.width : Math.max(cellWidth, widgetW + cellPad * 2))
      : Math.max(cellWidth, widgetW + cellPad * 2)
    implicitHeight: Math.max(Style.space(48), widgetH + cellPad * 2)
    radius: root.cornerRadius
    color: Util.alpha(root.cardText, 0.05)
    border.width: Math.max(1, Style.space(1))
    border.color: Util.alpha(root.cardText, 0.12)

    Item {
      id: contentBox
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: cell.cellPad
      anchors.rightMargin: cell.cellPad

      Loader {
        id: loader
        sourceComponent: cell.widgetComponent
        anchors.centerIn: parent
        onLoaded: {
          var item = loader.item
          if (!item) return
          if ("bar" in item) item.bar = root.shell ? root.shell.bar : null
          if ("moduleName" in item) item.moduleName = cell.widgetId
          if ("settings" in item) item.settings = cell.widgetSettings
          Qt.callLater(function() { loader.inject() })
        }
        function inject() {
          var item = loader.item
          if (!item) return
          if ("bar" in item) item.bar = root.shell ? root.shell.bar : null
          if ("moduleName" in item) item.moduleName = cell.widgetId
          if ("settings" in item) item.settings = cell.widgetSettings
        }
      }
    }
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

    readonly property bool hovered: tileArea.containsMouse
    readonly property color hotFill: Util.alpha(tile.foreground, tile.active ? 0.28 : 0.18)
    readonly property color activeFill: Util.alpha(tile.foreground, 0.09)
    readonly property color displayColor: tile.active ? tile.foreground : Util.alpha(tile.foreground, 0.82)
    readonly property color hoverOutline: Util.alpha(tile.foreground, 0.55)
    readonly property int tileSize: Math.max(Style.space(46), fontPixelSize + Style.space(18))

    width: tileSize
    height: tileSize

    Rectangle {
      id: tileBg
      anchors.fill: parent
      radius: root.cornerRadius > 0 ? Math.max(2, root.cornerRadius / 2) : Style.space(6)
      color: tileArea.containsMouse ? tile.hotFill : (tile.active ? tile.activeFill : "transparent")
      border.width: tileArea.containsMouse ? Math.max(1, Style.space(1)) : 0
      border.color: tile.hoverOutline

      Behavior on color {
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
    }

    MouseArea {
      id: tileArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }

    PanelToolTip {
      visible: tileArea.containsMouse && tile.tooltip !== ""
      text: tile.tooltip
      fontFamily: tile.fontFamily
    }
  }

  // A grid tile mirroring one of the bar's indicator components.
  component IndicatorTile: FloatButton {
    id: itile
    required property string indicatorId
    property bool loadActive: true

    readonly property var indicator: indLoad.item
    readonly property bool indicatorState: indicator ? indicator.active === true : false

    text: indicator
      ? (indicatorState ? String(indicator.activeText || "") : String(indicator.inactiveText || ""))
      : root.indicatorGlyph(indicatorId)
    active: itile.indicatorState
    tooltip: indicator ? String(indicator.activeTooltipText || "") : indicatorId

    onHoveredChanged: {
      if (hovered && indicator && typeof indicator.refresh === "function") indicator.refresh()
    }

    onClicked: root.activateIndicator(indicatorId, indicator)

    Loader {
      id: indLoad
      anchors.fill: parent
      visible: false
      active: itile.loadActive
      source: itile.loadActive ? "file:///usr/share/omarchy/shell/plugins/bar/indicators/" + itile.indicatorId + ".qml" : ""
      onLoaded: {
        var it = indLoad.item
        if (!it) return
        var bar = root.shell ? root.shell.bar : null
        if ("bar" in it) it.bar = bar
        if ("moduleName" in it) it.moduleName = itile.indicatorId
        if ("settings" in it) it.settings = ({})
        if ("indicatorBlock" in it) it.indicatorBlock = "single"
      }
      onStatusChanged: if (status === Loader.Error) console.warn("speakercorners indicator load failed", itile.indicatorId)
    }
  }

  // Picks the right tile for each floatbar grid cell.
  component GridCell: Item {
    id: gcell
    required property var cellData

    readonly property string kind: cellData && cellData.kind ? String(cellData.kind) : ""
    readonly property string cellId: cellData && cellData.id ? String(cellData.id) : ""

    width: root.buttonTileSize
    height: root.buttonTileSize

    IndicatorTile {
      anchors.fill: parent
      visible: gcell.kind === "indicator"
      loadActive: gcell.kind === "indicator"
      indicatorId: gcell.cellId
    }

    FloatButton {
      anchors.fill: parent
      visible: gcell.kind === "widget"
      text: root.glyphFor(gcell.cellId)
      fontFamily: root.glyphFontFor(gcell.cellId)
      tooltip: root.labelFor(gcell.cellId)
      onClicked: root.activateWidget(gcell.cellId)
    }

    FloatButton {
      anchors.fill: parent
      visible: gcell.kind === "shutdown"
      text: "\uf011"
      tooltip: "Shutdown"
      onClicked: root.shutdownDevice()
    }

    FloatButton {
      anchors.fill: parent
      visible: gcell.kind === "reboot"
      text: "\uf2f1"
      tooltip: "Reboot"
      onClicked: root.rebootDevice()
    }
  }
}