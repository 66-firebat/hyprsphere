# BUGFIX: newly spawned windows are inserted at MRU index 0 instead of the MRU-next slot (index 1)

## Severity: MEDIUM

## Symptom

When spawning a new application from the overlay (Ctrl+Enter, or Alt release
on a whitelisted app that is not currently running), the new window is placed
at the **front** of the list (index 0 / MRU-most) instead of the **MRU-next**
position (index 1).

This is most visible on a whitelisted node whose app has no running windows:

- The whitelist placeholder sits at the tail of `sphereModel`
  (`buildLayer0Flat()` appends placeholders after all live windows).
- On spawn the placeholder disappears and the new window jumps to index 0,
  displacing the currently-focused app.
- It should instead slot into index 1, leaving the currently-focused app at
  index 0 — i.e. the MRU-next slot that `finishOpenSwitcher()` already
  pre-selects on a normal open (`selectedAppIndex = sphereModel.length >= 2 ? 1 : 0`).

## Root Cause

`focusHistory` is the MRU-first source of truth. Its only insertion primitive
for a newly opened window was `addToFront()` in `shell.qml`, called from the
`openwindow` raw-event handler:

```javascript
focusHistory.unshift({ address: normAddr, appId: appId, title: title || "" });
```

`unshift()` always inserts at index 0. With `"layer_0": "ungrouped"`,
`buildLayer0Flat()` maps `focusHistory` order 1:1 onto `sphereModel`, so the
new window became `sphereModel[0]`.

