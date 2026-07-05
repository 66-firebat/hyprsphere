# PHASE_2_TESTS — Test suite for MRU tracking

**Log file:** `PHASE_2_TEST_LOG.txt` at repo root. Overwritten each run.

---

## Automated tests

### B1. MRU update on focus change (Python)

Tests the MRU update logic in isolation using mock focus events and
window close events. No compositor needed.

Run: `python3 phase2_test_mru.py`

**What it tests:**
- `onActiveToplevelChanged` moves the focused app to front of `appMru`
- `onActiveToplevelChanged` moves the focused window's address to front
  of `appWindowMru[appId]`
- Multiple focus cycles produce correct MRU order (most recent first)
- Focus on a window from an already-tracked app updates its per-app
  window MRU without changing the app's position
- `closewindow>>` event prunes the address from `appWindowMru[appId]`
- When last window of an app closes, the appId is removed from `appMru`
- Empty MRU on startup (no crash when `openSwitcher` runs before any
  focus change)

**Expected results:** All 8+ tests PASS.

### B2. Live MRU tracking (QML)

Connects to live Hyprland IPC, logs MRU state before and after manual
focus changes.

Requires compositor. Run after manual_start.sh is running.

```bash
QML2_IMPORT_PATH=... quickshell -p phase2_test_live.qml 2>&1 | tee -a PHASE_2_TEST_LOG.txt
```

**What it tests:**
- `appMru` is initially empty
- After focusing a different window, `appMru` has at least 2 entries
- `appWindowMru` has entries for each tracked app
- `buildLayer0()` output can be sorted by `appMru` positions
- Pre-select index 1 when `appMru.length >= 2`

**Expected log output:**
```
[INFO] appMru before focus: []
[INFO] appMru after focus: ["firefox", "com.mitchellh.ghostty"]
[PASS] appMru: length >= 2 after focus change
[PASS] appWindowMru: firefox has entries
[INFO] MRU-sorted sphere: firefox(0), ghostty(1), ...
[PASS] pre-select index = 1 (ghostty)
```

### B3. Wrap-around behavior (QML)

Tests the `advance()` function with wrap-around enabled and disabled.

```qml
// Test with wrapAround = true:
advance(1) at last item → index wraps to 0
advance(-1) at first item → index wraps to last

// Test with wrapAround = false:
advance(1) at last item → index stays at last
advance(-1) at first item → index stays at 0
```

**Expected log output:**
```
[PASS] wrapAround=true: advance wraps forward
[PASS] wrapAround=true: advance wraps backward
[PASS] wrapAround=false: advance stops at edges
```

### B4. Pruning on window close (QML)

Manual verification that `closewindow>>` events are received and
processed. Open a window, close it, check MRU.

```bash
# Terminal 1: watch MRU log
tail -f /run/user/1000/quickshell/by-id/*/log.qslog

# Terminal 2: open and close a window
kitty &
sleep 1
pkill kitty
```

**Expected log output:**
```
[INFO] rawEvent: closewindow>>0x...
[INFO] pruned address from appWindowMru
```

---

## Manual tests

### M1. MRU pre-selection ✅⬜

1. Open 3+ apps (ghostty, firefox, emacs)
2. Focus firefox, then ghostty (so ghostty is current, firefox is previous)
3. `qs ipc call hyprsphere toggle`
4. **Verify:** Pre-selected app is firefox (MRU index 1), not ghostty
   (index 0). The satellite card shows firefox's icon/name.

### M2. Tab cycling wraps around ✅⬜

1. Open overlay with 3+ apps
2. Press Tab enough times to go past the last item
3. **Verify:** Cycling wraps back to index 0 instead of stopping.
4. Test backward cycling with Shift wraps the other way.

### M3. Window close prunes MRU ✅⬜

1. Open a terminal, note its appId (e.g. `com.mitchellh.ghostty`)
2. Close the terminal
3. `qs ipc call hyprsphere toggle`
4. **Verify:** The closed app does not appear on the sphere. If it was
   the only window of that app, the appId is gone from `appMru`.

### M4. Fresh start MRU empty ✅⬜

1. Restart quickshell (kill all, `./manual_start.sh`)
2. Immediately `qs ipc call hyprsphere toggle` (before any focus change)
3. **Verify:** Sphere shows apps sorted alphabetically, index 0 selected.
   No crash or console errors.

### M5. Wrap-around config ✅⬜

1. Set `"cycling": { "wrapAround": false }` in hyprsphere.json
2. Close and reopen config (restart quickshell)
3. Open overlay, press Tab at the last item
4. **Verify:** Selection stops at the last item, does not wrap.
5. Restore `"wrapAround": true` in hyprsphere.json

---

## Running all tests

```bash
# Automated
echo "=== PHASE 2 TESTS $(date) ===" > PHASE_2_TEST_LOG.txt
python3 phase2_test_mru.py >> PHASE_2_TEST_LOG.txt 2>&1

# Live QML (requires running hyprland)
QML2_IMPORT_PATH=... quickshell -p phase2_test_live.qml >> PHASE_2_TEST_LOG.txt 2>&1

# Manual — go through M1 through M5 above
```
