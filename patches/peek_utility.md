# PATCH — Peek Utility (window snapshot preview)

> Configurable "peek": when a node is selected (keyboard cycling), show a
> **snapshot of that window's content** as a full-screen backdrop behind the
> sphere — without switching workspaces, without stealing focus, and without
> touching MRU or stacking order.

---

## Overview

Today the sphere overlay opens and, as you Tab through nodes, there is no way
to see *what* each node is beyond its icon/label. This patch adds a **peek
backdrop**: a `ScreencopyView` that renders a single captured frame of the
selected window's own surface buffer, placed behind the sphere cards.

The snapshot approach is strictly preferable to the earlier "raise the real
window" idea because Hyprland's `hyprland-toplevel-export-v1` protocol (which
Quickshell's `ScreencopyView` uses) can capture a window's contents **even when
it is obscured, minimized, on another workspace, or on another monitor**. This
eliminates workspace switching, focus stealing, MRU corruption, and z-order
changes entirely — the whole class of problems that made `focusOnTab` and
`slashPreview` fragile.

### Design decisions (locked)

| # | Decision |
|---|---|
| 1 | **Single frame** (not live): `live: false` + `captureFrame()` |
| 2 | **Large centered backdrop** behind the sphere cards |
| 3 | **Inside the existing overlay** (one `PanelWindow`), at low z |
| 4 | **Fit the screen, preserve aspect ratio** (via `constraintSize`) |
| 5 | **No label** overlaid on the snapshot |
| 6 | **Fully frozen** — one frame per selection change, no refresh |
| 7 | **Nothing** when there's no capturable window (transparent) |
| 8 | **Full opacity** (100%) |
| 9 | **Keep the satellite card** (it floats over the snapshot) |
| 10 | **Remove `slashPreview` and `focusOnTab`** (replaced by peek) |
| F1 | **Include** special-workspace (`special:*`) windows (free + side-effect-free) |
| F2 | **Transparent** letterbox/pillarbox bars |
| F3 | **No debounce** — capture on every keyboard advance |
| F4 | **Keyboard-only** — Tab/Shift+Tab + initial open; mouse click-select does **not** peek |
| F5 | **Fade with the overlay** — backdrop opacity bound to `introPhase` |
| — | Config: `"peek": { "enabled": true }` (on by default) |
| — | Peek applies at **all layers** (0/1/2); each node already carries a `.address` |

---

## Requirements / dependencies

- **Hyprland** — provides `hyprland-toplevel-export-v1` (present since well
  before 0.55; the project already targets 0.55+).
- **Quickshell** — must expose `Quickshell.Wayland.ScreencopyView` and the
  `ToplevelManager` singleton (`Quickshell.Wayland._ToplevelManagement`), i.e. be
  built with screencopy + toplevel-export support. **Confirmed working on
  Quickshell 0.3.0** (verified on this machine).
- **No new process, no helper binary.** `ScreencopyView` talks to the protocol
  natively. This keeps the daemon-free architecture intact.

### Protocol reference

- Quickshell's `ScreencopyView` captures a toplevel via
  `hyprland_toplevel_export_manager_v1::capture_toplevel_with_wlr_toplevel_handle`,
  which takes a **`zwlr_foreign_toplevel_handle_v1`** (the foreign-toplevel
  handle), *not* the window address. That is why the selected node must be
  resolved to a foreign-toplevel handle (by `appId` + `title`) rather than by
  address.
- `wl_shm` buffers are always supported, so a single-frame copy is reliable.
- Captured frames exclude server-side decorations and compositor geometry
  (rounded corners) — acceptable for a preview.

---

## Configuration change

### `hyprsphere.json`

Add a top-level `peek` object (enabled by default):

```json
{
  "peek": {
    "enabled": true
  },
  "colors": { /* ... unchanged ... */ }
}
```

Only `enabled` is read for v1. All other behaviors (single frame, fit-screen,
full opacity, no label) are hardcoded per the table above. The object shape
leaves room to add `live`, `opacity`, `refreshIntervalMs`, `label`, etc. later
without a breaking config change.

---

## Implementation

### 1. Add a `ScreencopyView` as the overlay's backdrop

`Quickshell.Wayland` is already imported in `shell.qml`. Add the view as the
**first visual child** of the root `PanelWindow` (so it renders behind
`scene3D` and `searchContainer`), with an explicit low z:

```qml
    // ══════════════════════════════════════════════════════════════════════
    // PEEK BACKDROP — snapshot of the selected window (behind the sphere)
    // ══════════════════════════════════════════════════════════════════════
    ScreencopyView {
        id: peekView
        anchors.centerIn: parent
        z: -1                              // behind scene3D + searchContainer
        live: false                        // single frame, not a stream
        paintCursor: false
        opacity: window.introPhase         // fade with the overlay (F5)
        captureSource: null                // set by refreshPeek()
        constraintSize: Qt.size(window.width, window.height)  // fit + preserve aspect (F4/F2)
    }
```

