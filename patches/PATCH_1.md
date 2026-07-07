# PATCH_1 — `mruMethod` config option for window-level Alt+Tab

---

## Overview

Add a `mruMethod` config option to `hyprsphere.json` that controls how the
overlay pre-selects its initial app group and which window receives focus
on commit.

**Values:**
- `"app"` — current behaviour (Alt+Tab cycles between apps by app-level MRU)
- `"window"` — Alt+Tab cycles back to the exact previous window, even if it
  belongs to the same app as the current window

**Default:** `"app"` when absent from config.

---

## Motivation

When you have multiple windows of the same app (e.g. two Ghostty terminals,
five Firefox tabs-as-windows), Alt+Tab with `mruMethod="app"` always jumps
to the previous APP, not the previous WINDOW. Switching between Firefox
window A and Firefox window B via Alt+Tab is impossible — it always takes
you out of Firefox to whatever app was last focused.

`mruMethod="window"` solves this by maintaining a **global window MRU**
that tracks individual window addresses across all apps. The overlay still
shows app groups on the sphere (layer 0), but the pre-selection and commit
target are driven by the most recent window rather than the most recent app.

---

## Data structures

### `globalWindowMru` (array of strings)

A flat array of window addresses ordered by most recent focus:

```
globalWindowMru = [
    "0x...current",    // index 0: currently focused window
    "0x...previous",   // index 1: window focused before that
    "0x...older",      // index 2: window focused before that
    ...
]
```

Only maintained when `mruMethod === "window"`. In all conditions below,
if `mruMethod !== "window"`, behaviour is unchanged from the current
implementation.

### `_preSelectedAppId` (string, internal property)

Set when the overlay opens or rebuilds. It stores the `appId` of whichever
app group owns `globalWindowMru[1]`. The sphere pre-selects this app's
node on open.

Updated dynamically during `scheduleRebuild()` — if a window closes and
`globalWindowMru[1]` shifts to a different app, the pre-selection follows.

---

## Behaviour

### Opening the overlay

1. `finishOpenSwitcher()` builds the sphere from `Hyprland.toplevels`
   (same as today — app groups sorted by `appMru`)
2. If `mruMethod === "window"`:
   - Read `globalWindowMru[1]` (the previous window)
   - Find which app group in `sphereModel` contains that address
   - Set `_preSelectedAppId` to that app's `appId`
   - Set `selectedAppIndex` to that app's index in `sphereModel`
   - If `globalWindowMru` has fewer than 2 entries, use index 0
   - If the owning app isn't found in the sphere (e.g. the window was on a
     special workspace), fall back to sphere index 0
3. If `mruMethod === "app"`:
   - Current behaviour: `selectedAppIndex = (appMru.length >= 2) ? 1 : 0`

### Cycling with Tab/Shift+Tab

Sphere cycling is unchanged — `advance(dir)` moves through sphere nodes
by index. The pre-selection sets the starting position, but the user can
Tab away from it freely.

### Committing at layer 0

`commitSelection()` at layer 0:

```python
if mruMethod == "window" AND node.appId == _preSelectedAppId:
    # User committed the pre-selected app → focus the exact window
    focus globalWindowMru[1] by address
else:
    # User tabbed to a different app → current behaviour
    focus appWindowMru[node.appId][0] (MRU-most window of that app)
```

### Committing at layer 1 (drill-down) or layer 2 (search)

Unchanged — focuses the specific window node the user selected. `mruMethod`
does not affect drill-down or search commit behaviour.

### Window focus tracking

In `onActiveToplevelChanged`, when `mruMethod === "window"`:

```javascript
// Move address to front of global window MRU
var gwFiltered = [];
for (var gi = 0; gi < globalWindowMru.length; gi++) {
    if (globalWindowMru[gi] !== addr) gwFiltered.push(globalWindowMru[gi]);
}
globalWindowMru = [addr].concat(gwFiltered);
```

This runs after the existing `appMru` and `appWindowMru` updates.

### Window close cleanup

In `onRawEvent` closewindow handler, when `mruMethod === "window"`:

