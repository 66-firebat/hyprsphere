# Untested Scenarios

Tests that were deferred during Phase 4 manual testing. These are edge cases
that are rare enough to not block shipping, but should be revisited when making
changes that touch the relevant code paths.

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
