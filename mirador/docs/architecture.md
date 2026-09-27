# Architecture & Protocol Guide — Mirador

This document details the architectural layout, Wayland protocol interactions, Quickshell bindings, coordinate systems, and data pipelines in Mirador.

---

## 1. System Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Wayland Compositor (Hyprland)                   │
│                                                                        │
│  • Workspaces & Windows (toplevel handles, addresses, geometry)        │
│  • hyprland-toplevel-export-v1 (DMA-BUF screencopy frames)             │
│  • wlr-layer-shell-unstable-v1 (overlay surface, exclusive focus)      │
│  • IPC Socket (/tmp/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock)   │
└───────────────────▲────────────────────────────────▲───────────────────┘
                    │                                │
                    │ Hyprland Signals               │ Screencopy & Layer Shell
                    │                                │
┌───────────────────▼────────────────────────────────▼───────────────────┐
│                          Quickshell Runtime                            │
│                                                                        │
│  • Quickshell.Hyprland (monitors, workspaces, toplevels, dispatch)     │
│  • Quickshell.Wayland._Screencopy (ScreencopyView, WlBufferQSGNode)    │
│  • WlrLayershell (Layer.Overlay, exclusive keyboard grab, namespace)   │
└───────────────────▲────────────────────────────────▲───────────────────┘
                    │                                │
                    │ QML Bindings                   │ QSG Render Nodes
                    │                                │
┌───────────────────▼────────────────────────────────▼───────────────────┐
│                               Mirador                                  │
│                                                                        │
│  • WorkspaceOverview.qml: Fullscreen overlay panel, grid layout, input │
│  • WorkspaceCard.qml: Per-workspace card surface, badge, dimming       │
│  • WindowPreview.qml: ScreencopyView viewport, group tab bar, title    │
│  • InsertionWorkspaceCard.qml: Dynamic drop target for workspace creation│
│  • WindowGeometry.js: Multi-monitor scaling, projection, 2D cycle, snap │
│  • WindowModel.js: Hyprland group resolution, deduplication, tabs      │
│  • DemoInputOverlay.qml: Key/mouse HUD for recording & demonstrations   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Component Breakdown

### 1. `WorkspaceOverview.qml` (Entry Point)
* Declares `PanelWindow` anchored to all 4 edges of the target screen.
* Sets `WlrLayershell.namespace: "omarchy-workspace-overview"`.
* Sets `WlrLayershell.layer: WlrLayer.Overlay` and `WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive`.
* Owns `gridGeometry` via `WindowGeometry.overviewGridGeometry(...)`.
* Manages workspace selection (`selectedCardIndex`), explicit carousel window selection (`selectedWindowAddress`), keyboard shortcuts, and drag-and-drop state. Close and workspace-move bindings resolve this address instead of relying on compositor focus while the exclusive overlay is open.
* Defers release-to-commit for 250 ms so asynchronously launched Hyprland bindings can consume the explicit carousel window selection before the overlay clears it.
* Retains the selected address for a two-second, single-use handoff when release wins the race. A late workspace-move IPC resolves that address directly and never falls back to the compositor's stale active window.
* Treats `Super+Shift+number` as an addressed move chord in carousel mode, preventing the number key from simultaneously navigating the carousel to the destination workspace and erasing the source selection.
* Overrides both key-symbol and physical-keycode forms of Omarchy's workspace-move bindings; the stock bindings use `code:10` through `code:19`, so overriding symbols alone leaves a destructive duplicate action.
* In cycle mode, the carousel selection is authoritative. Compositor workspace events are treated as echoes and cannot bounce selection back to the previously focused workspace while an addressed action is in flight.
* Renders existing workspaces using `workspaceModel` and dynamic creation slots using `insertionModel`.

### 2. `WorkspaceCard.qml`
* Represents a visual workspace on the monitor.
* Manages card styling:
  * Active workspace: fully opaque (`cardOpacity: 1.0`), border `Color.accent`.
  * Inactive workspaces: slightly dimmed (`cardOpacity: 0.90`), border `Color.menu.border`.
  * Workspace badge: top-left number badge (`1`, `2`, ..., `0` for 10).
* Hosts `spatialPreview` item where child `WindowPreview` instances are positioned.
* Calculates physical device pixel ratio (`dpr`) from `targetMonitor.scale` or `targetScreen.devicePixelRatio`.
* Positions child window previews using `WindowGeometry.snapToDevicePixels(displayGeometry.*, dpr)`.
* Enforces scale 1.0 (no transform nodes or fractional scale animations) to preserve pixel sharpness.

### 3. `WindowPreview.qml`
* Renders the live screencopy preview of a window or window group.
* Houses `ScreencopyView` with `anchors.fill: parent`:
  * `captureSource`: bound to `root.liveCaptureEnabled ? root.waylandToplevel : null`.
  * **Critical Lifecycle Invariant**: When Mirador is dismissed or hidden, `liveCaptureEnabled` becomes `false`, immediately releasing `captureSource` to `null`. This prevents dangling DMA-BUF handles from crashing Hyprland during DPMS sleep or monitor hotplug events.
