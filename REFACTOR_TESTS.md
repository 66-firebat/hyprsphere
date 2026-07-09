# REFACTOR_TESTS.md — Rigorous tests for the 2D focus tracking system

> **Purpose:** These tests validate that the `focusHistory`-based 2D tracking
> system correctly maintains MRU order at both the app level (dimension 1)
> and the window level (dimension 2). Each test includes setup, steps,
> expected result, and what to check in the debug logs.

---

## How to Read the Logs

All debug logs are prefixed with `[hyprsphere]`. Key log patterns:

```
activeToplevelChanged: addr=XXXXXX app=appId       → compositor focused a window
moveToFront: XXXXXX app=appId                       → window moved to [0] in focusHistory
addToFront: XXXXXX app=appId                        → new window added to focusHistory
removeAddress: XXXXXX                               → window removed from focusHistory
buildLayer0: N groups, order=[appId(N), ...]        → current layer 0 state with window counts
openwindow: addr=XXXXXX app=appId                   → new window opened
closewindow: addr=XXXXXX                             → window closed
commitSelection: app=appId addr=XXXXXX layer=N      → Alt-release commit
spawnAutoSelect: ... FOUND by ... at idx=N          → Ctrl+Enter spawn auto-selection
_executeSearch: N results for "query"                → search results count
```

---

## Test A — Basic MRU Tracking

### A1: Single app, single window — focus tracking

**Setup:** Ghostty running (1 window).

1. **Check logs** for:
   ```
   activeToplevelChanged: addr=XXXXXX app=com.mitchellh.ghostty
   moveToFront: XXXXXX app=com.mitchellh.ghostty
   ```
   This should appear at startup when Quickshell detects the active window.

2. **Verify:** `focusHistory.length === 1` with one Ghostty entry.

**Expected:** One entry in focusHistory with Ghostty's address at index [0].

---

### A2: Two apps — focus switches between them

**Setup:** Ghostty (current), Firefox running.

1. **Click on Firefox** to focus it.
2. **Check logs:**
   ```
   activeToplevelChanged: addr=AAAAAA app=firefox
   moveToFront: AAAAAA app=firefox
   ```
3. **Click back on Ghostty.**
4. **Check logs:**
   ```
   activeToplevelChanged: addr=BBBBBB app=com.mitchellh.ghostty
   moveToFront: BBBBBB app=com.mitchellh.ghostty
   ```
5. **Verify focusHistory order:** `[ghostty_addr, firefox_addr]`

**Expected:** Most recently focused app is at index [0]. Previous app at [1].
`appOrder()` = `["com.mitchellh.ghostty", "firefox"]`

---

### A3: Three apps — deep MRU ordering

**Setup:** Ghostty, Firefox, Blender all running.

1. Focus Ghostty → Firefox → Blender → Firefox → Ghostty
2. **Verify focusHistory order:** `[ghostty, firefox, blender]`
3. **Verify `appOrder()`:** `["com.mitchellh.ghostty", "firefox", "blender"]`

**Expected:** Each focus move puts that window at [0] and pushes others down.
`appOrder()` deduplicates consecutive same-app entries.

---

## Test B — Layer 0 (App List)

### B1: Alt+Tab opens to correct pre-selection

**Setup:** Ghostty (current), Firefox (previous), Blender (older).

1. Press **Alt+Tab**.
2. **Check:** The pre-selected app should be the previous app (Firefox).
3. **Verify in logs:**
   ```
   buildLayer0: 3 groups, order=["com.mitchellh.ghostty(1)","firefox(N)","blender(N)"]
   finishOpenSwitcher: 3 nodes, pre-selected index 1
   ```

**Expected:** Pre-selected index 1 = Firefox (the previous app).

---

### B2: Tab cycles through apps only

**Setup:** Same as B1.

1. Alt+Tab → overlay opens, Firefox selected.
2. Press **Tab** → moves to next app (Blender).
3. Press **Tab** → wraps to first app (Ghostty).
4. Press **Shift+Tab** → goes back to Blender.

**Expected:** Tab moves through `appOrder()` = `[ghostty, firefox, blender]`.
Each Tab press moves exactly one app forward. No window-level cycling.

---

### B3: App badge shows correct window count

**Setup:** Firefox with 3 windows.