Remove the closed address from `globalWindowMru`. If the removed address
was at `globalWindowMru[0]` or `globalWindowMru[1]`, the next window in
the list slides into its place automatically (since it's a flat array
maintained by focus order, not by position index).

### Dynamic pre-selection during rebuilds

`scheduleRebuild()` recalculates `_preSelectedAppId` after every rebuild:

```javascript
if (mruMethod === "window" && globalWindowMru.length >= 2) {
    // Find which app in the rebuilt sphere owns globalWindowMru[1]
    var targetAddr = globalWindowMru[1];
    for each app in sphereModel:
        if app.windows contains targetAddr:
            _preSelectedAppId = app.appId
            break
    // If not found, clear _preSelectedAppId (let sphere fall to index 0)
}
```

This ensures the sphere dynamically follows window opens and closes.

**Important:** The recalculation is **skipped** when `_pendingSpawnAppId` is
set (a Ctrl+Enter spawn is in progress), so the spawn auto-selection takes
priority and doesn't get overwritten.

### Spawn override in `commitSelection()`

When a window was just spawned via Ctrl+Enter, `_pendingSpawnAppId` is set.
The layer-0 commit path checks this BEFORE any `mruMethod` logic:

```javascript
if (window._pendingSpawnAppId === node.appId) {
    // Focus the MRU-most window via appWindowMru (updated immediately
    // by the openwindow handler, unlike node.windows which depends
    // on async toplevel refresh).
    var spawnMru = appWindowMru[node.appId] || [];
    addr = spawnMru.length >= 1 ? spawnMru[0] : "";
}
```

This handles the case where `onActiveToplevelChanged` hasn't fired (because
the overlay has keyboard focus, not the spawned window), so `globalWindowMru`
and `node.windows` in the sphere model are both stale.

### Drill-down pre-selection (layer 1)

When drilling down into the pre-selected app (`app.appId ===
_preSelectedAppId`), `drillDown()` sorts windows by `appWindowMru[appId]`
then sets `selectedAppIndex` to the index of `globalWindowMru[1]` rather
than the default `0`. This ensures the satellite card shows the window
that would be focused on commit (Ghostty-A in the M21 scenario), not the
MRU-most window of that app (Ghostty-B).

### Closed-window commit targeting

When a window is closed via Ctrl+C (or externally) while the overlay is
open, the closewindow handler removes its address from `globalWindowMru`.
If the closed window happened to be at `globalWindowMru[0]` (the most
recently focused window), the remaining array shifts: the SECOND most
recent window becomes the new `globalWindowMru[0]`, and what was the
THIRD most recent becomes `globalWindowMru[1]`.

The normal commit logic uses `globalWindowMru[1]` (the previous window).
But after closing the most recent window, the user expects to go to the
window they were on BEFORE it — which is now at `globalWindowMru[0]`, not
`globalWindowMru[1]`.

**Fix:** A `_windowClosedThisSession` flag is set in two cases when
a window is closed:

1. The closed window was at `globalWindowMru[0]` (the most recently
   focused window) — detected in the `globalWindowMru` cleanup block.
2. The closed window belongs to the pre-selected app (`appId ===
   _preSelectedAppId`) — detected in the `appWindowMru` cleanup block.

The flag is cleared in `openSwitcher()`. In `commitSelection()`, when
this flag is true, the commit uses `globalWindowMru[0]` instead of
`globalWindowMru[1]`:

```javascript
var wmruIdx = window._windowClosedThisSession ? 0 : 1;
addr = window.globalWindowMru.length >= 2
    ? window.globalWindowMru[wmruIdx]
    : (node.windows[0] ? node.windows[0].address : "");
window._windowClosedThisSession = false;
```

This ensures that Ctrl+C followed by Alt release takes you to the window
that was focused before the closed window, not an older one.

### Synchronous MRU update in `commitSelection()`

When the overlay closes (`visible = false`), the QML engine pauses. The
`onActiveToplevelChanged` signal for the newly focused window is queued
and may not fire until the overlay reopens — after `finishOpenSwitcher()`
has already calculated `_preSelectedAppId` from stale `globalWindowMru`
data.

