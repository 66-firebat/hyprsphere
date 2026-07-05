# PHASE_1_TESTS — Test suite for app grouping (layer 0)

**Log file:** `PHASE_1_TEST_LOG.txt` at repo root. Every test run
overwrites it.

---

## Automated tests

### A1. `buildLayer0()` grouping logic (Python)

**Results:** 17/17 PASS

```
[PASS] two apps → two groups
[PASS] firefox has 2 windows
[PASS] emacs has 1 window
[PASS] kitty excluded from special workspace
[PASS] firefox still present on normal workspace
[PASS] no groups when only window is on special workspace
[PASS] code appears in groups
[PASS] code has isWhitelistPlaceholder
[PASS] code has 0 windows
[PASS] firefox still in groups
[PASS] firefox is NOT a placeholder (real windows exist)
[PASS] only one group (no duplicate)
[PASS] null wayland → 'unknown' group
[PASS] unknown has 1 window
[PASS] no toplevels + no whitelist → empty array
[PASS] no toplevels + whitelist → 1 group
[PASS] whitelist entry is placeholder

Results: 17 passed, 0 failed, 17 total
```

### A2. Live toplevel enumeration (QML)

**Results:** PASS

```
[INFO] after 2nd delay, toplevels count = 3
[PASS] toplevels: count > 0 (3)
  toplevel 0: appId=com.mitchellh.ghostty title="bash" workspace=2
  toplevel 1: appId=firefox title="..." workspace=3
  toplevel 2: appId=com.mitchellh.ghostty title="..." workspace=1
[PASS] toplevels: all appIds resolved
[INFO] buildLayer0 returned 2 groups
  group 0: { appId: "com.mitchellh.ghostty", windowCount: 2 }
  group 1: { appId: "firefox", windowCount: 1 }
[PASS] all groups have valid label + icon + appId
```

### A3. Whitelist integration

**Results:** Not tested (no whitelist entries in hyprsphere.json yet).

### A4. appId resolution rebuild

**Results:** PASS

```
[PASS] scheduleRebuild: ran without error
[PASS] scheduleRebuild: sphereModel rebuilt (callback fired)
```

---

## Manual tests

### M1. Sphere shows real running apps ✅

Tested 2026-07-05. Opened ghostty + firefox. Ran:
```
qs ipc call hyprsphere toggle
```
Sphere showed 2 groups: `com.mitchellh.ghostty` and `firefox`.
One node per app (ghostty had 2 windows but showed as single node).

### M2. Whitelist entries appear at the end ⬜

Not tested — no whitelist entries configured.

### M3. Scratchpad windows excluded ⬜

Not tested.

### M4. Empty state ⬜

Not tested.

### M5. Overlay dismissal ✅

Escape closes the overlay. `qs ipc call hyprsphere toggle` reopens it.

---

## Running all tests

```bash
# Automated
echo "=== PHASE 1 TESTS $(date) ===" > PHASE_1_TEST_LOG.txt
python3 phase1_test_grouping.py >> PHASE_1_TEST_LOG.txt 2>&1
echo "" >> PHASE_1_TEST_LOG.txt
echo "=== LIVE TEST ===" >> PHASE_1_TEST_LOG.txt
QML2_IMPORT_PATH=/nix/store/b542sz5kqs7kv3lqc8pl7id0rkk4ynmg-qt5compat-6.11.0/lib/qt-6/qml \
  quickshell -p phase1_test_live.qml 2>&1 \
  | grep -E "\[(DEBUG|INFO|PASS|FAIL|WARN)\]|===" \
  >> PHASE_1_TEST_LOG.txt

# Manual — go through M1 through M5 above
```
