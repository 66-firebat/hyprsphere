# PHASE_2 — MRU tracking, two levels (in-memory, no daemon)

**Deliverable:** Alt+Tab pre-selects the previous app (MRU index 1).
Tab cycling wraps around. Closing a window prunes it from the MRU
immediately via `rawEvent`. No daemon, no files — just two tracked
arrays in QML that update reactively as focus changes.

---

## Steps

### 1. Add MRU data structures

Add to `hyprsphere.qml` (alongside `sphereModel`):

```qml
// App-level MRU: most-recent-first list of appId strings
property var appMru: []

// Per-app window MRU: { appId: [addr, addr, ...] } most-recent-first
property var appWindowMru: ({})
```

### 2. Update MRU on focus change

Track every focus change so MRU is always accurate, even while the
overlay is closed:

```qml
Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
        var t = Hyprland.activeToplevel;
        if (!t) return;
        var appId = (t.wayland && t.wayland.appId) ? t.wayland.appId : "unknown";
        var addr = t.address || "";

        // Move app to front of app-level MRU
        var filtered = [];
        for (var i = 0; i < appMru.length; i++) {
            if (appMru[i] !== appId) filtered.push(appMru[i]);
        }
        appMru = [appId].concat(filtered);

        // Move window to front of this app's per-app window MRU
        var winList = appWindowMru[appId] || [];
        var winFiltered = [];
        for (var j = 0; j < winList.length; j++) {
            if (winList[j] !== addr) winFiltered.push(winList[j]);
        }
        appWindowMru[appId] = [addr].concat(winFiltered);
    }
}
```

Uses explicit loops instead of `.filter()` for QML JS compatibility.

### 3. Update `openSwitcher()` to sort by MRU

Replace the current `openSwitcher()` with a version that sorts by
`appMru` and pre-selects index 1:

```qml
function openSwitcher() {
    var raw = buildLayer0();

    // Sort by MRU position: apps in appMru first, then unknown
    var sorted = [];
    for (var m = 0; m < appMru.length; m++) {
        for (var r = 0; r < raw.length; r++) {
            if (raw[r].appId === appMru[m]) {
                sorted.push(raw[r]);
                break;
            }
        }
    }
    // Append any apps not in MRU (new windows since last focus)
    for (var r2 = 0; r2 < raw.length; r2++) {
        if (sorted.indexOf(raw[r2]) === -1) sorted.push(raw[r2]);
    }

    sphereModel = sorted.length === 0
        ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
        : sorted;

    // Pre-select index 1 (previous app) if MRU has enough history,
    // otherwise index 0
    if (sphereModel.length > 0 && !sphereModel[0].isPlaceholder) {
        selectedAppIndex = (appMru.length >= 2) ? 1 : 0;
        if (selectedAppIndex < sphereModel.length) {
            centerOnApp(selectedAppIndex);
        }
    }

    projDirty = true;
    rebuildProjCache();
    window.visible = true;
    introPhaseAnim.restart();
}
```

### 4. Prune MRU on window close

Listen to `Hyprland.rawEvent` and match `closewindow>>` events:

```qml
Connections {
    target: Hyprland
    function onRawEvent(event) {
        var text = event.name || "";
        if (!text.startsWith("closewindow>>")) return;
        var addr = text.substring("closewindow>>".length);

        // Find and remove the address from all per-app window MRU lists
        for (var appId in appWindowMru) {
            var list = appWindowMru[appId];
            var idx = -1;
            for (var k = 0; k < list.length; k++) {
                if (list[k] === addr) { idx = k; break; }
            }
            if (idx !== -1) {
                // Remove this address
                var newList = [];
                for (var k2 = 0; k2 < list.length; k2++) {
                    if (k2 !== idx) newList.push(list[k2]);
                }
                if (newList.length === 0) {
                    delete appWindowMru[appId];
                    // Remove app from app-level MRU too
                    var newMru = [];
                    for (var m = 0; m < appMru.length; m++) {
                        if (appMru[m] !== appId) newMru.push(appMru[m]);
                    }
                    appMru = newMru;
                } else {
                    appWindowMru[appId] = newList;
                }
                break;
            }
        }
    }
}
```

### 5. Add wrap-around config

Add to `hyprsphere.json`:

```json
{
  "cycling": {
    "wrapAround": true
  }
}
```

### 6. Update `advance()` for wrap-around

Phase 3 will introduce `Keys.onPressed` which calls `advance(dir)`.
The advance function uses wrap-around based on config:

```qml
function advance(dir) {
    if (sphereModel.length === 0) return;
    var count = sphereModel.length;
    var next = selectedAppIndex + dir;
    if (next < 0) {
        next = cfg.cycling?.wrapAround !== false ? count - 1 : 0;
    } else if (next >= count) {
        next = cfg.cycling?.wrapAround !== false ? 0 : count - 1;
    }
    selectedAppIndex = next;
    centerOnApp(next);
}
```

### 7. Wire via IpcHandler for Phase 3 readiness

Add advance/drill/commit/cancel stubs to the IpcHandler (no-op bodies
for now, wired when Phase 3 delivers key handling):

```qml
IpcHandler {
    target: "hyprsphere"
    function toggle(): void { openSwitcher() }
    function advance(): void {}
    function drilldown(): void {}
    function commit(): void {}
    function cancel(): void { closeSequence.start() }
}
```

Cancel is wired now since Escape works in Phase 1.

---

## Exit criteria

- Alt+Tab (via `qs ipc call hyprsphere toggle`) opens the sphere with
  the previous app pre-selected at MRU index 1
- Tab cycling wraps around at the edges (configurable via
  `cfg.cycling?.wrapAround`)
- Closing a window via `closewindow>>` event prunes its address from
  `appWindowMru` and (if last window) the app from `appMru`
- No crashes when MRU is empty on first launch
