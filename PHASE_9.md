# PHASE_9 — Ctrl+Enter spawn new window

**Deliverable:** Press Ctrl+Enter while an app or window node is selected in
hyprsphere to spawn a new instance of that application. The new window is
properly focused, gets added to the MRU list, and the sphere rebuilds with
it as the selected node — allowing rapid spawning of multiple windows.

---

## Rationale

Inspired by GNOME's AATWS (Advanced Alt-Tab Window Switcher), which binds
a configurable hotkey (default Ctrl+Enter) to `app.open_new_window(-1)`.
This calls GNOME Shell's built-in method that reads the `.desktop` file,
strips field codes, and launches a new instance. AATWS then listens for
the `window-created` signal and refreshes the switcher list so the new
window appears immediately.

Hyprsphere's equivalent:
- Read `Exec=` from `.desktop` files (we already scan them in Phase 7)
- Strip freedesktop field codes (`%u`, `%U`, `%f`, `%F`, `%i`, `%c`, `%k`)
- Launch via `Quickshell.execDetached()`
- New window appears naturally via the `openwindow` raw event handler,
  which triggers `scheduleRebuild()` → sphere refreshes with new node
  selected

---

## Implementation

### 1. Extract `Exec=` lines in the icon reader

Modify the `iconReader` Process bash script (Phase 7) to also capture the
`Exec=` line from each `.desktop` file:

```
grep -E '^(Name=|Icon=|StartupWMClass=|Exec=)' "$f" 2>/dev/null;
```

Add a third map: `execMap` (`appId → cleaned command string`).

**Critical: Only the FIRST Exec= line is used.** Desktop files often have
multiple Exec lines for different actions (e.g., Firefox has `Exec=firefox
--name firefox %U`, `Exec=firefox --private-window %U`, `Exec=firefox
--new-window %U`, `Exec=firefox --ProfileManager`). Without this guard,
the parser would take the **last** one (`--ProfileManager`), causing the
profile manager to open instead of a normal window. The parse loop only
captures `Exec=` when `exec === null` (first occurrence).

**Field code stripping.** Desktop Entry Spec field codes must be removed
from the Exec value:

| Code | Meaning | Strip |
|---|---|---|
| `%f` | Single file | Yes |
| `%F` | Multiple files | Yes |
| `%u` | Single URL | Yes |
| `%U` | Multiple URLs | Yes |
| `%i` | Icon name | Yes |
| `%c` | Translated name | Yes |
| `%k` | Desktop file location | Yes |
| `%%` | Literal `%` | Replace with `%` |

Additional cleanup:
- Strip trailing whitespace after code removal
- Only strip codes, not quoted arguments

### 2. Add `execMap` property and `resolveExec()` function

```qml
property var execMap: ({})
property var execMap: ({})

function resolveExec(appId) {
    if (!appId) return null;
    return execMap[appId] || null;
}
```

Populated in `parseIcons()` alongside `iconMap` and `nameMap`:
```qml
if (id && exec) {
    emap[id] = exec;
    if (wmClass) emap[wmClass] = exec;
}
```

### 3. Add `openNewWindow()` function

```qml
function openNewWindow() {
    if (closeSequence.running) return;

    var node = sphereModel[selectedAppIndex];
    if (!node || node.isPlaceholder) return;

    // Resolve appId — for window nodes, use the parent appId
    var appId = node.appId;
    if (!appId) return;

    // Build exec command: whitelist exec → execMap → appId fallback
    var execCmd = node.exec || window.resolveExec(appId) || appId;

    // Launch the app
    window._pendingSpawnAppId = appId;
    Quickshell.execDetached(["bash", "-c", execCmd]);
}
```

**Note:** `node.exec` is available for whitelist entries (configured in
`hyprsphere.json`). For non-whitelisted apps, `resolveExec()` looks up
the cleaned Exec= line from the `.desktop` file. If neither is available,
the raw `appId` is used as the command (last-resort fallback).

### 4. Wire Ctrl+Enter into key handler

Added in the `focusGrabber` `Keys.onPressed` handler alongside Tab, `;`,
Ctrl+C, Backspace, and Escape:

```qml
} else if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) {
    window.openNewWindow();
    event.accepted = true;
}
```

### 5. Auto-select spawned window

This was the most nuanced part. When a new window is spawned:

1. **`openwindow` raw event** fires → the handler detects
   `window._pendingSpawnAppId === appId`, stores the address in
   `window._pendingSpawnAddr`, and calls `scheduleRebuild()`.

