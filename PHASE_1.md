# PHASE_1 — Data source: app grouping (layer 0)

**Deliverable:** Alt+Tab shows a sphere with your real running apps on it,
sorted alphabetically, whitelist entries appended at the end. No MRU
sorting, no key handling, no commit logic — just the data layer wired
into the sphere so you can visually verify it works.

---

## Steps

### 1. Add `import Quickshell.Hyprland`

Add to the top of `hyprsphere.qml` alongside the existing imports:

```qml
import Quickshell.Hyprland
```

### 2. Delete the old launcher data pipeline

Remove entirely:
- `import Quickshell.Io` — only needed for the old `Process` + `StdioCollector`
  (keep it if we find other Io usage; likely safe to remove)
- The `paths` Item (no longer needed without `app_fetcher.py`)
- The `appFetcher` Process block
- The `ListModel { id: appModel }` declaration
- The `appendChunk()` function inside the Process
- The `appFetcher` Process block
- Delete the file `applauncher/app_fetcher.py` from disk

The `Repeater` that was bound to `appModel` will be re-bound to
`sphereModel` (see step 4).

### 3. Add config for whitelist

Add to `hyprsphere.json`:

```json
{
  "whitelist": [
    {
      "appId": "firefox",
      "label": "Firefox",
      "icon": "firefox",
      "exec": "firefox"
    }
  ]
}
```

### 4. Implement `buildLayer0()`

Add this function and supporting properties to `hyprsphere.qml`:

```qml
// Holds the sphere node data — replaces the old ListModel
property var sphereModel: []

// Config loaded from hyprsphere.json (already exists from earlier work)
property var cfg: ({})

function buildLayer0() {
    let groups = {};

    // 1. Build running-app groups from Hyprland.toplevels
    for (let i = 0; i < Hyprland.toplevels.count; i++) {
        let t = Hyprland.toplevels.get(i);
        let ws = t.workspace;
        // Special workspace check: ws.id is always -1 in IPC mode, use name only
        let isSpecial = ws && String(ws.name ?? "").startsWith("special:");
        if (isSpecial) continue;
        let appId = t.wayland?.appId ?? "unknown";
        if (!groups[appId]) groups[appId] = { appId, label: appId, icon: appId, windows: [] };
        groups[appId].windows.push({ address: t.address, title: t.title });
        groups[appId].windowCount = groups[appId].windows.length;
    }

    // 2. Append whitelist entries, deduplicating by appId
    let whitelist = cfg.whitelist || [];
    for (let entry of whitelist) {
        if (groups[entry.appId]) continue;
        groups[entry.appId] = {
            appId: entry.appId,
            label: entry.label,
            icon: entry.icon,
            exec: entry.exec,
            windows: [],
            windowCount: 0,
            isWhitelistPlaceholder: true,
        };
    }

    return Object.values(groups);
}
```

### 5. Re-bind the Repeater to `sphereModel`

Replace the `Repeater`'s `model: appModel` with `model: sphereModel`.

Also update the delegate to read from the normalized node shape:
- `model.label` instead of `model.name` (for display text)
- `model.icon` instead of `model.icon` (already the same)
- Remove any reference to `model.exec` in the card display (exec is only
  used at commit time, not for rendering)

### 6. Minimal `openSwitcher()`

No MRU, no key handling. Just rebuild the sphere and show the overlay:

```qml
function openSwitcher() {
    let raw = buildLayer0();
    sphereModel = raw.length === 0
        ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
        : raw;  // no MRU sort yet — alphabetical from Object.values()

    // Pre-select first item (or placeholder)
    selectedAppIndex = 0;
    if (sphereModel.length > 0 && !sphereModel[0].isPlaceholder) {
        centerOnApp(0);
    }

    // Show overlay
    window.visible = true;
}
```

### 7. Wire IpcHandler.show()

```qml
import Quickshell.Io

IpcHandler {
    target: "hyprsphere"
    function show(): void { window.openSwitcher() }
}
```

### 8. Hyprland bind (in `keymaps.lua`)

```lua
hl.bind("ALT + Tab", hl.dsp.exec_cmd("qs ipc call hyprsphere show"))
```

### 9. `Hyprland.refreshToplevels()` on startup

In `Component.onCompleted`:

```qml
Component.onCompleted: {
    Hyprland.refreshToplevels();
    // configReader.running = true; — already exists from earlier work
}
```

### 10. Rebuild on `appId` resolution

When a toplevel's `wayland.appId` resolves from null to a real value,
re-run `buildLayer0()` and update `sphereModel`:

```qml
// Debounce guard: avoid rebuilding on rapid successive resolutions
property bool rebuildScheduled: false

function scheduleRebuild() {
    if (rebuildScheduled) return;
    rebuildScheduled = true;
    Qt.callLater(function() {
        rebuildScheduled = false;
        if (window.visible) {
            let raw = buildLayer0();
            sphereModel = raw.length === 0
                ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
                : raw;
        }
    });
}
```

### Late addition (added during Phase 2): Refresh on open

During testing, windows that opened shortly before `openSwitcher()` ran
sometimes had `wayland.appId === null`, lumping them into an `"unknown"`
group. The fix: call `Hyprland.refreshToplevels()` at the start of
`openSwitcher()`, then defer the sphere build to a `Qt.callLater()`
callback (one event-loop tick, ~16ms). This gives Quickshell's IPC
connection time to resolve pending `appId` values before we read them.

The overlay is shown immediately (intro animation starts playing) so
the user never sees a delay — the sphere populates ~16ms later with
correct app names, well before the 800ms intro animation finishes.
