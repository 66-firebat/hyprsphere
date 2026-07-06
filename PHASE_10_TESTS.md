# PHASE_10_TESTS — Test suite for gated overlay visibility

**Log file:** `PHASE_10_TEST_LOG.txt` at repo root. Overwritten each run.

---

## Automated checks

### C1. `openSwitcher()` no longer sets `visible = true`

```bash
grep -c "openSwitcher" hyprsphere.qml | head -1
grep -A 15 "function openSwitcher" hyprsphere.qml | grep -c "visible = true"
# Expected: 0
```

### C2. `openSwitcher()` no longer calls `introPhaseAnim.restart()`

```bash
grep -A 15 "function openSwitcher" hyprsphere.qml | grep -c "introPhaseAnim"
# Expected: 0
```

### C3. `openSwitcher()` no longer calls `focusGrabber.forceActiveFocus()`

```bash
grep -A 15 "function openSwitcher" hyprsphere.qml | grep -c "forceActiveFocus"
# Expected: 0
```

### C4. `finishOpenSwitcher()` sets `visible = true`

```bash
grep -A 30 "function finishOpenSwitcher" hyprsphere.qml | grep -c "visible = true"
# Expected: 1
```

### C5. `finishOpenSwitcher()` has overlay-active guard

```bash
grep -A 5 "function finishOpenSwitcher" hyprsphere.qml | grep -c "overlayActive"
# Expected: at least 1
```

---

## Manual tests

### M1. First open — no stale/no-data flash

**Setup:** Fresh quickshell start (kill any existing instance first).

1. Kill quickshell: `pkill -f "quickshell.*shell.qml"` wait 2 seconds
2. Start quickshell from your setup script
3. Wait 5 seconds for quickshell to fully initialize
4. Press **Alt+Tab**
5. **Verify:** The overlay appears with the sphere fully populated —
   no brief empty/transparent state, no "No windows" placeholder flash
6. **Verify:** The entrance fade animation plays from start to finish
7. **Verify:** The sphere is correctly centered on the previously focused
   app (MRU index 1)

### M2. Re-open after Escape — identical to first open

1. Open overlay with **Alt+Tab**
2. Tab around to verify the sphere is interactive
3. Press **Escape** to close
4. Press **Alt+Tab** to reopen
5. **Verify:** The overlay appears identically to step 1 — same entrance
   animation, no stale state, no zoom jump, no selection drift
6. **Verify:** The correct app is pre-selected based on current MRU

### M3. Rapid open/close cycle — no corruption

1. Open overlay with **Alt+Tab**
2. Immediately press **Escape** (before the sphere finishes its entrance
   animation)
3. Immediately press **Alt+Tab** again
4. **Verify:** The overlay opens cleanly — no half-drawn state, no frozen
   animation, no console errors
5. Repeat steps 1-4 rapidly 5 times
6. **Verify:** Each open shows a clean, fully-populated sphere

### M4. Escape during data gathering

**Setup:** Simulate slow data by temporarily blocking the icon reader or
toplevel refresh (or just rely on timing on a slower machine).

1. Press **Alt+Tab**
2. Immediately (within the first event tick) press **Escape**
3. **Verify:** The overlay never appears (it was still in the
   `finishOpenSwitcher()` retry loop)
4. **Verify:** The Hyprland submap is reset (Alt+Tab works for other apps)
5. Press **Alt+Tab** again
6. **Verify:** The overlay opens normally on this attempt

### M5. Rapid Alt+Tab during data gathering

1. Press **Alt+Tab**
2. Before the overlay appears, press **Alt+Tab** again rapidly
   (this sends another `toggle` IPC call while `overlayActive` is true,
   which should call `advance(1)`)
3. Continue pressing **Alt+Tab** 3-4 times rapidly
4. **Verify:** The overlay eventually appears with the correct last-advanced
   selection — no double-open, no crashes
5. **Verify:** The sphere shows the expected app or window as selected

### M6. Entrance animation plays correctly

1. Open overlay with **Alt+Tab**
2. **Verify:** The entrance fade animation is smooth and consistent
   (overlay fades in over ~800ms per config)
3. **Verify:** The search bar slides up from below during the animation
4. **Verify:** The sphere nodes appear to scale up from 0.8 to 1.0 during
   the animation
