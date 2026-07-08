# PATCH_4_TESTS — focusOnTab live window preview

**Log file:** `PATCH_4_TEST_LOG.txt` at repo root. Overwritten each run.

---

## Automated checks

### C1. `_mruFrozen` property declared

```bash
grep -c 'property bool _mruFrozen' shell.qml
# Expected: 1
```

### C2. `_targetAddrForNode` function defined

```bash
grep -c 'function _targetAddrForNode' shell.qml
# Expected: 1
```

### C3. `_targetAddrForNode` called from `commitSelection`

```bash
grep -A 5 'function commitSelection' shell.qml | grep -c '_targetAddrForNode'
# Expected: at least 1
```

### C4. `_targetAddrForNode` called from `advance`

```bash
grep -A 10 'function advance' shell.qml | grep -c '_targetAddrForNode'
# Expected: at least 1
```

### C5. `_mruFrozen = true` in `openSwitcher`

```bash
grep -A 10 'function openSwitcher' shell.qml | grep -c '_mruFrozen'
# Expected: at least 1
```

### C6. `onActiveToplevelChanged` returns early when frozen

```bash
grep -A 3 'function onActiveToplevelChanged' shell.qml | grep -c '_mruFrozen'
# Expected: at least 1
```

### C7. `_mruFrozen = false` in `commitSelection` and `cancelSwitch`

```bash
grep -c '_mruFrozen = false' shell.qml
# Expected: at least 2
```

### C8. Visibility toggle pattern in `advance`

```bash
grep -A 5 'visible = false' shell.qml | grep -c 'Qt.callLater'
# Expected: at least 1 (from advance) + existing occurrences
```

### C9. `focusOnTab` config key

```bash
grep -c 'focusOnTab' hyprsphere.json
# Expected: 1
```

### C10. No inline targeting logic remains in `commitSelection`

```bash
grep -A 3 '_pendingSpawnAppId === node.appId' shell.qml
# Expected: 0 (moved to _targetAddrForNode)
```

---

## Manual tests

### T1. Basic focusOnTab — initial pre-selection focus

**Setup:** Two apps running (e.g. Ghostty + Firefox). `focusOnTab: true`.

1. Focus Ghostty, then switch to Firefox
2. Press **Alt+Tab**
3. **Verify:** Ghostty appears focused behind the overlay (it was the
   previous window, globalWindowMru[1])
4. Release **Alt**
5. **Verify:** Ghostty stays focused (commit is no-op if same window)

| PASS / FAIL | Notes |
|---|---|

### T2. Tab cycling — each tab focuses the target

**Setup:** Ghostty-A, Ghostty-B, Firefox. `focusOnTab: true`.

1. Focus Ghostty-B, then switch to Ghostty-A
2. Press **Alt+Tab** — Ghostty-B should be pre-selected and focused
3. Press **Tab** — Firefox should become focused behind the overlay
4. Press **Tab** — Ghostty-A should become focused
5. Release **Alt** — Ghostty-A stays focused

| PASS / FAIL | Notes |
|---|---|

### T3. Multi-window app — pre-selected app window focus

**Setup:** Ghostty-A, Ghostty-B (same app), Firefox. `focusOnTab: true`.

1. Focus Ghostty-A, then Firefox, then Ghostty-B
2. Press **Alt+Tab** — Firefox pre-selected (globalWindowMru[1]), Firefox focused
3. Tab to Ghostty — Ghostty-A focused (appWindowMru["ghostty"][0], MRU-most)
4. Release **Alt** — Ghostty-A stays focused

| PASS / FAIL | Notes |
|---|---|

### T4. Drill-down — first window focused

**Setup:** Ghostty with 2+ windows. `focusOnTab: true`.

1. Press **Alt+Tab**, tab to Ghostty
2. Press **;** — layer 1 shows windows, first window (second MRU-most)
   is focused behind the overlay
3. Tab to a different window — that window becomes focused
4. Press **;** again — returns to layer 0, pre-selected app's target focused
5. Release **Alt** — commit targets the last previewed window

| PASS / FAIL | Notes |
|---|---|

### T5. Click to select and focus

**Setup:** Multiple apps. `focusOnTab: true`.

1. Press **Alt+Tab**
2. **Click** a different node on the sphere
3. **Verify:** That node's target window becomes focused behind the overlay

| PASS / FAIL | Notes |
|---|---|

### T6. MRU freeze — no feedback loops

**Setup:** Ghostty-A, Ghostty-B, Firefox. `focusOnTab: true`.

1. Focus Ghostty-A, press **Alt+Tab** — Firefox pre-selected and focused
2. Tab to Ghostty — Ghostty-A focused
3. Press **Tab** rapidly — each advance focuses a different window
4. **Verify:** The sphere selection doesn't jump around — it follows your
   tab advances linearly without feedback from the focus dispatches

| PASS / FAIL | Notes |
|---|---|

### T7. Rapid cycling — stability test

**Setup:** 5+ windows across multiple apps. `focusOnTab: true`.

1. Press **Alt+Tab**
2. **Hold Tab** to cycle rapidly through all nodes
3. **Verify:** No stutter, no freeze, no crash
4. **Verify:** Each window appears briefly behind the overlay
5. Let go of Tab, release **Alt**
6. **Verify:** The correct window is committed (the one last shown)