Notes:
- **No background rectangle** → the letterbox/pillarbox bars around the
  (aspect-preserved) snapshot are transparent, showing the desktop through (F2).
- `opacity: window.introPhase` gives the fade-in/out for free (F5). Do **not**
  place it inside `scene3D`, which also applies a `scale` transform that would
  visibly scale the window content on open/close.
- `constraintSize` is what makes `ScreencopyView` scale its *implicit* size to
  fit within the screen while preserving aspect ratio.

### 2. Resolve a selected node → foreign-toplevel handle

`ScreencopyView.captureSource` does **not** accept a `HyprlandToplevel` — it
expects a **foreign-toplevel handle** (`Quickshell.Wayland._ToplevelManagement.Toplevel`,
obtained from the `ToplevelManager` singleton). Those handles carry `appId` +
`title` but **no Hyprland address**, so the selected node is matched by
`appId` + `title`:

```javascript
    // Resolve a window (appId + title) to its foreign-toplevel capture source.
    function resolveForeignToplevel(appId, title) {
        if (!appId) return null;
        var tm = ToplevelManager.toplevels;
        var arr = (tm && tm.values) || [];
        var fallback = null;
        for (var i = 0; i < arr.length; i++) {
            var t = arr[i];
            if (!t || t.appId !== appId) continue;
            if (t.title === title) return t;      // exact match
            if (!fallback) fallback = t;          // first same-appId fallback
        }
        return fallback;                          // ambiguous title → best-effort
    }
```

`ToplevelManager` is a singleton re-exported by `Quickshell.Wayland` (already
imported), so no extra import is needed. Note this is title-based matching:
two windows of the same app with *identical* titles can't be disambiguated
(rare; the exact-match path handles the common case).

### 3. `refreshPeek()` — the single capture entry point

```javascript
    // Capture a snapshot of the currently selected node (keyboard-driven only).
    function refreshPeek() {
        if (cfg.peek?.enabled !== true) { peekView.captureSource = null; return; }
        var node = sphereModel[window.selectedAppIndex];
        if (!node || node.isPlaceholder || node.isWhitelistPlaceholder) {
            log("refreshPeek: placeholder node — clearing snapshot");
            peekView.captureSource = null;
            return;
        }
        var appId = node.appId || "";
        var title = node.isWindowNode
            ? (node.title || "")
            : (node.windows && node.windows.length ? node.windows[0].title : "");
        var t = window.resolveForeignToplevel(appId, title);
        peekView.captureSource = t;
        if (t) {
            peekView.captureFrame();
            log("refreshPeek: captured appId=" + appId + " title=\"" + String(title).substring(0, 40) + "\"");
        } else {
            log("refreshPeek: NO foreign toplevel for appId=" + appId + " title=\"" + String(title).substring(0, 40) + "\"");
        }
    }
```

Behavior details:
- **Placeholder node** (`isPlaceholder` / `isWhitelistPlaceholder`) → clears the view.
- **App-group node** → uses the MRU-most window's `title` (`node.windows[0].title`).
- **Window node** (layer 1/2) → uses its own `title`.
- **Capture failure** (window closed between selection and capture) → `hasContent`
  stays `false` and the view renders nothing. No extra handling needed.
- **Special-workspace windows** → matched by appId+title regardless of workspace (F1).

### 4. Wire the hook points (keyboard-only, F4)

Call `window.refreshPeek()` from the keyboard navigation paths, **not** from
mouse click.

**`binds.js` — `advance()`** (Tab / Shift+Tab):

```javascript
function advance(window, dir) {
    // ... existing index math + centerOnApp ...
    window.selectedAppIndex = next;
    window.centerOnApp(next);
    window.refreshPeek();                                   // ← NEW
    window.log("advance: ...");
}
```

**`binds.js` — `drillDown()`** (`;`): call `window.refreshPeek()` at the end of
each of the three branches (0→1, 2→0, 1→0), after the sphere model is rebuilt
and the new selection is centered.

**`shell.qml` — `_executeSearch()` and `cancelSearch()`**: call
`window.refreshPeek()` after the new `sphereModel`/`selectedAppIndex` is set.
Search is keyboard-driven, so results changing under your typing should update
the snapshot.

**`shell.qml` — `finishOpenSwitcher()`** (initial open): call
`window.refreshPeek()` once the pre-selected node is chosen. This satisfies
"peek on initial open."

**Do NOT add** `refreshPeek()` to the delegate `MouseArea.onClicked` handler —
click-select must not trigger a peek (F4). (Double-click commit is a separate
path and needs no peek either.)

### 5. Clear the peek on close