5. Close and reopen 3 times
6. **Verify:** The animation is identical every time

### M7. Keyboard focus is grabbed on open

1. Open overlay with **Alt+Tab**
2. Immediately type the letter "f"
3. **Verify:** The search bar starts filtering (this proves keyboard focus
   was delivered to the overlay)
4. Press **Escape**
5. Open overlay again
6. Press **Tab**
7. **Verify:** The selection advances to the next node (proves focus was
   re-grabbed correctly)

### M8. VisibleChanged handler integration

1. Open overlay
2. **Verify:** `sphereZoom` is 1.0 (not stale from a previous layer-2
   search session)
3. Press `;` to drill into an app with windows (layer 1)
4. Press **Escape** to close
5. Open overlay again
6. **Verify:** `sphereZoom` is 1.0 — no zoom animation plays on open

### M9. No regression — existing features

1. **Tab / Shift+Tab** — still cycles through sphere nodes
2. **`;` (semicolon)** — still drills down to windows and back
3. **Type letters** — still enters search mode (layer 2)
4. **Backspace** — still removes search characters / returns to layer 0
5. **Alt release** — still commits the selected node
6. **Ctrl+C** — still closes windows at all layers
7. **Ctrl+Enter** — still spawns new windows
8. **Escape** — still closes the overlay
9. **Mouse click** — still selects nodes
10. **Mouse double-click** — still commits selection
11. **Mouse drag** — still rotates the sphere
12. **Search results** — still fuzzy-match correctly
13. **Window count badges** — still show correct counts
14. **Satellite card** — still shows the selected node's details
15. **Window close handler** — when a window closes externally, the sphere
    still unmaps/remaps the surface correctly

---

## Running all tests

```bash
echo "=== PHASE 10 TESTS $(date) ===" > PHASE_10_TEST_LOG.txt
echo "" >> PHASE_10_TEST_LOG.txt
echo "--- Automated checks ---" >> PHASE_10_TEST_LOG.txt
echo "C1 (openSwitcher no visible=true): $(grep -A 15 'function openSwitcher' hyprsphere.qml | grep -c 'visible = true')" >> PHASE_10_TEST_LOG.txt
echo "C2 (openSwitcher no introPhaseAnim): $(grep -A 15 'function openSwitcher' hyprsphere.qml | grep -c 'introPhaseAnim')" >> PHASE_10_TEST_LOG.txt
echo "C3 (openSwitcher no forceActiveFocus): $(grep -A 15 'function openSwitcher' hyprsphere.qml | grep -c 'forceActiveFocus')" >> PHASE_10_TEST_LOG.txt
echo "C4 (finishOpenSwitcher has visible=true): $(grep -A 30 'function finishOpenSwitcher' hyprsphere.qml | grep -c 'visible = true')" >> PHASE_10_TEST_LOG.txt
echo "C5 (finishOpenSwitcher has overlayActive guard): $(grep -A 5 'function finishOpenSwitcher' hyprsphere.qml | grep -c 'overlayActive')" >> PHASE_10_TEST_LOG.txt
echo "" >> PHASE_10_TEST_LOG.txt
echo "--- Manual tests ---" >> PHASE_10_TEST_LOG.txt
echo "Run each manual test (M1-M9) and log PASS/FAIL below:" >> PHASE_10_TEST_LOG.txt
echo "" >> PHASE_10_TEST_LOG.txt
echo "M1 (first open — no stale/data flash):" >> PHASE_10_TEST_LOG.txt
echo "M2 (re-open identical to first open):" >> PHASE_10_TEST_LOG.txt
echo "M3 (rapid open/close):" >> PHASE_10_TEST_LOG.txt
echo "M4 (Escape during data gathering):" >> PHASE_10_TEST_LOG.txt
echo "M5 (rapid Alt+Tab during gathering):" >> PHASE_10_TEST_LOG.txt
echo "M6 (entrance animation):" >> PHASE_10_TEST_LOG.txt
echo "M7 (keyboard focus):" >> PHASE_10_TEST_LOG.txt
echo "M8 (visibleChanged integration):" >> PHASE_10_TEST_LOG.txt
echo "M9 (no regression):" >> PHASE_10_TEST_LOG.txt
```
