# PATCH_3 — Simplify drill-down pre-selection

## Overview

Remove the pre-selected-app special case in `drillDown()` and change the
default drill-down selection from MRU-most (index 0) to second MRU-most
(index 1). When you drill into an app's windows, you want to see the
window you'd switch **to**, not the window you're already on.

---

## Motivation

### Current behavior

When drilling into an app at layer 0:

1. Windows are sorted by `appWindowMru[appId]` (MRU order)
2. `selectedAppIndex = 0` → selects the **MRU-most window**
3. **Special case:** If the drilled app is the pre-selected app
   (`app.appId === _preSelectedAppId`), overrides to select the window
   at `globalWindowMru[1]` instead

### The problem

**Scenario:**
- Ghostty-A, Ghostty-B (same app), Firefox (different app)
- Focus Ghostty-A → Focus Firefox → Focus Ghostty-A
- Alt+Tab → Firefox pre-selected (`globalWindowMru[1]`)
- Shift+Tab back to Ghostty (not pre-selected)
- `;` drill-down → sees **Ghostty-A** (MRU-most, index 0)

The user expects to see **Ghostty-B** — the other Ghostty window they
might want to switch to. Ghostty-A is the window they're already on;
showing it as the drill-down target is redundant.

### The special case is also wrong

The `globalWindowMru[1]` override only fires when the drilled app happens
to be the pre-selected app (`_preSelectedAppId`). In the scenario above,
the user tabbed *away* from Firefox back to Ghostty, so Ghostty is NOT the
pre-selected app — the special case doesn't fire, and the user gets
Ghostty-A instead of Ghostty-B.

Removing the special case and always selecting index 1 (second MRU-most)
gives consistent, predictable behaviour regardless of whether the app is
pre-selected or tabbed-to.

---

## Changes

### File: `shell.qml` — `drillDown()` function (layer 0 path, around line 695)

**Before:**
```javascript
            selectedAppIndex = 0;
            // Drill-down from pre-selected app pre-selects the window at
            // globalWindowMru[1] (the window that would be focused on commit).
            if (app.appId === window._preSelectedAppId && window.globalWindowMru.length >= 2) {
                var drillTarget = window.globalWindowMru[1];
                for (var di = 0; di < sphereModel.length; di++) {
                    var dAddr = sphereModel[di].address || "";
                    if (dAddr.indexOf("0x") !== 0) dAddr = "0x" + dAddr;
                    if (dAddr === drillTarget) {
                        selectedAppIndex = di;
                        break;
                    }
                }
            }
```

**After:**
```javascript
            selectedAppIndex = 0;
            // Pre-select the second MRU-most window (index 1) so the drill-down
            // shows the window the user is likely to switch to, not the one
            // they're already on (which is what they'd get by committing at layer 0).
            if (winMru.length >= 2) {
                var secondTarget = winMru[1];
                for (var di = 0; di < sphereModel.length; di++) {
                    var dAddr = sphereModel[di].address || "";
                    if (dAddr.indexOf("0x") !== 0) dAddr = "0x" + dAddr;
                    if (dAddr === secondTarget) {
                        selectedAppIndex = di;
                        break;
                    }
                }
            }
```

### File: `shell.qml` — `drillDown()` function (layer 2 path, around line 745)

**Before:**
```javascript
            selectedAppIndex = 0;
```

**After:**
```javascript
            selectedAppIndex = 0;
            // Same second-MRU rule for layer-2 drill-down
            if (winMru.length >= 2) {
                var secondTarget = winMru[1];
                for (var di = 0; di < sphereModel.length; di++) {
                    var dAddr = sphereModel[di].address || "";
                    if (dAddr.indexOf("0x") !== 0) dAddr = "0x" + dAddr;
                    if (dAddr === secondTarget) {
                        selectedAppIndex = di;
                        break;
                    }
                }
            }
```

---

## Behaviour matrix

| Scenario | Before (index 0) | After (index 1 fallback) |
|---|---|---|
| 2+ windows, drilled app is pre-selected | `globalWindowMru[1]` (inconsistent) | `appWindowMru[1]` (second MRU-most) |
| 2+ windows, drilled app is NOT pre-selected | `appWindowMru[0]` (MRU-most) | `appWindowMru[1]` (second MRU-most) |
| 1 window | `appWindowMru[0]` (only choice) | `appWindowMru[0]` (fallback, unchanged) |

All paths now behave consistently: **always select second MRU-most when available, else first.**

---

## Edge cases

| Scenario | Expected behaviour |
|---|---|
| App has 2 windows, MRU = [A, B] | Drill-down selects B (index 1) |
| App has 1 window | Drill-down selects index 0 (single choice, no other option) |
| App has 3 windows, MRU = [A, B, C] | Drill-down selects B (index 1, second MRU-most) |
| App windows in `appWindowMru` but not in sphere (e.g. special workspace) | `winMru.indexOf(address)` returns -1 → sorted to end, defaults to index 0 |
| Layer 2 → drill-down | Same as layer 0: second MRU-most |
| Layer 1 → back to layer 0/2 | Unchanged (restores previous selection) |
