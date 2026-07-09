# REFACTOR.md — hyprsphere Architecture Analysis & Critique

> **Purpose:** This document provides a complete functional inventory of
> hyprsphere, followed by a detailed critique of the codebase's structural
> problems. Use this as a reference when planning a refactor.

---

## Part 1: Complete Functional Inventory

### 1.1 What hyprsphere Is

hyprsphere is a 3D Alt+Tab window switcher for Hyprland/Quickshell. It
runs as a permanent Quickshell PanelWindow on the overlay layer, listening
for IPC commands to show/hide a Fibonacci sphere that visualizes all running
applications and their windows. It provides keyboard-driven navigation,
fuzzy search, window management (close, spawn new instance), and a
mouse-interactive 3D scene.

**Runtime:** Quickshell (QML/C++ hybrid runtime) + Qt 6 + Qt5Compat
**IPC surface:** `qs ipc call hyprsphere <command>` from Hyprland keybinds
**Window type:** `WlrLayershell.layer: WlrLayer.Overlay` (covers entire screen)

---

### 1.2 Configuration (`hyprsphere.json`)

| Key | Type | Default | Purpose |
|---|---|---|---|
| `colors.*` | 15 hex colors | Catppuccin Mocha | Theme colors for all UI elements |
| `scaler.*` | 3 numbers | ref=1920, min=0.5, max=2.0 | Responsive scaling by screen width |
| `sizes.*` | 21 integers | 2-104 | Base size tokens used by scaler |
| `satellite.*` | 20 values | varied | Selected-card ("satellite") geometry |
| `sphere.*` | 12 values | varied | 3D sphere layout parameters |
| `animations.*` | 11 values | varied | All animation durations and easing |
| `mouse.*` | 1 number | 0.005 | Drag rotation sensitivity |
| `searchBar.*` | 16 values | varied | Search bar appearance and style |
| `search.*` | 6 values | varied | Fuse.js search parameters |
| `appCard.*` | 16 values | varied | Sphere card appearance, labels, badges |
| `cardTilt.*` | 6 values | varied | 3D card tilt and opacity effects |
| `whitelist` | N entries | [] | Persistent dock of apps always shown |
| `fullscreenOnActivate` | bool | true | Maximize window on Alt-release commit |
| `maximizeOnSlash` | bool | false | Also maximize window on `\` preview |
| `maximizeOnEscape` | bool | true | Maximize origin window on Escape |

---

### 1.3 Data Structures (State Variables)

#### Core MRU Tracking

| Variable | Type | Purpose |
|---|---|---|
| `globalWindowMru` | string[] | Window-level MRU: most-recently-focused window addresses, index 0 = current |
| `appMru` | string[] | App-level MRU: most-recently-committed app IDs |
| `appWindowMru` | object(string[]) | Per-app window MRU: `{ appId: [address, ...] }` per app |
| `_appOpeningOrder` | object(string[]) | Static window-open order: `{ appId: [address, ...] }` fixed at init, used for window index badges |

#### Sphere State

| Variable | Type | Purpose |
|---|---|---|
| `sphereModel` | object[] | Current nodes displayed on the sphere (varies by layer) |
| `selectedAppIndex` | int | Currently selected node index in sphereModel |
| `layer` | int (0/1/2) | Current layer: 0=apps, 1=drill-down windows, 2=search results |
| `drilledAppId` | string | The app whose windows are shown at layer 1 |
| `rebuildScheduled` | bool | Guard against concurrent rebuilds |
| `_staleRetryCount` | int | Retry counter for stale-data rebuild avoidance |
| `_spawnRetryCount` | int | Retry counter for spawn-tracking rebuild avoidance |
| `_preSelectedAppId` | string | The app that should be pre-selected on next open |

#### Overlay State

| Variable | Type | Purpose |
|---|---|---|
| `overlayActive` | bool | Whether the overlay is currently in use |
| `visible` | bool (inherited) | Qt Window visibility |
| `focusable` | bool (inherited) | Whether the overlay can receive keyboard focus |
| `_mruFrozen` | bool | When true, onActiveToplevelChanged is blocked |
| `_commitAddr` | string | Address being committed (allows its focus event through MRU freeze) |
| `_togglingVisibility` | bool | Guard during `\` preview visibility toggle cycle |
| `_pendingSpawnAppId` | string | App ID of a Ctrl+Enter spawned window awaiting toplevel update |
| `_pendingSpawnAddr` | string | Address of a spawned window awaiting toplevel update |

#### Search State

| Variable | Type | Purpose |
|---|---|---|
| `searchQuery` | string | Current search text |
| `fuseIndex` | Fuse instance | Compiled Fuse.js search index |
| `searchDatabase` | object[] | Flat array of all searchable items |
| `searchTimer` | Timer | Debounce timer for search execution |
| `savedLayer2Model` | object[] | Saved search results for drill-down round-trip |
| `savedLayer2Query` | string | Saved search query for drill-down round-trip |
| `searchFocused` | bool | Whether search input is focused |

#### 3D Sphere State

| Variable | Type | Purpose |
|---|---|---|
| `sphereRadius` | real | Current sphere radius (may auto-adjust) |
| `baseSphereRadius` | real | Configured sphere radius before auto-adjust |
| `sphereZoom` | real | Zoom multiplier (1.0 normal, 1.5 in search) |
| `rotX` | real | Current X-axis rotation (radians) |
| `rotY` | real | Current Y-axis rotation (radians) |
| `projCache` | object[] | Pre-computed 3D→2D projections for all sphere nodes |
| `projDirty` | bool | Whether projCache needs recomputation |
| `introPhase` | real | Entrance animation progress (0.0→1.0) |

---

### 1.4 Keybind Inventory

| Key(s) | Modifier | Layer(s) | Action | Function Called |
|---|---|---|---|---|
| Tab | None | All | Advance sphere forward | `advance(1)` |
| Shift+Tab | Shift | All | Advance sphere backward | `advance(-1)` |
| `\` | None | All | Advance + preview-focus window | `advance(1)` + `_previewFocus()` |
| `\|` (Shift+`\`) | Shift (produces `|`) | All | Backward + preview-focus | `advance(-1)` + `_previewFocus()` |
| `;` | None | 0→1, 2→1, 1→0/2 | Toggle drill-down | `drillDown()` |
| Letters/digits | None | All | Enter search mode (layer 2) | `_handleSearchInput()` |
| Backspace | None | All (if search active) | Remove last search char | `_handleSearchInput()` |
| Ctrl+C | Ctrl | All | Close selected window(s) | `closeSelection()` |
| Ctrl+Enter | Ctrl | All | Spawn new window instance | `openNewWindow()` |
| Escape | None | All | Close overlay | `cancelSwitch()` |
| Alt release | None | All | Commit selection | `commitSelection()` |
| Mouse click | None | All | Select node | `selectedAppIndex=index` + `centerOnApp()` |
| Mouse double-click | None | All | Commit selection | `commitSelection()` |
| Mouse drag | None | All | Rotate sphere | Direct rotX/rotY manipulation |

---

### 1.5 Event Handlers

| Event | Source | Purpose |
|---|---|---|
| `onActiveToplevelChanged` | Hyprland singleton | Update all MRU lists when compositor focus changes |
| `onRawEvent("openwindow")` | Hyprland socket | Track new window in appWindowMru, handle spawn tracking |
| `onRawEvent("closewindow")` | Hyprland socket | Remove closed window from all MRU lists, trigger rebuild |
| `onVisibleChanged` | Qt Window | Restart entrance animation and grab focus when overlay appears |

#### IPC Commands (via `qs ipc call hyprsphere <cmd>`)

| Command | Action |
|---|---|
| `toggle` | Open overlay or advance if already open (Alt+Tab chord fallback) |
| `commit` | Commit selection (Alt-release fallback from Hyprland submap) |
| `cancel` | Cancel switch (Escape from Hyprland submap) |

---

### 1.6 Three-Layer State Machine

#### Layer 0 — App Group List

One sphere node per unique `appId`. Windows grouped by app. Sorted by
`globalWindowMru` order (deduplicated by app). Pre-selects the app owning
`globalWindowMru[1]` (the previous window).

- **Commit:** Focuses the target app's MRU-most window
- **Drill-down:** Shows that app's individual windows (→ layer 1)
- **Ctrl+C:** Closes ALL windows of that app
- **Badge:** Shows `+N` where N = window count

#### Layer 1 — Window Drill-Down

One sphere node per window of the drilled-into app. Windows sorted by
`appWindowMru[appId]` order.

- **Commit:** Focuses the specific selected window
- **Drill-down (`;`):** Returns to previous layer (0 or 2, preserving search results)
- **Ctrl+C:** Closes only the selected window
- **Badge:** Shows window index (1-based) from `_appOpeningOrder`

#### Layer 2 — Search Results

Hybrid layer: running app groups + whitelisted apps + individual windows.
Filtered by Fuse.js fuzzy search. Sorted: running apps → whitelisted apps
→ individual windows.

- **Commit:** App group → MRU-most window; Window node → specific window
- **Drill-down (`;`):** App node → layer 1; Window node → no-op
- **Badge:** Same rules as layer 0/1 depending on node type
- **Zoom:** Sphere zooms in to `layer2Zoom` (default 1.5×)

---

### 1.7 Async Operations & Race Conditions

| Operation | Mechanism | Latency | Who Depends On It |
|---|---|---|---|
| `Hyprland.refreshToplevels()` | IPC request to compositor | 1-3 event loop ticks | `buildLayer0()`, sphere rebuild |
| `Quickshell.execDetached()` | Subprocess spawn | 1+ ticks | Focus dispatch, fullscreen, submap reset |
| `Qt.callLater(fn)` | Event loop scheduling | 1 tick | Deferred unfreeze, retry loops, visibility toggle |
| `onRawEvent` delivery | Event socket | 1-20ms | closewindow/openwindow handling |
| `iconReader Process` | Bash subprocess | 100-500ms | Icon/name/exec map population |
| `configReader Process` | File read | 10-50ms | Config parsing |

---

## Part 2: Codebase Critique

### 2.1 Overall Architecture Problems

#### Problem 1: Monolithic 2000+ Line QML File

Every function, every state variable, every UI element, and every event
handler lives in a single `shell.qml` file. There is no separation of
concerns. The MRU tracking logic, the 3D sphere rendering, the search
engine, the IPC handlers, the icon resolution, the animation system,
and the input handling are all interleaved in one scope with no
modularity.

**Consequences:**
- Impossible to reason about any single subsystem in isolation
- Changes to one feature frequently break unrelated features
- Merge conflicts are inevitable with parallel work
- Testing requires the entire runtime environment
- The file takes multiple seconds to parse on every edit

#### Problem 2: State Explosion (40+ State Variables)

There are ~40 mutable state variables tracking window MRU, sphere state,
overlay state, search state, animation state, and retry counters. Many
have overlapping or contradictory purposes (e.g., `_mruFrozen` vs
`_togglingVisibility` vs `_commitAddr` all gate different aspects of
the same focus-change problem). Several are only needed because of
timing bugs in other parts of the system.

**Consequences:**
- Every function must check a constellation of guards before acting
- Adding a new feature requires understanding all 40 variables
- Many states are "temporary hacks" that no one fully understands
- The interaction between `_mruFrozen`, `_commitAddr`, `_preSelectedAppId`,
  `_pendingSpawnAddr`, `_togglingVisibility`, `rebuildScheduled`,
  `_staleRetryCount`, and `_spawnRetryCount` is a byzantine maze

#### Problem 3: Implicit Timing Dependencies

The system relies on the ORDER of asynchronous events that it cannot
control. `commitSelection()` opens a Pandora's box of async races:

```
visible = false          → compositor auto-restores focus (async, 1-20ms)
execDetached(focus)      → hyprctl dispatches focus (async, 1-20ms)
execDetached(fullscreen) → hyprctl maximizes (async, 1-20ms)
Qt.callLater(unfreeze)   → unfreezes MRU (next tick)
```

These four events can arrive in any order, and each one modifies shared
state (`globalWindowMru`, `appWindowMru`, `appMru`). The system relies
on `_mruFrozen` and `_commitAddr` to gate the chaos, but the gating
logic itself has been patched multiple times (see PATCH_6, PATCH_7).

**Consequences:**
- Bugs manifest as "sometimes the wrong window is pre-selected"
- Fixes are always timing adjustments that break other timing paths
- The system is never truly deterministic
- Every async edge case requires another guard variable

#### Problem 4: Patchwork Evolution

The file has 10 PHASE documents, 5 PATCH documents, and a HANDOFF
document. Each patch added new state variables and new conditional
branches rather than refactoring the underlying structure. The result
is a codebase where:

- `scheduleRebuild()` is 150 lines with 5+ retry/cancellation paths
- `drillDown()` is 146 lines with 3 different layer transitions, each
  with `if (cfg.focusOnTab)` remnants and `if (cfg.focusOnTab)` is
  already removed but the structural complexity remains
- `commitSelection()` has 3 early-return paths (placeholder, whitelist,
  normal) that each handle state cleanup differently
- The stale-data retry in `scheduleRebuild()` was rewritten 3 times
  (address-based → count-based with limit → spawn retry with limit)

---

### 2.2 Specific Code Smells

#### Smell 1: `scheduleRebuild()` — 150 Lines of Callback Hell

```
function scheduleRebuild() {
    if (rebuildScheduled) return;         // guard
    rebuildScheduled = true;
    Qt.callLater(function() {              // defer
        rebuildScheduled = false;
        refreshToplevels();
        var raw = buildLayer0();           // read data
        
        // stale check with retry limit     ← PATCH_7 hack
        // spawn retry with limit            ← PATCH_7 hack  
        // layer 2 search rebuild            ← Phase 6
        // layer 1 window rebuild            ← Phase 4
        // layer 0 app rebuild               ← Phase 1
        // spawn auto-selection              ← Phase 9
        // pre-selection recalculation       ← PATCH_5
        focusGrabber.forceActiveFocus();   // done
    });
}
```

This function tries to do everything: handle stale data, handle spawn
tracking, handle all three layers, handle auto-selection of spawned
windows, and recalculate pre-selection. Each of these should be separate
concerns, but they're all interleaved in one callback with `return`
statements scattered throughout.

#### Smell 2: `drillDown()` — 146 Lines of State Mutation

Three different layer transitions (0→1, 2→1, 1→0/2) each with their
own copy of similar logic. The pre-selection logic for the "other"
window is duplicated between the layer 0→1 and layer 2→1 paths. The
layer 1→0 return path has two sub-cases (with saved search results and
without) that differ only in the sphere model source. The `focusOnTab`
auto-preview calls were removed in PATCH_6, leaving behind dead comments
and conditional structure.

#### Smell 3: Three Redundant MRU Lists

- `globalWindowMru`: window-level, for sphere ordering and pre-selection
- `appMru`: app-level, used in `onActiveToplevelChanged` and `onRawEvent`
- `appWindowMru`: per-app window-level, for drill-down sorting

These three lists track the SAME thing (focus history) at different
granularities. They must be kept in sync manually, and there are bugs
where one gets updated but another doesn't (e.g., the `openwindow`
handler originally forgot to update `globalWindowMru`). A single
ordered list of window addresses could derive all three levels.

#### Smell 4: The Stale-Data Retry Is a Heuristic

The count-based stale check (`trackedCount > liveCount`) is clever but
brittle. It assumes that `appWindowMru` is always the source of truth,
which is true for closewindow events but not for openwindow events
(where `appWindowMru` updates BEFORE toplevels catches up). The spawn
retry had to be added as a SEPARATE heuristic with its own retry limit.
Two heuristics that can interact (stale check triggers → retry resets
spawn counter → spawn retry also triggers → cascade).

#### Smell 5: `_mruFrozen` with Exceptions

The MRU freeze mechanism started as a simple boolean: "when the overlay
is open, block focus tracking." Then the `\` key was added (needs focus
previews but shouldn't update MRU → freeze is correct for this). Then
the auto-restore focus bug appeared (freeze blocks the committed
window's focus event too → added `_commitAddr` exception). Now it's a
boolean + a string + a deferred timer, which is three interacting
mechanisms for one problem.

#### Smell 6: `finishOpenSwitcher()` Does Too Much

This function:
1. Waits for icon map to be ready (async retry)
2. Builds layer 0 from toplevels
3. Retries if no data (async retry)
4. Sorts by MRU
5. Calculates pre-selection
6. Initializes Fuse index
7. Makes overlay visible
8. Schedules deferred rebuild

Steps 1-3 and 5-8 should be separate concerns. Steps 4 and 7 have
different timing requirements (sort needs data, visibility needs the
window to be mapped).

#### Smell 7: No Error Boundaries

If `buildLayer0()` throws (e.g., `Hyprland.toplevels` is null), the
entire overlay crashes. There are no try/catch blocks around data
access. If `Fuse.js` import fails, the search silently doesn't work.
If `configReader` fails, `cfg` stays empty and every config access
returns `undefined`, which QML handles gracefully but silently.

#### Smell 8: Debug Logs Duplicated Across the Codebase

17 `console.log` calls scattered across the file. Some are structured
(PATCH_7 debug logs with `[dbg]` prefix), some are just comments-in-code.
These should be a single centralized logging function that can be toggled.

#### Smell 9: Config Access Pattern Is Fragile

Every config value is accessed as `cfg.key?.subkey ?? default`. This
means a typo in a config key silently returns the default — no validation.
If `hyprsphere.json` is malformed JSON, the entire config fails silently.

#### Smell 10: The Visibility Toggle Dance

Three different mechanisms modify `visible`:
1. `commitSelection()` → `visible = false`
2. `closewindow` handler → `visible = false`, then `Qt.callLater` → `true`
3. `openwindow` handler → `visible = false`, then `Qt.callLater` → `true`
4. `_previewFocus()` → `visible = false`, then `Qt.callLater` → `true`
5. `closeSequence` → `visible = false` (via ScriptAction)

These compete. If `previewFocus` toggles visibility while `closewindow`
is also toggling it, the `Qt.callLater` callbacks fire in unpredictable
order, and the overlay can end up in the wrong visibility state.

---

### 2.3 Architectural Recommendations

#### R1: Split Into Multiple Files

| Module | Responsibility | Approx Lines |
|---|---|---|
| `MRUTracker.qml` | globalWindowMru, appWindowMru, appMru, event handlers | 150 |
| `SphereEngine.qml` | 3D math, projection, rotation, zoom | 100 |
| `SearchEngine.qml` | Fuse.js index, search execution, database building | 150 |
| `StateMachine.qml` | Layer state, overlay state, commit/cancel/drill logic | 300 |
| `OverlayUI.qml` | Main panel, key handlers, visual composition | 400 |
| `WindowManager.qml` | closeSelection, openNewWindow, focus dispatch | 100 |
| `ConfigManager.qml` | Config loading, validation, defaults | 100 |
| `Logger.qml` | Centralized debug logging | 30 |

Total: ~1330 lines (down from 2024)

#### R2: Two-Dimensional List Tracking (Replaces Three MRU Lists)

The core data structure is a single ordered list of window focus events.
From this list, two dimensions are derived — one for app-level navigation
(layer 0) and one for window-level navigation (layer 1). No manual sync
between lists, no stale state, no redundant tracking.

---

### The Single Source: `focusHistory`

```
focusHistory = [
  { address: "0xabc123", appId: "firefox",       windowTitle: "Mozilla Firefox",          timestamp: 1704067201000 },
  { address: "0xdef456", appId: "com.mitchellh.ghostty", windowTitle: "bash",           timestamp: 1704067200000 },
  { address: "0x789abc", appId: "firefox",       windowTitle: "GitHub — Mozilla Firefox", timestamp: 1704067199000 },
  { address: "0x111222", appId: "blender",       windowTitle: "Blender",                 timestamp: 1704067198000 },
]
```

Each entry is a window that has been focused at some point. The list is
always sorted most-recently-focused first. Events arrive from
`onActiveToplevelChanged` (manual focus) and `openwindow` (new window
spawned). Remove entries on `closewindow`.

---

### Dimension 1 — App Order (Layer 0)

Derived by walking `focusHistory` and collecting unique `appId`s in order
of first appearance. Consecutive entries with the same `appId` collapse
into a single entry.

```
focusHistory = [firefox_A, ghostty, firefox_B, blender]
                      ↓  collapse consecutive same-app