2. **`scheduleRebuild()`** defers to the next event tick via
   `Qt.callLater`, then rebuilds the sphere model. After the rebuild,
   it runs layer-aware auto-selection:

   ```
   Layer 0 (app nodes):
     SphereModel has { appId, windows, windowCount, ... } — NO .address
     → Match by appId against _pendingSpawnAppId
     → Select the first non-whitelist-placeholder node with matching appId

   Layer 1/2 (window nodes):
     SphereModel has { address, title, appId, ... } — HAS .address
     → Match by address against _pendingSpawnAddr
   ```

3. **`_pendingSpawnAppId` persists** until the rebuild callback consumes
   it. The `openwindow` handler does NOT clear it — it only sets
   `_pendingSpawnAddr`. This is important because at layer 0, app nodes
   don't have an `.address` field, so matching must be done by appId.

**Why layer awareness matters:** At layer 0, the sphere contains app
groups (one node per distinct appId). These nodes lack an `address`
property because they represent multiple windows. The original
implementation only searched by `sphereModel[si].address`, which never
matched at layer 0, leaving the selection unchanged (often pointing to
a different app entirely).

### 6. No-op for unresolvable apps

If no `exec` can be found (no desktop file, no whitelist entry, and the
appId doesn't work as a command), `openNewWindow()` silently returns.
The `resolveExec(appId)` returns `null`, and the fallback chain
`node.exec || resolveExec(appId) || appId` means the raw appId is tried
as a last resort. If that fails to launch anything, Hyprland simply
does nothing.

### 7. Behavior after spawn

Per requirements:
- Overlay stays open (user can spawn another)
- Sphere rebuilds with new window selected
- New window appears in MRU lists naturally via existing `openwindow`
  handler which pushes to `appMru` and `appWindowMru`

### 8. Fallback selection

If the layer-0 auto-selection fails to find a matching app node (edge
case), a fallback selects the first non-placeholder node in the sphere
to avoid an empty or invalid selection.

---

## Implementation details discovered during coding

### Firefox Exec= multi-line issue

Firefox's `.desktop` file has multiple `Exec=` lines for different
actions (normal launch, new window, private window, profile manager).
The grep pattern matches ALL of them. Without the `exec === null`
guard, the parser takes the LAST `Exec=` line, which is
`Exec=firefox --ProfileManager` → the profile manager opens instead of
a normal window.

**Fix:** Only capture the first `Exec=` line per block.

### Layer-0 vs layer-1 auto-selection

At layer 0, sphere nodes are app groups — they have `appId`,
`windows`, `windowCount`, etc., but NO `address` property. The
original auto-selection loop searched `sphereModel[si].address ===
pendingSpawnAddr`, which failed silently at layer 0. The sphere rebuilt
but the selection stayed on whatever `rebuildToLayer0()` set it to,
which could be a completely different app.

**Fix:** Layer-aware matching — appId at layer 0, address at layers 1/2.

### Pending spawn flag lifecycle

The `openwindow` handler initially cleared `_pendingSpawnAppId` before
calling `scheduleRebuild()`. But since `scheduleRebuild()` defers via
`Qt.callLater`, by the time the rebuild ran, the appId was gone and
layer-0 auto-selection had nothing to match against.

**Fix:** The `openwindow` handler only sets `_pendingSpawnAddr` and
leaves `_pendingSpawnAppId` intact. Both are cleared at the end of the
auto-selection block inside the deferred rebuild callback.

---

## Config

No new config fields needed for the basic feature. If we want to make the
launch command overridable later, it can go in a future refinement.

---

## Config additions

### `appCard` (no new fields required for v1)

---

## Exit criteria

1. **Ctrl+Enter** on an app node spawns a new window of that app
2. **Ctrl+Enter** on a window node spawns a new window of the parent app
3. **New window opens** and is usable (focused/visible)
4. **Sphere rebuilds** with the new window as the selected node
5. **New window** appears in MRU lists
6. **Overlay stays open** after spawn (can spawn again)
7. **No-op** for apps without a resolvable exec command
8. **Whitelisted apps** use their configured `exec` field
9. **Non-whitelisted apps** resolve from `.desktop` file `Exec=` line
10. **Field codes** (`%u`, `%U`, `%f`, `%F`, `%i`, `%c`, `%k`) are stripped
    from the exec command
11. **Firefox spawns a normal window** (not the profile manager) — first
    Exec= line is used, not the last
12. **Layer-0 auto-selection** matches by appId (not address), so the
    correct app group is selected after spawn
13. **Persistence of `_pendingSpawnAppId`** — the flag survives until the
    deferred rebuild callback consumes it