1. Alt+Tab → overlay opens.
2. **Check** the satellite card badge for Firefox.
3. **Verify in logs:**
   ```
   buildLayer0: ... order=[..., "firefox(3)", ...]
   ```

**Expected:** Firefox shows `+3` badge (total window count).

---

## Test C — Layer 1 (Drill-Down)

### C1: `;` drills into app's windows

**Setup:** Firefox with 3 windows, Ghostty.

1. Alt+Tab → select Firefox → press **`;`**.
2. **Verify:** Sphere shows individual Firefox windows, sorted by MRU.
3. **Verify in logs:**
   ```
   drillDown 0→1: app=firefox windows=3 sel=1
   ```
   The pre-selected index should be 1 (the "other" window, not the commit target).

**Expected:** Layer 1 shows all Firefox windows in `appWindowOrder["firefox"]` order
(MRU-most first). Pre-selects index 1 (the second MRU-most window).

---

### C2: Window badge shows correct index

**Setup:** Same as C1.

1. At layer 1, check the satellite card badge for each window.
2. The MRU-most window should show badge `1`, the second shows `2`, etc.

**Expected:** Badge shows 1-based index within `windowsForApp(appId)`.
MRU-most window = index 0 → badge `1`. Second window = index 1 → badge `2`.

---

### C3: `;` returns to layer 0

**Setup:** Same as C1.

1. At layer 1, press **`;`**.
2. **Verify:** Returns to layer 0 (app list).

**Expected:** `drillDown 1→0` logged, sphere shows app list, layer = 0.

---

## Test D — Layer 2 (Search)

### D1: Typing letters enters search mode

**Setup:** Multiple apps running.

1. Alt+Tab → type **"fire"**.
2. **Verify:** Sphere enters layer 2, shows matching results.
3. **Verify in logs:**
   ```
   _executeSearch: N results for "fire"
   ```

**Expected:** Search results show individual windows matching "fire" (from label,
title, or appId). No app groups. Results sorted by Fuse.js score.

---

### D2: Search results show windows only (no app groups)

**Setup:** Same as D1.

1. Type **"fire"**.
2. **Verify:** Every result node has `isWindowNode: true`.
3. **Verify in logs:** No `running-app` type entries in results.

**Expected:** Layer 2 shows only individual windows and whitelisted placeholders.
No app group aggregation.

---

### D3: `;` from search drills into app's windows

**Setup:** Search for "fire" with at least one result.

1. Select a Firefox search result → press **`;`**.
2. **Verify:** Drops into layer 1 showing all Firefox windows.

**Expected:** `drillDown 2→1: app=firefox windows=N` logged.

---

### D4: `;` from layer 1 returns to layer 0 (not search)

**Setup:** At layer 1 after drilling from search.

1. Press **`;`** from layer 1.
2. **Verify:** Returns to layer 0 (app list), not search results.

**Expected:** `drillDown 1→0` logged. No saved search state.

---

## Test E — Commit (Alt Release)

### E1: Layer 0 commit focuses MRU-most window

**Setup:** Firefox with 3 windows (window_A = MRU-most, window_B, window_C).

1. Alt+Tab → select Firefox → press **Alt-release**.
2. **Verify:** Firefox window_A is focused (the MRU-most window).
3. **Verify in logs:**
   ```
   commitSelection: app=firefox addr=AAAAAA layer=0
   moveToFront: AAAAAA app=firefox
   ```

**Expected:** The commit target is `windowsForApp("firefox")[0]` (MRU-most).
`moveToFront()` updates focusHistory.

---

### E2: Layer 1 commit focuses the specific selected window

**Setup:** Same as E1.

1. Alt+Tab → select Firefox → `;` → select window_C → **Alt-release**.
2. **Verify:** Firefox window_C is focused.
3. **Verify in logs:**
   ```
   commitSelection: app=firefox addr=CCCCCC layer=1
   moveToFront: CCCCCC app=firefox
   ```

**Expected:** The commit target is the specific window node's address.

---

### E3: Next Alt+Tab after commit pre-selects the previous app

**Setup:** Ghostty (current), Firefox (previous).

1. Commit to Firefox (Alt-release).
2. Wait for Firefox to focus.
3. Press Alt+Tab again.
4. **Verify:** Ghostty is pre-selected (it was the app you LEFT).

