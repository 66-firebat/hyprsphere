# PHASE_7_TESTS — Test suite for icon resolution

**Log file:** `PHASE_7_TEST_LOG.txt` at repo root. Overwritten each run.

---

## Automated checks

### C1. DesktopEntries import

```bash
grep -c 'import Quickshell.DesktopEntries' hyprsphere.qml
# Expected: 1
```

### C2. resolveIcon function exists

```bash
grep -c 'function resolveIcon' hyprsphere.qml
# Expected: 1
```

### C3. heuristicLookup usage

```bash
grep -c 'heuristicLookup' hyprsphere.qml
# Expected: at least 1
```

### C4. buildLayer0 uses resolveIcon

```bash
grep -c 'resolveIcon' hyprsphere.qml
# Expected: at least 2 (function def + usage in buildLayer0/buildSearchDatabase)
```

---

## Manual tests

**Setup:** Have a variety of apps running with different appId patterns:
- Simple name match (e.g., `"firefox"`)
- Reverse-DNS name (e.g., `"com.mitchellh.ghostty"`, `"org.mozilla.firefox"`)
- Apps without desktop files (e.g., custom scripts, terminal-based TUI)

### M1. Running app icons — layer 0

1. Open overlay with `ALT + Tab`
2. **Verify:** Each app node shows its correct application icon, not the
   generic "application-x-executable" fallback
3. Focus on apps with reverse-DNS appIds (Ghostty, etc.) — do they show
   the correct icon?

### M2. Running app icons — layer 1

1. Open overlay, drill into a multi-window app with `;`
2. **Verify:** Layer 1 window nodes show the same icon as the parent app
   group (inherited, not re-resolved)

### M3. Running app icons — layer 2 search

1. Open overlay, type something to enter layer 2
2. **Verify:** Both app nodes and window nodes in search results show
   correct icons

### M4. Whitelist icons unchanged

1. Open overlay, check your whitelisted apps (e.g., blender, kicad)
2. **Verify:** They show the icon specified in `hyprsphere.json`, not
   whatever `heuristicLookup()` would return

### M5. Apps without desktop entries

1. Find or launch an app that has no `.desktop` file (e.g., a raw terminal
   script or `xprop` run from a terminal)
2. Open overlay
3. **Verify:** The app shows the generic `"application-x-executable"`
   fallback — no crash, no blank icon

### M6. Satellite card icon

1. Open overlay
2. Tab through apps, check the satellite detail card
3. **Verify:** The satellite card shows the same icon as the sphere node
   (they use the same `model.icon` source)

### M7. No regression — MRU, search, drill-down all still work

1. Open overlay, type a search, drill down, commit — verify all Phase 6
   features still work correctly
2. Icons are display-only — they should not affect any functional behavior

---

## Running all tests

```bash
echo "=== PHASE 7 TESTS $(date) ===" > PHASE_7_TEST_LOG.txt
echo "DesktopEntries import: $(grep -c 'import Quickshell.DesktopEntries' hyprsphere.qml)" >> PHASE_7_TEST_LOG.txt
echo "resolveIcon def: $(grep -c 'function resolveIcon' hyprsphere.qml)" >> PHASE_7_TEST_LOG.txt
echo "heuristicLookup: $(grep -c 'heuristicLookup' hyprsphere.qml)" >> PHASE_7_TEST_LOG.txt
echo "resolveIcon usage: $(grep -c 'resolveIcon' hyprsphere.qml)" >> PHASE_7_TEST_LOG.txt

# Manual — go through M1 through M7 above
```
