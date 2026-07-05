# PHASE_4 — Selection & commit logic (two-layer state machine)

**Deliverable:** Full press→hold→cycle→(optional `;` drill)→cycle→release→focus
loop works at both layers, driven entirely by the focused overlay's own key
handlers with no per-keystroke IPC round-trip. Single-click selects a node,
double-click commits. Window titles are visible at layer 1.

---

## Implementation plan

### 0. Preconditions

The following already exist in `hyprsphere.qml`:
- `sphereModel`, `selectedAppIndex`, `overlayActive`
- `buildLayer0()`, `sortByMru(raw)`, `scheduleRebuild()`
- `advance(dir)`, `cancelSwitch()`, `centerOnApp(index)`
- `appMru`, `appWindowMru`
- `closeSequence` (SequentialAnimation), `introPhaseAnim`
- `focusGrabber` (Item with `Keys.onPressed`/`Keys.onReleased`)
- Satellite card with icon + label display

### 1. Add layer state properties

Insert after line 57 (`property int selectedAppIndex: -1`):

```qml
// ── Phase 4: two-layer state machine ──
property int layer: 0              // 0=apps, 1=windows of one app
property string drilledAppId: ""   // which app was drilled into (layer 1)
```

### 2. Update `openSwitcher()` to initialise layer 0

Changes to the existing `openSwitcher()` function (starts around line 75):

```qml
function openSwitcher() {
    console.log("[hyprsphere] openSwitcher called");

    window.layer = 0;
    window.drilledAppId = "";
    window.overlayActive = true;
    window.visible = true;
    introPhaseAnim.restart();

    // Focus is grabbed in onVisibleChanged (same call stack, but keeps
    // focus-grabbing colocated with the visible-state transition rather
    // than mixed into data-building logic). The overlayActive guard in
    // toggle() prevents re-entry while already open.

    Hyprland.refreshToplevels();
    Qt.callLater(function() {
        // ... rest unchanged: buildLayer0, sortByMru, centerOnApp, rebuildProjCache
    });
}
```

One addition:
- `window.layer = 0` / `window.drilledAppId = ""` — fresh state every open

### 3. Add `drillDown()` function

Insert after `scheduleRebuild()` (around line 141).

```qml
function drillDown() {
    if (window.layer === 0) {
        // --- Layer 0 → Layer 1 ---
        var app = sphereModel[selectedAppIndex];
        if (!app || app.isPlaceholder || app.isWhitelistPlaceholder) return;
        if (app.windowCount === 0) return;  // safety net for any future zero-window node

        window.layer = 1;
        window.drilledAppId = app.appId;

        // Enriched node shape: carry icon + label from parent app
        var winMru = appWindowMru[app.appId] || [];
        sphereModel = app.windows.slice().map(function(w) {
            return {
                address: w.address,
                title:   w.title,
                icon:    app.icon,
                label:   app.label,
                appId:   app.appId,
            };
        }).sort(function(a, b) {
            var ia = winMru.indexOf(a.address);
            var ib = winMru.indexOf(b.address);
            return (ia === -1 ? 999 : ia) - (ib === -1 ? 999 : ib);
        });

        selectedAppIndex = 0;
        projDirty = true;
        rebuildProjCache();
        centerOnApp(0);
    } else {
        // --- Layer 1 → Layer 0 ---
        window.layer = 0;
        var raw = buildLayer0();
        sphereModel = raw.length === 0
            ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
            : sortByMru(raw);
        projDirty = true;
        rebuildProjCache();

        // Try to re-center on the previously-drilled app
        var prevIdx = -1;
        for (var i = 0; i < sphereModel.length; i++) {
            if (sphereModel[i].appId === window.drilledAppId) { prevIdx = i; break; }
        }
        selectedAppIndex = prevIdx >= 0 ? prevIdx : 0;
        centerOnApp(selectedAppIndex);
        window.drilledAppId = "";
    }
}
```

Key design decisions:
- Drill-down always allowed (≥1 window). Even a single-window app can be
  drilled into — this surfaces the window title in the satellite card.
- **Whitelist placeholder guard:** `isWhitelistPlaceholder` and
  `windowCount === 0` are both checked. A whitelist entry with no running
  windows has zero nodes to show at layer 1.
- `;` at layer 1 always toggles back to layer 0 (not a no-op)
- Window list is sorted by `appWindowMru[appId]` on drill-down
- Layer-1 nodes carry enriched shape: `{ address, title, icon, label, appId }`
  where `icon` and `label` are copied from the parent app group

### 4. Add `commitSelection()` function

Insert after `drillDown()`.

