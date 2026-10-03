import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "AppUsage.js" as AppUsage

// Smart app menu summoned by the workspace strip's launcher cell.
//
// It lists the same installed applications as the Omarchy menu's "apps" list
// (the shell's shared AppLibrary, so hidden entries and fuzzy search behave
// identically), but the unfiltered grid is ordered by use: the app opened most
// recently comes first. That order is written to a small JSON file under
// XDG_STATE_HOME, so it survives reboots.
//
// Cells are square — a big full-colour app icon with the app name in small type
// underneath — rather than the wide rows the Omarchy menu uses.
Item {
  id: menu

  // Injected by Speakercorners.qml: the shell's shared application library.
  property var appLibrary: null
  property bool open: false
  // Same transparency the workspace strip uses, so both surfaces look related.
  property real surfaceOpacity: 0.97
  // Set by the host to the strip's accent color, so the launcher cell and the
  // menu it opens share a highlight color.
  property color accentColor: Color.accent

  // Rows currently rendered: { id, name, subtext, icon, used }. With an empty
  // query they are ordered by usage; with a query, by the search score.
  property var rows: []
  property var usage: AppUsage.emptyStore()
  property string query: ""
  property int selectedIndex: 0
  property int hoveredIndex: -1

  // The host dismisses the menu; it owns the click mask and the keyboard focus.
  signal dismissRequested()
  signal launched(string appId, string appName)

  // ---- Geometry ----------------------------------------------------------
  // The panel is centred on the screen, sized from the columns and the rows
  // that fit the height budget. The host reads panelX/panelY/panelW/panelH to
  // punch its click mask, so they must stay in window coordinates.
  //
  // The chain is deliberately one-directional (window -> budget -> rows -> panel)
  // so nothing here depends on panelH while panelH depends on it back.
  readonly property int columns: 6
  readonly property int cellGap: Style.space(6)
  readonly property int panelPad: Style.space(14)
  readonly property int headerH: Style.space(34)
  readonly property int footerH: Style.space(20)
  readonly property int cellFit: {
    var budgetW = menu.width - Style.gapsOut * 2
    var perCell = (budgetW - menu.panelPad * 2 - menu.cellGap * (menu.columns - 1)) / menu.columns
    var heightBudget = Math.floor(menu.height * 0.72) - menu.panelPad * 2 - menu.headerH - menu.footerH
    var perRow = Math.floor(heightBudget / 4) - menu.cellGap
    var size = Math.floor(Math.min(perCell, perRow, Style.space(112)))
    // Even, so a stray half-pixel never makes the grid wider than its panel.
    return size - (size % 2)
  }
  readonly property int cellSize: Math.max(Style.space(56), cellFit)
  readonly property int rowsBudgetH: Math.max(cellSize,
    Math.floor(menu.height * 0.72) - panelPad * 2 - headerH - footerH)
  readonly property int visibleRows: Math.max(1,
    Math.floor((rowsBudgetH + cellGap) / (cellSize + cellGap)))
  readonly property int panelW: columns * cellSize + (columns - 1) * cellGap + panelPad * 2
  readonly property int panelH: Math.min(menu.height - Style.gapsOut * 2,
    visibleRows * cellSize + Math.max(0, visibleRows - 1) * cellGap + panelPad * 2 + headerH + footerH)
  readonly property int panelX: Math.max(0, Math.round((menu.width - panelW) / 2))
  // Lifted a little above centre: the workspace strip owns the bottom edge.
  readonly property int panelY: Math.max(0, Math.round((menu.height - panelH) / 2 - Style.space(20)))
  readonly property int scrollH: Math.max(0, panelH - panelPad * 2 - headerH - footerH)

  readonly property bool hasRows: rows.length > 0
  readonly property var currentRow: hasRows && selectedIndex >= 0 && selectedIndex < rows.length
    ? rows[selectedIndex] : null

  // ---- Usage store -------------------------------------------------------
  readonly property string stateHome: {
    var dir = Quickshell.env("XDG_STATE_HOME")
    return dir ? dir : (Quickshell.env("HOME") + "/.local/state")
  }
  readonly property string usagePath: menu.stateHome + "/speakercorners/app-usage.json"
  readonly property string usageDir: menu.usagePath.slice(0, menu.usagePath.lastIndexOf("/"))

  property bool usageDirReady: false
  property bool usageSavePending: false

  function loadUsage(raw) {
    menu.usage = AppUsage.parse(raw)
    if (menu.open) menu.rebuild()
  }

  function saveUsage() {
    // The store lives one directory down, which does not exist on a fresh
    // install; the mkdir below creates it and retries whatever we held back.
    if (!menu.usageDirReady) {
      menu.usageSavePending = true
      if (!usageDirProcess.running) usageDirProcess.running = true
      return
    }
    usageFile.setText(AppUsage.serialize(menu.usage))
    menu.usageSavePending = false
  }

  function recordLaunch(row) {
    if (!row || !row.id) return
    menu.usage = AppUsage.record(menu.usage, row.id, Date.now())
    menu.saveUsage()
  }

  // ---- Model -------------------------------------------------------------
  function rowFor(entry) {
    var id = String((entry && entry.id) || "")
    if (!id) return null
    var name = menu.appLibrary ? menu.appLibrary.entryName(entry) : String(entry.name || "")
    if (!name) return null

    var subtext = menu.appLibrary ? menu.appLibrary.entrySubtext(entry) : String(entry.genericName || "")
    var icon = String((entry && entry.icon) || "")

    return {
      id: id,
      name: name,
      subtext: subtext || "",
      icon: icon,
      used: AppUsage.isKnown(menu.usage, id)
    }
  }

  // AppLibrary.sortedEntries already filters hidden entries and ranks by a
  // fuzzy score, which is what the Omarchy menu searches with. Only the
  // unfiltered grid gets the usage ordering laid on top.
  function rebuild() {
    if (!menu.appLibrary) {
      menu.rows = []
      return
    }

    var sorted
    try {
      sorted = menu.appLibrary.sortedEntries(menu.query) || []
    } catch (e) {
      menu.rows = []
      return
    }

    var out = []
    for (var i = 0; i < sorted.length; i++) {
      var row = menu.rowFor(sorted[i] ? sorted[i].entry : null)
      if (row) out.push(row)
    }

    menu.rows = menu.query.trim().length > 0 ? out : AppUsage.rank(out, menu.usage)
    menu.clampSelection()
  }

  function iconFor(row) {
    if (!row) return ""
    var icon = String(row.icon || "")
    if (menu.appLibrary && typeof menu.appLibrary.iconSource === "function") {
      try {
        var source = menu.appLibrary.iconSource(icon)
        if (source) return source
      } catch (e) { }
    }
    if (icon.length > 0) {
      var themed = Quickshell.iconPath(icon, true)
      if (themed.length > 0) return themed
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  // ---- Selection & navigation -------------------------------------------
  function clampSelection() {
    if (!menu.hasRows) {
      menu.selectedIndex = -1
      return
    }
    if (menu.selectedIndex < 0) menu.selectedIndex = 0
    if (menu.selectedIndex > menu.rows.length - 1) menu.selectedIndex = menu.rows.length - 1
  }

  function moveSelection(delta) {
    if (!menu.hasRows) return
    var count = menu.rows.length
    // Wrap: the grid is a torus, so arrowing past an edge comes back around.
    var next = (menu.selectedIndex + delta) % count
    if (next < 0) next += count
    menu.selectedIndex = next
    menu.scrollToSelection()
  }

  function moveSelectionBy(delta) {
    if (!menu.hasRows) return
    var count = menu.rows.length
    menu.selectedIndex = Math.max(0, Math.min(count - 1, menu.selectedIndex + delta))
    menu.scrollToSelection()
  }

  function pageSelection(direction) {
    menu.moveSelectionBy(direction * menu.columns * menu.visibleRows)
  }

  function selectEdge(where) {
    if (!menu.hasRows) return
    menu.selectedIndex = where === "first" ? 0 : menu.rows.length - 1
    menu.scrollToSelection()
  }

  function selectIndex(index) {
    if (!menu.hasRows) return
    if (index < 0 || index >= menu.rows.length) return
    menu.selectedIndex = index
    menu.scrollToSelection()
  }

  function scrollToSelection() {
    var index = menu.selectedIndex
    if (index < 0 || !menu.hasRows) return
    var pitch = menu.cellSize + menu.cellGap
    var top = Math.floor(index / menu.columns) * pitch
    var viewH = gridFlick.height
    var target

    if (gridFlick.contentHeight <= viewH) {
      // Everything fits on screen: centre the selected row.
      target = top - Math.floor((viewH - menu.cellSize) / 2)
    } else if (top - menu.cellGap < gridFlick.contentY) {
      target = top - menu.cellGap
    } else if (top + menu.cellSize + menu.cellGap > gridFlick.contentY + viewH) {
      target = top + menu.cellSize + menu.cellGap - viewH
    } else {
      return
    }

    gridFlick.contentY = Math.max(0, Math.min(target, gridFlick.contentHeight - viewH))
  }

  function activate(row) {
    var target = row || menu.currentRow
    if (!target || !target.id) return
    menu.recordLaunch(target)
    if (menu.appLibrary) menu.appLibrary.launch(target.id, target.name)
    menu.launched(target.id, target.name)
    menu.dismissRequested()
  }

  function clearQuery() {
    if (menu.query.length === 0) return
    menu.query = ""
    menu.rebuild()
  }

  // ---- Keyboard ----------------------------------------------------------
  // Returns true when the menu consumed the key; the rest fall through to the
  // field's own text editing (or, for Escape on an empty query, up to the host
  // which owns the dismiss action).
  function handleKey(event) {
    var key = event.key

    if (key === Qt.Key_Escape) {
      if (menu.query.length > 0) menu.clearQuery()
      else return false
      return true
    }
    if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      if (menu.hasRows) menu.activate(menu.currentRow)
      return true
    }
    if (key === Qt.Key_Down || key === Qt.Key_Tab) {
      menu.moveSelection(1)
      return true
    }
    if (key === Qt.Key_Up || key === Qt.Key_Backtab) {
      menu.moveSelection(-1)
      return true
    }
    if (key === Qt.Key_Right) {
      menu.moveSelection(1)
      return true
    }
    if (key === Qt.Key_Left) {
      menu.moveSelection(-1)
      return true
    }
    if (key === Qt.Key_PageDown) {
      menu.pageSelection(1)
      return true
    }
    if (key === Qt.Key_PageUp) {
      menu.pageSelection(-1)
      return true
    }
    if (key === Qt.Key_Home) {
      menu.selectEdge("first")
      return true
    }
    if (key === Qt.Key_End) {
      menu.selectEdge("last")
      return true
    }
    // Ctrl+U / Ctrl+W arrive as plain Backspace / Delete here, so they must
    // clear the whole query instead of eating one character.
    if ((key === Qt.Key_Backspace || key === Qt.Key_Delete)
        && (event.modifiers & Qt.ControlModifier) !== 0) {
      menu.clearQuery()
      return true
    }

    return false
  }

  function resetForOpen() {
    menu.query = ""
    menu.selectedIndex = 0
    menu.hoveredIndex = -1
    menu.rebuild()
    Qt.callLater(function() {
      if (menu.open) searchInput.forceActiveFocus()
    })
  }

  onOpenChanged: {
    if (menu.open) menu.resetForOpen()
    else menu.query = ""
  }

  onQueryChanged: {
    if (!menu.open) return
    // Every keystroke re-ranks the grid, so the cursor belongs back on top.
    menu.selectedIndex = 0
    gridFlick.contentY = 0
    menu.rebuild()
  }

  onAppLibraryChanged: if (menu.open) menu.rebuild()

  Component.onCompleted: if (!usageDirProcess.running) usageDirProcess.running = true

  Connections {
    target: menu.appLibrary
    // Desktop entries can arrive after this component does (the shell's
    // watcher fires late on a cold start), so keep the grid in step.
    function onAppsChanged() { if (menu.open) menu.rebuild() }
  }

  Process {
    id: usageDirProcess
    // Plain sh, not a login shell: sourcing the profile is a slow way to make
    // one directory.
    command: ["sh", "-c", "mkdir -p " + Util.shellQuote(menu.usageDir)]
    onExited: function(exitCode) {
      menu.usageDirReady = true
      if (menu.usageSavePending) menu.saveUsage()
    }
  }

  FileView {
    id: usageFile
    path: menu.usagePath
    preload: true
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: menu.loadUsage(text())
    onLoadFailed: menu.loadUsage("")
  }

  // Invisible full-screen catcher: a click that misses the panel dismisses.
  MouseArea {
    anchors.fill: parent
    visible: menu.open
    onClicked: menu.dismissRequested()
  }

  // ---- The panel ---------------------------------------------------------
  BorderSurface {
    id: panel
    x: menu.panelX
    y: menu.panelY
    width: menu.panelW
    height: menu.panelH
    radius: Style.cornerRadius
    color: Util.alpha(Color.menu.background, menu.surfaceOpacity)
    borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
    padding: menu.panelPad

    // Faded rather than popped, like the strip. `visible` tracks the fade so
    // the panel exists during the animation, and `enabled` drops out the
    // moment it starts closing so a fading panel cannot eat a click.
    opacity: menu.open ? 1 : 0
    visible: opacity > 0
    enabled: menu.open
    Behavior on opacity {
      NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
    }

    // Swallow clicks on the card itself so they never reach the catcher.
    MouseArea { anchors.fill: parent }

    // ---- Header ----
    Item {
      id: header
      x: panel.contentLeftInset
      y: panel.contentTopInset
      width: panel.width - panel.contentLeftInset - panel.contentRightInset
      height: menu.headerH - Style.spacing.hairline

      Text {
        id: searchGlyph
        anchors.left: parent.left
        anchors.leftMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        // fa-magnifying-glass (U+F002) from Font Awesome 7 Free, the family
        // the strip already uses for its launcher glyphs.
        text: "\uf002"
        color: Util.alpha(Color.menu.text, menu.query.length > 0 ? 0.75 : 0.45)
        font.family: "Font Awesome 7 Free"
        font.pixelSize: Style.font.bodySmall
        font.weight: Font.Bold
      }

      TextInput {
        id: searchInput
        anchors.left: searchGlyph.right
        anchors.leftMargin: Style.space(8)
        anchors.right: countLabel.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        focus: menu.open
        selectByMouse: true
        clip: true
        color: Color.menu.text
        selectionColor: Util.alpha(Color.menu.text, 0.30)
        selectedTextColor: Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.subtitle
        // Bound, not assigned: only the user's own edits are reported back, so
        // a programmatic reset of menu.query still reaches the field.
        text: menu.query
        onTextEdited: menu.query = text

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { event.accepted = menu.handleKey(event) }
      }

      Text {
        id: countLabel
        anchors.right: parent.right
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        text: menu.hasRows
          ? (menu.rows.length + (menu.rows.length === 1 ? " app" : " apps"))
          : "no apps"
        color: Util.alpha(Color.menu.text, 0.45)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: Style.spacing.hairline
        color: Util.alpha(Color.menu.border, 0.28)
      }
    }

    // ---- Grid ----
    Flickable {
      id: gridFlick
      x: panel.contentLeftInset
      y: header.y + menu.headerH
      width: panel.width - panel.contentLeftInset - panel.contentRightInset
      height: menu.scrollH
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      contentWidth: width
      contentHeight: grid.implicitHeight

      Grid {
        id: grid
        columns: menu.columns
        columnSpacing: menu.cellGap
        rowSpacing: menu.cellGap
        width: gridFlick.contentWidth

        Repeater {
          model: menu.rows

          delegate: Item {
            id: cell
            required property int index
            required property var modelData

            readonly property bool selected: menu.selectedIndex === cell.index
            readonly property bool hovered: menu.hoveredIndex === cell.index
            readonly property bool active: cell.selected || cell.hovered

            width: menu.cellSize
            height: menu.cellSize

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius > 0 ? Math.max(Style.space(4), Style.cornerRadius / 2) : Style.space(6)
              color: cell.selected
                ? Util.alpha(menu.accentColor, 0.20)
                : (cell.hovered ? Util.alpha(Color.menu.text, 0.07) : "transparent")
              border.width: Math.max(1, Style.space(1))
              border.color: cell.selected
                ? Util.alpha(menu.accentColor, 0.70)
                : (cell.hovered ? Util.alpha(Color.menu.text, 0.16) : "transparent")
              Behavior on color { ColorAnimation { duration: 90 } }
            }

            // Big, full-colour app icon filling the top of the square.
            Image {
              anchors.top: parent.top
              anchors.topMargin: Math.round(menu.cellSize * 0.14)
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.round(menu.cellSize * 0.52)
              height: width
              source: menu.iconFor(cell.modelData)
              fillMode: Image.PreserveAspectFit
              smooth: true
              mipmap: true
              asynchronous: true
              cache: true
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Math.round(menu.cellSize * 0.09)
              text: cell.modelData.name
              color: cell.active ? menu.accentColor : Util.alpha(Color.menu.text, 0.88)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.weight: cell.selected ? Font.DemiBold : Font.Normal
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }

            HoverHandler {
              onHoveredChanged: menu.hoveredIndex = hovered ? cell.index : -1
            }

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(mouse) {
                menu.selectIndex(cell.index)
                if (mouse.button === Qt.LeftButton) menu.activate(cell.modelData)
              }
            }
          }
        }
      }
    }

    // ---- Footer ----
    Text {
      x: panel.contentLeftInset
      y: panel.height - panel.contentBottomInset - menu.footerH
      width: panel.width - panel.contentLeftInset - panel.contentRightInset
      height: menu.footerH
      verticalAlignment: Text.AlignVCenter
      // With a query the grid is ordered by the search, without it by use; the
      // hint says which one is on screen.
      text: menu.query.trim().length > 0
        ? "↑ ↓ ← → move   ·   Enter open   ·   Esc clear"
        : "most recent first   ·   ↑ ↓ ← → move   ·   Enter open   ·   Esc close"
      color: Util.alpha(Color.menu.text, 0.38)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    // ---- Empty state ----
    Column {
      anchors.centerIn: parent
      width: parent.width - menu.panelPad * 2
      spacing: Style.space(6)
      visible: !menu.hasRows

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: menu.query.trim().length > 0 ? "No apps match" : "No apps found"
        color: Util.alpha(Color.menu.text, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: menu.query.trim().length > 0
          ? "\"" + menu.query + "\""
          : "check omarchy-menu apps for hidden entries"
        color: Util.alpha(Color.menu.text, 0.35)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}