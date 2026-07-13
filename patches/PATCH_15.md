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

## Proposed Fix
Add a `reconcileFocusHistory()` function that compares `focusHistory` against
Hyprland's actual toplevel list (`Hyprland.toplevels.values`) and removes any
entries whose addresses don't match a real window. This runs once when the
overlay initially opens, catching any orphans that accumulated since the last
session.

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

### Placement
Call `reconcileFocusHistory()` once at the start of `finishOpenSwitcher()`,
right before `buildLayer0()` — so it runs once per overlay open, not on every
`scheduleRebuild()`. This catches orphans that accumulated since the last
time the overlay was used, without adding cost to live rebuilds.

### Replaces `initWindowIndices`
The function subsumes `initWindowIndices` completely:
- Phase 3 scans toplevels and adds missing entries (same as `initWindowIndices`)
- Phase 2 adds orphan cleanup (new functionality)
- Therefore `Component.onCompleted` should call `reconcileFocusHistory()`
  instead of `initWindowIndices()`, and `initWindowIndices()` can be removed.

### Safety
- Entries without an `address` field (whitelisted placeholders) are never
  removed — they have no real window to match against.
- Entries that DO have an address will be removed only if no toplevel with
  that address exists. This is safe because a window's address is stable for
  its lifetime.

### Cost
O(n + m) where n = focusHistory length (~50) and m = toplevel count (~50).
Runs once per overlay open — negligible.

## Files Modified
- `shell.qml`:
  - Replace `initWindowIndices()` with `reconcileFocusHistory()`
  - Replace the call in `Component.onCompleted`
  - Add call in `finishOpenSwitcher()` before `buildLayer0()`
