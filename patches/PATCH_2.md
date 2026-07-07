# PATCH_2 — Remove `mruMethod` config, always use window-level MRU

> **This is a significant refactor.** PATCH_1 introduced `mruMethod` as a
> config toggle so that window-level MRU could be tested alongside the
> legacy app-level MRU without disrupting existing behaviour. Now that
> window-level MRU has been validated, this patch removes the toggle
> scaffolding entirely. The code always behaves as `mruMethod="window"`.
>
> PATCH_1 remains untouched as a historical record of the toggle's
> implementation. PATCH_2 supersedes it.

---

## Overview

Remove the `mruMethod` config option entirely. The code always behaves as
`mruMethod="window"`. This eliminates all 8 `if (cfg.mruMethod === "window")`
guard conditions and the associated `else` branches throughout `shell.qml`.

The sphere still sorts by app-level MRU (`appMru`) for visual grouping, but
pre-selection and commit targeting are always driven by `globalWindowMru`.

**Code compaction:** The duplicated sphere-scanning loop (searching for
which app owns `globalWindowMru[1]`) is extracted into a shared helper
function `_findAppForAddress(addr)`, reducing code duplication across
`finishOpenSwitcher()`, `scheduleRebuild()`, and `drillDown()`.

---

## Why this refactor

The current codebase supports two Alt+Tab modes via `mruMethod` config:
`"app"` (legacy) and `"window"` (PATCH 1). This duality introduces
branching everywhere: `finishOpenSwitcher`, `commitSelection`,
`drillDown`, `scheduleRebuild`, `onActiveToplevelChanged`,
`onRawEvent`, and more. Each branch doubles the mental model and
creates subtle edge cases where the two modes interact.

Window-level MRU (`"window"` mode) is strictly superior for multi-window
multitasking — it's the desired final state. The toggle scaffolding from
PATCH 1 is now removed.

---

## Files to change

| File | Nature of changes |
|---|---|
| `shell.qml` | Remove 8 `if (cfg.mruMethod === ...)` guards, 1 outer `if/else`, 4 comment blocks; add `_findAppForAddress()` helper; compact duplicated loops |
| `hyprsphere.json` | Remove `"mruMethod": "window"` key |
| `PHASE_10_TESTS.md` | Remove M18–M25 (`mruMethod`-specific tests); rewrite relevant core scenarios as permanent regression tests |
| `UNTESTED.md` | Remove M25 entry (legacy `"app"` mode, now irrelevant) |

**Not touched:** `PATCH_1.md` (preserved as historical record),
`README.md` (no `mruMethod` reference), `PHASE_10.md` (no `mruMethod` reference).

---

## Detailed changes

### Change 1 — `shell.qml`: Add `_findAppForAddress()` helper property

Add a new function property near the other PATCH 1 properties (around
line 199):

```javascript
function _findAppForAddress(addr) {
    if (!addr) return "";
    var normAddr = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
    for (var i = 0; i < (window.sphereModel || []).length; i++) {
        var app = window.sphereModel[i];
        if (app.isPlaceholder || app.isWhitelistPlaceholder) continue;
        for (var j = 0; j < (app.windows || []).length; j++) {
            var wAddr = app.windows[j].address || "";
            if (wAddr.indexOf("0x") !== 0) wAddr = "0x" + wAddr;
            if (wAddr === normAddr) return app.appId;
        }
    }
    return "";
}
```

This centralises the address-normalisation + sphere-search pattern that
was duplicated across `finishOpenSwitcher()` and `scheduleRebuild()`.

### Change 2 — `shell.qml`: Rewrite comment block (line 199)

```
// ── PATCH 1: mruMethod — window-level MRU tracking ──
```
→
```
// ── Global window-level MRU tracking ──
```

### Change 3 — `shell.qml`: `finishOpenSwitcher()` pre-selection (line 287)

Remove the `if (cfg.mruMethod === "window") { ... } else { ... }` wrapper.
The window-mode block becomes unconditional, using the new helper:

