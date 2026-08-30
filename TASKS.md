# TASKS — hyprsphere bug & problem backlog

Priority-ordered list of every bug, inconsistency, and cleanup item identified
during a full repository audit. Ordering: **P0** = breaks core functionality,
**P1** = high-impact/correctness, **P2** = medium (latent bugs, docs/code
mismatches), **P3** = low (cleanup, hygiene, minor polish).

Key to source locations:
- `shell.qml` — main app (1665 lines)
- `binds.js` / `effects.js` / `rotations.js` — QML script imports
- `hyprsphere.json` — config
- `potential_bugs.md` — prior audit ("Finding N" references)

---

## Active work — feature implementation (in progress)

- **Layer 0 app grouping** — `patches/layer0_grouping.md`. Refactor layer 0 from
  flat per-window to one node per app group; Tab-cycling shows each app's
  MRU-most window. Prerequisite for peek.
- **Peek utility** — `patches/peek_utility.md`. Snapshot preview of the selected
  window via `ScreencopyView` (single frame, keyboard-only triggers); removes
  `slashPreview`/`focusOnTab`.

---

## P0 — Breaks core functionality

### 1. `openwindow` only rebuilds the sphere when spawn-tracking matches
- **Location:** `shell.qml`, `onRawEvent` (`openwindow` branch)
- **Ref:** `potential_bugs.md` Finding 2 (marked unresolved)
- **Problem:** `scheduleRebuild()` is only called inside
  `if (window._pendingSpawnAppId === appId)`. Any window opened *manually*
  while the overlay is open (Ctrl+N in Firefox, dialogs, file choosers,
  external launches) is added to `focusHistory` via `addToFront()` but never
  reflected in `sphereModel` until the overlay is closed and reopened.
  The `closewindow` branch rebuilds unconditionally — an asymmetry.
- **Fix:** Always call `scheduleRebuild()` on `openwindow`; keep spawn-tracking
  (`_pendingSpawnAddr`) as a separate concern from rebuild-triggering.

### 2. Icon reader only scans NixOS paths → overlay can hang on non-NixOS
- **Location:** `shell.qml` `iconReader` command (~line 316)
- **Problem:** Only scans `/run/current-system/sw/share/applications/*.desktop`
  and `$HOME/.local/share/applications/*.desktop`. On Arch/Debian/Fedora
  (all documented in `README.md`), `iconMap` stays empty.
- **Downstream:** combined with task #3, `finishOpenSwitcher()` loops forever
  and Alt+Tab hangs.
- **Fix:** Also scan `/usr/share/applications`, `/usr/local/share/applications`,
  and honor `$XDG_DATA_DIRS` (or use `Quickshell.DesktopEntries` if available).

### 3. `finishOpenSwitcher()` infinite retry on icon-read failure
- **Location:** `shell.qml`, `finishOpenSwitcher()`
- **Ref:** `potential_bugs.md` Finding 7 (unresolved)
- **Problem:** `if (!iconReady) Qt.callLater(...)` retries forever with no
  guard. If the icon reader returns empty/fails, the overlay never opens.
- **Fix:** Add a retry counter/timeout and fall through with fallback icons.

---

## P1 — High-impact / correctness

### 4. Stale-toplevel race only *mitigated*, not eliminated
- **Location:** `shell.qml`, `scheduleRebuild()` + `refreshDelayTimer`
- **Ref:** `patches/bug-reconcile-stale-toplevels.md` vs `potential_bugs.md` Finding 1
- **Problem:** The patch doc's *robust* fix was to remove
  `reconcileFocusHistory()` from the hot path (trust synchronous events).
  The actual code instead keeps it in the hot path, deferred by a 66 ms
  `refreshDelayTimer` — which the same doc explicitly calls "a probabilistic
  band-aid… not a guarantee." `potential_bugs.md` then marks this Timer approach
  RESOLVED, contradicting the patch doc.
