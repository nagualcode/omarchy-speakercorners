import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "WindowGeometry.js" as WindowGeometry
import "WindowModel.js" as WindowModel

// ── CurrentWorkspaceWindows.qml ──────────────────────────────────────────────
// Chrome-free Exposé viewer for the windows of the *current* workspace only.
//
// It is deliberately NOT a WorkspaceCard: there is no card background, no outer
// border, no workspace-number badge and no header. The windows of the workspace
// are packed by `WindowGeometry.expoLayout` (capped-grid mode) so that every one
// of them is fully visible at once, none overlaps another, and each keeps its
// real aspect ratio. The arrangement uses as much of the screen as the cap
// allows, keeps a 10px outer margin and 10px between previews, caps each single
// window at a quarter of the usable area, and stays centred — not a picture of
// the desktop with its floating windows piled on top of each other.
//
// The composition is solved once for the whole workspace and every preview then
// takes the cell that belongs to its own index, so opening or closing a window
// re-solves the arrangement without ever reordering the survivors.
//
// Three further differences from WorkspaceCard:
//   * live previews start on the very first frame (no deferred `livePreviews`
//     window), and the app-icon placeholder is disabled, so the viewer never
//     flashes icons before swapping them for real frames;
//   * window drag is disabled: there are no other workspace drop targets in
//     this presentation, so a drag would have nowhere to land;
//   * clients with unusable IPC geometry still get a cell, so a window can never
//     disappear from the view.
//
// The compositor layout is never modified: this is a pure visual arrangement
// (non-destructive invariant).
Item {
  id: root

  required property var overview
  property int workspaceId: -1
  property var workspace: null
  property bool livePreviews: false
  property int toplevelRevision: 0

  readonly property var effectiveToplevels: {
    // `lastIpcObject` changes after refreshToplevels() completes. Reading this
    // revision makes that asynchronous, event-driven update invalidate the
    // effective array even though the ObjectModel membership did not change.
    var revision = root.toplevelRevision
    var activeAddr = Hyprland.activeToplevel ? Hyprland.activeToplevel.address : ""
    return WindowModel.resolveWorkspacePreviews(
      workspace ? workspace.toplevels.values : [], activeAddr)
  }
  readonly property int windowCount: effectiveToplevels.length
  readonly property bool occupied: windowCount > 0

  readonly property var workspaceMonitor: (workspace && workspace.monitor)
    ? workspace.monitor : Hyprland.focusedMonitor

  // Breathing room between neighbouring previews. Exposé never lets two
  // thumbnails touch, otherwise the boundary between them is unreadable.
  readonly property real previewSpacing: 10
  // Margin between the preview block and the screen edges.
  readonly property real previewOuterMargin: 10
  // A single preview never grows past a quarter of the usable area, so a lone
  // window cannot swallow the screen.
  readonly property real previewMaxAreaFraction: 0.25

  property bool enterAnimated: false

  onVisibleChanged: {
    if (visible) {
      // Start the entrance on the very next frame; no deferred call so the
      // previews begin moving with the backdrop fade instead of one tick later.
      enterAnimated = true
    } else {
      enterAnimated = false
    }
  }

  signal windowActivated(var toplevel)

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() { root.toplevelRevision++ }
  }

  // Track the completion of Quickshell's compositor-data refresh for existing
  // clients so a refresh that only rewrites `lastIpcObject` (geometry, class)
  // still re-projects the previews. Creates no delegates of its own.
  Repeater {
    model: root.workspace ? root.workspace.toplevels : []

    Item {
      required property var modelData

      Connections {
        target: modelData
        function onLastIpcObjectChanged() { root.toplevelRevision++ }
      }
    }
  }

  function screenForMonitor(monitor) {
    if (!monitor) return null
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && screens[i].name === monitor.name) return screens[i]
    }
    return null
  }

  // ── Empty state ─────────────────────────────────────────────────────────────
  // The card's "·" dot is gone with the card; an empty workspace simply says so.
  Text {
    visible: !root.occupied
    anchors.centerIn: parent
    text: "no windows on this workspace"
    color: Color.menu.text
    opacity: 0.45
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.body
    horizontalAlignment: Text.AlignHCenter
  }

  Item {
    id: spatialPreview
    anchors.fill: parent

    property var previewMap: ({})

    // Real window size drives the Exposé split: a tall window gets a tall cell
    // and a wide one a wide cell, so the composition keeps the workspace's own
    // proportions instead of flattening everything into equal slots.
    function naturalSizeOf(preview) {
      var toplevel = (preview && preview.toplevel) ? preview.toplevel : preview
      var ipc = (preview && preview.lastIpcObject)
        ? preview.lastIpcObject
        : (toplevel ? toplevel.lastIpcObject : null)
      var client = ipc ? WindowGeometry.clientGeometry(ipc) : null
      // A client whose IPC geometry is unusable still gets a cell, sized like a
      // normal landscape window, so it never disappears from the view.
      if (!client) return { width: 16, height: 10 }
      return { width: client.width, height: client.height }
    }

    // One arrangement for the whole workspace, re-solved only when the window
    // list or the size of the area changes. `toplevelRevision` is read so an
    // async `lastIpcObject` refresh re-solves the composition even when the
    // model membership did not change.
    readonly property var layout: {
      var revision = root.toplevelRevision
      var previews = root.effectiveToplevels
      var sizes = []
      for (var i = 0; i < previews.length; i++)
        sizes.push(spatialPreview.naturalSizeOf(previews[i]))
      return WindowGeometry.expoLayout(sizes, 0, 0,
        spatialPreview.width, spatialPreview.height, root.previewSpacing, {
          outerMargin: root.previewOuterMargin,
          maxAreaFraction: root.previewMaxAreaFraction
        })
    }

    function rectFor(index) {
      var cells = spatialPreview.layout
      if (!cells || index < 0 || index >= cells.length)
        return { x: 0, y: 0, width: 1, height: 1 }
      return cells[index]
    }

    function syncPreviews() {
      previewMap = WindowModel.syncPreviewDelegates(
        spatialPreview,
        previewMap,
        root.effectiveToplevels,
        windowPreviewComponent,
        {
          initialProps: function(p, i) {
            return {
              modelData: p,
              itemIndex: i,
              toplevel: (p && p.activeMember) ? p.activeMember : (p && p.toplevel ? p.toplevel : null)
            }
          },
          onUpdate: function(del, p, i) {
            del.itemIndex = i
            del.modelData = p
            var targetTop = (p && p.activeMember) ? p.activeMember : (p && p.toplevel ? p.toplevel : null)
            if (del.toplevel !== targetTop) {
              del.toplevel = targetTop
            }
          }
        }
      )
    }

    Component.onCompleted: syncPreviews()

    Connections {
      target: root
      function onEffectiveToplevelsChanged() {
        spatialPreview.syncPreviews()
      }
    }

    Component {
      id: windowPreviewComponent

      WindowPreview {
        id: previewItem
        required property var modelData
        property int itemIndex: 0

        readonly property var previewToplevel: modelData && modelData.toplevel ? modelData.toplevel : modelData

        readonly property var targetMonitor: root.workspaceMonitor || (previewToplevel && previewToplevel.monitor ? previewToplevel.monitor : Hyprland.focusedMonitor)
        readonly property var targetScreen: root.screenForMonitor(targetMonitor)

        // The Exposé cell that belongs to this preview. Nothing is projected
        // from the desktop position: the workspace's floating windows are
        // deliberately re-packed so that all of them stay visible side by side.
        readonly property var displayGeometry: spatialPreview.rectFor(itemIndex)

        readonly property real dpr: (targetMonitor && targetMonitor.scale > 0)
          ? targetMonitor.scale
          : ((targetScreen && targetScreen.devicePixelRatio) ? targetScreen.devicePixelRatio : 1.0)

        x: WindowGeometry.snapToDevicePixels(displayGeometry.x, dpr)
        y: WindowGeometry.snapToDevicePixels(displayGeometry.y, dpr)
        width: Math.max(1, WindowGeometry.snapToDevicePixels(displayGeometry.width, dpr))
        height: Math.max(1, WindowGeometry.snapToDevicePixels(displayGeometry.height, dpr))
        z: itemIndex + 1
        toplevel: previewToplevel
        isGroup: Boolean(modelData && modelData.isGroup)
        groupMembers: (modelData && modelData.members) ? modelData.members : []
        // No icon placeholder: the viewer goes straight to real frames, and the
        // capture stream is never deferred behind a first-paint timer.
        showIconFallback: false
        allowDrag: false
        // Round the captured frame to the window corner radius from the
        // look-and-feel, matching how the compositor draws the real windows.
        roundedCapture: true
        liveCaptureEnabled: root.livePreviews && root.visible
        onActivated: root.windowActivated(previewToplevel)
        onTabActivated: function(targetToplevel) { root.windowActivated(targetToplevel) }

        // Animação suave estilo macOS Exposé
        opacity: root.enterAnimated ? 1.0 : 0.0
        scale: root.enterAnimated ? 1.0 : 0.94

        transformOrigin: Item.Center

        Behavior on opacity {
          enabled: root.enterAnimated
          NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
          }
        }

        Behavior on scale {
          enabled: root.enterAnimated
          NumberAnimation {
            duration: 140
            easing.type: Easing.OutCubic
          }
        }
      }
    }
  }
}
