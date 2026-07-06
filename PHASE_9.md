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

## Tasks

### 1. Extract `Exec=` lines in the icon reader

Modify the `iconReader` Process bash script (Phase 7) to also capture the
`Exec=` line from each `.desktop` file:

```
grep -E '^(Name=|Icon=|StartupWMClass=|Exec=)' "$f" 2>/dev/null;
```

Add a third map: `execMap` (`appId → cleaned command string`).

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
- Strip trailing whitespace
- Handle quoted arguments (don't strip inside quotes)

### 2. Add `execMap` property and `resolveExec()` function

```qml
property var execMap: ({})

function resolveExec(appId) {
    if (!appId) return null;
    return execMap[appId] || null;
}
```

Populated in `parseIcons()` alongside `iconMap` and `nameMap`.

### 3. Add `_openNewWindow()` function

```qml
function openNewWindow() {
    if (closeSequence.running) return;

    var node = sphereModel[selectedAppIndex];
    if (!node || node.isPlaceholder) return;

    // Resolve the appId — for window nodes, use the parent appId
    var appId = node.appId || node.appId;
    if (!appId) return;

    // Prefer exec from whitelist entry, then execMap, then appId as fallback
    var execCmd = null;
    if (node.exec) {
        execCmd = node.exec;
    } else {
        execCmd = resolveExec(appId);
    }
    if (!execCmd) execCmd = appId; // last-resort: use appId as command

    // Launch via quickshell exec detached
    Quickshell.execDetached(["bash", "-c", execCmd]);

    // After launch, sphere will rebuild on next openwindow event
    // We set a flag so the rebuild selects the new window
    window._pendingSpawnAppId = appId;
}
```

### 4. Wire Ctrl+Enter into key handler

In the `focusGrabber` `Keys.onPressed` handler, add:

```qml
} else if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) {
    window.openNewWindow();
    event.accepted = true;
}
```

### 5. Auto-select spawned window

When the `openwindow` raw event fires and `_pendingSpawnAppId` is set,
trigger a rebuild that selects the newly created window.

Since the `openwindow` handler already calls `scheduleRebuild()` when the
overlay is visible, and `scheduleRebuild()` is layer-aware, the sphere
will automatically refresh. The new window will appear in the MRU lists
via the existing `openwindow` handler code.

To auto-select the new window, modify the `openwindow` handler or
`scheduleRebuild()` to check `_pendingSpawnAppId` and center on the
newest window matching that appId.

### 6. No-op for unresolvable apps

If no `exec` can be found (no desktop file, no whitelist entry, and the
appId doesn't work as a command), `openNewWindow()` silently returns.

### 7. Behavior after spawn

Per requirements:
- Overlay stays open (user can spawn another)
- Sphere rebuilds with new window selected
- New window appears in MRU lists naturally via existing `openwindow` handler

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