**Expected:** After committing to Firefox:
```
focusHistory = [firefox_addr, ghostty_addr, ...]
appOrder() = ["firefox", "com.mitchellh.ghostty", ...]
```
Next Alt+Tab pre-selects `appOrder()[1]` = Ghostty.

---

## Test F — Ctrl+Enter (Spawn New Window)

### F1: Layer 0 — spawn stays on same app, badge increments

**Setup:** Firefox with 3 windows (showing `+3` badge).

1. Alt+Tab → select Firefox → press **Ctrl+Enter**.
2. **Verify:** Firefox stays selected. Badge shows `+4`.
3. **Verify in logs:**
   ```
   openNewWindow: app=firefox
   addToFront: XXXXXX app=firefox
   openwindow: addr=XXXXXX app=firefox
   buildLayer0: ... "firefox(4)" ...
   spawnAutoSelect: ... FOUND appNode by appId at idx=0
   ```

**Expected:** New window added to focusHistory. BuildLayer0 shows `firefox(4)`.
Auto-selection keeps Firefox selected at index 0.

---

### F2: Layer 2 (search) — spawn selects the new window

**Setup:** Search for "fire" (several Firefox results visible).

1. Select a Firefox result → press **Ctrl+Enter**.
2. **Verify:** The new window appears as a search result and is selected.
3. **Verify in logs:**
   ```
   spawnAutoSelect: ... FOUND by address at idx=0
   spawnAutoSelect: sphere[0] app=firefox addr=XXXXXX isWin=Y
   ```

**Expected:** Auto-selection finds the new window's address in the search results
and selects it at index 0.

---

### F3: Multiple Ctrl+Enter — each spawn increments and auto-selects

**Setup:** Same as F1.

1. Press Ctrl+Enter 3 times on Firefox.
2. **Verify:** After each spawn, Firefox stays selected, badge increments
   (3→4→5→6).
3. **Verify in logs:**
   ```
   buildLayer0: ... "firefox(4)" ...
   buildLayer0: ... "firefox(5)" ...
   buildLayer0: ... "firefox(6)" ...
   ```

**Expected:** Each Ctrl+Enter adds one window to focusHistory. Badge reflects
total count. Selection never jumps to a different app.

---

## Test G — Ctrl+C (Close Window)

### G1: Close app at layer 0 — app removed from sphere

**Setup:** Blender (1 window), Ghostty.

1. Alt+Tab → select Blender → press **Ctrl+C**.
2. **Verify:** Blender's window closes. Blender disappears from sphere
   (or reverts to whitelisted placeholder if in whitelist).
3. **Verify in logs:**
   ```
   closewindow: addr=XXXXXX
   removeAddress: XXXXXX app=blender
   buildLayer0: N groups, order=[..., "blender(0)", ...] (if whitelisted)
   ```

**Expected:** `removeAddress` removes the address from focusHistory.
buildLayer0 shows Blender with 0 windows (whitelisted) or absent entirely.

---

### G2: Close specific window at layer 1 — only that window removed

**Setup:** Firefox with 2 windows.

1. Alt+Tab → Firefox → `;` → select window_B → **Ctrl+C**.
2. **Verify:** window_B closes. window_A remains.
3. **Check logs for** `closewindow` and `removeAddress`.
4. **Verify:** `buildLayer0` shows `firefox(1)`.

**Expected:** Only the closed window is removed from focusHistory. The other
window remains. Badge decrements from `+2` to `+1`.

---

## Test H — Cancel (Escape)

### H1: Escape closes overlay, no focus change

**Setup:** Any state.

1. Alt+Tab → press **Escape**.
2. **Verify:** Overlay closes. Focus stays on the current window (no jump).
3. **Verify in logs:**
   ```
   cancelSwitch
   ```

**Expected:** Overlay closes cleanly. Current focus undisturbed.

---

## Test I — Edge Cases

### I1: Whitelisted app with no windows — always visible

**Setup:** Blender whitelisted, not running.

1. Alt+Tab → **Verify:** Blender appears in app list with `(0)` windows.
2. Badge is hidden (not visible since `windowCount < 1`).

**Expected:** Whitelisted apps always appear regardless of running state.
Badge hidden. Node has `isWhitelistPlaceholder: true`.

---

### I2: Only whitelisted apps (no running windows)

**Setup:** No apps running, whitelist has entries.

1. Alt+Tab → **Verify:** Sphere shows whitelisted apps. No "No windows"
   placeholder.

