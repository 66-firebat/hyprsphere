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
- New window appears naturally via the `openwindow` raw event handler
- `scheduleRebuild()` refreshes the sphere with the new node selected

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

### 6. No-op for unresolvable apps

If no `exec` can be found (no desktop file, no whitelist entry, and the
appId doesn't work as a command), `openNewWindow()` silently returns.
The fallback chain `node.exec || resolveExec(appId) || appId` means the
raw appId is tried as a last resort. If that fails to launch anything,
Hyprland simply does nothing.

### 7. Behavior after spawn

Per requirements:
- Overlay stays open (user can spawn another)
- Sphere rebuilds with new window selected
- New window appears in MRU lists naturally via existing `openwindow`
  handler which pushes to `appMru` and `appWindowMru`

#### MRU focus consideration

Which window receives focus on Alt release after spawning depends on
where you spawned from:
- **Spawning from the app group (layer 0):** The **original MRU-most**
  window is focused on commit, not the newly spawned one. The new window
  is added to the app's window list but does not become the active MRU
  target.
- **Spawning from a specific window (layer 1):** The **newly spawned**
  window is focused on commit. Since you spawned while a specific window
  was selected, the new window becomes the MRU-most for that app, and
  layer-1 commits use `appWindowMru[appId][0]` to determine the focus
  target.

### 8. Fallback selection

If the layer-0 auto-selection fails to find a matching app node (edge
case), a fallback selects the first non-placeholder node in the sphere
to avoid an empty or invalid selection.

---

## Bugs discovered during testing

### Bug 1: Firefox profile manager instead of new window

**Symptom:** Ctrl+Enter on Firefox opened the profile manager dialog.

**Root cause:** Firefox's `.desktop` file has 4 `Exec=` lines:
```
Exec=firefox --name firefox %U       ← default (first)
Exec=firefox --private-window %U
Exec=firefox --new-window %U
Exec=firefox --ProfileManager        ← last, this was being picked!
```

The grep matched ALL Exec lines, and the parser kept the **last** one.

**Fix:** Only capture the first `Exec=` per block (`exec === null` guard).

### Bug 2: Layer-0 auto-selection matched by address (impossible)

**Symptom:** After spawning Firefox's first window, the sphere rebuilt but
a different app (Ghostty) was selected instead of Firefox.

**Root cause:** At layer 0, sphere nodes are app groups — they have
`appId`, `windows`, `windowCount`, etc., but NO `address` property. The
auto-selection loop searched `sphereModel[si].address === pendingSpawnAddr`,
which never matched at layer 0, so the selection stayed on whatever
`rebuildToLayer0()` set it to.

**Fix:** Layer-aware matching — match by `appId` at layer 0, by `address`
at layers 1/2.

### Bug 3: `_pendingSpawnAppId` cleared before deferred rebuild

**Symptom:** Same as Bug 2 — auto-selection failed.

**Root cause:** The `openwindow` handler initially cleared
`_pendingSpawnAppId = ""` before calling `scheduleRebuild()`. But
`scheduleRebuild()` defers via `Qt.callLater` — by the time the rebuild
callback ran, `_pendingSpawnAppId` was already gone. The layer-0
auto-selection had nothing to match against.

**Fix:** The `openwindow` handler only sets `_pendingSpawnAddr` and
leaves `_pendingSpawnAppId` intact. Both are cleared inside the deferred
rebuild callback after auto-selection completes.

### Bug 4: Toplevel data not yet available during deferred rebuild

**Symptom:** After spawning, the badge showed `+0` or `+1` incorrectly.
Closing and reopening the overlay showed the correct count.

**Root cause:** `Hyprland.toplevels` is populated asynchronously. When
the `openwindow` event fires and `scheduleRebuild()` runs on the next
tick, the toplevel list may not yet reflect the new window. So
`buildLayer0()` returns stale data — the spawned app still appears as a
whitelist placeholder or with an outdated window count.

**Fix:** Added a **retry loop** inside the deferred `scheduleRebuild()`
callback. After calling `Hyprland.refreshToplevels()` and
`buildLayer0()`, it checks if the specific pending address
(`_pendingSpawnAddr`) actually exists in the app's window list. If not,
it resets the rebuild guard and re-schedules for the next tick. This
continues until the toplevel data catches up.

### Bug 5: Retry check too lenient for subsequent spawns

**Symptom:** First spawn worked, second spawn showed stale count (e.g.,
+1 instead of +2), third spawn showed +2 instead of +3.

**Root cause:** The original retry check only verified `windowCount >= 1
&& !isWhitelistPlaceholder`. After the first spawn, the app already had
1 window, so this check passed immediately — even when the toplevel data
hadn't updated yet. The second spawn's data was silently ignored.

**Fix:** Instead of checking `windowCount >= 1`, the retry now checks if
the **specific pending address** exists in the app's window array by
comparing addresses.

### Bug 6: Address format mismatch (`0x` prefix)

**Symptom:** Retry loop never completed (infinite retries suspected).

**Root cause:** `t.address` from `HyprlandToplevel` may or may not
include the `0x` prefix. But `_pendingSpawnAddr` is always normalized to
include `0x` (done in the `openwindow` handler). The comparison
`raw[ri].windows[wj].address === window._pendingSpawnAddr` would fail
even when the window IS in the list, because one has `0x` and the other
doesn't.

**Fix:** Normalize both sides before comparing:
```js
var winAddr = raw[ri].windows[wj].address || "";
if (winAddr.indexOf("0x") !== 0) winAddr = "0x" + winAddr;
if (winAddr === window._pendingSpawnAddr) { ... }
```

---

## Retry loop flow

The retry logic inside `scheduleRebuild()`'s deferred callback:

```
scheduleRebuild() called
  │
  ▼
Qt.callLater → deferred callback
  │
  ├── Hyprland.refreshToplevels()
  ├── raw = buildLayer0()
  │
  ├── If _pendingSpawnAddr is set and raw has data:
  │     Check: does app's window list contain _pendingSpawnAddr?
  │       ├── YES → proceed to sphere rebuild
  │       └── NO  → rebuildScheduled = false
  │                  scheduleRebuild()  ← retry on next tick
  │                  return
  │
  ├── (normal sphere rebuild: layer handling, sortByMru, etc.)
  ├── Auto-select: find matching node by appId or address
  ├── Clear _pendingSpawnAddr and _pendingSpawnAppId
  └── forceActiveFocus()
```

---

## Config

No new config fields needed for the basic feature.

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
14. **Retry loop** handles async toplevel data — retries until the spawned
    window's address appears in the app's window list
15. **Multiple sequential spawns** — each Ctrl+Enter increments the badge
    correctly (+1, +2, +3, ...)
16. **Address format normalization** — `0x` prefix comparison is handled
    correctly between event data and toplevel data
