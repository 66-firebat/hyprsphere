# HANDOFF — Refactor: mruMethod="window" only

## Rationale

The current codebase supports two Alt+Tab modes via `mruMethod` config:
`"app"` (legacy) and `"window"` (PATCH 1). This duality introduces
branching everywhere: `finishOpenSwitcher`, `commitSelection`,
`drillDown`, `scheduleRebuild`, `onActiveToplevelChanged`,
`onRawEvent`, and more. Each branch doubles the mental model and
creates subtle edge cases where the two modes interact (e.g.,
`appMru` vs `globalWindowMru`, index-0 vs index-1 targeting).

**The `mruMethod` field is removed entirely from `hyprsphere.json`.**
No default, no fallback — the code always behaves as
`mruMethod="window"`. The sphere still sorts by app-level MRU
(`appMru`) for visual grouping, but pre-selection and commit
targeting are always driven by `globalWindowMru`.

Removing `"app"` mode eliminates all `if (cfg.mruMethod === "window")`
guards — that logic becomes unconditional.

---

## Priority order of changes

### P1 — Remove `mruMethod` config option

**File:** `hyprsphere.json`

Remove the key entirely (no default needed since it's no longer
checked).

**File:** `README.md`, `PHASE_10.md`, `PHASE_10_TESTS.md`, `patches/PATCH_1.md`

Remove all documentation references to `mruMethod`.

---

### P2 — Remove early-return guards in event handlers

These are the simplest changes — just remove the `if (cfg.mruMethod === "window")` condition and keep the block body unconditional.

**File:** `shell.qml`

#### 2a — `onActiveToplevelChanged()` (line ~1010)

```javascript
// Before:
if (cfg.mruMethod === "window" && addr) {
    // ... globalWindowMru update ...
}

// After:
if (addr) {
    // ... globalWindowMru update ...
}
```

#### 2b — `onRawEvent` closewindow (line ~1130)

```javascript
// Before:
if (cfg.mruMethod === "window") {
    var gwNorm = ...
    // ... globalWindowMru cleanup ...
}

// After:
var gwNorm = ...
// ... globalWindowMru cleanup ...
```

#### 2c — `scheduleRebuild()` MRU recalculation (line ~660)

```javascript
// Before:
if (cfg.mruMethod === "window" && window.visible && !window._pendingSpawnAppId) {
    // ... recalculate _preSelectedAppId ...
}

// After:
if (window.visible && !window._pendingSpawnAppId) {
    // ... recalculate _preSelectedAppId ...
}
```

#### 2d — `drillDown()` pre-selection (line ~762)

```javascript
// Before:
if (cfg.mruMethod === "window" && app.appId === window._preSelectedAppId && ...) {
    // ... select globalWindowMru[1] ...
}

// After:
if (app.appId === window._preSelectedAppId && ...) {
    // ... select globalWindowMru[1] ...
}
```

#### 2e — `commitSelection()` layer 0 targeting (line ~869)

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
// Always use window-mode targeting when on the pre-selected app:
if (node.appId === window._preSelectedAppId) {
    // ... window-mode targeting (with spawn override + wmruIdx) ...
} else {
    // User tabbed to a different app: focus its MRU-most window
    var winMru = appWindowMru[node.appId] || [];
    // ...
}
```

#### 2f — `commitSelection()` synchronous MRU update (line ~894)

```javascript
// Before:
if (cfg.mruMethod === "window" && addr) {
    // ... synchronous globalWindowMru update ...
}

// After:
if (addr) {
    // ... synchronous globalWindowMru update ...
}
```

---

### P3 — Remove app-mode pre-selection in `finishOpenSwitcher()`

**File:** `shell.qml` (line ~285)

```javascript
// Before:
if (cfg.mruMethod === "window") {
    // ... window-mode pre-selection ...
} else {
    selectedAppIndex = (appMru.length >= 2) ? 1 : 0;
}

// After:
// Window-mode pre-selection only (mruMethod was removed):
if (globalWindowMru.length >= 2) {
    // find app that owns globalWindowMru[1]
    _preSelectedAppId = ...
    selectedAppIndex = index of that app
} else {
    selectedAppIndex = 0;
}
```

---

### P4 — Remove now-unused properties

**File:** `shell.qml`

Check each property for remaining usage after P2 and P3:

| Property | Keep or remove |
|---|---|
| `globalWindowMru` | **Keep** — core to window mode |
| `_preSelectedAppId` | **Keep** — core to window mode |
| `_windowClosedThisSession` | **Keep** — handles close+commit targeting |
| `_fullscreenedAddresses` | **Keep** — prevents duplicate fullscreen dispatches |
| `_pendingFullscreenAppId` | **Keep** — fallback for GIMP-style apps |
| `_pendingFullscreenAddr` | Already removed (cleanup pass) |
| `appMru` | **Keep** — used for sphere sort order (`sortByMru()`) and `appWindowMru` maintenance |
| `appWindowMru` | **Keep** — used for drill-down sorting, spawn override, closewindow cleanup |

No properties to remove — everything still serves a purpose.

---

### P5 — Remove stale `onRawEvent` activewindow handler (cleanup)

If the duplicate `activewindow` handler blocks were not fully removed
during PATCH 1, strip them now. The `onActiveToplevelChanged` signal
is the proper channel; raw `activewindow` event handling was an
abandoned approach.

---

### P6 — Config documentation removal

**Files:** `hyprsphere.json`, `README.md`, `PHASE_10.md`

Remove the `mruMethod` field from `hyprsphere.json`. Update the config
table in `README.md` to note that window-level MRU is always used.
Update `PHASE_10.md` to remove the mruMethod config section.

---

### P7 — Simplify `finishOpenSwitcher()` initial pre-selection (optional)

The current code has two nested loops (search `sphereModel` for the
app that owns `globalWindowMru[1]`). This can stay as-is or be
refactored into a helper function `_findAppForAddress(addr)` shared
with `scheduleRebuild()` and `drillDown()`. Low priority — the code
is duplicated but correct.

---

## What to test

### Automated checks (grep-based)

Add these to a test script (e.g. `phase_refactor_tests.sh`):

```bash
# C1: No references to mruMethod remain
grep -c 'mruMethod' shell.qml
# Expected: 0