```javascript
// Before (lines ~287-313):
if (cfg.mruMethod === "window") {
    window._preSelectedAppId = "";
    if (window.globalWindowMru.length >= 2) {
        var wTargetAddr = window.globalWindowMru[1];
        for (var wsi = 0; wsi < sphereModel.length; wsi++) {
            var wApp = sphereModel[wsi];
            if (wApp.isPlaceholder || wApp.isWhitelistPlaceholder) continue;
            for (var wwi = 0; wwi < (wApp.windows || []).length; wwi++) {
                var wWa = wApp.windows[wwi].address || "";
                if (wWa.indexOf("0x") !== 0) wWa = "0x" + wWa;
                if (wWa === wTargetAddr) {
                    window._preSelectedAppId = wApp.appId;
                    break;
                }
            }
            if (window._preSelectedAppId) break;
        }
    }
    if (window._preSelectedAppId) {
        for (var wsi = 0; wsi < sphereModel.length; wsi++) {
            if (sphereModel[wsi].appId === window._preSelectedAppId) {
                selectedAppIndex = wsi;
                break;
            }
        }
    } else {
        selectedAppIndex = 0;
    }
} else {
    selectedAppIndex = (appMru.length >= 2) ? 1 : 0;
}

// After:
window._preSelectedAppId = "";
if (window.globalWindowMru.length >= 2) {
    window._preSelectedAppId = window._findAppForAddress(window.globalWindowMru[1]);
}
if (window._preSelectedAppId) {
    for (var wsi = 0; wsi < sphereModel.length; wsi++) {
        if (sphereModel[wsi].appId === window._preSelectedAppId) {
            selectedAppIndex = wsi;
            break;
        }
    }
} else {
    selectedAppIndex = 0;
}
```

### Change 4 — `shell.qml`: `scheduleRebuild()` MRU recalculation (line 659-699)

Before:
```javascript
// PATCH 1: mruMethod="window" — recalculate pre-selection
            // dynamically so the sphere follows window opens/closes.
            // Don't override the spawn auto-selection though.
            if (cfg.mruMethod === "window" && window.visible && !window._pendingSpawnAppId) {
                window._preSelectedAppId = "";
                if (window.globalWindowMru.length >= 2) {
                    var rsTargetAddr = window.globalWindowMru[1];
                    for (var rsi = 0; rsi < (window.sphereModel || []).length; rsi++) {
                        var rsApp = window.sphereModel[rsi];
                        if (rsApp.isPlaceholder || rsApp.isWhitelistPlaceholder) continue;
                        for (var rwi = 0; rwi < (rsApp.windows || []).length; rwi++) {
                            var rAddr = rsApp.windows[rwi].address || "";
                            if (rAddr.indexOf("0x") !== 0) rAddr = "0x" + rAddr;
                            if (rAddr === rsTargetAddr) {
                                window._preSelectedAppId = rsApp.appId;
                                break;
                            }
                        }
                        if (window._preSelectedAppId) break;
                    }
                }
                // If the current selection is no longer valid...
                var curApp = window.sphereModel && window.sphereModel.length > window.selectedAppIndex
                    ? window.sphereModel[window.selectedAppIndex] : null;
                if (window._preSelectedAppId && (!curApp || curApp.appId !== window._preSelectedAppId)) {
                    for (var rsi = 0; rsi < (window.sphereModel || []).length; rsi++) {
                        if (window.sphereModel[rsi].appId === window._preSelectedAppId) {
                            window.selectedAppIndex = rsi;
                            window.centerOnApp(rsi);
                            break;
                        }
                    }
                }
            }
```

After:
```javascript
            // Recalculate pre-selection so the sphere follows window opens/closes.
            // Don't override the spawn auto-selection though.
            if (window.visible && !window._pendingSpawnAppId) {
                window._preSelectedAppId = "";
                if (window.globalWindowMru.length >= 2) {
                    window._preSelectedAppId = window._findAppForAddress(window.globalWindowMru[1]);
                }
                // If the current selection is no longer valid...
                var curApp = window.sphereModel && window.sphereModel.length > window.selectedAppIndex
                    ? window.sphereModel[window.selectedAppIndex] : null;
                if (window._preSelectedAppId && (!curApp || curApp.appId !== window._preSelectedAppId)) {
                    for (var rsi = 0; rsi < (window.sphereModel || []).length; rsi++) {
                        if (window.sphereModel[rsi].appId === window._preSelectedAppId) {
                            window.selectedAppIndex = rsi;
                            window.centerOnApp(rsi);
                            break;
                        }
                    }
                }
            }
```

### Change 5 — `shell.qml`: `drillDown()` pre-selection (line 726-740)

