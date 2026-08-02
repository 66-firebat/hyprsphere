# Multi-Monitor Support Plan

## Overview

Currently `shell.qml` has a single `PanelWindow` as its root. On multi-monitor
setups, the overlay appears only on the primary screen. This plan refactors the
architecture to instantiate one `PanelWindow` per connected screen using
Quickshell's `ShellScreen` API, with shared state for the sphere model, MRU,
and selection.

## Architecture

### Before (single monitor)

```
PanelWindow (root)           ← single window, single screen
├── focusHistory, sphereModel, selectedAppIndex  (properties on PanelWindow)
├── Timers (perpetual, refreshDelay)
├── IPC handler
├── Key handler (focusGrabber)
├── Event handlers (onActiveToplevelChanged, onRawEvent)
└── Sphere rendering (Repeater, 3D transforms, satellite, search bar)
```

### After (multi-monitor)

```
ShellRoot (new root)         ← owns shared state + IPC + event handlers
├── QtObject sharedState     ← focusHistory, sphereModel, selectedAppIndex, layer, etc.
├── Timers (one set)
├── IPC handler
├── Event handlers
│
└── Instantiator / Variants (model: Quickshell.screens)
    └── PanelWindow (one per screen)
        ├── screen: modelData
        ├── WlrLayershell (per-screen)
        ├── Key handler (focusGrabber — per-screen)
        └── Sphere rendering (binds to sharedState)
```

### Why ShellRoot?

`PanelWindow` cannot be the parent of other `PanelWindow`s — QML only allows
one window as root. `ShellRoot` is a non-visual root that can own multiple
windows, timers, IPC handlers, and shared state objects.

## Required Changes by File

### 1. `shell.qml` — Root refactor

| Change | Detail |
|---|---|
| Replace `PanelWindow { id: window }` root with `ShellRoot { id: root }` | `ShellRoot` is a non-visual QtObject that owns everything |
| Move all non-visual state to `ShellRoot` | `focusHistory`, `sphereModel`, `selectedAppIndex`, `layer`, `searchQuery`, `overlayActive`, `_mruCommitAddr`, `_pendingSpawnAppId`, `_pendingSpawnAddr`, `cfg`, `iconMap`, `nameMap`, `execMap` |
| Move Timers to `ShellRoot` | `perpetualTimer`, `refreshDelayTimer` |
| Move IPC handler to `ShellRoot` | `IpcHandler { target: "hyprsphere" }` stays at root |
| Move event handlers to `ShellRoot` | `Connections { target: Hyprland }` for `onActiveToplevelChanged`, `onRawEvent` |
| Move non-graphical functions to `ShellRoot` | `dispatchFocus`, `dispatchCommit`, `dispatchClose`, `dispatchExec`, `dispatchSubmap`, `reconcileFocusHistory`, `buildLayer0`, `buildLayer1`, `buildSearchDatabase`, `initFuseIndex`, `_executeSearch`, `cancelSearch`, `scheduleRebuild`, `normalizeAddress`, `_resolveFullAddress`, `resolveIcon`, `resolveName`, `resolveExec`, all `focusHistory` mutations |
| Move Process elements to `ShellRoot` | `configReader`, `iconReader` |

### 2. `shell.qml` — Per-monitor PanelWindow

| Change | Detail |
|---|---|
| Wrap per-monitor PanelWindow in `Instantiator` or `Variants` with `model: Quickshell.screens` | One window per connected screen |
| Set `screen: modelData` on each PanelWindow | Binds window to a specific monitor |
| Replace `Screen.width/height` with `modelData.width/height` | Each window uses its own screen's dimensions |
| Replace `window.width/height` references with per-screen bindings | `implicitWidth`, `implicitHeight`, responsive scaler |
| Move `WlrLayershell` to each PanelWindow | Each window gets its own layer-shell surface |
| Replicate key handler per PanelWindow | `focusGrabber` Item with `Keys.onPressed/onReleased` |
| Replicate sphere rendering per PanelWindow | `scene3D`, `origin`, `Repeater`, satellite, `searchContainer` |
| Bind sphere rendering to `sharedState.sphereModel` (not local property) | `model: sharedState.sphereModel` |
| Bind selection to `sharedState.selectedAppIndex` | `isSelected: index === sharedState.selectedAppIndex` |
| Search bar per PanelWindow | Each screen has its own search bar, bound to shared `searchQuery` |
| Each PanelWindow's `focusGrabber` advances through `sharedState` | `Binds.advance(root, dir)` — root holds the shared state |

### 3. `binds.js` — Parameter refactor

| Change | Detail |
|---|---|
| All functions receive `root` (ShellRoot) instead of `window` (PanelWindow) | The shared state lives on `root` |
| References to `window.sphereModel` → `root.sphereModel` | And similarly for all shared properties |
| References to `window.dispatchFocus` → `root.dispatchFocus` | Dispatch functions move to ShellRoot |
| References to `window.centerOnApp` — needs thought | `centerOnApp` triggers sphere rotation which is per-window. Need to call on ALL windows. |
| References to `window.visible` — needs thought | Multiple windows, can't toggle one. Need to toggle ALL. |

