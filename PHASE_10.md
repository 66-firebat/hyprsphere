# PHASE_10 — Gate overlay visibility on data readiness

**Deliverable:** On first open (and every open), the overlay only becomes
visible after `finishOpenSwitcher()` has populated the sphere with real
data. This eliminates the "different overlay on startup vs re-open"
problem — no stale `sphereModel` flash, no empty-to-populated transition,
no zoom/drift artifacts. The user sees either nothing or the fully-built
sphere, every time.

---

## Rationale

The root cause is a **timing gap** in `openSwitcher()`:

```
openSwitcher() →
    window.visible = true           ← overlay visible NOW with stale/empty data
    Qt.callLater → finishOpenSwitcher() → sphereModel populated LATER
```

On first launch after quickshell starts, `sphereModel` is `[]` (the
initial property value), so the overlay appears transparent/empty until
`finishOpenSwitcher()` retries through its icon-readiness and toplevel
checks and finally populates the model.

On re-open (after Escape), `sphereModel` still holds the **previous
session's data** — `cancelSwitch()` does not clear it. So the overlay
appears immediately with old apps/windows, then flashes to the new data
a frame or two later. `selectedAppIndex` and `sphereZoom` are also stale,
creating visible jumps in the satellite card and zoom level.

The fix moves `visible = true` (and the entrance animation trigger) from
`openSwitcher()` into `finishOpenSwitcher()`, after the sphere data is
ready. The overlay stays invisible during the async data-gathering phase,
then appears all at once with the correct content, correct selection,
and correct zoom.

---

## Implementation

### 1. Move visibility and animation out of `openSwitcher()`

**Before:**
```qml
function openSwitcher() {
    window.layer = 0;
    window.drilledAppId = "";
    window.searchQuery = "";
    window.savedLayer2Model = [];
    window.savedLayer2Query = "";

    window.focusable = true;
    window.overlayActive = true;
    window.visible = true;
    introPhaseAnim.restart();
    focusGrabber.forceActiveFocus();

    Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("hyprsphere"))']);

    Hyprland.refreshToplevels();
    Qt.callLater(function() { finishOpenSwitcher(); });
}
```

**After:**
```qml
function openSwitcher() {
    window.layer = 0;
    window.drilledAppId = "";
    window.searchQuery = "";
    window.savedLayer2Model = [];
    window.savedLayer2Query = "";

    window.focusable = true;
    window.overlayActive = true;

    Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("hyprsphere"))']);

    Hyprland.refreshToplevels();
    Qt.callLater(function() { finishOpenSwitcher(); });
}
```

Removed three lines:
- `window.visible = true`
- `introPhaseAnim.restart()`
- `focusGrabber.forceActiveFocus()`

### 2. Add visibility and animation to `finishOpenSwitcher()`

**Before** (last lines of the function):
```qml
    projDirty = true;
    rebuildProjCache();

    // Initialize Fuse index for search
    initFuseIndex();

    // Refresh on next tick to catch pending appId resolutions.
    Qt.callLater(function() { scheduleRebuild(); });
```

**After:**
```qml
    projDirty = true;
    rebuildProjCache();

    // Initialize Fuse index for search
    initFuseIndex();

    // Now that sphere data is ready, make the overlay visible.
    // The entrance fade animation and keyboard focus are handled
    // by onVisibleChanged, which fires automatically.
    window.visible = true;

    // Refresh on next tick to catch pending appId resolutions.
    Qt.callLater(function() { scheduleRebuild(); });
```

The `onVisibleChanged` handler already takes care of the entrance
animation and focus grab:
```qml
Connections {
    target: window
    function onVisibleChanged() {
        if (window.visible) {
            window.sphereZoom   = 1.0;
            introPhaseAnim.restart();
            focusGrabber.forceActiveFocus();
        }
    }
}
```

So we get `introPhaseAnim.restart()` and `focusGrabber.forceActiveFocus()`
for free — no need to call them explicitly in `finishOpenSwitcher()`.

### 3. Edge case: Empty-state placeholder

If `finishOpenSwitcher()` builds a sphere with only the "No windows"
placeholder (e.g., no running apps at all), this is still **real data**
— the overlay appears with a meaningful state. No special handling
needed.

### 4. Edge case: Rapid Alt+Tab during data gathering

If the user presses Alt+Tab while `finishOpenSwitcher()` is still in its
retry loop (icons not ready, or toplevels empty):

- `IpcHandler.toggle()` checks `window.overlayActive`, which is `true`
  (set in `openSwitcher()`)
- It calls `window.advance(1)` instead of `openSwitcher()` again
- `selectedAppIndex` changes, but the overlay is still invisible
- When `finishOpenSwitcher()` eventually completes, it shows the correct
  state with the advanced index

This is benign — the advance is applied before the first render.

### 5. Edge case: Escape during data gathering

If the user presses Escape while `finishOpenSwitcher()` is still retrying:

- `Keys.onPressed` calls `window.cancelSwitch()`
- `cancelSwitch()` sets `overlayActive = false`, starts `closeSequence`
- `closeSequence` animates `introPhase` to 0.0 and sets `visible = false`
- Since the overlay was never made visible, the animation is invisible
  (but harmless)
- When `finishOpenSwitcher()` eventually runs, `overlayActive` is `false`,
  so `commitSelection()` guards prevent commits. But `finishOpenSwitcher()`
  will still set `visible = true` — this is a problem.

**Fix:** Add a guard at the top of `finishOpenSwitcher()` to abort if the
overlay is no longer active:

```qml
function finishOpenSwitcher() {
    // Guard: if the overlay was cancelled while we were gathering data, abort
    if (!window.overlayActive) {
        console.log("[hyprsphere] finishOpenSwitcher aborted — overlay no longer active");
        return;
    }
    // ... rest unchanged ...
}
```

This ensures that an Escape press during the async data-gathering phase
properly cancels the session without the overlay appearing unexpectedly
once the retry loop completes.

### 6. Edge case: `scheduleRebuild()` retry loop visibility

The `onRawEvent` closewindow handler also has a retry-like pattern that
toggles visibility:
```qml
if (window.visible) {
    window.visible = false;
    Qt.callLater(function() {
        window.visible = true;
    });
    scheduleRebuild();
}
```

This unmaps and remaps the surface to force the compositor to re-grant
keyboard focus. It only runs when the overlay is already visible, so it
doesn't interact with the Phase 10 changes.

---

## Config

No new config fields.

---

## Exit criteria

1. **First Alt+Tab** after quickshell starts — overlay appears only once
   sphere data is ready (no stale/empty flash)
2. **Re-open after Escape** — overlay appears identically to first open
   (no stale `sphereModel` flash from previous session)
3. **No visual difference** between first open and subsequent opens
4. **Entrance fade animation** still plays correctly on every open
5. **Keyboard focus** is grabbed when overlay appears
6. **Escape during data gathering** properly cancels the session (overlay
   never appears)
7. **Rapid Alt+Tab** during data gathering doesn't cause double-open or
   corruption
8. **`onVisibleChanged` handler** (`sphereZoom = 1.0`, `forceActiveFocus`,
   `introPhaseAnim.restart()`) fires correctly when visibility is set in
   `finishOpenSwitcher()`
9. **All existing features** continue to work: Tab cycling, `;` drill-down,
   search, Ctrl+C close, Ctrl+Enter spawn, Alt release commit, mouse
   interaction
