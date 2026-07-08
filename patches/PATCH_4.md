# PATCH_4 — `focusOnTab` live window preview on tab

> **This is a major feature.** When `focusOnTab: true`, every tab/click in the
> overlay immediately focuses the target window behind the overlay, showing you
> exactly which window you'll land on before you release Alt. The overlay
> freezes its MRU snapshot at open time to prevent feedback loops.

---

## Overview

Add a `focusOnTab` config option (default `true`) that controls whether the
overlay dispatches live focus to the target window on every selection change.
When `false`, behaviour is unchanged — the window is only focused on Alt
release (commit). When `true` (default), the target window appears behind the overlay
immediately, and the overlay uses a visibility toggle to preserve keyboard
focus.

**Key design decisions:**

1. **MRU freeze** — Once the overlay opens, MRU tracking is frozen
   (`_mruFrozen = true`). This prevents the `onActiveToplevelChanged` focus
   dispatches from creating a feedback loop where each focus changes MRU,
   which changes the pre-selection, which re-dispatches focus. MRU is
   unfrozen in `commitSelection()` and `cancelSwitch()`.

2. **Shared target resolution** — The address-resolution logic from
   `commitSelection()` is extracted into a shared `_targetAddrForNode(node)`
   function so the preview focus uses the exact same targeting rules.

3. **Visibility toggle** — Uses the same `visible=false → callLater →
   visible=true` pattern as the existing spawn/openwindow handler to prevent
   the overlay from losing keyboard focus to the previewed window.

4. **Initial focus before overlay appears** — The pre-selected window is
   focused BEFORE the overlay becomes visible, so the user sees the target
   window immediately with no flash.

---

## Config

### New field: `focusOnTab`

| Field | Type | Default | Description |
|---|---|---|---|
| `focusOnTab` | boolean | `true` | When `true` (default), the overlay focuses the target window behind the sphere on every selection change (tab, click, drill-down). The overlay uses a visibility toggle to preserve keyboard focus. When `false`, existing behaviour (focus only on commit). |

Placed at the top level of `hyprsphere.json`:
```json
{
  "focusOnTab": true,
  ...existing config...
}
```

---

## Data structures

### `_mruFrozen` (boolean, internal property)

Set to `true` in `openSwitcher()`. When `true`, `onActiveToplevelChanged`
skips all MRU updates (both `appMru`/`appWindowMru` and `globalWindowMru`).
Set to `false` in `commitSelection()` and `cancelSwitch()`.

### `_targetAddrForNode(node)` (function, internal)

Extracted from `commitSelection()`. Returns the address that would be
focused if the given node were committed. Used by both the preview focus
logic and `commitSelection()`.

```javascript
function _targetAddrForNode(node) {
    if (!node || node.isPlaceholder) return "";
    if (node.isWhitelistPlaceholder) return "";

    if (window.layer === 0 || (window.layer === 2 && !node.isWindowNode)) {
        // Spawn override
        if (window._pendingSpawnAppId === node.appId) {
            var spawnMru = appWindowMru[node.appId] || [];
            return spawnMru.length >= 1 ? spawnMru[0] : "";
        }
        // Pre-selected app
        if (node.appId === window._preSelectedAppId) {
            return window.globalWindowMru.length >= 2
                ? window.globalWindowMru[1]
                : (node.windows[0] ? node.windows[0].address : "");
        }
        // Other app: MRU-most window
        var winMru = appWindowMru[node.appId] || [];
        for (var m = 0; m < winMru.length; m++) {
            for (var w = 0; w < node.windows.length; w++) {
                if (node.windows[w].address === winMru[m]) return winMru[m];
            }
        }
        return node.windows[0] ? node.windows[0].address : "";
    } else {
        // Layer 1 or layer 2 window node
        return node.address || "";
    }
}
```

---

## Changes

### File: `hyprsphere.json`

Add `"focusOnTab": true` at the top level.

### File: `shell.qml`

#### Change 1 — Add `_mruFrozen` property and `_targetAddrForNode()` helper

Near the other MRU tracking properties (around line 200):
```javascript
// ── TrackWindow: live window preview ──
property bool _mruFrozen: false
```