**Expected:** Whitelisted apps fill the sphere. No empty-state issues.

---

### I3: Window opens via external means (not hyprsphere)

**Setup:** Ghostty running.

1. Open a terminal and run `firefox &`.
2. **Verify:** Firefox window appears. openwindow event fires.
3. **Check logs for:**
   ```
   addToFront: XXXXXX app=firefox
   ```

**Expected:** Even without `_pendingSpawnAppId`, the window is added to
focusHistory. No auto-selection (since no pending spawn), but the window
is tracked.

---

### I4: Window closes externally (not via Ctrl+C)

**Setup:** Firefox running.

1. Close Firefox by clicking its window close button.
2. **Verify:** closewindow event fires.
3. **Check logs for:**
   ```
   closewindow: addr=XXXXXX
   removeAddress: XXXXXX app=firefox
   ```

**Expected:** Window removed from focusHistory. If overlay is visible, sphere
rebuilds without the closed window.

---

### I5: Escape with `maximizeOnEscape: true`

**Setup:** Firefox (current), `maximizeOnEscape: true` in hyprsphere.json.

1. Alt+Tab → press **Escape**.
2. **Verify:** Overlay closes. Firefox is maximized.
3. **Check logs for:** `cancelSwitch` (no separate maximize log currently).

**Expected:** Escape maximized the origin window (Firefox).

---

### I6: `\` key preview at layer 0

**Setup:** Ghostty (current), Firefox (previous).

1. Alt+Tab → press **`\`**.
2. **Verify:** Sphere advances to next app + the previewed window appears
   behind the overlay.
3. **Verify:** Overlay stays visible and interactive (visibility toggle).

**Expected:** `\` = advance(1) + dispatchFocus + visibility toggle.
Overlay returns focus after the brief hide/re-show cycle.

---

## Test J — Stress / Concurrency

### J1: Rapid Ctrl+Enter (3+ spawns in quick succession)

**Setup:** Firefox with 3 windows.

1. Alt+Tab → select Firefox.
2. Press Ctrl+Enter as fast as possible 5 times.
3. **Verify:** After the burst settles, Firefox shows `+8` (3 + 5).
4. **Verify:** No infinite retry loops in logs.
5. **Verify:** Layer 0 selection is still on Firefox.

**Expected:** All 5 spawns are tracked. Badge increments to 8. No crash,
no infinite loops, no selection jump.

---

### J2: Rapid Ctrl+C on multi-window app

**Setup:** Firefox with 5 windows.

1. Alt+Tab → select Firefox → press Ctrl+C rapidly.
2. **Verify:** All Firefox windows close. Firefox disappears from sphere
   (or shows whitelisted placeholder).
3. **Verify:** No stale `+N` badge.
4. **Verify:** No infinite retry loops.

**Expected:** All closewindow events processed. removeAddress called for each.
buildLayer0 eventually shows 0 windows.

---

### J3: Tab while a spawn is in-flight (Ctrl+Enter then immediately Tab)

**Setup:** Firefox selected.

1. Press Ctrl+Enter → immediately press Tab before sphere rebuilds.
2. **Verify:** Tab advances to next app. When spawn completes, the auto-selection
   finds and selects the spawned window.

**Expected:** Tab should work during spawn in-flight. Auto-selection may or
may not succeed depending on timing, but no crash or infinite loop.

---

## Test K — Multiple Monitors / Workspaces

### K1: Windows on different workspaces

**Setup:** Firefox on workspace 1, Ghostty on workspace 2.

1. Switch to workspace 1 → Alt+Tab.
2. **Verify:** Both Firefox AND Ghostty appear on the sphere.

**Expected:** Workspace scope is ALL workspaces. Not filtered by current
workspace.

---

### K2: Special workspace (scratchpad) windows excluded

**Setup:** A window moved to a special workspace (e.g., `special:scratchpad`).

1. Alt+Tab → **Verify:** The special workspace window does NOT appear.

**Expected:** `buildLayer0` skips windows where `workspace.name` starts with
`"special:"`. These windows are excluded from the sphere.

---

## Test Log Format

When running tests, record results in this format:

```
## Test A1 — Single app focus tracking
Date: 2026-07-08
Result: PASS / FAIL
Notes: [any observations]
Logs: [relevant log excerpts]
```
