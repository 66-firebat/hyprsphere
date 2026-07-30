# Potential Bugs & Hardening Proposals

> Audit of `shell.qml`, `binds.js`, `effects.js`, `hyprsphere.json`, and all patches.
>
> **Primary symptom:** Intermittently, a newly spawned Firefox window appears
> in the sphere but cannot be switched to (Alt-release does nothing or focuses
> the wrong window). The bug is not reliably reproducible — it depends on
> system load and event-loop scheduling.

---

## Finding 1 ✅ RESOLVED: `reconcileFocusHistory()` uses stale toplevel data inside `scheduleRebuild()`

> **Status:** Fixed via Timer-based deferral (see `patches/bug-reconcile-stale-toplevels.md`).
> `scheduleRebuild()` now calls `Hyprland.refreshToplevels()` then starts a
> `refreshDelayTimer` (66ms, configurable via `toplevelRefreshDelayMs`). When
> the Timer fires, `reconcileFocusHistory()` runs with guaranteed-fresh data.

### What it is

`scheduleRebuild()` calls both `Hyprland.refreshToplevels()` and
`reconcileFocusHistory()` inside the **same `Qt.callLater` callback**,
with no deferral between them:

```javascript
// shell.qml, ~line 658–664
function scheduleRebuild() {
    if (rebuildScheduled) return;
    rebuildScheduled = true;
    Qt.callLater(function() {
        rebuildScheduled = false;
        Hyprland.refreshToplevels();    // ← fires async IPC, returns immediately
        reconcileFocusHistory();         // ← reads Hyprland.toplevels.values — STALE!
        var raw = buildLayer0();         // ← built from focusHistory (possibly just corrupted)
        rebuildToLayer(raw);
        // ...
    });
}
```

`Hyprland.refreshToplevels()` sends a `j/clients` request on Hyprland's
Unix socket and returns immediately. The response arrives **asynchronously**
via a separate event-loop callback, where it finally updates
`Hyprland.toplevels.values`. But `reconcileFocusHistory()` runs
**synchronously** in the same `Qt.callLater` callback — **before the
response can possibly arrive**.

### How reconcile corrupts focusHistory with stale data

`reconcileFocusHistory()` has three phases:

1. **Build `validAddrs`** — scans `Hyprland.toplevels.values` to collect
   every live window address. If the refresh hasn't completed yet, this set
   is **missing** the newly opened window.

2. **Phase 2 — remove orphans** — iterates `focusHistory` in reverse.
   Any entry whose `address` is not in `validAddrs` is **deleted**. The
   newly opened window (added moments earlier by the `openwindow` event
   handler) is absent from the stale `validAddrs` → **removed**.

3. **Phase 3 — add missing** — scans the (stale) toplevel list and
   adds any windows not already in `focusHistory`. The new window isn't
   in the stale toplevel list either → **not added back**.

**Net result:** The new window is silently deleted from `focusHistory`.
`buildLayer0()` produces a sphere **without** it.

### Why it's intermittent

Whether the window survives depends on a race between two event-loop
callbacks:

| Scenario | IPC latency | Outcome |
|---|---|---|
| `j/clients` response arrives **before** `Qt.callLater` fires | Fast socket (< 1ms) | Window survives |
| `Qt.callLater` fires **before** the IPC response arrives | Socket congested, slow JSON parse (2–10ms) | **Window deleted** |

System load, Hyprland's internal state, and Qt event-loop scheduling all
affect the ordering. This is a textbook async race condition.

### The contrast: `openSwitcher` gets this right

```javascript
// shell.qml ~line 617–618
function openSwitcher() {
    Hyprland.refreshToplevels();                       // fire async
    Qt.callLater(function() { finishOpenSwitcher(); }); // defer → IPC can complete
}
```

Here the `Qt.callLater` gives the IPC response time to arrive before
`reconcileFocusHistory()` runs inside `finishOpenSwitcher()`.
`scheduleRebuild()` lacks this deferral.

### Proposed fix

Split the rebuild into two async phases, matching the `openSwitcher` pattern:

```javascript
function scheduleRebuild() {
    if (rebuildScheduled) return;
    rebuildScheduled = true;
    Qt.callLater(function() {
        rebuildScheduled = false;
        Hyprland.refreshToplevels();
        // Defer the rest — let the IPC response arrive first
        Qt.callLater(function() {
            reconcileFocusHistory();
            var raw = buildLayer0();
            rebuildToLayer(raw);
            // ... spawn auto-select, projDirty, etc.
        });
    });
}
```

This guarantees `reconcileFocusHistory()` always sees fresh toplevel data,
eliminating the race entirely.

---

## Finding 2 (HIGH): `openwindow` events only trigger a rebuild when spawn-tracking matches

### What it is

The `onRawEvent` handler for `openwindow` only calls `scheduleRebuild()`
when the opening window's `appId` matches `_pendingSpawnAppId`:

```javascript
// shell.qml ~line 787–808
if (event.name === "openwindow") {
    var parts = (event.data || "").split(",");
    if (parts.length >= 3) {
        var addr = parts[0];
        if (addr.indexOf("0x") !== 0) addr = "0x" + addr;
        var appId = parts[2];
        if (!appId) return;
        window.addToFront(addr, appId, "");

        // Spawn tracking — ONLY path that triggers a rebuild
        if (window._pendingSpawnAppId === appId) {
            window._pendingSpawnAddr = addr;
            if (window.visible) {
                window.visible = false;
                Qt.callLater(function() { window.visible = true; });
                window.scheduleRebuild();
            }
        }
        // ← NO rebuild if _pendingSpawnAppId doesn't match
    }
}
```

Any window that opens **without** a matching `_pendingSpawnAppId` is added
to `focusHistory` but **never** reflected in `sphereModel` during the
current session. This includes:

- Windows opened manually (e.g., Ctrl+N in Firefox while the overlay is open)
- Browser popups, file choosers, dialogs
- External applications launched via keybind or launcher
- A real window whose spawn-tracking was **consumed** by a transient (see below)

### Firefox transient-window concern

Firefox and Chromium-based browsers are known to create **short-lived
transient toplevels** before the real window. The pattern observed on
Hyprland's socket2:

```
openwindow>>TRANSIENT_ADDR,1,,        ← empty class and title
activewindow>>,
closewindow>>TRANSIENT_ADDR            ← closes immediately
openwindow>>REAL_ADDR,1,firefox,Firefox  ← real window
```

The transient's class may be empty (filtered by `if (!appId) return;`)
or `"firefox"` (which would **consume** `_pendingSpawnAppId`).
In either case, by the time the real window's `openwindow` fires,
`_pendingSpawnAppId` is **already cleared** — no rebuild occurs.
The real window sits in `focusHistory` but is invisible.

### Asymmetry with `closewindow`

The `closewindow` handler ALWAYS triggers a rebuild:

```javascript
// shell.qml ~line 810–823
if (event.name !== "closewindow") return;
// ...
window.removeAddress(addr);
if (window.visible) {
    window.visible = false;
    Qt.callLater(function() { window.visible = true; });
    scheduleRebuild();   // ← unconditional
}
```

This means windows are reliably **removed** from the sphere on close,
but **not** reliably **added** on open.

### Proposed fix

Decouple spawn-tracking from rebuild-triggering. Always call
`scheduleRebuild()` on `openwindow`, and keep the spawn-tracking state
(`_pendingSpawnAddr`) as a separate concern:

```javascript
if (event.name === "openwindow") {
    // ... parse and addToFront ...

    // Spawn tracking — record the address for auto-selection
    if (window._pendingSpawnAppId === appId) {
        window._pendingSpawnAddr = addr;
    }

    // Always rebuild when a window opens
    if (window.visible) {
        window.visible = false;
        Qt.callLater(function() { window.visible = true; });
        window.scheduleRebuild();
    }
}
```

---

## Finding 3 (HIGH): `_mruFrozen` can become permanently stuck at `true`

### What it is

When committing a selection, `_mruFrozen` is **not** cleared.
It stays `true` even after the overlay closes:

```javascript
// binds.js — commitSelection()
window._commitAddr = addr;          // address we expect focus on
window.stopPerpetual();
window.overlayActive = false;
window.visible = false;
window.dispatchFocus(addr);        // focus dispatch — may fail silently
window.dispatchSubmap("reset");
// NOTE: _mruFrozen is NOT set to false here
```

The unfreeze is delegated to `onActiveToplevelChanged`:

```javascript
// shell.qml — onActiveToplevelChanged
if (window._mruFrozen && addr !== window._commitAddr) {
    return;  // ← BLOCK all focus changes
}
if (window._mruFrozen && addr === window._commitAddr) {
    window._mruFrozen = false;     // ← UNFREEZE (only here)
    window._commitAddr = "";
}
```

If `dispatchFocus(addr)` is a silent no-op (window in a transitional
state, Firefox content not loaded, address subtly wrong), the
`activeToplevelChanged` event **never** fires for that address.
`_mruFrozen` stays `true`. All subsequent real focus changes are
blocked, and `focusHistory` stops tracking reality.

### Impact

While `_mruFrozen` is stuck:
- `onActiveToplevelChanged` blocks all `moveToFront()` calls
- `focusHistory` diverges from reality — new focus changes don't move
  windows to the front
- The **current** overlay session's commit is silently broken

On the **next** Alt+Tab, `openSwitcher()` calls `reconcileFocusHistory()`
which cross-references against `Hyprland.toplevels` — this **corrects**
the stale `focusHistory` by removing closed windows and adding missing
ones. So the corruption doesn't carry between sessions, but the session
where it happened is broken.

### Proposed fix

Add a safety timeout: if `_commitAddr` is set and the corresponding
`activeToplevelChanged` hasn't arrived within a reasonable window
(e.g., 2 seconds), auto-clear `_mruFrozen`:

```javascript
// In commitSelection(), after setting _commitAddr:
window._commitAddr = addr;
window._mruUnfreezeTimer = Date.now() + 2000;  // deadline

// In onActiveToplevelChanged, add a fallback:
if (window._mruFrozen && window._mruUnfreezeTimer && Date.now() > window._mruUnfreezeTimer) {
    window._mruFrozen = false;
    window._commitAddr = "";
    window._mruUnfreezeTimer = 0;
    log("mruFrozen: TIMEOUT — force-unfroze");
}
// ... then the normal commit-addr check
```

Alternatively, simply set `_mruFrozen = false` in `commitSelection()`
after the dispatch, and accept that the committed window's
`activeToplevelChanged` may fire and update focusHistory (which is
actually the desired behavior — the committed window should become
MRU-most).

---

## Finding 4 (MEDIUM): `addToFront()` address normalization is incomplete

### What it is

`addToFront()` handles hex addresses but not decimal:

```javascript
// shell.qml ~line 172
function addToFront(address, appId, title) {
    var normAddr = address.indexOf("0x") === 0 ? address : "0x" + address;
    // ...
}
```

Compare with `normalizeAddress()`, which handles all three formats:

```javascript
// shell.qml
function normalizeAddress(addr) {
    if (!addr) return "";
    if (addr.indexOf("0x") === 0) return addr;
    var num = Number(addr);
    if (!isNaN(num)) return "0x" + num.toString(16);  // decimal → hex
    return "0x" + addr;                                // hex without 0x
}
```

### Current safety & latent risk

Currently `addToFront()` is **only** called from the `openwindow` event
handler, which receives hex addresses. So the bug is latent, not active.

If anyone ever calls `addToFront()` with a toplevel decimal address
(from `t.address`), it would produce `"0x" + decimalString` — a
**corrupt** address that will never match any `dispatchFocus` or
`normalizeAddress` output. Comparisons would silently fail.

### Proposed fix

Replace the inline normalization in `addToFront()` with the canonical
`normalizeAddress()`:

```javascript
function addToFront(address, appId, title) {
    if (!address || !appId) return;
    var normAddr = window.normalizeAddress(address);
    // ... rest as before
}
```

Same for `moveToFront()` and `removeAddress()` — all address-ingesting
functions should use the single canonical normalizer.

---