appOrder      = [firefox, ghostty, blender]
```

**Tab cycles through `appOrder`** — each Tab press moves to the next app
in the list. You cannot have two entries for the same app in a row. When
you commit to an app, the target window is the MRU-most window for that
app (index 0 of that app's window list).

**Pre-selection on overlay open:** Index 1 of `appOrder` (the previous
app) is pre-selected. If `appOrder` has fewer than 2 entries, index 0
is pre-selected.

---

### Dimension 2 — Window Order (Layer 1)

Derived by filtering `focusHistory` by `appId` and extracting just the
addresses, preserving MRU order.

```
appWindowOrder = {
  "firefox":       ["0xabc123", "0x789abc"],
  "com.mitchellh.ghostty": ["0xdef456"],
  "blender":       ["0x111222"],
}
```

**Drill-down (`;`) on an app at layer 0** switches to layer 1, where the
sphere shows one node per window in `appWindowOrder[appId]`. The first
entry is the MRU-most window (the one that would be targeted by a
layer-0 commit). Pre-selects index 1 (the "other" window) when there are
2+ windows.

**`;` at layer 1** returns to layer 0.

---

### Concrete Example: Full Tab Cycle

```
focusHistory = [firefox_A (latest), ghostty, firefox_B, blender (oldest)]