```qml
function commitSelection() {
    // Guard: Escape already started the close animation; don't double-fire
    if (closeSequence.running) return;

    var node = sphereModel[selectedAppIndex];
    if (!node || node.isPlaceholder) {
        closeSequence.start();
        return;
    }

    // Whitelist placeholder — not running, launch it
    if (node.isWhitelistPlaceholder) {
        Hyprland.dispatch("exec " + node.exec);
        closeSequence.start();
        return;
    }

    var addr;
    if (window.layer === 0) {
        // Layer 0: focus the MRU-most window of the selected app
        var winMru = appWindowMru[node.appId] || [];
        var best = null;
        // Find the window address that appears first in winMru
        for (var m = 0; m < winMru.length; m++) {
            for (var w = 0; w < node.windows.length; w++) {
                if (node.windows[w].address === winMru[m]) {
                    best = winMru[m];
                    break;
                }
            }
            if (best) break;
        }
        addr = best || node.windows[0].address; // fallback to first window
    } else {
        // Layer 1: focus the specific window
        addr = node.address;
    }

    Hyprland.dispatch("focuswindow address:" + addr);

    // Reset overlay flag immediately so IPC toggle() won't try to advance
    // a dying sphere during the 400ms fade animation.
    window.overlayActive = false;
    closeSequence.start();
}

**Narrow timing race (non-blocking, worth knowing):** `scheduleRebuild()`
is debounced via `Qt.callLater`, but `commitSelection()` runs synchronously
on Alt release. If a window closes in the same event-loop tick that you
release Alt to commit it, `appWindowMru` is pruned immediately (Phase 2's
`onRawEvent` is synchronous) but `sphereModel` itself isn't rebuilt until
the deferred callback runs. This means `commitSelection()` could
theoretically dispatch `focuswindow` to an address that closed a few
milliseconds earlier. The race window is: window-close event processed
in the same event-loop tick as Alt-release, and that window happens to
be the one you're committing to. Not blocking for v1, but worth being
aware of.
```

### 5. Update `cancelSwitch()` to reset layer

Current function (around line 360):

```qml
function cancelSwitch() {
    window.layer = 0;
    window.drilledAppId = "";
    window.overlayActive = false;
    closeSequence.start();
}
```

Add `layer = 0` and `drilledAppId = ""` before starting the close sequence.

### 6. Update `onVisibleChanged` to grab focus

Current handler (around line 335):

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

Add `focusGrabber.forceActiveFocus()` so keyboard focus is always captured
when the overlay appears.

### 7. Update `scheduleRebuild()` for layer awareness

**Design rule — if the drilled app still exists, stay at layer 1.**
Drill-down is always allowed (≥1 window), so `scheduleRebuild()` should
not bounce to layer 0 just because the window count dropped. Instead,
check whether the selected window's address survived the rebuild. If it
did, preserve the user's position. If it didn't (the selected window
closed), go to index 0 (MRU-most remaining). Only fall back to layer 0
if the entire app disappeared (no windows left).

When a window closes while the overlay is open:

- **Layer 1:** save the selected address, rebuild the window list for
  the drilled app. If the app still exists, restore selection or land
  on index 0. If the app is gone entirely, fall back to layer 0.
- **Layer 0:** rebuild from `buildLayer0()`. If the selected app's last
  window closed and it's gone from the list, clamp to `length - 1`.

```qml
function scheduleRebuild() {
    if (rebuildScheduled) return;
    rebuildScheduled = true;
    Qt.callLater(function() {
        rebuildScheduled = false;
        if (!window.visible) return;

        var raw = buildLayer0();

        if (window.layer === 1 && window.drilledAppId) {
            // Save current selection before rebuild
            var prevAddress = sphereModel[selectedAppIndex]
                ? sphereModel[selectedAppIndex].address
                : null;

            // Find the drilled app in the fresh data
            var app = null;
            for (var i = 0; i < raw.length; i++) {
                if (raw[i].appId === window.drilledAppId) { app = raw[i]; break; }
            }

            if (app && app.windowCount >= 1) {
                // App still exists — rebuild window list
                var winMru = appWindowMru[app.appId] || [];
                sphereModel = app.windows.slice().map(function(w) {
                    return {
                        address: w.address,
                        title:   w.title,
                        icon:    app.icon,
                        label:   app.label,
                        appId:   app.appId,
                    };
                }).sort(function(a, b) {
                    var ia = winMru.indexOf(a.address);
                    var ib = winMru.indexOf(b.address);
                    return (ia === -1 ? 999 : ia) - (ib === -1 ? 999 : ib);
                });

                // Try to restore previous selection
                var restoredIdx = -1;
                for (var si = 0; si < sphereModel.length; si++) {
                    if (sphereModel[si].address === prevAddress) { restoredIdx = si; break; }
                }
                selectedAppIndex = restoredIdx >= 0 ? restoredIdx : 0;
                centerOnApp(selectedAppIndex);
            } else {
                // App completely gone (all windows closed) — fall back to layer 0
                window.layer = 0;
                window.drilledAppId = "";
                rebuildToLayer0(raw);
            }
        } else {
            // At layer 0 — rebuild, clamp if selected app disappeared
            rebuildToLayer0(raw);
        }

        projDirty = true;
        rebuildProjCache();
    });
}

// Helper: rebuild sphereModel from layer-0 data, clamping selection if needed.
function rebuildToLayer0(raw) {
    if (raw.length === 0) {
        sphereModel = [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }];
        selectedAppIndex = 0;
        return;
    }
    sphereModel = sortByMru(raw);
    selectedAppIndex = Math.min(sphereModel.length - 1, selectedAppIndex);
    centerOnApp(selectedAppIndex);
}
```

