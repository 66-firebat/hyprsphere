# PHASE_9_TESTS — Test suite for Ctrl+Enter new window spawning

**Log file:** `PHASE_9_TEST_LOG.txt` at repo root. Overwritten each run.

---

## Automated checks

### C1. `execMap` property exists

```bash
grep -c "property var execMap" hyprsphere.qml
# Expected: 1
```

### C2. `resolveExec` function exists

```bash
grep -c "function resolveExec" hyprsphere.qml
# Expected: 1
```

### C3. `openNewWindow` function exists

```bash
grep -c "function openNewWindow" hyprsphere.qml
# Expected: 1
```

### C4. Ctrl+Enter bound in key handler

```bash
grep -c "Key_Return.*ControlModifier" hyprsphere.qml
# Expected: at least 1
```

### C5. Icon reader extracts Exec= lines

```bash
grep -c "Exec=" hyprsphere.qml
# Expected: at least 1 (in the iconReader Process script)
```

### C6. `parseIcons` populates `execMap`

```bash
grep -c "execMap" hyprsphere.qml
# Expected: at least 2 (property + assignment in parseIcons)
```

---

## Manual tests

### M1. Spawn new window — app node (layer 0)

**Setup:** Have Firefox running with 1+ windows.

1. Open overlay with `ALT + Tab`
2. Tab to the Firefox app node (satellite card shows Firefox)
3. Press **Ctrl+Enter**
4. **Verify:** A new Firefox window opens
5. **Verify:** The overlay stays open
6. **Verify:** The sphere rebuilds with the new Firefox window selected
7. **Verify:** The Firefox app badge now shows `+N+1` (one more than before)

### M2. Spawn new window — window node (layer 1)

**Setup:** Have Firefox running with 2+ windows.

1. Open overlay, tab to Firefox, press `;` to drill into its windows
2. Tab to any Firefox window node
3. Press **Ctrl+Enter**
4. **Verify:** A new Firefox window opens (not a duplicate of the selected window)
5. **Verify:** The overlay stays open
6. **Verify:** The sphere shows the new window in layer 1 with the next
   sequential index

### M3. Spawn new window — search result (layer 2)

1. Open overlay, type to search for Firefox
2. Tab to a Firefox app result or window result
3. Press **Ctrl+Enter**
4. **Verify:** A new Firefox window opens
5. **Verify:** The overlay stays open
6. **Verify:** The sphere rebuilds correctly (at layer 2 with updated results)

### M4. Spawn multiple windows in succession

1. Open overlay, select Firefox
2. Press **Ctrl+Enter** 3 times rapidly
3. **Verify:** 3 new Firefox windows open
4. **Verify:** The overlay stays open throughout
5. **Verify:** The sphere shows all new windows
6. **Verify:** Each new window has a sequential index number badge

### M5. Whitelisted app spawning