appOrder      = ["firefox", "ghostty", "blender"]
appWindowOrder = {
  "firefox": ["0xabc123" (firefox_A), "0x789abc" (firefox_B)],
  "ghostty": ["0xdef456"],
  "blender": ["0x111222"],
}
```

| Action | Layer | What Happens | Selection |
|---|---|---|---|
| Alt+Tab | 0 | Open overlay | Pre-select `appOrder[1]` = **ghostty** |
| Tab | 0 | Advance to next app | **blender** |
| Tab | 0 | Wrap to first app | **firefox** |
| `;` | 0→1 | Drill into Firefox | Show `appWindowOrder["firefox"]`, pre-select firefox_B (index 1) |
| Tab | 1 | Advance to next window | **firefox_A** (index 0) |
| Alt-release | 1 | Commit to firefox_A | Focus firefox_A, add to front of focusHistory |

After commit, `focusHistory` is re-ordered (firefox_A moves to front,
no new entry created — list stays bounded):
```
focusHistory = [firefox_A (now first), firefox_B, ghostty, blender]

appOrder after commit = ["firefox", "ghostty", "blender"]
// Same app order — only window ordering within firefox changed
// firefox_A is now MRU-most, firefox_B is second
```

---

### Update Rules

| Event | `focusHistory` update | `appOrder` derivation | `appWindowOrder` derivation |
|---|---|---|---|
| `onActiveToplevelChanged` | Move address to front (or add if new) | Re-derive (collapse consecutive same-app) | Re-derive (filter by appId) |
| `openwindow` | Add to front | Re-derive | Re-derive |
| `closewindow` | Remove address | Re-derive | Re-derive |
| `commitSelection` | Move committed address to front | Re-derive | Re-derive |

---

### What This Eliminates

| Current Variable | Replaced By |
|---|---|
| `globalWindowMru` | `focusHistory.map(e => e.address)` |
| `appMru` | "appOrder" (derived, not stored) |
| `appWindowMru` | "appWindowOrder" (derived, not stored) |
| `_appOpeningOrder` | Window index badges use `appWindowOrder` index + 1 |
| `_preSelectedAppId` | `appOrder[1]` (live derivation) |
| Manual sync bugs | Single source of truth, zero sync |

> **Why this is better than the current approach:** Currently, three
> separate lists (`globalWindowMru`, `appMru`, `appWindowMru`) are
> maintained independently, and every event handler must update all three
> in sync. Any missed update creates a subtle MRU ordering bug. The
> two-dimensional approach derives everything from one list, so there's
> no sync — the derived views are always correct.

#### R3: Extract Keybind Functions Into `binds.qml`

Move all keyboard handling and key-triggered functions into a separate
`binds.qml` file that gets imported into `shell.qml`. This includes:

| What | Current Location | Destination |
|---|---|---|
| `Keys.onPressed` handler with 9 key checks | shell.qml ~1515 | binds.qml → exported function |
| `Keys.onReleased` handler (Alt release) | shell.qml ~1546 | binds.qml → exported function |
| `advance(dir)` function | shell.qml ~1224 | binds.qml |
| `drillDown()` function | shell.qml ~774 | binds.qml |
| `commitSelection()` function | shell.qml ~922 | binds.qml |
| `cancelSwitch()` function | shell.qml ~1485 | binds.qml |
| `closeSelection()` function | shell.qml ~993 | binds.qml |
| `openNewWindow()` function | shell.qml ~1029 | binds.qml |
| `_previewFocus(addr)` function | shell.qml ~217 | binds.qml |
| `_targetAddrForNode(node)` function | shell.qml ~234 | binds.qml |
| `_handleSearchInput(text)` function | shell.qml ~521 | binds.qml |
| `_executeSearch()` function | shell.qml ~537 | binds.qml |
| `cancelSearch()` function | shell.qml ~604 | binds.qml |

**Files to create:**
```
binds.qml          → Key handlers + all key-triggered functions
```

**Files to modify:**
```
shell.qml          → Import binds.qml, remove ~600 lines of key logic
```

**Import mechanism:**
```qml
import "binds.qml" as Binds
```

The key handlers in `shell.qml` become thin wrappers:
```qml
Keys.onPressed: (event) => { Binds.handleKeyPress(event); }
Keys.onReleased: (event) => { Binds.handleKeyRelease(event); }
```

No change to how the functions work internally — just relocation for
readability and maintainability.

#### R4: Replace Timing-Dependent Guards With Deterministic State Machine

Instead of `_mruFrozen + _commitAddr + Qt.callLater`, model the overlay
as a state machine:

```
Closed → Opening → Open → Closing → Closed
```

Each state explicitly defines which events are processed:
- `Closed`: all events flow normally (no overlay)
- `Opening`: queue events until Open
- `Open`: block focus-tracking (overlay has keyboard focus)
- `Closing`: queue the focus dispatch, ignore auto-restore, then transition to Closed

#### R5: Remove Async Visibility Toggle

Instead of setting `visible = false` then `Qt.callLater` → `true`, use a
dedicated "preview mode" surface or a blur/overlay flag that doesn't
require unmapping the window. The visibility toggle causes more bugs
than it fixes.

#### R6: Unify Rebuild Logic

Instead of `scheduleRebuild()` having 5 different retry/heuristic paths,
have it call `refreshToplevels()` and wait for the response via a
promise/callback. When the data arrives, rebuild once. No retries, no
heuristics.

#### R7: Extract Config Validation

Add a startup validation pass that checks every config key exists and
has the expected type. Log warnings for unknown keys. This catches typos
at startup rather than producing silent wrong behavior.

#### R8: Use Constants Not Magic Numbers

The spawn retry limit (15), stale retry limit (3), and visibility toggle
timing are magic numbers scattered across the file. These should be named
constants at the top of the file or in a separate config section.

#### R9: Centralize ExecDetached Calls

Every `Quickshell.execDetached(["hyprctl", "dispatch", ...])` call is a
raw string with ad-hoc prefix handling (`var prefix = addr.indexOf("0x") === 0 ? "" : "0x"`).
This pattern is duplicated 10+ times. A single `dispatchFocus(addr)`,
`dispatchFullscreen(addr)`, `dispatchClose(addr)`, `execLaunch(cmd)`,
`execSubmap(name)` set of functions would eliminate the duplication.

---

## Part 3: Patch Archaeology

### What Each Patch Actually Changed

| Patch | Lines Changed | What It Did | What It Broke |
|---|---|---|---|
| PATCH_1 | ~80 | Window-based MRU ordering, `sortByWindowMru` | Introduced `_findAppForAddress`, complex MRU sync |
| PATCH_2 | ~60 | Removed dual MRU mode (app/window) | Simplified but left legacy conditionals in place |
| PATCH_3 | ~40 | Fixed address normalization (decimal vs hex) | Fixed window close detection but added `normalizeAddress` |
| PATCH_4 | ~120 | Ctrl+Enter spawn, fullscreen-on-activate | Added `_pendingSpawnAppId/Addr`, spawn retry |
| PATCH_5 | ~100 | Window-based sphere ordering, visibility toggle guard | Added `_togglingVisibility`, complex pre-selection logic |
| PATCH_6 | ~150 | `\` key replaces `focusOnTab`, `maximizeOnSlash`, `maximizeOnEscape` | Removed auto-focus-on-tab, added key handlers |
| PATCH_7 | ~100 | Count-based stale check, MRU freeze timing, spawn retry limit | Added `_staleRetryCount`, `_spawnRetryCount`, `_commitAddr` |

### Cumulative Complexity Growth

```
Base (Phase 1-10): ~1600 lines, 20 state variables, 15 functions
After PATCH_1:     ~1680 lines, 22 state variables
After PATCH_2:     ~1720 lines, 22 state variables
After PATCH_3:     ~1760 lines, 22 state variables
After PATCH_4:     ~1820 lines, 24 state variables
After PATCH_5:     ~1880 lines, 26 state variables
After PATCH_6:     ~1940 lines, 28 state variables
After PATCH_7:     ~2024 lines, 32 state variables
```

Every patch added complexity without removing any. The codebase has
grown 26% in size and 60% in state variables through accretive patching.

---

## Questions for the Refactor (Answered)

### Q1 — Whitelist system

**Answer:** Keep as-is functionally. The whitelist just needs to be a
persistent app dock — entries in `hyprsphere.json` that always appear on
layer 0 whether the app is running or not. The current mechanism (append
placeholder nodes in `buildLayer0()`, `isWhitelistPlaceholder` flag for
commit targeting) works but mixes config data with runtime state.

**Suggested improvement:** Separate the whitelist config schema from
runtime state. Store the raw config in its own structure and derive
placeholder nodes at sphere-build time without polluting the node objects
with boolean flags. This simplifies the commit path (no more
`if (node.isWhitelistPlaceholder)` branches) and makes the node shape
consistent between running apps and placeholders.

**Next question:**

2. **Search:** Should Fuse.js remain the search backend, or is a
   simpler filter sufficient?

**Answer:** Keep Fuse.js with full fuzzy support. The fuzzy matching is
essential for window title search (e.g., finding a specific page title
within Firefox) and for handling typos during fast Alt+Tab cycles. The
2000-line bundle is a one-time cost and doesn't affect runtime performance
(the index is built once, searches are in-memory).

**Suggested improvement:** Move the Fuse.js import and index construction
into a dedicated `SearchEngine.qml` module instead of inline in
`shell.qml`. This makes the search behavior testable in isolation.

3. **Fullscreen-on-activate:** Should this be extracted to the keybind
   layer (Lua config) instead of handled inside hyprsphere?

**Answer:** Keep inside hyprsphere. The fullscreen/maximize behavior is
an integral part of the switching workflow — when you commit to a window,
it should be maximized as part of the same action. Splitting it across
Hyprland Lua config and hyprsphere QML would create timing dependencies
and make the behavior harder to configure consistently.

**Suggested improvement:** Centralize all focus+fullscreen dispatch into
a single `dispatchCommit(addr)` function instead of the current pattern
of two separate `execDetached` calls with ad-hoc prefix handling. This
makes the fullscreen behavior easier to modify and guarantees both
dispatches happen together.

4. **Three-layer model:** Is the drill-down → search → drill-down
   round-trip (layer 0→1→2→1→0) actually used by anyone, or would a
   simple two-layer model (apps + windows) be sufficient?

**Answer:** Simplify layer 2 to only show individual windows and
whitelisted placeholders — **no app groups** in search results. This
means:
   - `${toolPrefix}search (layer 2) = flat list of window nodes + whitelisted placeholders
   - `;` from layer 2 returns directly to layer 0 (no saved search state)
   - No savedLayer2Model/savedLayer2Query round-trip needed
   - No `isSearchResult` property needed on nodes
   - `;` from layer 1 also returns to layer 0 (no special case for search)

**What's removed:** `savedLayer2Model`, `savedLayer2Query` properties
and all associated branching in `drillDown()` and `cancelSearch()`.
Sphere zoom at layer 2 stays at `layer2Zoom` (1.5×) for readability.

5. **IPC vs direct binding:** Currently, Hyprland keybinds send IPC
   commands to Quickshell, which then processes them in QML. Would a
   direct QML-level keybind registration be more reliable?

**Answer:** Keep the current IPC + submap approach. The submap is
required to block Hyprland's global keybinds from firing during search
(e.g., typing `f` in search must not trigger `SUPER + F`). Without the
submap, every letter key typed into search would be intercepted by
Hyprland. There is no alternative approach in Hyprland's current API
for "pass-through when surface is focused."

The current split is correct:
   - Alt+Tab → Hyprland bind → IPC `toggle` → QML open
   - Alt-release → Submap bind → IPC `commit` → QML commit
   - Escape → Submap bind → IPC `cancel` / QML direct key handler
   - All other keys → Submap pass-through → QML `Keys.onPressed`

QML `Keys.onReleased` handles Alt-release natively (already works),
but the IPC fallback via the submap is a safety net in case the direct
handler misses the release (e.g., focus stolen during visibility toggle).
