# Untested Scenarios

Tests that were deferred during manual testing. These are edge cases
that are rare enough to not block shipping, but should be revisited when making
changes that touch the relevant code paths.

## PATCH_2 (Window-level MRU only)

### M15. fullscreenOnActivate: false

When `fullscreenOnActivate` is set to `false`, no window should be maximised
on commit. This was tested and verified as working correctly.

**Tested:** PASS — committed windows remain un-maximised when the flag is off.

---

### CTRL+C close with multiple Firefox windows

When multiple Firefox windows are open and CTRL+C is used to close them,
Ghostty correctly appears as the pre-selected app, but ALT+RELEASE drops
the user into the same Ghostty window (no window switch occurs). This could
be intended behaviour (the current Ghostty window IS the MRU-most window
of the Ghostty app), but it's extremely difficult to reproduce reliably.

**Reason not investigated:** Extremely difficult to reproduce. The effect
requires a specific MRU ordering with multiple Firefox windows that is hard
to recreate consistently. Not blocking shipping — revisit if this pattern
becomes a recurring complaint.

## Phase 9

### M7. No-op on unresolvable app

Select an app with no `.desktop` file, no whitelist entry, and whose raw
`appId` won't run as a shell command. Ctrl+Enter should silently do nothing.

**Reason skipped:** Requires a running window whose appId has no desktop
file entry. All common GUI apps have desktop files. Hard to reproduce in
practice.

## Phase 4

### M13. Double-click commits, single-click selects

Open overlay, single-click selects a node, double-click commits. The overlay
is primarily keyboard-driven (Alt+Tab), so mouse interaction is secondary.

**Reason skipped:** Mouse clicks don't fit naturally with the keyboard-centric
Alt+Tab interaction model.

### M10. Background window close preserves selection

Drill into a 3-window app, Tab to window #3, then externally close window #1
(a background window, not the selected one). The sphere should keep window #3
selected rather than snapping to index 0.

**Reason skipped:** Requires 3 windows of the same app and external `hyprctl`
commands to trigger. Rare edge case in practice since external closes while
overlay is open are uncommon.

### M11. Selected window close snaps to MRU-most

Same setup as M10, but close the *currently selected* window instead of a
background one. Should land on index 0 (MRU-most remaining).

**Reason skipped:** Requires external `hyprctl closewindow` while overlay
is open — very rare. Phase 5 (Ctrl+C close) will have its own tests for
this behavior.

### M12. Last window close bounces to layer 0

Drill into a single-window app, close that window externally while drilled
in. Should fall back to layer 0.

**Reason skipped:** Same as M11 — external close while overlay is open is
rare. Phase 5's Ctrl+C close will cover this.

### M14. Empty-state placeholder blocks everything

With whitelist entries always configured, the "No windows" placeholder
should never appear — there are always whitelist ghost entries visible.

**Reason skipped:** Effectively unreachable in practice due to whitelist.

## Phase 6

### M14. Drill-down from layer 2, then window close

Drill into a multi-window app from layer 2, close a background window
externally, verify layer 1 rebuilds, then toggle back to layer 2 and
verify layer 2 also rebuilds with updated data.

**Reason skipped:** Cannot physically close a window while hyprsphere
overlay is active (the overlay covers all windows and grabs keyboard
focus). External `hyprctl dispatch closewindow` would be needed from
a different terminal, but closing windows during an active search
session is an extremely rare edge case.