## Finding 5 (MEDIUM): `openwindow` does NOT skip `scheduleRebuild` for never-added addresses on close

### What it is

The `closewindow` handler always calls `scheduleRebuild()`, even when
the closed address was **never in** `focusHistory`:

```javascript
// shell.qml ~line 810–823
window.removeAddress(addr);   // logs "NOT FOUND", no-op
if (window.visible) {
    window.visible = false;
    Qt.callLater(function() { window.visible = true; });
    scheduleRebuild();          // ← triggers rebuild anyway
}
```

This happens when Firefox creates a transient toplevel that gets
filtered by `if (!appId) return;` in the openwindow handler — it was
never added, but its `closewindow` still triggers a full rebuild.
The rebuild:
1. Calls `Hyprland.refreshToplevels()` (async)
2. Calls `reconcileFocusHistory()` with potentially stale data (Finding 1)
3. Clears `_pendingSpawnAppId` and `_pendingSpawnAddr` unconditionally

If this close-triggered rebuild runs **before** the real window's
`openwindow` event, `_pendingSpawnAppId` is consumed, and the real
window opens without spawn tracking → no rebuild → invisible.

### Proposed fix

Skip `scheduleRebuild()` in `closewindow` when `removeAddress()` found
nothing to remove:

```javascript
var removed = window.removeAddress(addr);  // return bool: true if removed
if (window.visible && removed) {
    window.visible = false;
    Qt.callLater(function() { window.visible = true; });
    scheduleRebuild();
}
```

(Requires changing `removeAddress` to return `true`/`false`.)

---

## Finding 6 (MEDIUM): Whitelist dedup depends on exact `appId` match

### What it is

`buildLayer0()` appends whitelisted placeholders for any whitelist entry
whose `appId` is not found in `focusHistory`:

```javascript
// shell.qml buildLayer0()
for (var w = 0; w < whitelist.length; w++) {
    var alreadyPresent = false;
    for (var a = 0; a < focusHistory.length; a++) {
        if (focusHistory[a].appId === entry.appId) {
            alreadyPresent = true;
            break;
        }
    }
    if (!alreadyPresent) {
        result.push({ ... isWhitelistPlaceholder: true });
    }
}
```

If Hyprland reports Firefox's `wayland.appId` as anything other than
`"firefox"` (e.g., `"Firefox"`, `"firefox-esr"`, `"firefoxdeveloperedition"`,
or `"firefox"` with a different case), the whitelist entry would NOT
deduplicate, producing **two** Firefox nodes — one real window node and
one unresponsive placeholder with `isWhitelistPlaceholder: true`.

Committing the placeholder calls `dispatchExec("firefox")` — which just
launches another Firefox instance, not the visible window.

### Proposed fix

Make the dedup case-insensitive:

```javascript
var alreadyPresent = false;
for (var a = 0; a < focusHistory.length; a++) {
    if (focusHistory[a].appId.toLowerCase() === entry.appId.toLowerCase()) {
        alreadyPresent = true;
        break;
    }
}
```

---

## Finding 7 (LOW): `finishOpenSwitcher()` infinite retry on icon-read failure

### What it is

If the `.desktop` file reader never returns or returns empty data,
`finishOpenSwitcher()` retries forever via `Qt.callLater` with no guard:

```javascript
function finishOpenSwitcher() {
    if (!window.overlayActive) return;
    var iconReady = Object.keys(iconMap).length > 0;
    if (!iconReady) {
        Qt.callLater(function() { finishOpenSwitcher(); });
        return;
    }
    // ...
}
```

This blocks the overlay from ever opening. If the icon reader is slow
(very large number of `.desktop` files, NFS-mounted home directory),
the user experiences a hung Alt+Tab with no visual feedback.

### Proposed fix

Add a retry counter with a maximum:

```javascript
property int _iconRetries: 0

function finishOpenSwitcher() {
    if (!window.overlayActive) return;
    var iconReady = Object.keys(iconMap).length > 0;
    if (!iconReady) {
        if (window._iconRetries++ < 50) {
            Qt.callLater(function() { finishOpenSwitcher(); });
        } else {
            log("finishOpenSwitcher: icon timeout, proceeding without icons");
            // fall through — build sphere with fallback icons
        }
        return;
    }
    window._iconRetries = 0;
    // ...
}
```