* Handles Hyprland window groups (tabbed windows) by rendering an interactive group tab bar.
* Renders window title pills with `Text.PlainText` to neutralize any formatting or injection issues.
* Two opt-outs used by the current-workspace viewer: `showIconFallback: false` (never draw the app-icon placeholder, so previews do not flash icons first) and `allowDrag: false` (disable the `DragHandler` where there are no drop targets).

### 4. `InsertionWorkspaceCard.qml`
* Transient drop zone card created only during window drag operations.
* Positioned in calculated empty slots (before, between, or after existing workspaces).
* Provides clear visual cues (`+` icon, `Drop to create WS N`) and handles window moves to newly generated workspace IDs.

### 5. `WindowGeometry.js`
* Pure JS geometry engine:
  * `logicalMonitorGeometry`: Computes compositor-space coordinates.
  * `usableMonitorGeometry`: Accounts for top/bottom status bar reservations (e.g. Omarchy peekbar).
  * `workspaceTransform`: Computes uniform scale factor and centering offsets.
  * `previewGeometry`: Projects Hyprland client rectangles into the card preview canvas (faithful mirror: one uniform scale, real relative positions, overlaps preserved).
  * `expoLayout` / `aspectFitRect`: Exposé arrangement — packs a set of window sizes into non-overlapping cells that each keep their real aspect ratio.
  * `snapToDevicePixels`: Quantizes logical values to physical device pixel boundaries.
  * `overviewGridGeometry`: Calculates optimal column/row matrix to maximize card size.
  * `cyclicCardMove`: Implements 2D cyclic keyboard navigation (global continuous horizontal cycle, spatial nearest-center vertical row movement with top/bottom wrap-around).

### 7. Current-Workspace Window Viewer (`activePresentation === "single"`)
* `CurrentWorkspaceWindows.qml` — the bottom-right corner action. It shows the windows of the focused workspace only and is deliberately **not** a `WorkspaceCard`: no card surface, no border, no header, no workspace-number badge, and no grid.
* Windows are packed by `expoLayout` instead of being projected. The faithful projection (`previewGeometry`) is wrong for this view: floating windows overlap on the desktop, so a mirror would bury the window underneath and the user could not click it. `expoLayout` is a recursive area-balanced binary partition ("slice and dice") — a region with more than one window is cut in two along the axis the group fits best, at the fraction that best balances the real window area of both halves; a region with a single window aspect-fits and centers it. Result: every window fully visible, no two previews overlapping, every aspect ratio preserved, and a large window getting the large share of the view. Neither a grid nor a desktop mirror.
* The composition is solved once per workspace (`spatialPreview.layout`) and every preview takes the cell of its own index (`rectFor(itemIndex)`). Input order is the model's order and is never re-sorted, so re-solving the layout never reorders or re-identifies the surviving previews. A client whose IPC geometry is unusable gets a default 16:10 cell (`naturalSizeOf`) so it can never disappear, which is why this view needs no `fallbackGeometry` corner grid. `fallbackGeometry` and `previewGeometry` are still what the workspace cards and the compact/carousel cycle views use.
* `showIconFallback: false` plus an immediate `livePreviews` binding (no `livePreviewsReady` deferral) means the viewer shows previews only — it never renders app icons and then swaps them for frames.
* `allowDrag: false` disables the `DragHandler`: this presentation has no workspace drop targets, so a drag would have nowhere to land.
* Tracks the compositor's focused workspace via `singleWorkspaceId()`/`singleWorkspaceObject()` so the preview stays truthful under live focus changes.
* Clicking a window calls the regular `activateWindow()` path (focus by address + `raiseToTop` + dismiss), restoring the original desktop layout untouched.
* Hides the multi-workspace cards and drag insertion targets, and makes wheel/Tab/arrow/keys navigation inert — windows are the only interactive targets. `setPresentation("single" || "full")` performs tear-free in-place presentation switches.

### 6. `WindowModel.js`
* Hyprland group and client resolver:
  * Resolves clustered window geometries into unified group representations.
  * Groups windows sharing identical compositor positions and active group flags.
  * Normalizes window addresses (`0x...` hex strings).

---

## 3. Wayland & Compositor Protocols

1. **`hyprland-toplevel-export-v1`**:
   Hyprland protocol used by Quickshell to capture DMA-BUF framebuffers of individual toplevel windows. Each buffer is imported into OpenGL/Vulkan via EGL and bound to a `QSGTexture`.

2. **`wlr-layer-shell-unstable-v1`**:
   Used by `PanelWindow` to display Mirador directly over all normal windows on the `Overlay` layer without altering Hyprland tiling state or triggering window resize events.

3. **Compositor Blur Integration**:
   Mirador sets `WlrLayershell.namespace: "omarchy-workspace-overview"`. Users configure Hyprland layer rules targeting this namespace to enable background blur:
   ```ini
   layerrule = blur, omarchy-workspace-overview
   layerrule = ignorealpha 0.85, omarchy-workspace-overview
   ```