After the existing helpers, add `_targetAddrForNode(node)` as a new function.

#### Change 2 — Freeze MRU in `openSwitcher()`

```javascript
window._mruFrozen = true;
```

Add alongside the other state resets in `openSwitcher()`.

#### Change 3 — Block MRU updates when frozen

In `onActiveToplevelChanged()`, add an early return after the `addr`
normalisation:

```javascript
if (window._mruFrozen) return;
```

This prevents the focus dispatches from creating feedback loops.

#### Change 4 — Initial pre-selection focus in `finishOpenSwitcher()`

After the sphere is built and pre-selection is calculated, but **before**
`window.visible = true`, dispatch focus to the pre-selected window:

```javascript
// If focusOnTab is enabled, focus the pre-selected window
// behind the overlay before it becomes visible.
if (cfg.focusOnTab && sphereModel.length > 0 && selectedAppIndex >= 0) {
    var targetNode = sphereModel[selectedAppIndex];
    var targetAddr = window._targetAddrForNode(targetNode);
    if (targetAddr) {
        var prefix = targetAddr.indexOf("0x") === 0 ? "" : "0x";
        Quickshell.execDetached(["hyprctl", "dispatch",
            'hl.dsp.focus({window="address:' + prefix + targetAddr + '"})']);
    }
}
```

This runs before `window.visible = true`, so the overlay isn't visible to
steal focus — the `onVisibleChanged` → `forceActiveFocus()` handles focus
reclamation when the overlay appears.

#### Change 5 — Preview focus in `advance()`

After the selection changes, dispatch focus to the new target:

```javascript
function advance(dir) {
    // ... existing sphereModel guard and index update ...

    // TrackWindow: focus the new target immediately
    if (cfg.focusOnTab && sphereModel.length > 0 && selectedAppIndex >= 0) {
        var targetNode = sphereModel[selectedAppIndex];
        var targetAddr = window._targetAddrForNode(targetNode);
        if (targetAddr) {
            var prefix = targetAddr.indexOf("0x") === 0 ? "" : "0x";
            Quickshell.execDetached(["hyprctl", "dispatch",
                'hl.dsp.focus({window="address:' + prefix + targetAddr + '"})']);
            // Toggle visibility to preserve overlay keyboard focus
            if (window.visible) {
                window.visible = false;
                Qt.callLater(function() {
                    window.visible = true;
                });
            }
        }
    }
}
```

#### Change 6 — Preview focus on node click

In the `onClicked` handler of the `nodeMa` MouseArea (around line 1859):

```javascript
onClicked: {
    window.selectedAppIndex = index;
    window.centerOnApp(index);
    // TrackWindow: focus the clicked node
    if (cfg.focusOnTab) {
        var targetAddr = window._targetAddrForNode(window.sphereModel[index]);
        if (targetAddr) {
            var prefix = targetAddr.indexOf("0x") === 0 ? "" : "0x";
            Quickshell.execDetached(["hyprctl", "dispatch",
                'hl.dsp.focus({window="address:' + prefix + targetAddr + '"})']);
            if (window.visible) {
                window.visible = false;
                Qt.callLater(function() {
                    window.visible = true;
                });
            }
        }
    }
}
```

#### Change 7 — Preview focus in `drillDown()`

After the layer transition and selection is set, dispatch focus to the
selected window:

```javascript
// TrackWindow: focus the drilled-down window
if (cfg.focusOnTab) {
    var targetNode = sphereModel[selectedAppIndex];
    var targetAddr = window._targetAddrForNode(targetNode);
    if (targetAddr) {
        var prefix = targetAddr.indexOf("0x") === 0 ? "" : "0x";
        Quickshell.execDetached(["hyprctl", "dispatch",
            'hl.dsp.focus({window="address:' + prefix + targetAddr + '"})']);
        if (window.visible) {
            window.visible = false;
            Qt.callLater(function() {
                window.visible = true;
            });
        }
    }
}
```

This applies to all three drill-down paths (layer 0→1, layer 2→1,
and 1→back). Add at the end of each path's selection logic.

#### Change 8 — Unfreeze MRU in `commitSelection()`