Set `_iconRetries = 0` in `openSwitcher()`.

---

## Finding 8 (LOW): `_pendingSpawnAppId` is consumed by ANY `scheduleRebuild`, not just spawn-related ones

### What it is

Every call to `scheduleRebuild()` unconditionally clears
`_pendingSpawnAppId` and `_pendingSpawnAddr` at the end:

```javascript
// shell.qml ~line 701–702 (inside scheduleRebuild's Qt.callLater)
window._pendingSpawnAddr = "";
window._pendingSpawnAppId = "";
```

This runs even when the rebuild was triggered by a `closewindow` event
(unrelated to spawning). If a `closewindow`-triggered rebuild runs
**between** the `openNewWindow` call and the `openwindow` event,
`_pendingSpawnAppId` is cleared and the real openwindow will not
trigger spawn auto-selection.

### Proposed fix

Only clear spawn state when it was actually consumed (a matching window
was found) or when a timeout expires. Or, alternatively, use a flag
to distinguish spawn-triggered rebuilds from others.

---

## Finding 9 ✅ RESOLVED: "Local History" ghost nodes from toplevels with empty Wayland appId

> **Status:** Fixed. See `patches/bug-local-history.md` for full details.
> `reconcileFocusHistory` Phase 3 now skips toplevels with empty `appId`.
> `buildLayer0()` and `buildSearchDatabase()` also filter empty-`appId` entries
> as safety nets.

---

## Finding 10 ❌ REJECTED: `dispatchFocus` dispatcher may not switch workspaces

> **Status:** Rejected — incorrect diagnosis. The Lua dispatcher
> `hl.dsp.focus({window="address:0x..."})` correctly switches workspaces.
> The `focuswindow` old-style dispatcher attempted as a fix does not work
> in the user's Hyprland version and broke all window switching.
> Reverted to original `hl.dsp.focus`.

### What it is

`dispatchFocus()` uses Hyprland's Lua dispatcher:

```javascript
Quickshell.execDetached(["hyprctl", "dispatch",
    'hl.dsp.focus({window="address:' + p + addr + '"})']);
```

The Lua dispatcher `hl.dsp.focus({window="address:0x..."})` may be
**workspace-scoped** — it focuses the window only if it's on the current
workspace. If the target window is on a different workspace, the dispatch
is a silent no-op.

### Evidence

User reports: "If I physically move to that workspace, then I can
see/focus on the window, but sometimes I cannot do this through hyprsphere."

### Proposed fix

Use Hyprland's old-style `focuswindow` dispatcher, which explicitly
switches to the window's workspace:

```javascript
function dispatchFocus(addr) {
    if (!addr) { log("dispatchFocus: no addr"); return; }
    var p = _prefix(addr);
    // focuswindow dispatcher reliably switches workspace
    Quickshell.execDetached(["hyprctl", "dispatch",
        "focuswindow address:" + p + addr]);
}
```

---

## Finding 11 (HIGH): `dispatchFocus`, `dispatchFullscreen`, and `dispatchSubmap` race via independent `execDetached` calls

### What it is

In `commitSelection()`, three separate `execDetached` calls fire in
sequence but execute asynchronously:

```javascript
window.dispatchFocus(addr);          // Process A: hyprctl dispatch focuswindow ...
if (cfg.fullscreenOnActivate)
    window.dispatchFullscreen(addr); // Process B: hyprctl dispatch fullscreen ...
window.dispatchSubmap("reset");      // Process C: hyprctl eval submap reset
```

Each spawns an independent `hyprctl` process. They connect to Hyprland's
IPC socket in an **indeterminate order** — process scheduling determines
which arrives first.

If the fullscreen dispatch (B) arrives before the focus dispatch (A),
the fullscreen command targets a window that isn't focused yet and may
fail or produce side effects. If the submap reset (C) arrives first,
Hyprland exits the submap before processing the focus dispatch.

### Proposed fix

Serialize the exit sequence into a single shell command:

```javascript
var p = _prefix(addr);
var cmd = 'hyprctl dispatch focuswindow address:' + p + addr;
if (window.cfg.fullscreenOnActivate) {
    cmd += ' && hyprctl dispatch \'hl.dsp.window.fullscreen({ mode = "maximized", action = "set", window = "address:' + p + addr + '" })\'';
}
cmd += ' && hyprctl eval \'hl.dispatch(hl.dsp.submap("reset"))\'';
Quickshell.execDetached(["bash", "-c", cmd]);
```

This guarantees: focus first → fullscreen second → submap reset last.

---

## Finding 12 (MEDIUM): `dispatchFocus` silently exits on empty address, leaving `_mruFrozen` locked

### What it is

If `resolveTargetAddress()` returns a falsy address (empty string, null,
undefined — e.g. if the node's `address` property is missing), `dispatchFocus`
returns immediately:

```javascript
function dispatchFocus(addr) {
    if (!addr) { log("dispatchFocus: no addr"); return; }   // ← silent exit
    // ...
}
```

But `commitSelection()` has already set `overlayActive = false`,
`visible = false`, and called `dispatchSubmap("reset")`. The overlay is
gone, but `_mruFrozen` remains `true` with `_commitAddr = ""`.

In `onActiveToplevelChanged`, the unfreeze gate checks:

```javascript
if (window._mruFrozen && addr !== window._commitAddr) { return; }   // "" !== "" → false
if (window._mruFrozen && addr === window._commitAddr) {             // "" === "" → true
    window._mruFrozen = false;   // ← unfreezes immediately
}
```

Actually, this is a **self-correcting** edge case: the NEXT focus change
will have `addr = "" === _commitAddr = ""` → unfreezes. So this is not as
severe as Finding 3.

### Proposed fix

Covered by the timeout-based unfreeze proposed in Finding 3.

---

## Summary Table

| # | Severity | Symptom | Root cause | Proposed fix | Status |
|---|---|---|---|---|---|
| 1 | CRITICAL | New window sometimes missing from sphere | `reconcileFocusHistory` uses stale toplevel data in `scheduleRebuild` | Timer-based deferral (66ms) | ✅ FIXED |
| 2 | HIGH | New window in `focusHistory` but invisible in sphere | `openwindow` only triggers rebuild when `_pendingSpawnAppId` matches | Always call `scheduleRebuild()` on `openwindow` | |
| 3 | HIGH | Commit silently fails, MRU stuck | `_mruFrozen` never cleared if `dispatchFocus` is no-op | Add timeout-based unfreeze or clear `_mruFrozen` in `commitSelection` | |
| 4 | MEDIUM | Latent address corruption | `addToFront` doesn't handle decimal addresses | Use canonical `normalizeAddress()` in all ingestors | |
| 5 | MEDIUM | `_pendingSpawnAppId` consumed by closewindow rebuild | Unnecessary rebuild triggered on irrelevant close | Skip rebuild when close had no effect | |
| 6 | MEDIUM | Duplicate Firefox nodes, wrong commit target | Case-sensitive whitelist dedup | Case-insensitive comparison | |
| 7 | LOW | Overlay never opens | Infinite retry on icon-read failure | Add retry counter | |
| 8 | LOW | Spawn-tracking state consumed by unrelated rebuild | `_pendingSpawnAppId` cleared unconditionally | Only clear when consumed or timeout | |
| 9 | HIGH | Ghost "Local History" nodes with broken icon | Phase 3 added toplevels with empty appId to focusHistory | Skip toplevels with empty appId in Phase 3, buildLayer0, and buildSearchDatabase | ✅ FIXED |
| 10 | HIGH | Can't switch to window on different workspace | `hl.dsp.focus` dispatcher may not switch workspaces | Use old-style `focuswindow address:0x...` dispatcher | |
| 11 | HIGH | Dispatchers race in commitSelection exit sequence | Three independent `execDetached` calls unordered | Serialize into single shell command | |
| 12 | MEDIUM | dispatchFocus exits silently on empty addr | `addr` can be falsy if node.address is missing | Timeout unfreeze (same as #3) | |