```javascript
// Before:
            // PATCH 1: mruMethod="window" — drill-down from pre-selected app
            // should pre-select the window at globalWindowMru[1] (the window
            // that would be focused on commit), not the MRU-most window.
            if (cfg.mruMethod === "window" && app.appId === window._preSelectedAppId && window.globalWindowMru.length >= 2) {
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

// After:
            // Drill-down from the pre-selected app pre-selects the window at
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

### Change 6 — `shell.qml`: `commitSelection()` layer 0 targeting (line 870)

```javascript
// Before:
} else if (cfg.mruMethod === "window" && node.appId === window._preSelectedAppId) {
    // ... window-mode targeting ...
} else {
    // Layer 0 or layer 2 app node: focus MRU-most window
    var winMru = appWindowMru[node.appId] || [];
    // ...
}

// After:
if (node.appId === window._preSelectedAppId) {
    // Pre-selected app: focus the exact window at globalWindowMru[1]
    var wmruIdx = window._windowClosedThisSession ? 0 : 1;
    addr = window.globalWindowMru.length >= 2
        ? window.globalWindowMru[wmruIdx]
        : (node.windows[0] ? node.windows[0].address : "");
    window._windowClosedThisSession = false;
} else {
    // User tabbed to a different app: focus its MRU-most window
    var winMru = appWindowMru[node.appId] || [];
    var best = null;
    for (var m = 0; m < winMru.length; m++) {
        for (var w = 0; w < node.windows.length; w++) {
            if (node.windows[w].address === winMru[m]) {
                best = winMru[m];
                break;
            }
        }
        if (best) break;
    }
    addr = best || node.windows[0].address;
}
```

Note: the `else if` becomes a plain `if` (no `else if` parent needed — the
spawn-override `if` above it already covers `_pendingSpawnAppId === node.appId`).

### Change 7 — `shell.qml`: `commitSelection()` synchronous MRU update (line 901)

```javascript
// Before:
if (cfg.mruMethod === "window" && addr) {
    // ... synchronous globalWindowMru update ...
}

// After:
if (addr) {
    var commitNorm = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
    var commitFiltered = [];
    for (var ci = 0; ci < globalWindowMru.length; ci++) {
        if (globalWindowMru[ci] !== commitNorm) commitFiltered.push(globalWindowMru[ci]);
    }
    globalWindowMru = [commitNorm].concat(commitFiltered);
}
```

### Change 8 — `shell.qml`: `onActiveToplevelChanged()` (line 1039-1045)

```javascript
// Before:
            // PATCH 1: mruMethod="window" — maintain global window MRU
            if (cfg.mruMethod === "window" && addr) {
                var gwAddr = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
                var gwFiltered = [];
                for (var gi = 0; gi < globalWindowMru.length; gi++) {
                    if (globalWindowMru[gi] !== gwAddr) gwFiltered.push(globalWindowMru[gi]);
                }
                globalWindowMru = [gwAddr].concat(gwFiltered);
            }

// After:
            // Maintain global window MRU on every focus change
            if (addr) {
                var gwAddr = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
                var gwFiltered = [];
                for (var gi = 0; gi < globalWindowMru.length; gi++) {
                    if (globalWindowMru[gi] !== gwAddr) gwFiltered.push(globalWindowMru[gi]);
                }
                globalWindowMru = [gwAddr].concat(gwFiltered);
            }
```

### Change 9 — `shell.qml`: `onRawEvent` closewindow `_windowClosedThisSession` guard (line 1144)

```javascript
// Before:
                    if (cfg.mruMethod === "window" && appId === window._preSelectedAppId) {
                        window._windowClosedThisSession = true;
                    }

// After:
                    if (appId === window._preSelectedAppId) {
                        window._windowClosedThisSession = true;
                    }
```

### Change 10 — `shell.qml`: `onRawEvent` closewindow `globalWindowMru` cleanup (line 1165-1178)

```javascript
// Before:
            // PATCH 1: mruMethod="window" — clean closed address from global MRU
            if (cfg.mruMethod === "window") {
                var gwNorm = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
                var gwNew = [];
                for (var gi = 0; gi < globalWindowMru.length; gi++) {
                    if (globalWindowMru[gi] !== gwNorm) gwNew.push(globalWindowMru[gi]);
                }
                // If the closed window was at index 0, the remaining index 0
                // now holds the window the user was on before it — commit
                // should target that window, not the older one at index 1.
                if (globalWindowMru.length >= 1 && globalWindowMru[0] === gwNorm) {
                    window._windowClosedThisSession = true;
                }
                globalWindowMru = gwNew;
            }

