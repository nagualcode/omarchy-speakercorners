import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "IconModel.js" as IconModel

// One miniature workspace card.
//
// The card is a fixed-width panel showing the icons of the apps open in that
// Hyprland workspace. Icons resolve the same way as b.omahud: a Nerd Font
// glyph from Omarchy's app mapping, falling back to the matched desktop entry
// image and finally to a generic app glyph. One icon per distinct app.
Item {
  id: root

  required property var ws
  property var shell: null
  property var desktopEntries: []
  property bool focused: false

  signal activate(var ws)

  readonly property real previewHeight: Math.round(root.width * 9 / 16)
  readonly property real labelHeight: Math.max(Style.space(12), Style.font.caption + Style.space(4))

  readonly property color focusedBorder: Color.accent
  readonly property color idleBorder: "transparent"
  readonly property color borderColor: root.focused ? focusedBorder : idleBorder
  readonly property int borderWidth: Math.max(2, Style.space(2))

  readonly property string label: ws ? String(ws.label || ws.id) : ""

  // The focused card inverts the theme like the HUD's active tile, keeping
  // glyphs readable on either background instead of relying on a preview image.
  readonly property color previewBackground: root.focused ? Color.foreground : Color.background
  readonly property color previewForeground: root.focused ? Color.background : Color.popups.text
  readonly property color imageTint: {
    var tint = IconModel.fallbackIconTint(root.previewForeground, root.previewBackground)
    return Qt.rgba(tint.r, tint.g, tint.b, tint.a)
  }

  readonly property int iconMaxSize: Style.space(24)
  readonly property int iconGap: Style.space(4)
  readonly property int iconPad: Style.space(5)

  // Distinct apps in this workspace, first appearance in reading order.
  readonly property var appList: buildAppList(root.ws)
  readonly property int appCount: root.appList.length

  readonly property int iconColumns: {
    var n = root.appCount
    if (n <= 0) return 1
    var w = Math.max(1, preview.width - root.iconPad * 2)
    var h = Math.max(1, preview.height - root.iconPad * 2)
    return Math.max(1, Math.ceil(Math.sqrt(n * (w / h))))
  }

  // Square icons sized to fit the preview area in the computed grid.
  readonly property int iconSize: {
    var n = root.appCount
    if (n <= 0) return 0
    var w = Math.max(1, preview.width - root.iconPad * 2)
    var h = Math.max(1, preview.height - root.iconPad * 2)
    var cols = root.iconColumns
    var rows = Math.max(1, Math.ceil(n / cols))
    var size = Math.floor(Math.min(
      (w - (cols - 1) * root.iconGap) / cols,
      (h - (rows - 1) * root.iconGap) / rows
    ))
    return Math.max(10, Math.min(root.iconMaxSize, size))
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
    var entry = IconModel.matchDesktopEntry(member, root.desktopEntries)
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
    if (entry === undefined) entry = desktopEntry(member)
    var candidates = member && Array.isArray(member.iconCandidates)
      ? member.iconCandidates
      : []
    var genericSource = root.genericIconSource()

    if (entry && entry.icon) {
      if (root.shell && root.shell.appLibrary
          && typeof root.shell.appLibrary.iconSource === "function") {
        var libraryIcon = root.actualIcon(
          root.shell.appLibrary.iconSource(entry.icon),
          genericSource
        )
        if (libraryIcon) return libraryIcon
      }

      var entryIcon = root.actualIcon(Quickshell.iconPath(String(entry.icon), true), genericSource)
      if (entryIcon) return entryIcon
    }

    for (var j = 0; j < candidates.length; j++) {
      var classIconCandidate = String(candidates[j] || "").trim()
      if (!classIconCandidate) continue
      var classIcon = root.actualIcon(Quickshell.iconPath(classIconCandidate, true), genericSource)
      if (classIcon) return classIcon
    }

    return ""
  }

  implicitHeight: previewHeight + labelHeight + borderWidth * 2
  implicitWidth: root.width

  // Card surface: the icon preview plus a small label row.
  BorderSurface {
    id: card
    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter
    width: root.width
    height: root.previewHeight + root.labelHeight + root.borderWidth * 2
    radius: Style.cornerRadius
    color: Util.alpha(Color.background, 0.6)
    borderSpec: Border.flat(root.borderColor, root.borderWidth)
    clip: true

    // -------- preview area (inset so the card border stays visible) --------
    Item {
      id: preview
      anchors.top: parent.top
      anchors.topMargin: card.contentTopInset
      anchors.left: parent.left
      anchors.leftMargin: card.contentLeftInset
      width: card.width - card.contentLeftInset - card.contentRightInset
      height: root.previewHeight
      clip: true

      Rectangle {
        anchors.fill: parent
        color: root.previewBackground
      }

      GridLayout {
        anchors.centerIn: parent
        columns: root.iconColumns
        columnSpacing: root.iconGap
        rowSpacing: root.iconGap

        Repeater {
          model: root.appList

          delegate: Item {
            id: appIcon
            required property var modelData
            readonly property var member: modelData.member
            readonly property var entry: root.desktopEntry(member)
            readonly property string mappedGlyph: IconModel.appGlyph(member, entry)
            readonly property var imageSource: mappedGlyph.length === 0
              ? root.iconSource(member, entry)
              : ""
            readonly property bool imageUnavailable: mappedGlyph.length === 0
              && (String(imageSource).length === 0 || appImage.status === Image.Error)
            readonly property string glyph: mappedGlyph.length > 0
              ? mappedGlyph
              : (imageUnavailable ? IconModel.genericAppGlyph() : "")
            readonly property int iconPixelRatio: Math.max(1, Math.round(Screen.devicePixelRatio))

            width: root.iconSize
            height: root.iconSize

            OpticalGlyph {
              anchors.centerIn: parent
              width: parent.width
              height: parent.height
              visible: appIcon.glyph.length > 0
              text: appIcon.glyph
              color: root.previewForeground
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
                colorizationColor: root.imageTint
              }
            }
          }
        }
      }
    }

    // -------- label row --------
    RowLayout {
      anchors.top: preview.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.topMargin: Style.space(1)
      spacing: Style.space(4)

      Text {
        text: root.label
        textFormat: Text.PlainText
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: root.focused
        color: root.focused ? Color.accent : Util.alpha(Color.popups.text, 0.7)
      }

      Rectangle {
        visible: root.ws && root.ws.urgent
        width: Style.space(5)
        height: Style.space(5)
        radius: width / 2
        color: Color.urgent
      }
    }

    // Clicking a card switches to that workspace.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activate(root.ws)
    }
  }
}