### 8. Update satellite card text for layer 1

In the satellite `sourceComponent` (around line ~680), the screen text
currently reads:

```qml
Text {
    text: window.sphereModel[window.selectedAppIndex]?.label || ""
    ...
}
```

Replace with layer-aware text selection:

```qml
Text {
    text: {
        var node = window.sphereModel[window.selectedAppIndex];
        if (!node) return "";
        return window.layer === 1 && node.title ? node.title : (node.label || "");
    }
    ...
}
```

Also update the satellite icon's `source` — it already reads `node.icon`
which is correct for both layers (enriched during drill-down).

### 9. Update normal card text for layer 1

In the delegate's non-selected card (around line ~630), the label Text reads:

```qml
Text {
    text: model.label
    ...
}
```

Replace with:

```qml
Text {
    text: window.layer === 1 && model.title ? model.title : (model.label || "")
    ...
}
```

### 10. Add click-to-select and double-click-to-commit

**Design decision — drill-down is keyboard-only.** There is no mouse
equivalent to `;` (e.g. middle-click or long-press to drill).
Double-click at layer 0 always commits directly to the MRU-most window;
it does not drill into the app. This keeps mouse interactions simple:
click = select, double-click = commit. If a mouse-driven drill-down
is desired later, a middle-click handler is an easy addition.

In the delegate's `MouseArea` (around line ~715, currently has only
`hoverEnabled: true` and `cursorShape`):

```qml
MouseArea {
    id: nodeMa
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onClicked: {
        window.selectedAppIndex = index;
        window.centerOnApp(index);
    }

    onDoubleClicked: {
        window.selectedAppIndex = index;
        window.commitSelection();
    }
}
```

Note: `centerOnApp()` will be called by `onClicked` for single-click
selection. The auto-rotate timer is already stopped during drag (via
`sceneMouse.pressed`), so rotating the sphere by mouse drag and then
clicking a node will correctly select+center it.

### 11. Guard `advance()` against placeholder

The current `advance()` already works fine with placeholders (it just
cycles the single placeholder node). No change needed — the guard is
already in `commitSelection()` and `drillDown()`. But add a guard so
Tab does nothing on the "No windows" screen:

```qml
function advance(dir) {
    if (sphereModel.length === 0) return;
    if (sphereModel[0].isPlaceholder) return;  // no-op on "No windows"
    var count = sphereModel.length;
    // ... rest unchanged
}
```

### 12. Update `closewindow` pruning — handle layer-1 staleness

When a window closes while the overlay is open at layer 1, the removed
window's address is pruned from `appWindowMru` (Phase 2), but the
layer-1 sphereModel still contains a stale node for it. The user could
Tab onto a deleted window and commit to a dead address.

Fix: after pruning in `onRawEvent`, call `scheduleRebuild()` to refresh
the visible data. Add to the existing `closewindow` handler:

```qml
// After the pruning logic block, add:
if (window.visible) {
    scheduleRebuild();
}
```

---

## Exit criteria

1. **Alt+Tab** opens sphere at layer 0 with app groups, pre-selected at MRU index 1
2. **`;` (semicolon)** drills into an app's windows → sphere rebuilds in place with
   one node per window, sorted by per-app MRU, showing window titles
3. **`;` again** returns to layer 0 app groups, centered on the previously-drilled app
4. **`;` on a single-window app** drills in and shows the window title
   in the satellite card (drill-down always allowed, ≥1 window)
5. **Tab/Shift+Tab** cycles correctly at both layers, wraps around
6. **Alt release** dispatches `focuswindow address:...` for the selected node:
   - Layer 0: focuses the MRU-most window of the selected app group
   - Layer 1: focuses the specific window
7. **Escape** closes overlay without dispatching, resets layer to 0
8. **Double-click** on any node commits it (same as Alt release)
9. **Single-click** on any node selects it and centers the sphere
10. **Escape + Alt release race**: pressing Escape then releasing Alt during
    the fade-out does NOT dispatch focus (`closeSequence.running` guard)
11. **Satellite card** shows window title at layer 1, app label at layer 0
12. **Normal cards** show window title at layer 1, app label at layer 0
13. **"No windows" placeholder** prevents Tab cycling, drill-down, and commit
14. **Window close** while overlay is open triggers `scheduleRebuild()` to
    refresh the visible sphere correctly at whichever layer
15. **Whitelist placeholder** app commits via `Hyprland.dispatch("exec ...")`
    at layer 0 (no windows yet, launch instead of focus)