# C2: globalWindowMru is always maintained in onActiveToplevelChanged
grep -A 5 'function onActiveToplevelChanged' shell.qml | grep -c 'globalWindowMru'
# Expected: at least 1

# C3: globalWindowMru is always cleaned in closewindow handler
grep -A 5 'if (event.name !== "closewindow")' shell.qml | grep -c 'globalWindowMru'
# Expected: at least 1

# C4: _preSelectedAppId is always recalculated in scheduleRebuild
grep -A 3 'window._preSelectedAppId' shell.qml | grep -c '_preSelectedAppId'
# Expected: at least 3 (property, finishOpenSwitcher, scheduleRebuild)

# C5: commitSelection always uses window-mode targeting
grep -A 2 '_preSelectedAppId' shell.qml | grep -c '_windowClosedThisSession'
# Expected: at least 1

# C6: drillDown always pre-selects globalWindowMru[1]
grep -A 5 'function drillDown' shell.qml | grep -c 'globalWindowMru'
# Expected: at least 1

# C7: No else branches for app-mode pre-selection remain
grep -c 'selectedAppIndex = (appMru.length >= 2)' shell.qml
# Expected: 0

# C8: No cfg.mruMethod references
grep -c 'cfg.mruMethod' shell.qml
# Expected: 0

# C9: fullscreen-on-activate paths still intact
grep -c 'fullscreenOnActivate' shell.qml
# Expected: at least 2 (whitelist commit + openNewWindow)

# C10: exec_cmd maximize rule still used
grep -c 'exec_cmd.*maximize' shell.qml
# Expected: at least 2 (whitelist commit + openNewWindow)
```

### Manual tests (from existing M18-M25 suite)

| Test | What to verify |
|---|---|
| M18 | Same app, two windows: Alt+Tab cycles between them correctly |
| M19 | Window MRU across different apps: Firefox → Ghostty-B → Alt+Tab shows Firefox |
| M20 | Tab away from pre-selection: commit uses `appWindowMru` for non-pre-selected app |
| M21 | Window close shifts pre-selection mid-session |
| M22 | New window during overlay (Ctrl+Enter focus on spawn) |
| M23 | Single window no-op commit |
| M24 | Whitelisted apps appear after running apps |
| M13 | Whitelisted Blender launch maximises (exec_cmd + fallback) |
| M10–M17 | Fullscreen-on-activate on all commit paths |

### Regression tests (new scenarios)

| Scenario | Expected behaviour |
|---|---|
| Close pre-selected app via Ctrl+C, then Alt release | Land on the window before the closed app (index 0) |
| Close non-pre-selected app via Ctrl+C, then Alt release | Normal targetting (index 1) |
| Spawn via Ctrl+Enter, then Alt release | Focus the spawned window |
| Spawn via Ctrl+Enter, then Ctrl+C | Close the spawned window |
| Drill down, select a non-MRU-most window, Alt release | Focus that specific window |
| Alt release from layer 1 after tabbing | Focus the selected window, not globalWindowMru[1] |
| Multiple Alt+Tab cycles without committing | Pre-selection updates dynamically |

### Edge cases

| Scenario | Expected behaviour |
|---|---|
| `globalWindowMru` length 0 (no windows, fresh start) | Pre-select sphere index 0 (whitelist or placeholder) |
| `globalWindowMru` length 1 (one window) | Pre-select that window's app; commit is no-op |
| All windows on special workspaces | `buildLayer0()` skips them; show whitelisted placeholders |
| `globalWindowMru[1]` address no longer in any `appWindowMru` entry | Fall back to sphere index 0 |
| Rapid Ctrl+Enter on same app | Each spawn auto-selects correctly |

---

## Summary of removals

| What | Where | Lines affected |
|---|---|---|
| `"mruMethod": "app"` config | `hyprsphere.json` | 1 |
| `if (cfg.mruMethod === "window")` guard | `onActiveToplevelChanged` | ~3 |
| `if (cfg.mruMethod === "window")` guard | `onRawEvent` closewindow | ~3 |
| `if (cfg.mruMethod === "window")` guard | `scheduleRebuild` | ~3 |
| `if (cfg.mruMethod === "window")` guard | `drillDown` | ~3 |
| `if (cfg.mruMethod === "window")` guard | `commitSelection` layer 0 | ~3 |
| `if (cfg.mruMethod === "window")` guard | `commitSelection` sync update | ~3 |
| `else` app-mode pre-selection | `finishOpenSwitcher` | ~10 |
| `else` app-mode commit targeting | `commitSelection` | ~15 |
| `mruMethod` config docs | `README.md`, `PHASE_10.md` | ~20 |

Everything else stays: `globalWindowMru`, `_preSelectedAppId`,
`_windowClosedThisSession`, spawn override, synchronous MRU update,
visibility cycling, all fullscreen-on-activate paths.
