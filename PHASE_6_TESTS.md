# PHASE_6_TESTS — Test suite for search bar + layer 2

**Log file:** `PHASE_6_TEST_LOG.txt` at repo root. Overwritten each run.

---

## Automated checks

### C1. Fuse.js import and init

```bash
grep -c 'import "lib/fuse.js" as FuseJs' hyprsphere.qml
# Expected: 1

grep -c 'new FuseJs.Fuse' hyprsphere.qml
# Expected: at least 1
```

### C2. Search bar config exists

```bash
grep -c '"searchBar"' hyprsphere.json
# Expected: 1

grep -c '"search"' hyprsphere.json
# Expected: 1
```

### C3. Search key handlers exist

```bash
grep -c 'Key_Backspace' hyprsphere.qml
# Expected: at least 1

grep -c '_handleSearchInput' hyprsphere.qml
# Expected: at least 2 (function def + call)
```

---

## Manual tests

**Setup:** Have 4-5 apps running, with at least one app having 2+ windows
(e.g. Firefox with 2 windows, or 2+ terminals of the same app). Also
configure whitelist entries for apps not currently running.

### M1. Opening overlay — layer 0 unchanged

1. Alt+Tab
2. **Verify:** Overlay opens as before — layer 0, app groups sorted by MRU
3. **Verify:** Search bar is visible at bottom-center with placeholder text
4. **Verify:** Tab, `;`, Escape, Alt release all work on layer 0 (no regression)

### M2. Typing transitions to layer 2

1. Open overlay with Alt+Tab
2. Type "fire" (or a few characters matching an app name)
3. **Verify:** Sphere transitions to layer 2 — shows filtered results
4. **Verify:** Search bar shows "fire" as typed text
5. **Verify:** Search bar border changes color (mauve when active)
6. **Verify:** Sphere zoomed in (1.5x default)

### M3. Layer 2 ordering

1. Open overlay, type a letter that matches:
   - An app that IS running
   - A whitelisted app that is NOT running
   - A window title
2. **Verify:** Results are ordered: running apps → whitelisted apps → windows
3. **Verify:** Each result type has correct icon and label display

### M4. Tab cycling in layer 2

1. Open overlay, type to get multiple results in layer 2
2. Tab forward through results
3. **Verify:** Each Tab moves to the next result
4. Tab past the last result
5. **Verify:** Wraps around to first result

### M5. Backspace in search

1. Open overlay, type "firefox"
2. Press Backspace
3. **Verify:** Search bar shows "firefo", sphere re-filters
4. Continue backspacing until empty
5. **Verify:** Returns to layer 0 (app groups), zoom resets to 1.0

### M6. Escape from layer 2

1. Open overlay, type something to enter layer 2
2. Press Escape
3. **Verify:** Overlay closes (same as layer 0 behavior)

### M7. `;` drill-down from layer 2 on an app

1. Open overlay, type to find a multi-window app
2. Tab to the app node, press `;`
3. **Verify:** Drills into layer 1 (that app's windows)
4. **Verify:** Sphere zoom is 1.0 (normal zoom for drill-down)
5. Press `;` again
6. **Verify:** Returns to layer 2 — previous search results and query restored
7. **Verify:** Sphere zooms back to 1.5x

### M8. `;` on a window node in layer 2 is no-op

1. Open overlay, type to find results that include individual windows
2. Tab to a window node (has a window title), press `;`
3. **Verify:** No-op — layer stays 2, no sphere change

### M9. Commit from layer 2 — app node

1. Open overlay, type to find a running app with multiple windows
2. Tab to the app node
3. Release Alt
4. **Verify:** Focuses the MRU-most window of that app, overlay closes

### M10. Commit from layer 2 — window node

1. Open overlay, type to find a specific window title
2. Tab to the window node
3. Release Alt
4. **Verify:** Focuses that exact window, overlay closes

### M11. Commit from layer 2 — whitelisted app

1. Open overlay, type to find a whitelisted app that is NOT running
2. Tab to the whitelisted placeholder node
3. Release Alt
4. **Verify:** Launch + focus dispatched, overlay closes

### M12. Ctrl+C from layer 2

1. Open overlay, type to find an app with multiple windows
2. Tab to the app node, press Ctrl+C
3. **Verify:** All windows of that app close (at layer 0 equivalent behavior)
4. Open overlay again, type to find a specific window
5. Press Ctrl+C
6. **Verify:** Only that window closes

### M13. Layer 2 with no results

1. Open overlay, type "zzzznonexistent"
2. **Verify:** "No results" placeholder appears
3. **Verify:** Tab does nothing (placeholder guard)
4. **Verify:** Backspace removes characters, Escape closes overlay

### M14. Drill-down from layer 2, then window close

1. Open overlay, type to find a multi-window app
2. Drill into it with `;`
3. Close a background window externally
4. **Verify:** Layer 1 sphere rebuilds (scheduleRebuild handles layer 1)
5. Press `;` to return to layer 2
6. **Verify:** Layer 2 sphere rebuilds with updated data

### M15. Layer 0/1 no regression

1. Open overlay (no typing)
2. Tab through apps, press `;` on a multi-window app
3. **Verify:** Layer 1 looks and works exactly as it did before Phase 6
4. Tab through windows, release Alt
5. **Verify:** Correct window gets focus
6. Open overlay again, drill down, press Escape
7. **Verify:** Overlay closes cleanly (no stuck state)

### M16. Multiple overlay open/close cycles

1. Open overlay, type "abc", Escape
2. Open overlay, type "xyz", Escape
3. Open overlay again
4. **Verify:** Search bar is empty, layer 0 app groups shown
5. **Verify:** No stale state from previous sessions (searchQuery reset)

---

## Running all tests

```bash
# Automated checks
echo "=== PHASE 6 TESTS $(date) ===" > PHASE_6_TEST_LOG.txt
echo "Fuse import: $(grep -c 'import \"lib/fuse.js\" as FuseJs' hyprsphere.qml)" >> PHASE_6_TEST_LOG.txt
echo "Fuse usage: $(grep -c 'new FuseJs.Fuse' hyprsphere.qml)" >> PHASE_6_TEST_LOG.txt
echo "SearchBar config: $(grep -c '\"searchBar\"' hyprsphere.json)" >> PHASE_6_TEST_LOG.txt
echo "Search config: $(grep -c '\"search\":' hyprsphere.json)" >> PHASE_6_TEST_LOG.txt

# Manual — go through M1 through M16 above
```