In `cancelSwitch()` and the `commitSelection`/close paths (or centrally in
`closeSequence`'s `ScriptAction`), set `peekView.captureSource = null` so the
capture buffer is released and no stale frame lingers. Simplest: clear it where
`window.visible = false` is already set (the view is hidden anyway, but nulling
the source releases the buffer).

### 6. Remove the old preview mechanisms (F10)

**`binds.js`** — delete `slashPreview()` entirely (and its `maximizeOnSlash`
reference, which is the only remaining use of that config key).

**`shell.qml`** — in `focusGrabber`'s `Keys.onPressed`, remove the
`Qt.Key_Backslash` / `Qt.Key_Bar` branch that calls `Binds.slashPreview`.

**`hyprsphere.json`** — remove the dead `"focusOnTab": false` key.

**`README.md`** — remove the "Known Limitations → Held Tab does not cycle when
`focusOnTab` is enabled" section (the visibility-toggle workaround it describes
no longer exists for this feature), and any other `focusOnTab`/`slashPreview`
references.

Note: `_togglingVisibility` is *also* referenced by the IPC `toggle()` guard
and the window open/close visibility-toggle workaround — leave it in place;
it is orthogonal to peek.

---

## Files modified

| File | Change |
|---|---|
| `hyprsphere.json` | Add `"peek": { "enabled": true }`; remove `"focusOnTab"` |
| `shell.qml` | Add `ScreencopyView` backdrop; add `resolveToplevelByAddress()` + `refreshPeek()`; call `refreshPeek()` in `finishOpenSwitcher`, `_executeSearch`, `cancelSearch`; remove `\`/`|` key branch; clear `captureSource` on close |
| `binds.js` | Call `refreshPeek()` in `advance()` and `drillDown()`; delete `slashPreview()` |
| `README.md` | Remove `focusOnTab` Known-Limitations section + any `slashPreview` references; document `peek` config |

---

## Verification

### Automated checks (grep-based)

```bash
# C1: peek config present, enabled by default
grep -c '"peek"' hyprsphere.json                     # >= 1

# C2: ScreencopyView present, live:false, constraintSize set
grep -c 'ScreencopyView' shell.qml                    # >= 1
grep -c 'live: false' shell.qml                       # >= 1
grep -c 'constraintSize' shell.qml                    # >= 1

# C3: refreshPeek defined and wired into keyboard paths
grep -c 'function refreshPeek' shell.qml              # == 1
grep -c 'window.refreshPeek()' binds.js shell.qml     # >= 4 (advance, drillDown, search, open)

# C4: slashPreview + focusOnTab fully removed
grep -c 'slashPreview' shell.qml binds.js             # 0
grep -c 'focusOnTab' shell.qml binds.js hyprsphere.json # 0

# C5: no refreshPeek in the mouse click handler
grep -A2 'onClicked' shell.qml | grep -c 'refreshPeek'  # 0
```

### Manual tests

| # | Scenario | Expected |
|---|---|---|
| M1 | Open overlay with apps running | Pre-selected node's window snapshot appears behind the sphere |
| M2 | Tab forward through nodes | Snapshot updates on every advance to the new window's content |
| M3 | Shift+Tab backward | Same as M2, reversed |
| M4 | Tab to a **whitelist placeholder** (not running) | No snapshot (transparent backdrop) |
| M5 | `;` drill-down into an app | Snapshot shows the selected window at layer 1 |
| M6 | Type to search (layer 2) | Snapshot updates as results change |
| M7 | Click a node (not double-click) | **No** snapshot change (keyboard-only) |
| M8 | Alt-release commit | Overlay closes; focus lands on the committed window; no stray workspace switch |
| M9 | Escape cancel | Overlay closes; you remain on your original workspace |
| M10 | Peek a window on a **different workspace** | Snapshot shows it **without** switching workspaces |
| M11 | Peek a window on a **different monitor** | Snapshot shows it (monitor-agnostic) |
| M12 | Close the selected window externally while peeking | Backdrop clears (hasContent false / source null on rebuild) |

---

## Edge cases

| Scenario | Behavior |
|---|---|
| Selected node is a whitelist placeholder | `address` empty → `captureSource = null` → transparent |
| "No windows" / "No results" placeholder | Same — no address → transparent |
| Window closes mid-peek | `resolveToplevelByAddress` returns null (or capture fails) → transparent |
| Window on `special:*` workspace | Captured (no workspace filter in the resolver) |
| Window on another workspace/monitor | Captured via `hyprland-toplevel-export-v1` (no switch) |
| Non-16:9 window | `constraintSize` preserves aspect; transparent bars |
| `peek.enabled: false` | `refreshPeek()` nulls the source; overlay behaves exactly as before |

## Known limitations

1. **Hyprland-only** — the capture path depends on `hyprland-toplevel-export-v1`.
2. **Still frame** — content does not update while you hold on a node (by design,
   single-frame mode).
3. **No decorations** — captured frames lack server-side decorations/rounded corners.
4. **Quickshell build requirement** — needs screencopy + toplevel-export support
   (≥ 0.3.1 recommended). Smoke-test `ScreencopyView` before relying on it.
5. **Brief latency** — a captured frame is not instantly available; `hasContent`
   flips when ready, which is already handled (nothing renders until then).
