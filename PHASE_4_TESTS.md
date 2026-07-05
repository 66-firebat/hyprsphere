# PHASE_4_TESTS — Test suite for selection & commit logic

**Log file:** `PHASE_4_TEST_LOG.txt` at repo root. Overwritten each run.

---

## Automated tests

### D1. Layer state machine (Python)

Tests the drill-down logic, layer transitions, and commit-address resolution
in isolation. No compositor needed.

Run: `python3 phase4_test_state_machine.py`

**What it tests:**

| # | Test | Expected |
|---|---|---|
| 1 | Empty sphereModel → drillDown is no-op | No crash, layer stays 0 |
| 2 | Single-window app → drillDown allowed | Drill-down always works, ≥1 window |
| 3 | Whitelist placeholder → drillDown no-op | `isWhitelistPlaceholder` guard works |
| 4 | Multi-window app drill down → layer becomes 1 | `layer === 1` |
| 5 | Drill-down nodes have `address`, `title`, `icon`, `label` | Enriched node shape |
| 6 | Drill-down nodes sorted by per-app MRU | Most-recent window first |
| 7 | Toggle back from layer 1 → layer becomes 0 | `layer === 0` |
| 8 | Toggle back centers on previously-drilled app | `selectedAppIndex` matches |
| 9 | Commit at layer 0 resolves MRU-most window address | Correct address chosen |
| 10 | Commit at layer 1 uses `node.address` directly | Correct address chosen |
| 11 | Commit on placeholder → no dispatch, starts close | Early return |
| 12 | Commit on whitelist placeholder → exec dispatch | `Hyprland.dispatch("exec ...")` |
| 13 | `advance()` is no-op on placeholder sphere | Early return |
| 14 | `closeSequence.running` guard prevents double-commit | Early return |
| 15 | `scheduleRebuild()` at layer 1 rebuilds window list | Layer preserved |
| 16 | `scheduleRebuild()` at layer 1 when app gone → fallback to layer 0 | Layer reset |
| 17 | Whitelist placeholder drill-down → no crash | `sphereModel` unchanged, layer stays 0 |

### D2. Live layer switching (QML)

Connects to live Hyprland IPC, tests drill-down with real toplevel data.

Run:
```bash
QML2_IMPORT_PATH=... quickshell -p phase4_test_live.qml 2>&1 | tee -a PHASE_4_TEST_LOG.txt
```

**What it tests:**
- Open overlay, verify layer 0 app groups appear
- Press `;` on a multi-window app → sphere transitions to window list
- Verify each window node's `title` is the window's actual title
- Press `;` again → sphere returns to app groups
- Satellite card shows `title` at layer 1, `label` at layer 0

**Expected log output:**
```
[INFO] openSwitcher: layer=0
[PASS] layer 0: app groups present
[INFO] drillDown: layer=1, app=firefox, windows=2
[PASS] layer 1: window nodes have title + address + icon + label
[INFO] drillDown (toggle): layer=0
[PASS] toggle back: app groups restored
[PASS] satellite shows title at layer 1
[PASS] satellite shows label at layer 0
```

### D3. Click-to-select (QML)

Tests that clicking a node selects it and double-clicking commits it.

```
[PASS] single click: selectedAppIndex updated
[PASS] single click: centerOnApp called (rotation animated)
[PASS] double click: commitSelection called
[PASS] double click: focus dispatched or close started
```

---

## Manual tests