- **Fix:** Decide and implement consistently — either remove reconcile from the
  hot path (patch doc's recommendation) or accept/justify the Timer deferral
  and fix both docs to agree.

### 5. `dispatchCommit` docs contradict actual code
- **Location:** `shell.qml`, `dispatchCommit()`
- **Ref:** `potential_bugs.md` Finding 11 (stale)
- **Problem (a):** `potential_bugs.md` says "Fullscreen was removed from the
  serialized command," but fullscreen is still appended to the `&&` chain.
- **Problem (b):** The inline comment says "Focus runs last," but actual order is
  `submap reset → focus → fullscreen` (fullscreen is last). Intent (focus before
  fullscreen) is correct; the comment is wrong.
- **Fix:** Correct the comment and reconcile `potential_bugs.md`.

### 6. Hiding the `PanelWindow` may break IPC (self-documented lesson violated)
- **Location:** `shell.qml` (commit/cancel/close paths set `window.visible = false`),
  plus the `visible=false → callLater visible=true` toggle workaround
- **Ref:** `WARNINGS.md` #6 and #12
- **Problem:** `WARNINGS.md` explicitly documents that hiding a Quickshell
  `PanelWindow` (`visible: false`) pauses the engine and breaks `IpcHandler`.
  The current code hides the window on every commit/cancel. If the lesson still
  holds, the *next* `toggle()` IPC may never arrive.
- **Fix:** Verify against current Quickshell behavior; if real, switch to an
  input-region/exclusion approach or keep the window mapped and only fade it.

### 7. Address ingestors don't use the canonical normalizer
- **Location:** `shell.qml`, `addToFront()` / `moveToFront()` / `removeAddress()`
- **Ref:** `potential_bugs.md` Finding 4 (unresolved)
- **Problem:** These use inline `address.indexOf("0x") === 0 ? address : "0x" + address`
  instead of `normalizeAddress()`. A decimal address would be corrupted into
  `"0x" + decimalString` (wrong address). Latent today, active if any caller
  ever passes a toplevel decimal.
- **Fix:** Route all three through `normalizeAddress()`.

---

## P2 — Medium (latent bugs, docs/code mismatches)

### 8. `closewindow` rebuilds even when nothing was removed
- **Location:** `shell.qml`, `onRawEvent` (`closewindow` branch)
- **Ref:** `potential_bugs.md` Finding 5 (unresolved)
- **Problem:** A transient window that was never added (filtered by empty appId)
  still triggers a full rebuild, which can consume `_pendingSpawnAppId` and break
  spawn auto-selection.
- **Fix:** Make `removeAddress()` return a boolean; skip `scheduleRebuild()`
  when it returns false.

### 9. Whitelist dedup is case-sensitive
- **Location:** `shell.qml`, `buildLayer0()` / `buildSearchDatabase()`
- **Ref:** `potential_bugs.md` Finding 6 (unresolved)
- **Problem:** `firefox` vs `Firefox` vs `firefox-esr` won't dedup → duplicate
  placeholder node; committing it launches a second instance.
- **Fix:** Case-insensitive `appId` comparison (and ideally also handle
  reverse-DNS vs short-name via `StartupWMClass`).

### 10. `_pendingSpawnAppId`/`_pendingSpawnAddr` cleared unconditionally
- **Location:** `shell.qml`, `refreshDelayTimer.onTriggered`
- **Ref:** `potential_bugs.md` Finding 8 (unresolved)
- **Problem:** Any rebuild (including close-triggered) clears spawn-tracking
  state, so a pending spawn can lose its auto-select.
- **Fix:** Only clear when consumed or on timeout; distinguish spawn-triggered
  rebuilds from others.

### 11. `focusOnTab` config key is dead/unimplemented
- **Location:** `hyprsphere.json` (`"focusOnTab": false`) + `README.md`
- **Problem:** A whole "Known Limitations" section documents `focusOnTab`, but
  it is never referenced in `shell.qml` or `binds.js`.
- **Fix:** Implement it, or remove the config key + README section.

### 12. Dead config keys documented but not wired
- **Location:** `shell.qml` card/satellite rendering + `README.md` config tables
- **Problem:** The following are documented but have no effect:
  - `appCard.labelBgColor` / `appCard.labelTextColor` (bg hardcoded `"transparent"`,
    text hardcoded `"#8C8C8C"`)
  - `satellite.selectedBackground` (no SVG decoration; see #19)
  - `windowCountBadge.satellite` / `windowCountBadge.nonSelected` (non-selected
    badge hardcoded `visible: false`; satellite badge hardcoded to window nodes only)
- **Fix:** Wire them up or remove them from the README/JSON.

### 13. Config default-value mismatches (JSON vs README vs code fallback)
- **Problem:**
  - `baseSphereRadius`: code fallback 368, JSON/README 360
  - `satellite.iconSize`: code fallback 40, JSON/README 160
  - `nonSelectedIconSize`: code fallback 55, JSON/README 110
  - `appCard.labelBgOpacity`: JSON 0.5, README 0.60
  - README documents `animations.sphereAutoRotateIntervalMs` / `sphereRotateSpeed`
    that don't exist anywhere
- **Fix:** Make code fallbacks match JSON, and prune README entries for
  nonexistent keys.

### 14. Whitelist `exec` quoting is fragile (Lua/shell injection)
- **Location:** `shell.qml`, `dispatchExec()` / whitelist commit fallback in `binds.js`
- **Problem:** `exec` is interpolated into `hl.dsp.exec_cmd("…")` and a nested
  `bash -c` string. Double quotes in `exec` (see the `emacs` entry) can break the
  Lua string or shell. The fallback branch builds a deeply nested quoted command.
- **Fix:** Use a single robust escaping path; consider passing via environment
  or an argument array instead of string interpolation.

### 15. `dispatchFocusByClass` fixed 0.5 s sleep + class mismatch
- **Location:** `shell.qml`, `dispatchFocusByClass()`
- **Problem:** Sleeps 0.5 s then focuses by `class:`, racing slow launches.
  `class` may not equal reverse-DNS `appId`.
- **Fix:** Poll/wait for the window, or dispatch focus by the actual spawned
  address once known.

---

## P3 — Low (cleanup, hygiene, polish)

### 16. `rotations.js` is dead code
- **Location:** `rotations.js`
- **Problem:** Never imported or called anywhere, yet `manual_start.sh` symlinks it.
- **Fix:** Delete the file + symlink (or actually use it).

### 17. `bracketIcon()` is broken and unused
- **Location:** `shell.qml` (~line 296)
- **Problem:** Defined but never called. Thresholds 6/12–11/12 all return the
  same glyph, and the returned glyphs don't match the commented Nerd Font
  codepoints (U+EE00–U+EE0B).
- **Fix:** Delete, or fix the mapping and wire it to the badge if the feature
  is intended.

### 18. `assets/selected.svg` is unreferenced
- **Location:** `assets/selected.svg`
- **Problem:** Never referenced in any source file; still symlinked by
  `manual_start.sh`. Related to dead `satellite.selectedBackground` (task #12).
- **Fix:** Use it for the satellite decoration or delete it + the symlink.

### 19. `debug: true` left enabled in production config
- **Location:** `hyprsphere.json`
- **Problem:** 40+ `console.log` statements spam output during normal use.
- **Fix:** Default to `false`.

### 20. `searchBar` colors are bright orange (`#ff4400`) — likely debug placeholders
- **Location:** `hyprsphere.json` `searchBar.*`
- **Problem:** Text, border, placeholder, active border all `#ff4400`, clashing
  with the documented Catppuccin Mocha theme.
- **Fix:** Restore theme-consistent colors or confirm intentional.

### 21. Search-timer object leak
- **Location:** `shell.qml`, `_handleSearchInput()`
- **Problem:** Each keystroke `Qt.createQmlObject` creates a new `Timer` parented
  to `window`; the previous one is only `.running=false`'d, never destroyed →
  timers accumulate for the session.
- **Fix:** Use a single persistent `Timer` with a restart, or destroy the old one.

### 22. Test coverage is grep-count / re-implemented logic
- **Location:** `PHASE_*_TEST_LOG.txt`, `phase1_test_grouping.py`, `phase2_test_mru.py`
- **Problem:** Phase 6/7/9/10 "tests" only count keyword occurrences; the Python
  tests re-implement the logic instead of exercising the actual QML. Many edge
  cases are explicitly deferred (`UNTESTED.md`).
- **Fix:** Add a real QML integration harness and cover the deferred cases.

### 23. Git history hygiene
- **Location:** repo history (e.g., `|.git| = 4` commits)
- **Problem:** The `gitdir:` pointer file appears to have been committed/echoed
  at some point; this is a submodule-style checkout.
- **Fix:** Clean history / confirm the repo metadata layout is intentional.

### 24. Minor cosmetic/robustness notes
- Search input regex allows single-char match but appends full `event.text`
  (fine for ASCII, odd for IME/multichar).
- `_extRotDirX`/`_extRotDirY` use `Math.sign(diff)`, so a zero net rotation
  won't resume `extendRotation`.
- Duplicated select-by-address logic in `drillDown` layer 1→0 and 2→0 branches
  (candidate for a shared helper).
