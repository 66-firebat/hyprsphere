# PHASE_6 — Search bar with fuzzy filtering (layer 2)

**Deliverable:** A search bar at the bottom-center of the overlay that, when
the user types, transitions the sphere to **layer 2** — a fuzzy-filtered view
showing matching running apps, then matching whitelisted apps, then matching
windows. Typing any letter/digit key starts the search. Backspace when the
field is empty returns to layer 0. Escape always closes the overlay.

Uses **Fuse.js v7.0.0** (copied from polysphere's `lib/fuse.js`) for fuzzy
matching — the same library and build that was proven working in the previous
prototype.

---

## Architecture

### Three-layer state machine

| Layer | Description | Source |
|---|---|---|
| 0 | All app groups (running + whitelist), MRU-sorted | `buildLayer0()` |
| 1 | Individual windows of one app, MRU-sorted | Drill-down from layer 0 or 2 |
| 2 | Fuzzy-filtered results across apps + windows | Fuse.js search |

### Layer 2 node ordering

When the user types, the layer-2 sphere shows results in this order:

1. **Matching running apps** (in Fuse score order, then MRU order for ties)
2. **Matching whitelisted placeholder apps** (apps not currently running)
3. **Matching windows** (individual window titles, across all apps)

### Search data flow

```
User types "fire"
    │
    ▼
_handleSearchInput() — accumulates searchQuery, starts debounce timer
    │
    ▼ (after cfg.search.delayMs, default 150ms)
_executeSearch()
    │
    ├─ Build searchDatabase from all running apps + whitelist + all windows
    ├─ Fuse index search across label/appId/title keys
    ├─ Sort results: running apps → whitelisted apps → windows
    ├─ Set sphereModel = layer2 results
    ├─ Set layer = 2
    ├─ Zoom sphere to cfg.search.layer2Zoom (default 1.5)
    └─ Center on index 0
```

### Drill-down from layer 2

Pressing `;` on an app node at layer 2 saves the current search state and
drills into layer 1 (that app's windows). Pressing `;` again restores the
search state and returns to layer 2.

- `savedLayer2Model` — snapshot of sphereModel before drill-down
- `savedLayer2Query` — snapshot of searchQuery before drill-down

### Node shapes at layer 2

**Running app node** (same as layer 0):
```js
{ appId, label, icon, windows: [...], windowCount, isSearchResult: true }
```

**Whitelisted placeholder node:**
```js
{ appId, label, icon, exec, windows: [], windowCount: 0,
  isWhitelistPlaceholder: true, isSearchResult: true }
```

**Window node:**
```js
{ appId, label, icon, address, title, isWindowNode: true, isSearchResult: true }
```

### Commit behavior at layer 2

Same as layers 0/1:
- Running app node → focus MRU-most window via `appWindowMru`
- Whitelisted placeholder → launch via `exec`, dispatch focus by class
- Window node → focus that address directly

---

## Steps

### 1. Copy Fuse.js into the project

```bash
cp /home/fireshark/polysphere/lib/fuse.js lib/fuse.js
```

Fuse.js v7.0.0 — `.pragma library`, QML-compatible build (UMD wrapper
stripped). Already proven working in polysphere.

### 2. Add `import "lib/fuse.js" as FuseJs`

Alongside existing imports at top of `hyprsphere.qml`.

### 3. Add search/layer-2 state properties

```qml
property string searchQuery: ""
property var fuseIndex: null
property var searchDatabase: []
property var searchTimer: null
property var savedLayer2Model: []
property string savedLayer2Query: ""
property bool searchFocused: false
```

### 4. Build search database from live data

```qml
function buildSearchDatabase() {
    var db = [];
    var tls = Hyprland.toplevels;
    var arr = (tls && tls.values) || [];

    // Add running apps (deduplicated by appId)
    var seenApps = {};
    for (var i = 0; i < arr.length; i++) {
        var t = arr[i];
        if (!t) continue;
        var ws = t.workspace;
        if (ws && String(ws.name || "").startsWith("special:")) continue;
        var wl = t.wayland;
        var appId = (wl && wl.appId) ? wl.appId : "unknown";
        if (!seenApps[appId]) {
            seenApps[appId] = true;
            db.push({
                type: "running-app",
                appId: appId,
                label: appId,
                icon: appId,
                windows: []
            });
        }
        // Find the app entry and add this window
        for (var d = 0; d < db.length; d++) {
            if (db[d].appId === appId && db[d].type === "running-app") {
                db[d].windows.push({ address: t.address, title: t.title });
                break;
            }
        }
    }

    // Add window-level entries for title search
    for (var i2 = 0; i2 < arr.length; i2++) {
        var t2 = arr[i2];
        if (!t2) continue;
        var ws2 = t2.workspace;
        if (ws2 && String(ws2.name || "").startsWith("special:")) continue;
        var wl2 = t2.wayland;
        var appId2 = (wl2 && wl2.appId) ? wl2.appId : "unknown";
        db.push({
            type: "window",
            appId: appId2,
            label: appId2,
            icon: appId2,
            address: t2.address,
            title: t2.title || appId2
        });
    }

    // Add whitelisted placeholder apps (not already running)
    var whitelist = cfg.whitelist || [];
    for (var e = 0; e < whitelist.length; e++) {
        var entry = whitelist[e];
        if (seenApps[entry.appId]) continue;
        db.push({
            type: "whitelisted-app",
            appId: entry.appId,
            label: entry.label,
            icon: entry.icon,
            exec: entry.exec,
            windows: [],
            windowCount: 0
        });
    }

    return db;
}
```

### 5. Initialize Fuse index

```qml
function initFuseIndex() {
    var db = buildSearchDatabase();
    searchDatabase = db;
    try {
        fuseIndex = new FuseJs.Fuse(db, {
            keys: [
                { name: "label", weight: 0.5 },
                { name: "title", weight: 0.4 },
                { name: "appId", weight: 0.1 }
            ],
            threshold: cfg.search?.fuseThreshold ?? 0.4,
            minMatchCharLength: cfg.search?.fuseMinMatchCharLength ?? 1,
            includeScore: true,
            shouldSort: true
        });
    } catch (e) {
        console.log("[hyprsphere] Fuse init error:", String(e));
        fuseIndex = null;
    }
}
```

### 6. Search input handler (debounced)

```qml
function _handleSearchInput(text) {
    searchQuery = text;

    // If query is empty and we were on layer 2, return to layer 0
    if (searchQuery === "" && window.layer === 2) {
        cancelSearch();
        return;
    }

    // Debounce search
    if (searchTimer) searchTimer.running = false;
    searchTimer = Qt.createQmlObject(
        'import QtQuick; Timer { interval: ' + (cfg.search?.delayMs ?? 150)
        + '; running: true; repeat: false; onTriggered: window._executeSearch(); }',
        window
    );
}

function _executeSearch() {
    if (searchQuery === "") return;
    if (!fuseIndex) {
        initFuseIndex();
        if (!fuseIndex) return;
    }

    var results = fuseIndex.search(searchQuery);
    var maxResults = cfg.search?.maxResults ?? 30;
    var top = results.slice(0, maxResults);

    // Organize results by type
    var runApps = [];
    var whitelistApps = [];
    var windows = [];

    for (var i = 0; i < top.length; i++) {
        var item = top[i].item;
        if (item.type === "running-app") {
            runApps.push(item);
        } else if (item.type === "whitelisted-app") {
            whitelistApps.push(item);
        } else if (item.type === "window") {
            windows.push(item);
        }
    }

    // Build layer 2 model: running apps → whitelisted apps → windows
    var layer2Model = [];

    // Running apps: full app group shape for consistency
    for (var r = 0; r < runApps.length; r++) {
        var ra = runApps[r];
        layer2Model.push({
            appId: ra.appId,
            label: ra.label,
            icon: ra.icon,
            windows: ra.windows,
            windowCount: ra.windows.length,
            isSearchResult: true
        });
    }

    // Whitelisted apps
    for (var w = 0; w < whitelistApps.length; w++) {
        var wa = whitelistApps[w];
        layer2Model.push({
            appId: wa.appId,
            label: wa.label,
            icon: wa.icon,
            exec: wa.exec,
            windows: [],
            windowCount: 0,
            isWhitelistPlaceholder: true,
            isSearchResult: true
        });
    }

    // Windows
    for (var w2 = 0; w2 < windows.length; w2++) {
        var wnode = windows[w2];
        layer2Model.push({
            appId: wnode.appId,
            label: wnode.label,
            icon: wnode.icon,
            address: wnode.address,
            title: wnode.title,
            isWindowNode: true,
            isSearchResult: true
        });
    }

    window.layer = 2;
    sphereModel = layer2Model.length === 0
        ? [{ label: "No results", icon: "", appId: "", isPlaceholder: true }]
        : layer2Model;
    selectedAppIndex = 0;
    projDirty = true;
    rebuildProjCache();
    centerOnApp(0);

    // Zoom in on layer 2
    sphereZoom = cfg.search?.layer2Zoom ?? 1.5;
}

function cancelSearch() {
    searchQuery = "";
    savedLayer2Model = [];
    savedLayer2Query = "";
    var raw = buildLayer0();
    window.layer = 0;
    sphereModel = raw.length === 0
        ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
        : sortByMru(raw);
    sphereZoom = 1.0;
    projDirty = true;
    rebuildProjCache();
    if (sphereModel.length > 0 && !sphereModel[0].isPlaceholder) {
        selectedAppIndex = Math.min(sphereModel.length - 1, selectedAppIndex);
        centerOnApp(selectedAppIndex);
    }
}
```

### 7. Update key handlers for search

Add letter key capture and Backspace to `focusGrabber.Keys.onPressed`:

```qml
} else if (event.key === Qt.Key_Backspace && !event.isAutoRepeat) {
    if (window.searchQuery.length > 0) {
        window._handleSearchInput(window.searchQuery.slice(0, -1));
    }
    event.accepted = true;
} else if (!event.isAutoRepeat && event.text.length > 0
           && event.text.match(/[a-zA-Z0-9 _.-]/)) {
    window._handleSearchInput(window.searchQuery + event.text);
    event.accepted = true;
}
```

### 8. Update `drillDown()` for layer 2

```qml
function drillDown() {
    if (window.layer === 0) {
        // ... existing layer 0 → layer 1 code ...
    } else if (window.layer === 2) {
        // Layer 2 → drill into app → Layer 1
        var node = sphereModel[selectedAppIndex];
        if (!node || node.isPlaceholder || node.isWhitelistPlaceholder) return;
        if (node.isWindowNode) return; // no-op on window nodes
        if (!node.windows || node.windowCount === 0) return;

        // Save layer 2 state for restoration
        savedLayer2Model = sphereModel.slice();
        savedLayer2Query = searchQuery;

        window.layer = 1;
        window.drilledAppId = node.appId;

        var winMru = appWindowMru[node.appId] || [];
        sphereModel = node.windows.slice().map(function(w) {
            return {
                address: w.address,
                title:   w.title,
                icon:    node.icon,
                label:   node.label,
                appId:   node.appId,
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
        sphereZoom = 1.0;
    } else {
        // Layer 1 → back to previous layer
        if (savedLayer2Model.length > 0) {
            // Return to layer 2
            window.layer = 2;
            searchQuery = savedLayer2Query;
            sphereModel = savedLayer2Model;
            savedLayer2Model = [];
            savedLayer2Query = "";
            projDirty = true;
            rebuildProjCache();

            var prevIdx = -1;
            for (var i = 0; i < sphereModel.length; i++) {
                if (sphereModel[i].appId === window.drilledAppId) { prevIdx = i; break; }
            }
            selectedAppIndex = prevIdx >= 0 ? prevIdx : 0;
            centerOnApp(selectedAppIndex);
            window.drilledAppId = "";
            sphereZoom = cfg.search?.layer2Zoom ?? 1.5;
        } else {
            // Normal layer 1 → layer 0
            window.layer = 0;
            var raw = buildLayer0();
            sphereModel = raw.length === 0
                ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
                : sortByMru(raw);
            projDirty = true;
            rebuildProjCache();

            var prevIdx = -1;
            for (var i = 0; i < sphereModel.length; i++) {
                if (sphereModel[i].appId === window.drilledAppId) { prevIdx = i; break; }
            }
            selectedAppIndex = prevIdx >= 0 ? prevIdx : 0;
            centerOnApp(selectedAppIndex);
            window.drilledAppId = "";
        }
    }
}
```

### 9. Update `commitSelection()` for layer 2

Add layer 2 handling. Window nodes at layer 2 have `isWindowNode` set and
carry an `address` property directly. App nodes follow the same logic as
layer 0 (focus MRU-most window). Whitelisted placeholders still launch.

### 10. Update `scheduleRebuild()` for layer 2

When rebuilding at layer 2, re-run the search with the current query
instead of trying to preserve node positions (the search may return
different results after the data change).

### 11. Add search bar UI

Bottom-center Rectangle with semi-transparent background, readOnly TextField,
and a subtle shadow. Always visible during the overlay (shows placeholder
text when empty).

### 12. Update satellite card

Layer 2 app nodes: show app label (like layer 0)
Layer 2 window nodes: show window title (like layer 1)

---

## Key design decisions

| Decision | Choice |
|---|---|
| Search activation | Type any letter/digit → auto-enters layer 2 |
| Search exit | Backspace when empty → back to layer 0 |
| Escape behavior | Always closes overlay (any layer) |
| Search bar visibility | Always visible during overlay |
| TextField focus | readOnly, text set programmatically — no focus steal |
| Fuse library | Fuse.js v7.0.0 (copied from polysphere/lib/) |
| Fuzzy keys | label (0.5), title (0.4), appId (0.1) |
| Search scope | All running apps, all whitelisted apps, all windows |
| Layer 2 ordering | Running apps → whitelisted apps → windows |
| `;` at layer 2 | Drills into app (layer 1), restores search on toggle back |
| `;` on window node | No-op |
| Commit at layer 2 | Same as layer 0/1: MRU for apps, address for windows |
| Layer 2 zoom | Configurable, default 1.5 |
| Debounce | 150ms default (configurable) |

---

## Submap integration (Hyprland key event pass-through)

The core problem is that **33 Alt-prefixed Hyprland keymaps** (fullscreen,
focus, launch rofi, etc.) consume key events before QML ever sees them.
When the user holds Alt and types 'f', Hyprland fires `ALT + F` →
fullscreen toggle and the 'f' key never reaches the overlay.

### Solution: Hyprland submap

When the overlay opens, we enter a dedicated `hyprsphere` submap via
`hyprctl dispatch submap hyprsphere`. Inside the submap:

- **Only three binds are defined:**
  - `ALT + Alt_L` release → `qs ipc call hyprsphere commit`
  - `ALT + Alt_R` release → `qs ipc call hyprsphere commit`
  - `Escape` → `qs ipc call hyprsphere cancel`
- **All other keys are unbound** → Hyprland passes them through to the
  focused layer surface (the overlay). QML's `Keys.onPressed` receives
  them directly, including letter keys and Tab.

### Flow

```
User presses Alt+Tab
    │
    ▼
Global `ALT + Tab` bind fires (Lua function)
    ├─ hl.dispatch(hl.dsp.submap("hyprsphere"))     ← synchronously enters submap FIRST
    └─ hl.dispatch(hl.dsp.exec_cmd("qs ipc call hyprsphere toggle"))  ← then opens overlay
    │
    ▼
QML: openSwitcher() sets up sphere
    │
    ▼
Submap active → user types 'f'
    │  Hyprland checks submap: no ALT+F bind → passes key through
    ├─ Global `ALT + F` bind does NOT fire (submap blocks it)
    └─ QML receives 'f' → _handleSearchInput() → layer 2
    │
    ▼
User releases Alt → submap `release = true` bind fires → commit
    │
    ▼
QML commitSelection() → focus dispatch + submap reset

User presses Escape → submap bind fires → IPC cancel → submap reset
```

### Changes to keymaps.lua

```lua
hl.define_submap("hyprsphere", function()
    -- Alt release to commit
    hl.bind("ALT + Alt_L", hl.dsp.exec_cmd("qs ipc call hyprsphere commit"), { release = true })
    hl.bind("ALT + Alt_R", hl.dsp.exec_cmd("qs ipc call hyprsphere commit"), { release = true })

    -- Escape to close overlay and reset submap
    hl.bind("Escape", function()
        hl.dispatch(hl.dsp.exec_cmd("qs ipc call hyprsphere cancel"))
    end)
end)

-- The global release binds (ALT + Alt_L / Alt_R) are commented out since
-- the submap now handles Alt release detection. They would never fire
-- because the submap intercepts the release event first.
```

### Changes to hyprsphere.qml

- `openSwitcher()`: `execDetached` submap dispatch kept as safety net (harmless no-op if submap already active)
- `cancelSwitch()`: add submap reset + `closeSequence.running` guard
- `commitSelection()`: add submap reset after focus dispatch
- New `cancel()` IpcHandler function for Escape IPC route

### `Keys.onPressed` for Escape

The QML `Keys.onPressed` handler for Escape is kept as a safety fallback.
When the submap is active, Hyprland consumes the Escape key and the QML
handler won't fire. If the submap is somehow inactive, the QML handler
still works. A `closeSequence.running` guard in `cancelSwitch()` prevents
double-fire if both paths execute.

### `Keys.onPressed` for Tab

With the submap active and `submap_universal` unset (default `false`),
global binds are blocked inside the submap. `ALT + Tab` is not bound in
the submap, so the Tab key passes through to QML directly.
`Keys.onPressed` sees `Qt.Key_Tab` (possibly with `Qt.AltModifier`) and
calls `advance(1)` — Tab cycling works natively now, no IPC fallback
needed. The `overlayActive` guard in `toggle()` is kept as a safety net.

### Why this approach (not Phase 3's submap failure)

Phase 3's submap attempt failed for a different scenario: it tried to
detect Alt release INSIDE a submap entered by holding Alt+Tab, where
the release-bind was consumed by the submap entry mechanism itself.
Here, the submap is entered programmatically via `hyprctl dispatch`
from QML, not by a keypress. The release-binds work correctly in this
context.

---

## Config additions (`hyprsphere.json`)

### `searchBar` block (updated from old launcher config)

```json
{
  "searchBar": {
    "width": 560,
    "height": 56,
    "borderRadius": 28,
    "bottomMargin": 63,
    "borderWidth": 1.5,
    "backgroundOpacity": 0.92,
    "shadowOpacity": 0.4,
    "shadowBlur": 1.5,
    "placeholderText": "Search apps and windows...",
    "placeholderColor": "#6c7086"
  }
}
```

### `search` block (new)

```json
{
  "search": {
    "delayMs": 150,
    "maxResults": 30,
    "fuseThreshold": 0.4,
    "fuseMinMatchCharLength": 1,
    "layer2Zoom": 1.5
  }
}
```

Removed from `sphere` block: `searchZoom` (replaced by `search.layer2Zoom`).

---

## Exit criteria

1. **Typing a letter** while overlay is open transitions to layer 2 with
   fuzzy-filtered results
2. **Layer 2 ordering**: matching running apps → whitelisted apps → windows
3. **Backspace** removes last character; empty field returns to layer 0
4. **Escape** always closes the overlay regardless of layer
5. **Tab** cycles through layer 2 results
6. **`;` on an app node** drills into layer 1 (that app's windows)
7. **`;` again** restores the layer 2 search results and query
8. **`;` on a window node** is a no-op
9. **Alt release** commits the selected node (focus or launch)
10. **Ctrl+C** closes the selected window(s) at layer 2
11. **Search bar** is visible at bottom-center with placeholder text
12. **searchZoom/layer2Zoom** sphere zoom is configurable
13. **Fuse.js** settings are configurable via hyprsphere.json
14. **No search bar/keyboard focus conflict** — TextField is readOnly
