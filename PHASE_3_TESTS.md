# PHASE_3_TESTS — Test suite for key handling

**Log file:** `PHASE_3_TEST_LOG.txt` at repo root. Overwritten each run.

---

## Automated tests

### C1. Shortcut conflict check (manual script)

Verifies that no `Shortcut { sequence: "Escape" }` block remains.

```bash
grep -c 'Shortcut' hyprsphere.qml
# Expected: 0
```

---

## Manual tests

### M1. Alt+Tab opens overlay ✅

1. Press Alt+Tab
2. **Verify:** Overlay appears with the sphere and apps.
3. Press Escape to close.

### M2. Tab cycles forward while Alt held ✅

1. Hold Alt, press Tab to open overlay
2. While still holding Alt, press Tab again
3. **Verify:** Selection moves to the next app. No sphere rebuild/refresh.
4. Repeat a few times — each Tab moves one step forward.

### M3. Shift+Tab cycles backward while Alt held ⬜

1. Open overlay with Alt+Tab
2. While holding Alt, press Shift+Tab
3. **Verify:** Selection moves to the previous app.

### M4. Tab wraps around ⬜

1. Open overlay with 3+ apps
2. Hold Alt and Tab until you pass the last item
3. **Verify:** Selection wraps from last back to first (or vice versa).

### M5. `;` drill calls drillDown ⬜

1. Open overlay
2. Press `;`
3. **Verify:** No crash or console errors. (drillDown is no-op until Phase 4.)

### M6. Escape closes overlay ✅

1. Open overlay
2. Press Escape
3. **Verify:** Overlay closes with exit animation.
4. Press Alt+Tab again
5. **Verify:** Overlay opens fresh (no stale state from previous session).

### M7. Alt release calls commit (no-op) ⬜

1. Open overlay
2. Release Alt
3. **Verify:** No crash. (commitSelection is no-op until Phase 4.)

### M8. No key conflicts ⬜

1. Open overlay
2. Rapidly Alt+Tab multiple times, then Escape, then Alt+Tab again
3. **Verify:** All inputs work — no stuck selections, no double-fire,
   no Escape-fails-after-Tab.

### M9. overlayActive prevents rebuild ⬜

1. Open overlay (observe log for `buildLayer0 returned X groups`)
2. Press Tab while holding Alt
3. **Verify:** `buildLayer0 returned X groups` does NOT appear in the
   log again. The overlay was already open, so `toggle()` returned
   early after calling `advance(1)`.

---

## Recorded results

- M1: ✅ Alt+Tab opens, Escape closes
- M2: ✅ Tab cycles forward while Alt held (via IPC advance)
- M3: ✅
- M4: ✅
- M5: ✅ (no-op, no crash)
- M6: ✅
- M7: ✅ (no-op, no crash)
- M8: ⬜
- M9: ⬜

---

## Running all tests

```bash
# Shortcut conflict check
echo "Shortcut count: $(grep -c 'Shortcut' hyprsphere.qml)" >> PHASE_3_TEST_LOG.txt

# Manual — go through M1 through M9 above
```