Before the overlay closes:
```javascript
window._mruFrozen = false;
```

Add near the top of `commitSelection()`, before the close sequence.

#### Change 9 — Unfreeze MRU in `cancelSwitch()`

```javascript
window._mruFrozen = false;
```

Add alongside the other state resets in `cancelSwitch()`.

#### Change 10 — Simplify `commitSelection()` to use `_targetAddrForNode()`

The address-resolution block in `commitSelection()` (currently ~25 lines)
becomes:

```javascript
var addr = window._targetAddrForNode(node);
if (!addr) { /* handle whitelist or placeholder */ return; }
```

This eliminates the duplicated targeting logic.

---

## Behaviour matrix

| Scenario | focusOnTab: false | focusOnTab: true |
|---|---|---|
| Overlay opens | Sphere appears, pre-selected app highlighted | Sphere appears + target window focused behind it |
| Tab/Shift+Tab | Selection advances on sphere | Selection advances + target window focused + visibility toggle |
| Click node | Sphere centers on clicked node | Sphere centers + target window focused + visibility toggle |
| Drill-down (`;`) | Layer transitions, window list shown | Layer transitions + first window focused + visibility toggle |
| `;` back | Returns to previous layer | Returns + pre-selected app's target focused + visibility toggle |
| Commit (Alt release) | Focus dispatched, overlay closes | Focus dispatched (harmless no-op), overlay closes |
| Escape | Overlay closes, MRU unfrozen | Overlay closes, MRU unfrozen, tracking stops |
| Rapid cycling (hold Tab) | Spins through sphere nodes | Each advance dispatches focus (mark for testing) |

---

## What stays unchanged

| Feature | Reason |
|---|---|
| `globalWindowMru`, `appWindowMru`, `appMru` | Still tracked, just frozen during overlay |
| `_preSelectedAppId` | Still calculated at open time, frozen |
| `_pendingSpawnAppId` / `_pendingSpawnAddr` | Still used for spawn auto-selection |
| `fullscreenOnActivate` | Unrelated to focusOnTab |
| Drill-down sort order | Still `appWindowMru`-based |
| Commit targeting | Same logic, just extracted into `_targetAddrForNode()` |
| Existing visibility toggle (closewindow) | Still works independently |

---

## Files to change

| File | Changes |
|---|---|
| `hyprsphere.json` | Add `"focusOnTab": true` |
| `shell.qml` | Add `_mruFrozen` property, `_targetAddrForNode()` function, freeze/unfreeze logic, preview focus in `advance()`, `drillDown()`, `onClicked`, `finishOpenSwitcher()`, simplify `commitSelection()` |
| `README.md` | Add `focusOnTab` to config table |
| `patches/PATCH_4.md` | This document |

---

## Verification (automated grep checks)

```bash
# C1: _mruFrozen property exists
grep -c '_mruFrozen' shell.qml
# Expected: at least 2 (property + usage)

# C2: _targetAddrForNode function exists
grep -c '_targetAddrForNode' shell.qml
# Expected: at least 2 (definition + usage)

# C3: focusOnTab config reference exists
grep -c 'focusOnTab' shell.qml
# Expected: at least 2

# C4: focusOnTab in hyprsphere.json
grep -c 'focusOnTab' hyprsphere.json
# Expected: 1

# C5: Visibility toggle pattern in advance/drillDown
grep -c "visible = false" shell.qml
# Expected: at least the original count + new occurrences

# C6: commitSelection targeting simplified (no inline address logic)
grep -c '_targetAddrForNode' shell.qml
# Expected: at least 3 (definition + commitSelection + advance/drillDown)
```

---

## PATCH_4_TESTS.md — Manual tests

### T1. Basic focusOnTab — initial pre-selection focus
**Setup:** Two apps running (e.g. Ghostty + Firefox). `focusOnTab: true`.

1. Focus Ghostty, then switch to Firefox
2. Press **Alt+Tab**
3. **Verify:** Ghostty appears focused behind the overlay (it was the
   previous window, globalWindowMru[1])
4. Release **Alt**
5. **Verify:** Ghostty stays focused (commit is no-op if it's the same
   window already focused)

