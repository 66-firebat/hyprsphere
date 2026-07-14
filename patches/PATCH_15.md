# PATCH 15 — FocusHistory Reconciliation Guard

## Motivation
When `openNewWindow` (Ctrl+Enter) spawns a new window via `Quickshell.execDetached`,
the `openwindow` Hyprland event is expected to fire and call `addToFront()` to
register the window in `focusHistory`. Similarly, when a window closes, the
`closewindow` event should fire and call `removeAddress()`.

However, Hyprland can occasionally drop these events (or they arrive out of
order during rapid workspace transitions, high compositor load, or ghostty
opening multiple terminals at once). When a `closewindow` event is missed, the
corresponding entry remains in `focusHistory` as an **orphan** — a node that
appears in the sphere but whose address no longer corresponds to a real window.
Committing on this node calls `dispatchFocus("")` which is a no-op, so nothing
happens.

## Root Cause Analysis

There are two independent gaps where an orphan can survive:

### Gap A — Cross-session orphan (initial open)
A closewindow event is dropped while the overlay is closed. The orphan sits in
`focusHistory` until the next time the overlay opens.

### Gap B — Mid-session orphan (live rebuild)
A closewindow event is dropped while the overlay IS visible. The overlay is
hidden and re-shown via `scheduleRebuild()`, but `scheduleRebuild()` calls
`buildLayer0()` directly — it never reconciles. The orphan survives the rebuild
and appears in the currently visible overlay.

## Proposed Fix
Add a `reconcileFocusHistory()` function that compares `focusHistory` against
Hyprland's actual toplevel list (`Hyprland.toplevels.values`) and removes any
entries whose addresses don't match a real window.

### Algorithm
```
reconcileFocusHistory():
  // Phase 1: build a set of valid addresses from the compositor
  validAddrs = {}
  for each toplevel t in Hyprland.toplevels:
    if t is on a non-special workspace:
      addr = normalizeAddress(t.address)
      validAddrs[addr] = true

  // Phase 2: remove orphans from focusHistory
  for each entry in focusHistory (reverse):
    if entry has an address AND addr ∉ validAddrs:
      remove entry from focusHistory

  // Phase 3: add any missing toplevels (belt-and-suspenders)
  for each toplevel t in Hyprland.toplevels:
    if t is on a non-special workspace:
      addr = normalizeAddress(t.address)
      if addr not in focusHistory:
        push { address, appId, title } to focusHistory
```

### Placement (covers both gaps)
Call `reconcileFocusHistory()` in two places:

1. **`finishOpenSwitcher()`** — before `buildLayer0()` → catches Gap A on every
   full overlay open (Alt press → IPC toggle).

2. **`scheduleRebuild()`** — before `buildLayer0()` → catches Gap B on every
   live rebuild triggered by `closewindow` / `openwindow` events while the
   overlay is visible.

Both calls are before the sphere is rebuilt, so the update is seen immediately.

### Replaces `initWindowIndices`
The function subsumes `initWindowIndices` completely:
- Phase 3 scans toplevels and adds missing entries (same as `initWindowIndices`)
- Phase 2 adds orphan cleanup (new functionality)
- Therefore `Component.onCompleted` calls `reconcileFocusHistory()`
  instead of `initWindowIndices()`, and `initWindowIndices()` is removed.

### Safety
- Entries without an `address` field (whitelisted placeholders) are never
  removed — they have no real window to match against.
- Entries that DO have an address will be removed only if no toplevel with
  that address exists. This is safe because a window's address is stable for
  its lifetime.

### Cost
O(n + m) where n = focusHistory length (~50) and m = toplevel count (~50).
Runs once per overlay open and once per live rebuild — negligible.

## Status
**Already partially implemented.** The implementation in the current codebase
has:
- `reconcileFocusHistory()` function ✓
- Called from `finishOpenSwitcher()` ✓ (Gap A)
- Called from `Component.onCompleted` ✓ (startup)
- `initWindowIndices()` removed ✓

**Missing:** Call from `scheduleRebuild()` (Gap B).

## Files Modified (remaining)
- `shell.qml`:
  - Add `reconcileFocusHistory();` at the top of `scheduleRebuild()`,
    right before `var raw = buildLayer0();`
