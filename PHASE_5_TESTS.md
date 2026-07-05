# PHASE_5_TESTS — Test suite for Ctrl+C close

**Log file:** `PHASE_5_TEST_LOG.txt` at repo root. Overwritten each run.

---

## Manual tests

**Setup:** Have 3+ apps open, with at least one app having 2+ windows
(e.g. Firefox with 2 windows, or 2+ terminals of the same app). Also
configure whitelist entries for apps not currently running.

### M1. Ctrl+C at layer 0 closes all windows of selected app

1. Alt+Tab to open overlay at layer 0
2. Tab to an app with 2+ windows (e.g. Firefox)
3. Press Ctrl+C
4. **Verify:** Overlay stays open, no crash
5. **Verify:** All Firefox windows close (check with `hyprctl clients`)
6. **Verify:** Firefox disappears from the sphere
7. **Verify:** Selection moves to the next MRU app

### M2. Ctrl+C at layer 1 closes selected window

1. Alt+Tab, drill into a multi-window app with `;`
2. Tab to a specific window (e.g. window #2 of 3)
3. Press Ctrl+C
4. **Verify:** Overlay stays open, sphere rebuilds
5. **Verify:** The closed window is gone from the sphere
6. **Verify:** Selection moves to index 0 (MRU-most remaining window)

### M3. Ctrl+C on whitelist placeholder is no-op

1. Alt+Tab to open overlay
2. Tab to a whitelisted app that is NOT running (ghost entry)
3. Press Ctrl+C
4. **Verify:** No crash, no change — nothing happens
5. **Verify:** Overlay stays open

### M4. Ctrl+C on "No windows" placeholder is no-op

1. (If reachable: no apps + no whitelist)
2. Alt+Tab
3. Press Ctrl+C
4. **Verify:** No crash, no change

### M5. Close last window at layer 1 bounces to layer 0

1. Alt+Tab, drill into an app that has exactly 2 windows with `;`
2. Press Ctrl+C to close the selected window (only 1 remains)
3. **Verify:** Sphere stays at layer 1 (single window shown)
4. Press Ctrl+C again to close the last window
5. **Verify:** Falls back to layer 0, app is gone from sphere
6. **Verify:** Selection clamped to next MRU app

### M6. Rapid Ctrl+C doesn't cause issues

1. Alt+Tab to open overlay
2. Press Ctrl+C twice quickly
3. **Verify:** First press closes the window, second press is harmless
   (either no-op on already-closing window, or closes next selection)
4. **Verify:** No crash, overlay stays open

### M7. Ctrl+C + normal cycling still works

1. Alt+Tab to open overlay
2. Tab forward, press Ctrl+C on a window, Tab again, `;` drill, release Alt
3. **Verify:** Full keyboard loop works after close — no stuck state
4. **Verify:** The committed window is the one selected after the last close

---

## Running all tests

```bash
echo "=== PHASE 5 TESTS $(date) ===" > PHASE_5_TEST_LOG.txt
# Manual — go through M1 through M7 above
```