**Setup:** open 2-3 disposable terminal windows (e.g. Ghostty) plus one
multi-window app (e.g. Firefox with 2+ windows) so you have both single-
and multi-window apps to test against. Also configure one whitelist entry
for an app that is NOT currently running (e.g. `"appId": "code"` if VS
Code isn't open).

### M1. Alt+Tab pre-selects previous app

1. Focus app A, then app B
2. Alt+Tab
3. **Verify:** Sphere opens centered on app A (previous), not B (current)

### M2. `;` drill-down shows window titles

1. Center on the multi-window app, press `;`
2. **Verify:** Sphere rebuilds with one node per window
3. **Verify:** Each card shows the window title, not the app name
4. **Verify:** Satellite card also shows the window title
5. Tab forward through windows, release Alt
6. **Verify:** The specific selected window gets focus

### M3. `;` toggle back to layer 0

1. Drill into an app (M2 step 1-2)
2. Press `;` again
3. **Verify:** Sphere returns to layer 0 app groups
4. **Verify:** Previously-drilled app is centered (not index 0)

### M4. Single-window app drill-down

1. Center on the single-window terminal, press `;`
2. **Verify:** Drills in and shows one node with that window's title
   (this is the case that was broken two revisions ago — test deliberately)
3. **Verify:** `;` again toggles back to layer 0

### M5. Whitelist ghost drill-down (no crash)

1. If Firefox is whitelisted, quit Firefox entirely so only the whitelist
   placeholder remains
2. Alt+Tab, Tab to the Firefox ghost entry
3. Press `;`
4. **Verify:** No-op — no crash, no blank sphere, `;` does nothing
5. Release Alt or Escape to close — still works normally

### M6. Tab/Shift+Tab wraps at both layers

1. At layer 0, Tab past the last app
2. **Verify:** Wraps to index 0, not stuck at the end
3. Drill into a multi-window app; Tab past the last window
4. **Verify:** Wraps to index 0
5. Test Shift+Tab wraps backward at both layers

### M7. Layer-0 commit focuses MRU window

1. Multi-window app (e.g. Firefox with 3 windows)
2. Focus its 2nd window manually first (so 2nd is MRU-most for that app)
3. Alt+Tab to the app at layer 0 (no drill), release Alt
4. **Verify:** Focuses the 2nd window (MRU-most), not just "the first window"

### M8. Layer-1 commit focuses exact window

1. Drill into a multi-window app, Tab to a non-default window (not index 0)
2. Release Alt
3. **Verify:** That exact window gets focus, not the MRU-most one

### M9. Escape + Alt-release race

1. Hold Alt+Tab, press Escape, then release Alt as fast as possible
2. Run `hyprctl activewindow` before and after
3. **Verify:** If the guard works, no `focuswindow` dispatch happens
   (you stay on whatever was focused before Alt+Tab)
4. **Note:** Repeat 5-10× — timing-sensitive. Can also run window churn
   in a background terminal while you test:
   `while true; do hyprctl dispatch exec kitty; sleep 2; hyprctl dispatch
   closewindow address:$(hyprctl clients -j | jq -r '.[0].address'); sleep 2; done`

### M10. Background window close preserves selection

1. Drill into a 3-window app, Tab to window #3
2. From a different terminal:
   `hyprctl dispatch closewindow address:<window #1>`
   (get address via `hyprctl clients -j | jq -r '.[].address'`)
3. **Verify:** Sphere still shows window #3 selected, not snapped to index 0
   (this was the regression fixed this round)

### M11. Selected window close snaps to MRU-most

1. Same setup as M10, but close the address of your *currently selected*
   window instead of a background one
2. **Verify:** Lands on index 0 (MRU-most remaining), not an error or stale card

### M12. Last window close bounces to layer 0

1. Drill into a single-window app, close that window externally while drilled in
2. **Verify:** Falls back to layer 0, not an empty layer-1 sphere
3. If that was the only running app, confirm it lands on "No windows" placeholder

### M13. Double-click commits, single-click selects

1. Open overlay via mouse (only click, no keyboard)
2. Single-click a different card
3. **Verify:** Selection moves, satellite updates — no dispatch yet
4. Double-click the same card (or another)
5. **Verify:** It commits and closes (focus dispatched)

### M14. Empty-state placeholder blocks everything

1. Close every window (or test in a fresh session with nothing open)
2. Alt+Tab
3. **Verify:** "No windows" placeholder is shown
4. **Verify:** Tab, `;`, and Alt-release are all no-ops — no crash
5. **Verify:** Escape closes the overlay cleanly

### M15. Whitelist launch vs. focus (both states)

1. **Not running:** Tab to a whitelisted-but-not-running app, release Alt
2. **Verify:** The app is launched via `exec`, overlay closes
3. **Running:** Open overlay again (app is now running), Tab to it, release Alt
4. **Verify:** Focuses its MRU-most window — does NOT launch a second instance

---

## Running all tests

```bash
# Automated
echo "=== PHASE 4 TESTS $(date) ===" > PHASE_4_TEST_LOG.txt
python3 phase4_test_state_machine.py >> PHASE_4_TEST_LOG.txt 2>&1

# Live QML (requires running hyprland + quickshell)
QML2_IMPORT_PATH=... quickshell -p phase4_test_live.qml >> PHASE_4_TEST_LOG.txt 2>&1

# Manual — go through M1 through M15 above
```