### T2. Tab cycling — each tab focuses the target
**Setup:** Ghostty-A, Ghostty-B, Firefox. `focusOnTab: true`.

1. Focus Ghostty-B, then switch to Ghostty-A
2. Press **Alt+Tab** — Ghostty-B should be pre-selected and focused
3. Press **Tab** — Firefox should become focused behind the overlay
4. Press **Tab** — Ghostty-A should become focused
5. Release **Alt** — Ghostty-A stays focused (it was already focused)

### T3. Multi-window app — pre-selected app window focus
**Setup:** Ghostty-A, Ghostty-B (same app), Firefox. `focusOnTab: true`.

1. Focus Ghostty-A, then Firefox, then Ghostty-B
2. Press **Alt+Tab** — Firefox pre-selected (globalWindowMru[1]), Firefox focused
3. Tab to Ghostty — Ghostty-A focused (appWindowMru["ghostty"][0], MRU-most)
4. Release **Alt** — Ghostty-A stays focused

### T4. Drill-down — first window focused
**Setup:** Ghostty with 2+ windows. `focusOnTab: true`.

1. Press **Alt+Tab**, tab to Ghostty
2. Press **;** — layer 1 shows windows, first window (second MRU-most)
   is focused behind the overlay
3. Tab to a different window — that window becomes focused
4. Press **;** again — returns to layer 0, pre-selected app's target focused
5. Release **Alt** — commit targets the last previewed window

### T5. Click to select and focus
**Setup:** Multiple apps. `focusOnTab: true`.

1. Press **Alt+Tab**
2. **Click** a different node on the sphere
3. **Verify:** That node's target window becomes focused behind the overlay

### T6. MRU freeze — no feedback loops
**Setup:** Ghostty-A, Ghostty-B, Firefox. `focusOnTab: true`.

1. Focus Ghostty-A, press **Alt+Tab** — Firefox pre-selected and focused
2. Tab to Ghostty — Ghostty-A focused
3. Press **Tab** rapidly — each advance focuses a different window
4. **Verify:** The sphere selection doesn't jump around — it follows your
   tab advances linearly without feedback from the focus dispatches

### T7. Rapid cycling — stability test
**Setup:** 5+ windows across multiple apps. `focusOnTab: true`.

1. Press **Alt+Tab**
2. **Hold Tab** to cycle rapidly through all nodes
3. **Verify:** No stutter, no freeze, no crash
4. **Verify:** Each window appears briefly behind the overlay
5. Let go of Tab, release **Alt**
6. **Verify:** The correct window is committed (the one last shown)

### T8. Search (layer 2) — preview focus on results
**Setup:** Multiple apps. `focusOnTab: true`.

1. Press **Alt+Tab**, type letters to enter search
2. Tab through search results — each result's window is focused
3. Release **Alt** — correct window committed

### T9. commitSelection no-op when already focused
**Setup:** `focusOnTab: true`.

1. Open overlay, tab to an app — it becomes focused behind overlay
2. Release **Alt**
3. **Verify:** The overlay closes cleanly, no double-dispatch issues,
   window stays focused

### T10. focusOnTab: false — existing behaviour preserved
**Setup:** `focusOnTab: false`.

1. Open overlay, tab through nodes
2. **Verify:** No window focus changes behind the overlay
3. Release **Alt** — focus dispatched only on commit (existing behaviour)

---

## Edge cases

| Scenario | Expected behaviour |
|---|---|
| Whitelisted placeholder selected | No focus dispatch (no window to focus) |
| `_pendingSpawnAppId` set during preview | Spawn override takes priority in `_targetAddrForNode` |
| Single window app, pre-selected | Focus that window (no-op commit) |
| `globalWindowMru` length < 2 | Fallback to `node.windows[0]` |
| Drill-down into single-window app | Focus the only window |
| Search results include whitelisted placeholders | Skip focus for placeholders |
| Rapid Alt+Tab during data gathering | MRU freeze isn't set until `finishOpenSwitcher`, so early toggles work normally |
| Escape during data gathering | `cancelSwitch()` unfreezes MRU (guard at top of `finishOpenSwitcher` aborts) |