// After:
            // Remove closed address from global window MRU
            var gwNorm = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
            var gwNew = [];
            for (var gi = 0; gi < globalWindowMru.length; gi++) {
                if (globalWindowMru[gi] !== gwNorm) gwNew.push(globalWindowMru[gi]);
            }
            // If the closed window was at index 0, the remaining index 0
            // now holds the window the user was on before it — commit
            // should target that window, not the older one at index 1.
            if (globalWindowMru.length >= 1 && globalWindowMru[0] === gwNorm) {
                window._windowClosedThisSession = true;
            }
            globalWindowMru = gwNew;
```

### Change 11 — `hyprsphere.json`: Remove `mruMethod` key

Remove the line:
```json
  "mruMethod": "window",
```

### Change 12 — `PHASE_10_TESTS.md`: Rewrite test sections

Replace the entire `mruMethod tests` section (M18–M25) with a compact
set of permanent regression tests that verify window-level MRU behaviour
without referencing a config toggle. The rewritten scenarios cover:

- **MR1:** Same-app window cycling (two Ghostty windows)
- **MR2:** Cross-app window MRU (Ghostty → Firefox → back)
- **MR3:** Tab away from pre-selection (different app targeting)
- **MR4:** Window close shifts pre-selection mid-session
- **MR5:** New window during active overlay
- **MR6:** Single window no-op commit
- **MR7:** Whitelisted apps after running apps

These tests mirror M18–M24 but drop the `"mruMethod"` prerequisite and
the numbered-format references to the old toggle.

### Change 13 — `UNTESTED.md`: Remove M25

Remove the Phase 10 / M25 entry entirely. This test verified `"app"` mode
which no longer exists.

---

### Change 14 — `shell.qml`: Remove `_pendingFullscreenAppId` and `_fullscreenedAddresses` fallback mechanisms

During testing, Blender launched maximised (via `exec_cmd` PID-tracked rule) but the
`_pendingFullscreenAppId` fallback mechanisms in `onActiveToplevelChanged` and `onRawEvent`
openwindow handler were **interfering** with it. Removing these fallbacks fixed Blender
maximise-on-launch.

**What was removed:**
1. `_pendingFullscreenAppId` property declaration (line ~194)
2. `_fullscreenedAddresses` property declaration + tracking (line ~197)
3. `onActiveToplevelChanged` fullscreen re-apply block (~8 lines)
4. `onRawEvent` openwindow fullscreen dispatch block (~10 lines)
5. All set/clear sites in `openSwitcher()`, `cancelSwitch()`, `commitSelection()`, `openNewWindow()`

The `exec_cmd` with `{ maximize = true }` PID-tracked rule is now the **sole** mechanism
for maximising whitelisted launches. This simplified the launch path to a single
`hyprctl dispatch` call with no event-handler fallbacks.

**Files changed:** `shell.qml` — 7 edits, removing both properties and all references.

---

## What stays unchanged

| Feature | Reason |
|---|---|
| `globalWindowMru` property | Core to window-mode — always updated |
| `_preSelectedAppId` property | Core to window-mode — always calculated |
| `_windowClosedThisSession` flag | Needed for close+commit targeting in window-mode |
| Synchronous MRU update in `commitSelection()` | Always needed (QML engine pauses on hide) |
| `_findAppForAddress()` (NEW) | Shared helper, reduces duplication |
| `fullscreenOnActivate` config & Path A dispatch | Address-based fullscreen on existing-window commit (unrelated to launch) |
| `appMru` sorting | Still used for sphere sort order |
| `appWindowMru` maintenance | Still used for drill-down sorting, spawn override, close cleanup |
| `_pendingSpawnAppId` / `_pendingSpawnAddr` | Needed for Ctrl+Enter spawn tracking |

---

## Verification (automated grep checks)

```bash
# C1: No references to mruMethod remain in shell.qml
grep -c 'mruMethod' shell.qml
# Expected: 0

# C2: No references to mruMethod remain in hyprsphere.json
grep -c 'mruMethod' hyprsphere.json
# Expected: 0