This also contradicted the documented intent (README "Ctrl+Enter MRU focus
behavior"): spawning from the app group at layer 0 should leave the existing
MRU order intact so that the original MRU-most window remains the commit
target. Because the new window was pushed to `focusHistory[0]`, it became the
MRU-most window of its app instead.

### Why the MRU sentinel did not already handle this

While the overlay is open, `openSwitcher()` sets `_mruCommitAddr = "blocked"`,
and `onActiveToplevelChanged` deliberately ignores focus changes in that state.
That suppresses `moveToFront()` but **not** `addToFront()` — focus tracking was
frozen, yet list insertion was not. The spawned window therefore still jumped
to the front. This asymmetry is the bug.

## Method / Approach

Change exactly one insertion in `addToFront()` from "insert at 0" to
"insert at the MRU-next slot (index 1)", and do nothing else.

Key properties of this approach:

1. **No conditionals.** The insertion is unconditional. While the overlay is
   open the MRU sentinel is `"blocked"`, so `onActiveToplevelChanged` does not
   call `moveToFront()` and the window stays at index 1 — the desired result.
2. **Ordinary operation is unchanged.** When the overlay is closed the new
   window receives focus normally; `onActiveToplevelChanged` → `moveToFront()`
   promotes it to index 0. So transient index-1 placement self-corrects for
   every normal (non-overlay) window open.
3. **Empty history is safe.** `Math.min(1, focusHistory.length)` clamps to 0
   when the list is empty, which is the only available slot.
4. **No sentinel reset.** An earlier candidate approach also cleared
   `_mruCommitAddr` in the whitelist branch of `commitSelection()`. That was
   rejected: clearing the sentinel would let the spawned window's own focus
   event run `moveToFront()` and promote it to 0, defeating the fix for the
   Alt-release path.

This is deliberately a one-expression change (plus a diagnostic log field). It
touches no other file.

## Files Modified

| File | Change |
|---|---|
| `shell.qml` | `addToFront()` — insert at `Math.min(1, focusHistory.length)` via `splice()` instead of `unshift()` |

## Implementation

### `shell.qml` — `addToFront()`

**Before:**

```javascript
    // --- Mutation: add new entry (on window open) ---
    function addToFront(address, appId, title) {
        if (!address || !appId) return;
        var normAddr = address.indexOf("0x") === 0 ? address : "0x" + address;
        // Remove existing entry if present (dedup safeguard)
        for (var i = 0; i < focusHistory.length; i++) {
            if (focusHistory[i].address === normAddr) {
                focusHistory.splice(i, 1);
                break;
            }
        }
        focusHistory.unshift({ address: normAddr, appId: appId, title: title || "" });
        log("addToFront: " + normAddr.substring(normAddr.length - 6) + " app=" + appId);
    }
```

**After:**

```javascript
    // --- Mutation: insert new entry (on window open) at the MRU-next slot ---
    // New windows go to index 1, not index 0. While the overlay is open the
    // MRU sentinel is "blocked" (openSwitcher), so onActiveToplevelChanged
    // deliberately does not call moveToFront — the new window therefore stays
    // at index 1 and the currently-focused app keeps index 0. When the overlay
    // is closed the new window receives focus normally and moveToFront promotes
    // it to index 0, so ordinary MRU behaviour is unchanged. On an empty
    // history the insert clamps to index 0 (the only slot available).
    function addToFront(address, appId, title) {
        if (!address || !appId) return;
        var normAddr = address.indexOf("0x") === 0 ? address : "0x" + address;
        // Remove existing entry if present (dedup safeguard)
        for (var i = 0; i < focusHistory.length; i++) {
            if (focusHistory[i].address === normAddr) {
                focusHistory.splice(i, 1);
                break;
            }
        }
        var insertIdx = Math.min(1, focusHistory.length);
        focusHistory.splice(insertIdx, 0, { address: normAddr, appId: appId, title: title || "" });
        log("addToFront: " + normAddr.substring(normAddr.length - 6) + " app=" + appId + " idx=" + insertIdx);
    }
```

`moveToFront()` still uses `unshift()` at index 0 — that is correct, because it
represents an actual focus change promoting a window to MRU-most.

## Verification

### Static simulation

A standalone JS replica of `addToFront()` + `buildLayer0Flat()` +
`spawnAutoSelect` was run for the relevant scenarios:

| Scenario | Before | After |
|---|---|---|
| Ctrl+Enter, 3 running apps, overlay open | window @ **0**, auto-select 0 | window @ **1**, auto-select 1 |
| Alt release on whitelist, sentinel `"blocked"` | window @ 0 | window @ **1** |
| Normal window open, overlay closed, then focused | @ 0 | @ 0 (unchanged via `moveToFront`) |
| Empty `focusHistory` (no other windows) | @ 0 | @ 0 (only possible slot) |

### Manual test plan

1. `./manual_start.sh`
2. Open the overlay (`qs ipc call hyprsphere toggle`).
3. Navigate to a whitelisted app that is **not** running (e.g. Blender if not
   open) and press **Ctrl+Enter**.
4. **Verify:** the spawned window appears at sphere index 1 (second position),
   and the previously-focused app stays at index 0.
5. Tab once: the selection should move off the new window to index 2.
6. Repeat via **Alt release** on the whitelist placeholder: after launching,
   reopen the overlay and confirm the app is at index 1, not index 0.
7. With `"debug": true`, the log line `addToFront: ... idx=1` confirms the
   insertion index (`idx=0` only when the list was empty).
8. Regression: launch a normal window while the overlay is **closed** (e.g.
   from a terminal). It should still end up at index 0 after receiving focus.

## Edge Cases / Non-goals

| Scenario | Behaviour |
|---|---|
| Empty `focusHistory` | New window lands at index 0 — no index 1 exists |
| Overlay closed, new window focused normally | Transiently at 1, promoted to 0 by `moveToFront` |
| Multiple rapid spawns while overlay open | Each new window lands at index 1; earlier spawns shift down (newest closest to the front) |
| `openwindow` event missed; reconcile Phase 3 adds the window | Still appended at the **tail** (`shell.qml` `reconcileFocusHistory` Phase 3 `focusHistory.push`). Left unchanged: altering it would scramble startup ordering for pre-existing windows. Normal Ctrl+Enter / Alt-release spawns go through `openwindow` → `addToFront` and are unaffected. |
| Alt-release path persistence | The whitelist branch of `commitSelection()` (`binds.js`) never clears `_mruCommitAddr` from `"blocked"`, so the spawned window's focus event is ignored and it stays at index 1. This fix relies on that current behaviour. If the sentinel leak is ever fixed, the Alt-release spawn would be promoted to 0; making it robust would require an explicit spawn flag in the whitelist branch (follow-up). |
| Function naming | `addToFront()` now inserts at MRU-next, so the name is a slight misnomer. Kept for a minimal diff; can be renamed to `addAtMruNext()` as a follow-up. |
