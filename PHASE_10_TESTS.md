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

### C6. `fullscreenOnActivate` config reference exists

```bash
grep -c "fullscreenOnActivate" hyprsphere.qml
# Expected: at least 1
```

### C7. Path A fullscreen dispatch with address targeting

```bash
grep -A 20 "function commitSelection" hyprsphere.qml | grep -c "fullscreenOnActivate"
# Expected: at least 1
```

### C8. Path B fullscreen dispatch in whitelist chain

```bash
grep -A 10 "isWhitelistPlaceholder" hyprsphere.qml | grep -c "fullscreenOnActivate"
# Expected: at least 1
```

### C9. Uses `mode = "maximized"` in the dispatch

```bash
grep -c "maximized" hyprsphere.qml
# Expected: at least 1
```

### C10. Uses `action = "set"` in the dispatch

```bash
grep -c 'action = "set"' hyprsphere.qml
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

## Fullscreen-on-activate tests

**Prerequisites:**
- Set `"fullscreenOnActivate": true` in `hyprsphere.json` before running
  M10–M17
- For M15, set `"fullscreenOnActivate": false` (or remove it)
- Restart quickshell after each config change: `pkill -f quickshell.*shell.qml`
  then restart

---

### M10. Basic fullscreen — layer 0 app node commit

**Setup:** Have two or more apps running (e.g., Ghostty + Firefox), neither
currently maximized. `fullscreenOnActivate: true`.

1. Open overlay with **Alt+Tab**
2. Tab to an app that is NOT currently maximized
3. Release **Alt** to commit
4. **Verify:** The overlay closes
5. **Verify:** The selected window is now focused
6. **Verify:** The window is maximized (fills workspace, title bar visible)
7. Manually un-maximize the window (e.g., click the restore button)
8. Open overlay again, select a different app, release Alt
9. **Verify:** The second app's window is also maximized

---

### M11. Fullscreen — layer 1 window node commit

**Setup:** Have one app with 2+ windows open. `fullscreenOnActivate: true`.

1. Open overlay, tab to the multi-window app
2. Press `;` to drill into its windows (layer 1)
3. Tab to a specific window that is NOT maximized
4. Release **Alt** to commit
5. **Verify:** The specific window is focused and maximized
6. Open overlay again, drill down, select a different window
7. Release **Alt**
8. **Verify:** The second window is focused and maximized

---

### M12. Fullscreen — layer 2 search result commit

**Setup:** App running, `fullscreenOnActivate: true`.

1. Open overlay, type letters to search for an app
2. Tab to the app result or a window result in the search results
3. Release **Alt** to commit
4. **Verify:** The window is focused and maximized

---

### M13. Fullscreen — whitelisted app launch

**Setup:** Have a whitelisted app that is NOT currently running (e.g.,
Blender, KiCad, or Sioyek). `fullscreenOnActivate: true`.

1. Open overlay with **Alt+Tab**
2. Tab to the whitelisted app placeholder (shows the app even though it's
   not running)
3. Release **Alt** to commit (launches the app)
4. **Verify:** The app launches
5. **Verify:** After the app opens, it is focused
6. **Verify:** The window is maximized

---

### M14. Idempotency — already-maximized window stays maximized

**Setup:** `fullscreenOnActivate: true`. An app that is already maximized
(e.g., use Alt+F or the window buttons to maximise it first).

1. Open overlay with **Alt+Tab**
2. Tab to the already-maximized window
3. Release **Alt** to commit
4. **Verify:** The window is STILL maximized (not toggled off)
5. Manually un-maximize the window
6. Open overlay and commit the same window again
7. **Verify:** The window is now maximized (re-maximized correctly)

---

### M15. Feature disabled — `fullscreenOnActivate: false`

**Setup:** Set `"fullscreenOnActivate": false` (or remove the key entirely).
Restart quickshell.

1. Open overlay with **Alt+Tab**
2. Select any app that is NOT currently maximized
3. Release **Alt** to commit
4. **Verify:** The window is focused but NOT maximized (preserves existing
   behavior)
5. Repeat with a different window
6. **Verify:** No window is maximized on commit

---

### M16. Fullscreen through double-click

**Setup:** `fullscreenOnActivate: true`.

1. Open overlay with **Alt+Tab**
2. Double-click a non-maximized app node
3. **Verify:** The overlay closes, the window is focused and maximized
4. Repeat with a different app
5. **Verify:** Same behavior

---

### M17. Fullscreen through Ctrl+Enter spawn

**Setup:** `fullscreenOnActivate: true`. Have Firefox (or any spawnable app)
running.

1. Open overlay with **Alt+Tab**
2. Tab to Firefox (or another spawnable app)
3. Press **Ctrl+Enter** to spawn a new window
4. **Verify:** The overlay stays open, sphere rebuilds with the new window
5. Release **Alt** to commit
6. **Verify:** The newly spawned window is focused and maximized

---

## mruMethod tests

**Prerequisites:**
- Set `"mruMethod": "window"` in `hyprsphere.json` before running M18–M24
- For M25, set `"mruMethod": "app"` (or remove it)
- Restart quickshell after each config change
- These tests require **two windows of the same app** (e.g. two Ghostty
  terminals or two Firefox windows) AND a second app with at least one
  window

---

### M18. Basic window MRU — same app, two windows

**Setup:** Two windows of App A (e.g. Ghostty-A and Ghostty-B), one window
of App B (e.g. Firefox). `mruMethod: "window"`.

1. Focus Ghostty-A
2. Focus Ghostty-B (now Ghostty-B is current, Ghostty-A is previous)
3. Press **Alt+Tab**
4. **Verify:** The overlay shows Ghostty pre-selected (the app group
   containing the previous window Ghostty-A)
5. Release **Alt** to commit
6. **Verify:** Ghostty-A is focused (the exact previous window, not
   Ghostty-B)
7. Press **Alt+Tab** again
8. **Verify:** Ghostty-B is now pre-selected (because it was just focused)
9. Release **Alt**
10. **Verify:** Ghostty-B is focused (cycling back to the original window)

---

### M19. Window MRU across different apps

**Setup:** Ghostty-A, Ghostty-B (same app), Firefox (different app).
`mruMethod: "window"`.

1. Focus Ghostty-A
2. Focus Firefox
3. Focus Ghostty-B (now Ghostty-B is current, Firefox is previous)
4. Press **Alt+Tab**
5. **Verify:** Firefox is pre-selected (Firefox was the previous window
   before Ghostty-B)
6. Release **Alt**
7. **Verify:** Firefox is focused (the exact previous window from a
   different app)

---

### M20. Tab away from pre-selection

**Setup:** Ghostty-A, Ghostty-B, Firefox. `mruMethod: "window"`.

1. Focus Ghostty-A
2. Focus Ghostty-B (prep: B is current, A is previous)
3. Press **Alt+Tab**
4. **Verify:** Ghostty is pre-selected (owns window MRU[1] = Ghostty-A)
5. Press **Tab** to cycle to Firefox (different app)
6. Release **Alt**
7. **Verify:** Firefox is focused, and it's the MRU-most Firefox window
   (`appWindowMru["firefox"][0]`), not window MRU[1] (which is Ghostty-A)

---

### M21. Window close shifts pre-selection mid-session

**Setup:** Ghostty-A, Ghostty-B, Firefox. `mruMethod: "window"`.

1. Focus Ghostty-A
2. Focus Firefox (prep: Firefox is previous, Ghostty-A is older)
3. Focus Ghostty-B (now Ghostty-B is current, Firefox is previous)
4. Press **Alt+Tab**
5. **Verify:** Firefox is pre-selected (window MRU[1] = Firefox)
6. **Without closing the overlay**, externally close the Firefox window
   (e.g. Ctrl+W or `hyprctl dispatch closewindow address:0x...`)
7. **Verify:** The sphere rebuilds and Ghostty is now pre-selected
   (Ghostty-A is now window MRU[1] after Firefox was removed)
8. Release **Alt**
9. **Verify:** Ghostty-A is focused

---

### M22. New window during overlay open

**Setup:** Ghostty-A only (single window). `mruMethod: "window"`.

1. Focus Ghostty-A
2. Press **Alt+Tab**
3. **Verify:** Ghostty is pre-selected (only window, index 0)
4. Without closing the overlay, open a new window (e.g. Firefox or a
   second Ghostty via Ctrl+Enter)
5. **Verify:** The sphere rebuilds with the new window. The pre-selection
   may change depending on whether the new window was focused.

---

### M23. Single window — no-op commit

**Setup:** Only one window open (e.g. Ghostty-A). `mruMethod: "window"`.

1. Press **Alt+Tab**
2. **Verify:** Ghostty is pre-selected (only window, `globalWindowMru`
   length is 1, so uses index 0)
3. Release **Alt**
4. **Verify:** Ghostty-A stays focused (no-op, stays on same window)
5. Press **Alt+Tab** again
6. Tab to a whitelisted placeholder app (e.g. Blender)
7. Release **Alt**
8. **Verify:** The whitelisted app launches (placeholders work normally)

---

### M24. Whitelisted apps after running apps

**Setup:** Ghostty-A (one window), whitelisted apps configured.
`mruMethod: "window"`.

1. Press **Alt+Tab**
2. **Verify:** Ghostty is pre-selected (the only running app)
3. Press **Tab** past Ghostty
4. **Verify:** Whitelisted placeholders appear after all running apps
5. Tab to a whitelisted app and release **Alt**
6. **Verify:** The whitelisted app launches (focus by class still works)

---

### M25. mruMethod defaults to "app" when absent

**Setup:** Ghostty-A, Ghostty-B, Firefox. Remove `mruMethod` from
`hyprsphere.json` (or set `"mruMethod": "app"`). Restart quickshell.

1. Focus Ghostty-A
2. Focus Ghostty-B
3. Press **Alt+Tab**
4. **Verify:** The pre-selected app is the one at `appMru[1]` (the
   previous APP, which is Firefox or whatever was before Ghostty in
   app-level MRU — NOT Ghostty-A)
5. Release **Alt**
6. **Verify:** The MRU-most window of that app is focused (current
   behaviour)

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
echo "C6 (fullscreenOnActivate config ref): $(grep -c 'fullscreenOnActivate' hyprsphere.qml)" >> PHASE_10_TEST_LOG.txt
echo "C7 (Path A fullscreen in commitSelection): $(grep -A 20 'function commitSelection' hyprsphere.qml | grep -c 'fullscreenOnActivate')" >> PHASE_10_TEST_LOG.txt
echo "C8 (Path B fullscreen in whitelist chain): $(grep -A 10 'isWhitelistPlaceholder' hyprsphere.qml | grep -c 'fullscreenOnActivate')" >> PHASE_10_TEST_LOG.txt
echo "C9 (mode=maximized dispatch): $(grep -c 'maximized' hyprsphere.qml)" >> PHASE_10_TEST_LOG.txt
echo "C10 (action=set dispatch): $(grep -c 'action.*set' hyprsphere.qml)" >> PHASE_10_TEST_LOG.txt
echo "" >> PHASE_10_TEST_LOG.txt
echo "--- Manual tests (gated visibility) ---" >> PHASE_10_TEST_LOG.txt
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
echo "" >> PHASE_10_TEST_LOG.txt
echo "--- Manual tests (fullscreen on activate) ---" >> PHASE_10_TEST_LOG.txt
echo "Set '"'"'fullscreenOnActivate': true'"'"' in hyprsphere.json before running M10-M17." >> PHASE_10_TEST_LOG.txt
echo "" >> PHASE_10_TEST_LOG.txt
echo "M10 (layer 0 app node commit):" >> PHASE_10_TEST_LOG.txt
echo "M11 (layer 1 window node commit):" >> PHASE_10_TEST_LOG.txt
echo "M12 (layer 2 search result commit):" >> PHASE_10_TEST_LOG.txt
echo "M13 (whitelisted app launch):" >> PHASE_10_TEST_LOG.txt
echo "M14 (idempotency — already maximized):" >> PHASE_10_TEST_LOG.txt
echo "M15 (disabled — false/absent):" >> PHASE_10_TEST_LOG.txt
echo "M16 (double-click commit):" >> PHASE_10_TEST_LOG.txt
echo "M17 (Ctrl+Enter spawn):" >> PHASE_10_TEST_LOG.txt
echo "" >> PHASE_10_TEST_LOG.txt
echo "--- Manual tests (mruMethod) ---" >> PHASE_10_TEST_LOG.txt
echo "Set '\"'mruMethod': '\"'window'\"'" in hyprsphere.json before running M18-M24." >> PHASE_10_TEST_LOG.txt
echo "For M25, set '\"'mruMethod': '\"'app'\"'" (or remove it)." >> PHASE_10_TEST_LOG.txt
echo "" >> PHASE_10_TEST_LOG.txt
echo "M18 (same app, two windows):" >> PHASE_10_TEST_LOG.txt
echo "M19 (window MRU across apps):" >> PHASE_10_TEST_LOG.txt
echo "M20 (tab away from pre-selection):" >> PHASE_10_TEST_LOG.txt
echo "M21 (window close shifts pre-selection):" >> PHASE_10_TEST_LOG.txt
echo "M22 (new window during overlay):" >> PHASE_10_TEST_LOG.txt
echo "M23 (single window no-op):" >> PHASE_10_TEST_LOG.txt
echo "M24 (whitelisted apps after running):" >> PHASE_10_TEST_LOG.txt
echo "M25 (defaults to app when absent):" >> PHASE_10_TEST_LOG.txt
```
