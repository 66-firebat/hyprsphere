# BUGFIX: "Local History" ghost nodes from toplevels with no Wayland appId

## Severity: HIGH

## Symptom

After opening and closing certain applications (most reliably reproduced with
KiCad's project manager → schematic editor workflow), generic purple/black
checkerboard nodes appear on the sphere with titles like "Local History."
These nodes have the fallback QML icon (`application-x-executable`), no
meaningful app name, and cannot be meaningfully interacted with.

The nodes persist across overlay close/reopen cycles and survive
`reconcileFocusHistory()` cleanup passes.

## Root Cause

### The pipeline

`focusHistory` receives new entries from exactly two sources:

| Source | Trigger | appId value |
|---|---|---|
| `addToFront()` | `openwindow` Hyprland event | `WINDOWCLASS` from event data — always non-empty |
| `reconcileFocusHistory()` Phase 3 | `refreshToplevels()` → `Hyprland.toplevels.values` | `t.wayland.appId \|\| "unknown"` |

The `openwindow` event handler has a guard:

```javascript
var appId = parts[2];   // WINDOWCLASS
if (!appId) return;     // skip windows with empty class
```

So `addToFront` never creates entries with empty/missing appIds.

But `reconcileFocusHistory` Phase 3 had no such guard. It added **every**
toplevel from `Hyprland.toplevels.values` whose address wasn't already in
`focusHistory`, using `appId = t.wayland.appId || "unknown"`:

```javascript
// Phase 3 — BEFORE the fix
var appId = (wl && wl.appId) ? wl.appId : "unknown";
var addr = window.normalizeAddress(t.address);
// ... check not already in focusHistory ...
focusHistory.push({ address: addr, appId: appId, title: t.title });
```

### The adversary: Hyprland toplevels with no appId

Some applications (KiCad, possibly others) create **internal sub-windows**
that Hyprland reports in its `j/clients` response but that have **no
Wayland appId set**. These are things like:

- Tool palette windows
- Floating property editors
- Transient popup dialogs
- XDG desktop portal surfaces
- Internal helper windows created by GUI toolkits

These windows:
1. Are **never** announced by `openwindow` events (the event socket doesn't emit them, or emits them with empty class which our handler filters out)
2. Appear in `j/clients` with `class: ""` (empty) and titles like `"Local History"`
3. May linger in the toplevel list after the parent application closes
4. Have no usable icon (no desktop entry matches an empty appId), no usable name, and serve no purpose in a window switcher

### The exact reproduction (KiCad)

Traced from production logs:

```
1. User opens KiCad project manager
   openwindow: addr=9e8220 app=kicad    ← fires, addToFront adds with appId="kicad" ✓
   reconcile: toplevel[1] addr=9e8220 appId=kicad    ← consistent ✓

2. User opens schematic editor (separate window)
   openwindow: addr=0e2400 app=kicad    ← fires ✓

3. User opens another KiCad sub-window
   openwindow: addr=ac17a0 app=kicad    ← fires ✓

4. User closes all KiCad windows
   closewindow: addr=ac17a0  →  removeAddress ✓
   closewindow: addr=0e2400  →  removeAddress ✓
   closewindow: addr=9e8220  →  removeAddress ✓

5. Timer-based reconcile runs (66ms after refreshToplevels):
   reconcileFocusHistory: toplevel[1] addr=b30ed0 appId=(none) title=Local History
                                                       ^^^^^^   ^^^^^^^^^^^^^^
                                                       EMPTY    GHOST WINDOW
   → Phase 3: b30ed0 not in focusHistory → ADDED with appId="unknown"
   → buildLayer0 produces sphere node with broken icon + "Local History" title
```

**Key observation:** Address `b30ed0` never appeared in any `openwindow` or
`closewindow` event. It was an internal KiCad sub-window that Hyprland
included in the `j/clients` response but never emitted socket events for.
When KiCad closed, this sub-window lingered briefly in the toplevel list
before Hyprland cleaned it up — but our reconcile ran during that window
and captured it.

### Why Phase 2 didn't clean it up

Phase 2 removes entries from `focusHistory` whose addresses are NOT in
`validAddrs` (the toplevel list). But since Phase 3 just added `b30ed0`
FROM the toplevel list, its address IS in `validAddrs`. Phase 2 sees it
as valid and leaves it alone. On the next reconcile pass, the toplevel
list has been cleaned up by Hyprland and `b30ed0` is gone from both
`focusHistory` (removed by Phase 2) and the toplevel list. But the
intermediate reconcile captured the ghost.

## The Fix

### Strategy

If a toplevel has no Wayland appId, it has no useful metadata. We cannot
resolve an icon. We cannot resolve a display name. The user cannot
meaningfully interact with it (no exec command, no identifiable class).
There is zero value in showing it in the sphere.

The fix is to **never ingest toplevels with empty appIds** at any entry
point into `focusHistory`.

### Changes

Three layers of defense:

**1. `reconcileFocusHistory` Phase 3 — primary fix**

Skip toplevels whose `wayland.appId` is empty/null. This is the source —
Phase 3 was the only path that created entries with `appId="unknown"`.

```javascript
// Phase 3 — AFTER the fix
var appId = (wl && wl.appId) ? wl.appId : "";
// Skip toplevels with no Wayland appId — these are internal
// sub-windows that leak into Hyprland's j/clients response
// without openwindow events. They have no usable icon or name.
if (!appId) continue;
```

**2. `buildLayer0()` — safety net**

Skip `focusHistory` entries with empty `appId`. Even if an entry somehow
gets past Phase 3 (future code changes, race conditions), `buildLayer0`
will not render it:

```javascript
for (var i = 0; i < focusHistory.length; i++) {
    var entry = focusHistory[i];
    var appId = entry.appId;
    if (!appId) continue;   // skip ghost entries
    // ...
}
```

**3. `buildSearchDatabase()` — safety net**

Same filter for the Fuse.js search index, so ghost entries never appear
in layer 2 search results either:

```javascript
for (var i = 0; i < focusHistory.length; i++) {
    var entry = focusHistory[i];
    if (!entry.appId) continue;
    // ...
}
```

### Files Modified

| File | Change |
|---|---|
| `shell.qml` | `reconcileFocusHistory` Phase 3 — skip toplevels with empty `appId` |
| `shell.qml` | `buildLayer0` — skip `focusHistory` entries with empty `appId` |
| `shell.qml` | `buildSearchDatabase` — skip `focusHistory` entries with empty `appId` |

## Verification

1. Open KiCad (or any app that creates sub-windows with empty appIds)
2. Open schematic editor / sub-windows
3. Close all windows
4. Open the overlay (Alt+Tab)
5. **Verify:** No generic purple/black checkerboard nodes with "Local History" titles
6. Check logs: no `reconcileFocusHistory: toplevel[...] appId=(none)` entries
7. Repeat with other multi-window applications (Firefox, Blender, GIMP)

## Related

This bug was a downstream consequence of the `reconcileFocusHistory` stale-data
race condition (see `patches/bug-reconcile-stale-toplevels.md`). Prior to that
fix, Phase 3 was also adding phantom entries from stale toplevel data that
included windows from before a `refreshToplevels()` IPC completed. The Timer-based
deferral eliminated stale-to-Phase-3 additions, and this fix eliminates the
remaining case: legitimate (but useless) toplevels with no appId.