**Fix:** Update `globalWindowMru` synchronously in `commitSelection()`
before `visible = false`, using the `addr` of the committed window:

```javascript
if (cfg.mruMethod === "window" && addr) {
    var commitNorm = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
    var commitFiltered = [];
    for (var ci = 0; ci < globalWindowMru.length; ci++) {
        if (globalWindowMru[ci] !== commitNorm) commitFiltered.push(globalWindowMru[ci]);
    }
    globalWindowMru = [commitNorm].concat(commitFiltered);
}
```

This runs the same logic as `onActiveToplevelChanged` but synchronously,
so the next `finishOpenSwitcher()` always sees the correct MRU order
regardless of signal queuing delays.

### `0x` prefix normalization in `globalWindowMru`

Window addresses from `t.address` in `onActiveToplevelChanged` do NOT
include the `0x` hex prefix, but addresses from `buildLayer0()`
(`Hyprland.toplevels`) also omit it. Comparisons against `sphereModel`
normalize both sides to include `0x`. To avoid mismatches, all addresses
are normalized to include `0x` when they enter `globalWindowMru`:

```javascript
var gwAddr = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
```

### State cleanup in `openSwitcher()`

`_pendingSpawnAppId` is cleared at the start of each overlay session to
prevent stale spawn state from a previous session affecting commit logic:

```javascript
window._pendingSpawnAppId = "";
window._preSelectedAppId = "";
```

### Whitelisted apps

Whitelisted apps (placeholders without windows) always appear after all
running apps in the sphere, regardless of `mruMethod`. If there are no
running windows, the sphere shows whitelisted placeholders and the
pre-selection falls to index 0.

---

## Config

### New fields in `hyprsphere.json`

```json
{
  "mruMethod": "app",
  ...existing config...
}
```

| Field | Type | Default | Values | Description |
|---|---|---|---|---|
| `mruMethod` | string | `"app"` | `"app"` \| `"window"` | Controls Alt+Tab pre-selection and commit targeting |

---

## Edge cases

| Scenario | Behaviour |
|---|---|
| `globalWindowMru` length 0 (no windows) | Pre-select sphere index 0 (whitelist or placeholder) |
| `globalWindowMru` length 1 (one window) | Pre-select the app of that window; commit is a no-op (stays focus) |
| `globalWindowMru[1]` closed while overlay open | `closewindow` cleanup shifts the array; next rebuild picks up the new index-1 |
| `globalWindowMru[1]` belongs to a special-workspace window | `buildLayer0()` skips special workspaces, so the app isn't in `sphereModel`; fall back to index 0 |
| User Tabs away from pre-selected app | Commit uses `appWindowMru[appId][0]` — current behaviour for non-pre-selected apps |
| Ctrl+Enter spawns a window of the pre-selected app | `_pendingSpawnAppId` diverts commit to `appWindowMru[appId][0]` (the spawned window) instead of `globalWindowMru[1]` |
| Ctrl+Enter spawn + rebuild | MRU recalculation is skipped when `_pendingSpawnAppId` is set, so the spawn auto-selection is not overwritten |
| Drill-down from pre-selected app | Pre-selects the window at `globalWindowMru[1]` (not MRU-most index 0) so the satellite card matches what commit would focus |
| `mruMethod` not in config | Defaults to `"app"` — zero behavioural change |
| Next Alt+Tab after committing via `mruMethod="window"` | The committed window is now at `globalWindowMru[0]` (current), and the window that was current before it is now at `globalWindowMru[1]` (previous) |

---

## Implementation plan

### Files to change

| File | Changes |
|---|---|
| `hyprsphere.json` | Add `"mruMethod": "app"` |
| `shell.qml` | Add `globalWindowMru` property; add `_preSelectedAppId` property; update `onActiveToplevelChanged`; update `onRawEvent` closewindow; update `openSwitcher`/`finishOpenSwitcher`; update `commitSelection` layer 0; update `scheduleRebuild` recalc |
| `PHASE_10.md` | Add `mruMethod` to config table |
| `PHASE_10_TESTS.md` | Add automated and manual tests for both methods |
| `README.md` | Document `mruMethod` in config section |
