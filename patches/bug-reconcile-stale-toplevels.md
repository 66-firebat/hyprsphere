# BUGFIX: `reconcileFocusHistory` corrupts `focusHistory` in `scheduleRebuild` due to stale toplevel data

## Severity: CRITICAL

## Symptom
Intermittently, a newly spawned window (most often observed with Firefox)
appears in the sphere but cannot be switched to, or appears to be missing
from the sphere entirely immediately after opening.

## Root Cause

`scheduleRebuild()` calls `reconcileFocusHistory()` in the **same synchronous
block** as `Hyprland.refreshToplevels()`:

```javascript
Qt.callLater(function() {
    Hyprland.refreshToplevels();    // fires async IPC, returns immediately
    reconcileFocusHistory();         // uses Hyprland.toplevels.values — STILL STALE
    var raw = buildLayer0();
    // ...
});
```

`Hyprland.refreshToplevels()` sends a `j/clients` request on Hyprland's
Unix socket and returns immediately. The response arrives **asynchronously**
via the Qt event loop — but `reconcileFocusHistory()` runs synchronously
in the same callback, **before the response can possibly arrive**.

### How reconcile corrupts focusHistory

`reconcileFocusHistory()` has two phases:

1. **Phase 2 (remove orphans):** Builds `validAddrs` from `Hyprland.toplevels.values`.
   The newly opened window is absent from the **stale** toplevel list → **removed**
   from `focusHistory`.

2. **Phase 3 (add missing):** Scans the stale toplevel list. The new window
   isn't there either → **not added back**.

The newly opened window is silently deleted from `focusHistory`. `buildLayer0()`
produces a sphere without it.

### Why `Qt.callLater` cannot fix this

`Qt.callLater(fn)` is equivalent to `setTimeout(fn, 0)` in browser JavaScript.
It queues `fn` into the Qt event loop to run when the current call stack
unwinds. Socket notifiers (IPC responses) and timer callbacks both fire in
the same event loop tick, but their relative ordering is **not guaranteed**.

If the `j/clients` response arrives before the next `poll()` cycle, both the
socket notifier and the `Qt.callLater` callback land in the same tick — either
could fire first. If the response is delayed (multiple ticks), the callback
always runs with stale data.

Adding more `Qt.callLater` nesting gives you a probabilistic band-aid (~0-16ms
per tick), not a guarantee. There is no `await refreshToplevels()` because
Quickshell's `refreshToplevels()` is fire-and-forget with no completion signal.

## The Robust Fix: Trust Events, Remove Reconcile from the Hot Path

### Why this is safe

`focusHistory` is the single source of truth for the sphere. It is mutated
by two synchronous, always-correct event handlers that fire in the same
event loop tick as the window lifecycle change:

| Event | Mutation | Reliability |
|---|---|---|
| `openwindow` (onRawEvent) | `addToFront(addr, appId)`   | Fires before the window is visible |
| `closewindow` (onRawEvent) | `removeAddress(addr)`       | Fires when the window unmaps |

These event handlers are **synchronous** — when Hyprland emits an event on
the socket, Quickshell delivers it to `onRawEvent` and the mutation happens
immediately. No async gap. No stale data.

`reconcileFocusHistory()` was added (PATCH_15) as belt-and-suspenders against
**dropped** events. But calling it in the hot path with stale data is worse
than the disease — it actively corrupts `focusHistory` by deleting valid
entries. A dropped `closewindow` leaves an orphan; running reconcile with
stale data **deletes a live window**. The cure is worse than the disease.

### The fix

1. **Remove `Hyprland.refreshToplevels()` and `reconcileFocusHistory()` from
   `scheduleRebuild()` entirely.** The rebuild simply calls `buildLayer0()`
   from the existing `focusHistory` state, which events have correctly
   maintained.

2. **Keep `reconcileFocusHistory()` in `finishOpenSwitcher()` only.** This
   runs after the `openSwitcher()` → `Qt.callLater` deferral, where the
   `refreshToplevels()` IPC has had time to complete. This is the safety
   net that catches any accumulated drift from dropped events between
   overlay sessions.

### Guarantees

- `focusHistory` is always correct in the common path (events working)
- No window can ever be falsely deleted from `focusHistory` during a rebuild
- Orphans from dropped events persist until the next overlay open, where
  full reconcile cleans them up
- The common case is 100% reliable with zero timing dependencies

## Files Modified

| File | Change |
|---|---|
| `shell.qml` | `scheduleRebuild()` — remove `Hyprland.refreshToplevels()` and `reconcileFocusHistory()` |

## Implementation

### `shell.qml` — `scheduleRebuild()` function

**Before:**

```javascript
    function scheduleRebuild() {
        if (rebuildScheduled) return;
        rebuildScheduled = true;
        Qt.callLater(function() {
            rebuildScheduled = false;
            Hyprland.refreshToplevels();
            reconcileFocusHistory();
            var raw = buildLayer0();
            rebuildToLayer(raw);
```

**After:**

```javascript
    function scheduleRebuild() {
        if (rebuildScheduled) return;
        rebuildScheduled = true;
        Qt.callLater(function() {
            rebuildScheduled = false;
            // focusHistory is maintained correctly by synchronous
            // openwindow/closewindow event handlers. No reconcile here —
            // calling reconcileFocusHistory() with potentially stale
            // toplevel data can silently delete valid windows (see bugfix).
            var raw = buildLayer0();
            rebuildToLayer(raw);
```

## Verification

1. Open the overlay (Alt+Tab) with multiple apps running
2. Ctrl+Enter on Firefox to spawn a new window
3. **Verify:** The new window appears in the sphere immediately
4. **Verify:** Tab to it and release Alt — it switches correctly
5. Repeat 10–20 times with different apps — the window should always appear
6. With `"debug": true`, check logs:
   - `openwindow` logged with correct addr/app
   - No `reconcileFocusHistory: removed=...` during rebuilds
   - `reconcileFocusHistory` only logged on overlay open (`finishOpenSwitcher`)
7. Open and close several windows while the overlay is open — sphere updates correctly
8. Close windows externally while overlay is open — sphere removes them correctly

## Edge Cases

| Scenario | Expected behavior |
|---|---|
| New window opens (spawned or manual) | `openwindow` → `addToFront` → `scheduleRebuild` → `buildLayer0` → window visible |
| Window closes | `closewindow` → `removeAddress` → `scheduleRebuild` → sphere updated |
| Multiple rapid open/close | Each event updates `focusHistory` directly; coalesced rebuild sees net state |
| Hyprland drops a `closewindow` event | Orphan in `focusHistory` persists this session; cleaned by full reconcile on next overlay open |
| Hyprland drops an `openwindow` event | Window absent until next overlay open (full reconcile Phase 3 adds it) |
| Overlay opens after many external window changes | `finishOpenSwitcher` runs full reconcile with fresh toplevel data → correct sphere |