**Setup:** Have a whitelisted app that is NOT currently running (e.g., disable
Blender if it's running, or ensure sioyek is not running).

1. Open overlay
2. Tab to the whitelisted app (sioyek, blender, etc.)
3. Press **Ctrl+Enter**
4. **Verify:** The app launches
5. **Verify:** The overlay stays open
6. **Verify:** The sphere rebuilds with the new window selected

### M6. Non-whitelisted app with desktop file

**Setup:** Have an app running that IS in the desktop files but NOT in the
whitelist (e.g., Ghostty, or any other app you use).

1. Open overlay, select the app
2. Press **Ctrl+Enter**
3. **Verify:** A new window of that app opens
4. **Verify:** The Exec= line from the .desktop file was used (field codes
   stripped correctly — no `%u` or `%U` in the launched command)

### M7. App without resolvable exec (no-op)

**Setup:** If possible, find or create a running window whose appId does not
have a corresponding .desktop file and is not in the whitelist. (Or simulate
by temporarily removing an entry.)

1. Open overlay, select that app
2. Press **Ctrl+Enter**
3. **Verify:** Nothing happens — overlay stays open, no crash, no launch
   attempt
4. **Verify:** The app is still selectable and committable via Alt release

### M8. Field code stripping

1. Run the icon reader script manually and check that Exec= lines have their
   field codes properly stripped
2. Expected field codes stripped: `%u`, `%U`, `%f`, `%F`, `%i`, `%c`, `%k`
3. Expected preserved: `%%` → `%`

```bash
# Manual check — look at execMap entries for common apps
grep "Exec=" /usr/share/applications/firefox.desktop | head -1
# Should show something like: Exec=firefox %u
# After stripping: firefox
```

### M9. Satellite card reflects new window

1. Open overlay, select Firefox
2. Note how many windows Firefox has (check badge)
3. Press **Ctrl+Enter**
4. **Verify:** The satellite card now shows the Firefox icon with the
   updated window count badge
5. Press `;` to drill into Firefox
6. **Verify:** The new window appears in the window list with the correct
   index number

### M10. MRU integration

1. Open overlay, select Firefox
2. Press **Ctrl+Enter** to spawn a new Firefox window
3. Press **Escape** to close the overlay
4. Press **ALT+Tab** to reopen
5. **Verify:** The spawned Firefox window is tracked in MRU (Firefox
   appears at MRU index 0 or 1 depending on focus)

### M11. No regression — existing features still work

1. **Tab cycling** — still cycles through nodes
2. **`;` drill-down** — still works at all layers
3. **Search** — still fuzzy-filters correctly
4. **Alt release** — still commits selection
5. **Ctrl+C** — still closes windows
6. **Escape** — still cancels
7. **Mouse** — click, double-click, drag all still work
8. **Badges** — still show `+N` for apps and index for windows

---

## Running all tests

```bash
echo "=== PHASE 9 TESTS $(date) ===" > PHASE_9_TEST_LOG.txt
echo "execMap property: $(grep -c 'property var execMap' hyprsphere.qml)" >> PHASE_9_TEST_LOG.txt
echo "resolveExec function: $(grep -c 'function resolveExec' hyprsphere.qml)" >> PHASE_9_TEST_LOG.txt
echo "openNewWindow function: $(grep -c 'function openNewWindow' hyprsphere.qml)" >> PHASE_9_TEST_LOG.txt
echo "Key_Return + ControlModifier: $(grep -c 'Key_Return.*ControlModifier' hyprsphere.qml)" >> PHASE_9_TEST_LOG.txt
echo "Exec= in iconReader: $(grep -c 'Exec=' hyprsphere.qml)" >> PHASE_9_TEST_LOG.txt
echo "execMap references: $(grep -c 'execMap' hyprsphere.qml)" >> PHASE_9_TEST_LOG.txt
echo "" >> PHASE_9_TEST_LOG.txt
echo "Manual tests M1 through M11 — run each and log results below:" >> PHASE_9_TEST_LOG.txt
echo "M1 (app node spawn):" >> PHASE_9_TEST_LOG.txt
echo "M2 (window node spawn):" >> PHASE_9_TEST_LOG.txt
echo "M3 (search result spawn):" >> PHASE_9_TEST_LOG.txt
echo "M4 (rapid multiple spawns):" >> PHASE_9_TEST_LOG.txt
echo "M5 (whitelist spawn):" >> PHASE_9_TEST_LOG.txt
echo "M6 (non-whitelist .desktop spawn):" >> PHASE_9_TEST_LOG.txt
echo "M7 (no-op unresolvable):" >> PHASE_9_TEST_LOG.txt
echo "M8 (field code stripping):" >> PHASE_9_TEST_LOG.txt
echo "M9 (satellite card update):" >> PHASE_9_TEST_LOG.txt
echo "M10 (MRU integration):" >> PHASE_9_TEST_LOG.txt
echo "M11 (no regression):" >> PHASE_9_TEST_LOG.txt
```