# C3: globalWindowMru is always maintained in onActiveToplevelChanged
grep -A 40 'function onActiveToplevelChanged' shell.qml | grep -c 'globalWindowMru'
# Expected: at least 1

# C4: globalWindowMru is always cleaned in closewindow handler
grep -A 50 'event.name !== "closewindow"' shell.qml | grep -c 'globalWindowMru'
# Expected: at least 1

# C5: _findAppForAddress helper exists
grep -c '_findAppForAddress' shell.qml
# Expected: at least 1

# C6: _preSelectedAppId is referenced in finishOpenSwitcher, scheduleRebuild, commitSelection, drillDown
grep -c '_preSelectedAppId' shell.qml
# Expected: at least 4

# C7: commitSelection still uses _windowClosedThisSession
grep -c '_windowClosedThisSession' shell.qml
# Expected: at least 2

# C8: drillDown still pre-selects globalWindowMru[1]
grep -A 30 'function drillDown' shell.qml | grep -c 'globalWindowMru'
# Expected: at least 1

# C11: exec_cmd maximize rule still used
grep -c 'exec_cmd.*maximize' shell.qml
# Expected: at least 2

# C9: No app-mode pre-selection else branch remains
grep -c 'selectedAppIndex = (appMru.length >= 2)' shell.qml
# Expected: 0

# C10: fullscreen-on-activate paths still intact
grep -c 'fullscreenOnActivate' shell.qml
# Expected: at least 2

# C12: No _pendingFullscreenAppId remains (removed fallback mechanisms)
grep -c '_pendingFullscreenAppId' shell.qml
# Expected: 0

# C13: No _fullscreenedAddresses remains (removed fallback mechanisms)
grep -c '_fullscreenedAddresses' shell.qml
# Expected: 0
```

---

## Manual tests (rewritten from M18–M24 as permanent regression tests)

### MR1. Same-app window cycling
**Setup:** Two windows of App A (e.g. Ghostty-A and Ghostty-B), one window of App B.
1. Focus Ghostty-A → Focus Ghostty-B
2. Press **Alt+Tab** — verify Ghostty is pre-selected (owns the previous window Ghostty-A)
3. Release **Alt** — verify Ghostty-A is focused
4. Press **Alt+Tab** again — verify Ghostty-B is pre-selected
5. Release **Alt** — verify Ghostty-B is focused

### MR2. Window MRU across different apps
**Setup:** Ghostty-A, Ghostty-B, Firefox.
1. Focus Ghostty-A → Focus Firefox → Focus Ghostty-B
2. Press **Alt+Tab** — verify Firefox is pre-selected (was previous window)
3. Release **Alt** — verify Firefox is focused

### MR3. Tab away from pre-selection
**Setup:** Ghostty-A, Ghostty-B, Firefox.
1. Focus Ghostty-A → Focus Ghostty-B
2. Press **Alt+Tab** — verify Ghostty pre-selected
3. Press **Tab** to cycle to Firefox
4. Release **Alt** — verify Firefox is focused (via `appWindowMru["firefox"][0]`)

### MR4. Window close shifts pre-selection
**Setup:** Ghostty-A, Ghostty-B, Firefox.
1. Focus Ghostty-A → Focus Firefox → Focus Ghostty-B
2. Press **Alt+Tab** — verify Firefox pre-selected
3. Externally close Firefox window while overlay is open
4. Verify sphere rebuilds and Ghostty is now pre-selected
5. Release **Alt** — verify Ghostty-A is focused

### MR5. New window during active overlay
**Setup:** Ghostty-A only.
1. Focus Ghostty-A, press **Alt+Tab**
2. Without closing overlay, open a new window (Ctrl+Enter or external)
3. Verify sphere rebuilds with the new window

### MR6. Single window no-op commit
**Setup:** Only one window open (Ghostty-A).
1. Press **Alt+Tab** — verify Ghostty pre-selected (index 0)
2. Release **Alt** — verify no-op (stays on Ghostty-A)

### MR7. Whitelisted apps after running apps
**Setup:** Ghostty-A running, whitelisted apps configured.
1. Press **Alt+Tab** — verify Ghostty pre-selected
2. Tab past Ghostty — verify whitelisted placeholders appear after running apps
3. Select a whitelisted app and commit — verify it launches