| PASS / FAIL | Notes |
|---|---|

### T8. Search (layer 2) — preview focus on results

**Setup:** Multiple apps. `focusOnTab: true`.

1. Press **Alt+Tab**, type letters to enter search
2. Tab through search results — each result's window is focused
3. Release **Alt** — correct window committed

| PASS / FAIL | Notes |
|---|---|

### T9. commitSelection no-op when already focused

**Setup:** `focusOnTab: true`.

1. Open overlay, tab to an app — it becomes focused behind overlay
2. Release **Alt**
3. **Verify:** The overlay closes cleanly, no double-dispatch issues,
   window stays focused

| PASS / FAIL | Notes |
|---|---|

### T10. focusOnTab: false — existing behaviour preserved

**Setup:** `focusOnTab: false`.

1. Open overlay, tab through nodes
2. **Verify:** No window focus changes behind the overlay
3. Release **Alt** — focus dispatched only on commit (existing behaviour)

| PASS / FAIL | Notes |
|---|---|

### T11. Rapid cycling under heavy load (performance)

**Setup:** 10+ windows, `focusOnTab: true`.

1. Press **Alt+Tab**
2. Hold **Tab** for 5 full cycles through the sphere
3. **Verify:** Hyprland doesn't stall, no IPC backlog
4. Release **Alt** — committed window is correct

| PASS / FAIL | Notes |
|---|---|

### T12. Escape during focusOnTab session

**Setup:** `focusOnTab: true`.

1. Open overlay, tab a few times (various windows focused behind overlay)
2. Press **Escape**
3. **Verify:** Overlay closes, no window is left in a weird focus state,
   MRU unfrozen correctly for next session

| PASS / FAIL | Notes |
|---|---|

### T13. Fullscreen + focusOnTab interaction

**Setup:** `fullscreenOnActivate: true`, `focusOnTab: true`.

1. Open overlay, tab between apps
2. **Verify:** Live preview focuses the target window (it may get maximised
   by the `onActiveToplevelChanged` fullscreen fallback if not frozen)
3. Release **Alt** — commit dispatches fullscreen as normal (harmless no-op)

| PASS / FAIL | Notes |
|---|---|

---

## Running all tests

```bash
echo "=== PATCH_4 TESTS $(date) ===" > PATCH_4_TEST_LOG.txt
echo "" >> PATCH_4_TEST_LOG.txt
echo "--- Automated checks ---" >> PATCH_4_TEST_LOG.txt
echo "C1 (_mruFrozen property): $(grep -c 'property bool _mruFrozen' shell.qml)" >> PATCH_4_TEST_LOG.txt
echo "C2 (_targetAddrForNode fn): $(grep -c 'function _targetAddrForNode' shell.qml)" >> PATCH_4_TEST_LOG.txt
echo "C3 (targetAddr in commit): $(grep -A 5 'function commitSelection' shell.qml | grep -c '_targetAddrForNode')" >> PATCH_4_TEST_LOG.txt
echo "C4 (targetAddr in advance): $(grep -A 10 'function advance' shell.qml | grep -c '_targetAddrForNode')" >> PATCH_4_TEST_LOG.txt
echo "C5 (_mruFrozen in openSwitcher): $(grep -A 10 'function openSwitcher' shell.qml | grep -c '_mruFrozen')" >> PATCH_4_TEST_LOG.txt
echo "C6 (onActiveToplevel frozen guard): $(grep -A 3 'function onActiveToplevelChanged' shell.qml | grep -c '_mruFrozen')" >> PATCH_4_TEST_LOG.txt
echo "C7 (_mruFrozen false count): $(grep -c '_mruFrozen = false' shell.qml)" >> PATCH_4_TEST_LOG.txt
echo "C8 (focusOnTab config): $(grep -c 'focusOnTab' hyprsphere.json)" >> PATCH_4_TEST_LOG.txt
echo "" >> PATCH_4_TEST_LOG.txt
echo "--- Manual tests ---" >> PATCH_4_TEST_LOG.txt
echo "Run each manual test (T1-T13) and log PASS/FAIL below:" >> PATCH_4_TEST_LOG.txt
echo "" >> PATCH_4_TEST_LOG.txt
echo "T1 (initial pre-selection focus):" >> PATCH_4_TEST_LOG.txt
echo "T2 (tab cycling focus):" >> PATCH_4_TEST_LOG.txt
echo "T3 (multi-window app focus):" >> PATCH_4_TEST_LOG.txt
echo "T4 (drill-down focus):" >> PATCH_4_TEST_LOG.txt
echo "T5 (click to focus):" >> PATCH_4_TEST_LOG.txt
echo "T6 (MRU freeze stability):" >> PATCH_4_TEST_LOG.txt
echo "T7 (rapid cycling stability):" >> PATCH_4_TEST_LOG.txt
echo "T8 (search preview focus):" >> PATCH_4_TEST_LOG.txt
echo "T9 (commit no-op):" >> PATCH_4_TEST_LOG.txt
echo "T10 (focusOnTab false):" >> PATCH_4_TEST_LOG.txt
echo "T11 (heavy load cycling):" >> PATCH_4_TEST_LOG.txt
echo "T12 (Escape during session):" >> PATCH_4_TEST_LOG.txt
echo "T13 (fullscreen interaction):" >> PATCH_4_TEST_LOG.txt
```