### 4. `effects.js` — No changes needed

Effects operate on `window` properties (`rotX`, `rotY`, `sphereRadius`) which
are per-PanelWindow. Each PanelWindow runs its own effects. No shared state
needed for visual effects.

### 5. `hyprsphere.json` — Add config toggle

```json
{
  "multiMonitor": true,
  ...
}
```

| Field | Type | Default | Description |
|---|---|---|---|
| `multiMonitor` | boolean | `true` | When true, creates one overlay per connected monitor. When false, single overlay on primary screen only. |

## Tricky Parts

### 1. `centerOnApp(index)` — per-window rotation

`centerOnApp` computes 3D rotation targets and starts the rotation animation.
Each PanelWindow has its own `rotX`/`rotY` and rotation animations. When the
user Tabs on one monitor, all monitors need to rotate to the same target.

**Solution:** `centerOnApp` becomes a function on ShellRoot that iterates all
PanelWindows and calls a per-window helper.

### 2. `window.visible` — toggling all windows

`openSwitcher()`, `commitSelection()`, and `cancelSwitch()` toggle visibility.
With multiple windows, they need to toggle ALL windows in sync.

**Solution:** Store PanelWindow references in an array on ShellRoot. Provide
`showAll()` / `hideAll()` helpers.

### 3. `focusGrabber.forceActiveFocus()` — per-window focus

Each PanelWindow needs keyboard focus. Calling `forceActiveFocus()` on one
doesn't affect others. But Wayland delivers key events to the focused surface.

**Solution:** On overlay open, call `forceActiveFocus()` on all PanelWindows.
Only the one on the currently-focused monitor actually receives keys (Wayland
behavior). If the user moves the mouse to another monitor, that monitor's
PanelWindow becomes focused.

### 4. IPC handler — single entry point

`IpcHandler` receives `toggle()`, `commit()`, `cancel()` calls. These now
operate on the ShellRoot's shared state instead of a single PanelWindow.

**Solution:** Move IpcHandler to ShellRoot. No change to IPC protocol.

### 5. Event handlers — single set

`onActiveToplevelChanged` and `onRawEvent` fire once. They update the shared
`focusHistory` on ShellRoot. All PanelWindows react via QML property bindings.

**Solution:** Move Connections to ShellRoot. Already planned.

### 6. `Quickshell.screens` — dynamic monitor hotplug

Screens can be connected/disconnected at runtime. `Instantiator`/`Variants`
handles creation/destruction of PanelWindows automatically.

**Solution:** Use `Variants { model: Quickshell.screens }` which handles
dynamic changes natively.

### 7. `multiMonitor: false` fallback

When the config toggle is off, instantiate a single PanelWindow (like today).

**Solution:** Conditional: if `cfg.multiMonitor`, use Variants with
`Quickshell.screens`; else use a single PanelWindow with `screen: undefined`
(defaults to primary).

## Implementation Order

1. **Phase 1:** Extract all non-visual state/functions from `PanelWindow` into a `QtObject` at the `ShellRoot` level. The single `PanelWindow` binds to it. Verify everything still works on one monitor.

2. **Phase 2:** Wrap the `PanelWindow` in `Variants { model: Quickshell.screens }`. Each instance binds to the shared state. Fix per-screen sizing. Verify overlays appear on all monitors.

3. **Phase 3:** Fix `centerOnApp` to propagate to all windows. Fix `visible` toggling. Fix `forceActiveFocus`.

4. **Phase 4:** Add `multiMonitor` config toggle. Implement single-monitor fallback.

5. **Phase 5:** Test with monitors connected/disconnected at runtime.

## Questions

1. On multi-monitor, should the sphere be **identical** on all screens (same rotation, same selection) or **independent** (each screen can show different nodes)?

2. When you tab on monitor A, should monitor B's sphere also rotate to show the same selection, or stay where it is?

3. Should pressing Escape close ALL overlays on all monitors simultaneously, or just the one you're looking at?

4. If you Alt-release on monitor A to commit a window, and monitor B is showing a different node, what happens? Commit monitor A's selection? Close both overlays?

5. When `fullscreenOnActivate` is enabled, should the committed window go fullscreen on ALL monitors (span) or just the monitor where it lives?

6. Should the search bar appear on all monitors or just the active one? If on all, should typing on one sync to all?

7. In single-monitor fallback mode (`multiMonitor: false`), should the overlay appear on the **focused** monitor or always the **primary** monitor?

8. On a laptop with external monitor: if you unplug the external monitor while the overlay is open, what should happen? Close the overlay on that monitor only? Rebuild?

9. The responsive scaler currently uses `window.width / refWidth`. With multiple monitors of different sizes, should each screen scale independently, or should all use the same scale factor?

10. The `WlrLayershell.exclusiveZone` is currently 0 (overlay). On multi-monitor, should this stay 0, or should the overlay reserve space differently per monitor?
