# PATCH — Layer 0 App Grouping Refactor

> Refactor layer 0 from **one node per window** (flat) to **one node per app
> group**, so Tab-cycling at layer 0 steps through *apps*, and each app node
> represents its **MRU-most window** (used by peek and commit).
>
> This is a prerequisite for `patches/peek_utility.md`: with app-group nodes,
> "peek the MRU-most window of the selected app" becomes a simple read of
> `node.address`.

---

## Overview

The current `buildLayer0()` produces a **flat** list: one node per entry in
`focusHistory` (i.e. one node per *window*), each marked `isWindowNode: true`
and carrying `badgeIndex` (the window's 1-based index within its app). This is a
leftover from the `mruMethod="window"` refactor (see `HANDOFF.md`).

This patch restores app-level grouping **at layer 0 only**, while keeping the
window-level data model (`focusHistory`) and layer 1 (per-app window drill-down)
intact.

### Target behavior

| Layer | Node granularity | Tab-cycling shows | Commit focuses | Peek captures |
|---|---|---|---|---|
| 0 | **App group** | the app's **MRU-most window** | MRU-most window | MRU-most window |
| 1 | Window | the specific window | that window | that window |
| 2 | Window / whitelist placeholder | that window / nothing | that window | that window |

---

## Current vs target node shape

### Current layer 0 (flat, per-window)

```js
{
  address: entry.address,        // this window
  appId: appId,
  title: title,                  // this window's title
  label: resolveName(appId),
  icon: resolveIcon(appId),
  isWindowNode: true,            // ← every layer-0 node is a "window"
  badgeIndex: seenCounts[appId], // 1-based index within app
  windows: [], windowCount: 0,   // ← always empty for real nodes
}
```

### Target layer 0 (grouped, per-app)

```js
{
  appId: appId,
  label: resolveName(appId),
  icon: resolveIcon(appId),
  address: windows[0].address,   // MRU-most window (commit + peek target)
  windows: [ { address, title }, ... ],  // full list, MRU order
  windowCount: windows.length,
  isWindowNode: false,           // app-group node
  isAppGroup: true,
  // whitelist placeholder adds:
  //   exec, isWhitelistPlaceholder: true, windows: [], windowCount: 0
}
```

Key invariant: **`node.address` on an app-group node is always its MRU-most
window address**, because `windowsForApp(appId)` returns addresses in
`focusHistory` order (MRU-first), and `focusHistory[0]` is the most recently
focused window.

---

## Why this is safe

`focusHistory` remains the single source of truth. It is already maintained by
the synchronous event handlers and is untouched by this patch:

| Event | Mutation | Unchanged |
|---|---|---|
| `openwindow` | `addToFront(addr, appId, "")` | ✓ |
| `closewindow` | `removeAddress(addr)` | ✓ |
| `onActiveToplevelChanged` | `moveToFront(addr)` | ✓ |

`appOrder()` (unique appIds, MRU-first) and `windowsForApp(appId)` (addresses,
MRU-first) are pure derivations from `focusHistory` and already exist. The
refactor only changes **how layer 0 is rendered** from those derivations, not
how the underlying data is tracked.

---

## Changes

### 1. `buildLayer0()` — group by app

Replace the flat loop with an app-group loop driven by `appOrder()`:

```javascript
function buildLayer0() {
    var result = [];
    var whitelist = cfg.whitelist || [];
    var order = appOrder();          // unique appIds, MRU-first

    // One node per running app group
    for (var i = 0; i < order.length; i++) {
        var appId = order[i];
        var wins = windowsOf(appId);
        if (wins.length === 0) continue;   // safety net (shouldn't happen)
        result.push({
            appId: appId,
            label: window.resolveName(appId),
            icon: window.resolveIcon(appId),
            address: wins[0].address,      // MRU-most → commit + peek target
            windows: wins,
            windowCount: wins.length,
            isWindowNode: false,           // app-group node
            isAppGroup: true,
        });
    }

    // Append whitelist placeholders (dedup case-insensitively, see TASKS #9)
    for (var w = 0; w < whitelist.length; w++) {
        var entry = whitelist[w];
        var alreadyPresent = order.some(function (a) {
            return a.toLowerCase() === entry.appId.toLowerCase();
        });
        if (!alreadyPresent) {
            result.push({
                appId: entry.appId, label: entry.label, icon: entry.icon,
                exec: entry.exec, windows: [], windowCount: 0,
                isWindowNode: false, isAppGroup: true,
                isWhitelistPlaceholder: true,
            });
        }
    }

    log("buildLayer0: " + result.length + " app groups");
    return result;
}
```

Note: `isWindowNode: false` makes app-group nodes flow through the existing
"app-level node" branches in `binds.js` (see §7) without new flags. `isAppGroup`
is a convenience label for clarity in the delegate.

### 2. Add `windowsOf(appId)` helper

`windowsForApp()` already returns bare **address strings** (used by
`resolveTargetAddress`, `buildLayer1`, and the badge). Add a sibling that
returns **objects** with resolved titles, for the `node.windows` field:

```javascript
    // All windows of an app as { address, title } objects, MRU-first.
    function windowsOf(appId) {
        var result = [];
        for (var i = 0; i < focusHistory.length; i++) {
            if (focusHistory[i].appId !== appId) continue;
            var addr = focusHistory[i].address;
            result.push({
                address: addr,
                title: focusHistory[i].title
                    || window._resolveTitle(addr) || appId,
            });
        }
        return result;
    }
```

### 3. `buildLayer1()` — reuse `windowsOf()`

Simplify to avoid the duplicated title-resolution loop:

```javascript
function buildLayer1(appId) {
    var wins = windowsOf(appId);
    var result = [];
    for (var i = 0; i < wins.length; i++) {
        result.push({
            address: wins[i].address, title: wins[i].title,
            icon: window.resolveIcon(appId), label: window.resolveName(appId),
            appId: appId, isWindowNode: true,
        });
    }
    log("buildLayer1(" + appId + "): " + result.length + " windows");
    return result;
}
```

### 4. `appOrder()` — now actually used

`appOrder()` exists (shell.qml ~line 147) but is currently **dead** (never
called). This refactor makes it the layer-0 ordering source. No code change
needed to the function itself — only that `buildLayer0()` now calls it.

Ordering semantics (already correct): `appOrder()` returns unique appIds in
first-appearance order of `focusHistory`. Since `focusHistory` is MRU-first,
`appOrder()[0]` is the **current** app and `appOrder()[1]` is the **previous**
app — exactly the classic Alt+Tab order.

### 5. `finishOpenSwitcher()` — pre-select by app count

Current pre-selection keys off `focusHistory.length` (window count):

```javascript
selectedAppIndex = focusHistory.length >= 2 ? 1 : 0;
```

Change to key off the number of app groups (`sphereModel.length`), since
`sphereModel` is now app groups and index 1 is the previous app:

```javascript
selectedAppIndex = sphereModel.length >= 2 ? 1 : 0;
```

### 6. `rebuildToLayer()` — restore selection by `appId`, not index

The layer-0 `else` branch currently clamps the index:

```javascript
selectedAppIndex = Math.min(sphereModel.length - 1, selectedAppIndex);
```

If an app closes (or opens) while the overlay is open, app-group indices shift
and the clamped index can land on the wrong app. Capture the selected `appId`
before rebuilding and re-resolve it:

```javascript
var prevAppId = sphereModel[selectedAppIndex]
    ? sphereModel[selectedAppIndex].appId : null;
sphereModel = raw.length === 0
    ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
    : raw;
selectedAppIndex = 0;
for (var i = 0; i < sphereModel.length; i++) {
    if (sphereModel[i].appId === prevAppId) { selectedAppIndex = i; break; }
}
centerOnApp(selectedAppIndex);
```

The layer-1 branch of `rebuildToLayer()` already checks
`raw[i].appId === window.drilledAppId && !raw[i].isWhitelistPlaceholder`, which
still works against app-group nodes (they carry `appId`).

### 7. `binds.js` — selection / commit / close paths

**`resolveTargetAddress()`** (used by commit) — already correct for app nodes:

```javascript
function resolveTargetAddress(window, node) {
    if (!node || node.isPlaceholder || node.isWhitelistPlaceholder) return "";
    if (node.isWindowNode) return node.address || "";
    var addrs = window.windowsForApp(node.appId);   // MRU-first
    return addrs.length >= 1 ? addrs[0] : "";        // MRU-most window
}
```

App-group nodes hit the `else` branch and resolve to the MRU-most window. This
matches `node.address` (which now also holds the MRU-most window), so it can be
left as-is or simplified to `return node.address || (windowsForApp(...)[0] || "")`.

**`drillDown()` 1→0 and 2→0** — currently select-by-`address` in the flat layer 0.
Change both branches to select-by-`appId` (the app that owns the window you were
viewing):

```javascript
// drillDown 1→0 (and identically 2→0):
var returnNode = window.sphereModel[window.selectedAppIndex];
var returnAppId = returnNode ? returnNode.appId : null;
// ... rebuild layer 0 ...
var matched = false;
if (returnAppId) {
    for (var si = 0; si < window.sphereModel.length; si++) {
        if (window.sphereModel[si].appId === returnAppId) {
            window.selectedAppIndex = si;
            window.centerOnApp(si);
            matched = true;
            break;
        }
    }
}
if (!matched) { window.selectedAppIndex = 0; window.centerOnApp(0); }
```

**`drillDown()` 0→1** — **keep the existing "other window" pre-selection** for
quick intra-app selection. No change is needed: with app groups,
`selNode.address` is the MRU-most window (index 0 in `buildLayer1`), so the
current `wasIdx === 0 → selectedAppIndex = 1` logic already lands on the second
window (the "other" one). The `wasAddr`-based logic in `shell.qml`/`binds.js`
works unchanged against app-group nodes.

**`closeSelection()`** — the app-level `else` branch closes `node.windows`, which
is now populated (previously always empty → no-op), so Ctrl+C at layer 0 will
close **all** windows of the selected app:

```javascript
} else {
    // App-level node: close all windows (node.windows now populated)
    for (var w = 0; w < node.windows.length; w++)
        window.dispatchClose(node.windows[w].address);
}
```

**`advance()`** — no change (still just cycles `selectedAppIndex`).

### 8. Delegate (`shell.qml` Repeater) — badges, labels, icon opacity

**Fix `bracketIcon()` first** — it exists in `shell.qml` (~line 296) but is
broken: steps 5/12–11/12 all return the same glyph. The correct 12 glyphs are
the **Fira Code progress indicators** (`U+F143F`–`U+F144A`), which Nerd Fonts
ships for exactly this purpose. Replace with a clean 12-step mapping:

```javascript
function bracketIcon(badgeIndex, total) {
    if (!badgeIndex || !total || total < 1) return "";
    var step = Math.ceil((badgeIndex / total) * 12);   // 1..12
    if (step < 1) step = 1;
    if (step > 12) step = 12;
    // Fira Code progress indicators (Nerd Font): U+F143F..U+F144A
    return String.fromCharCode(0xF143E + step);
}
```

Font note: the badge's `font.family` is currently `JetBrains Mono`. The
`U+F143F` range only renders in a Nerd-Font-patched variant, so set the badge
font to the patched family name (e.g. `JetBrainsMono Nerd Font`), or confirm the
system's `JetBrains Mono` alias already resolves to the patched face.

**Badge text (satellite only)** — replace the numeric badge on the **satellite
(selected) card** with the bracket glyph. The non-selected card badge stays
hidden, and app-group nodes have no badge. Update `satBadgeLabel.text`:

```javascript
text: {
    var n = window.sphereModel[window.selectedAppIndex];
    if (!n || !n.isWindowNode) return "";
    // window recency within its app (1 = MRU-most, N = oldest)
    var winList = window.windowsForApp(n.appId);
    var pos = n.badgeIndex || (winList.indexOf(n.address || "") + 1);
    return window.bracketIcon(pos, winList.length);
}
```

**Badge color/opacity** — already branches on `isWindowNode`, so app-group nodes
pick up the *app* badge colors (`windowCountBadge.bgColor` / `.color`) and window
nodes keep the *window* colors (`windowBgColor` / `windowColor`). No change
needed; verify the defaults read sensibly.

**Badge visibility** — unchanged: the satellite badge stays `visible: n.isWindowNode`
and the non-selected card badge stays `visible: false`. The only badge change is
the satellite badge *text* (number → glyph). No `windowCountBadge.*` wiring is
needed.

**Icon opacity** — already branches on `isWindowNode`, so app-group nodes use
`appIconOpacity` and window nodes use `windowIconOpacity`. No change needed.

**Labels** — `labelBg.visible` currently requires `n.isWindowNode`. Relax it so
app-group nodes also show a label (the app name) at layer 0:

```javascript
visible: {
    if (!window.showNonSelectedLabel()) return false;
    var n = window.sphereModel[index];
    return n && !n.isPlaceholder && !n.isWhitelistPlaceholder;   // app OR window
}
```

The label text already falls back to `n.label` (app name) when `n.title` is
absent, which is the case for app-group nodes.

**Satellite label** — `satLabelBg.visible` already handles app nodes via
`cfg.appCard.satelliteAppLabel === true`; unchanged.

### 9. `spawnAutoSelect` — already compatible

The spawn auto-select block already has an app-node branch:

```javascript
} else if (!_n.isWindowNode && _n.appId === window._pendingSpawnAppId) {
    // selects the app group by appId
}
```

With app-group layer 0, the window-address branch no longer matches, but the
appId branch does. No change required — verify it still selects correctly after
a Ctrl+Enter spawn.

---

## Peek integration

`patches/peek_utility.md` needs no changes to work with app groups:

- `refreshPeek()` reads `node.appId` + `node.windows[0].title` (the MRU-most
  window) and passes them to `resolveForeignToplevel()`, which matches against
  `ToplevelManager.toplevels` by `appId` + `title`.
- Whitelist placeholders have no `appId` window → peek stays a no-op.
- Layers 1/2 nodes are `isWindowNode: true` and carry their own `title`.

The only coupling to remember: **`buildLayer0()` must set `node.address` to the
MRU-most window and `node.windows[0]` to its `{ address, title }`** (§1), which
is what "peek the MRU-most window of the app group" falls out of.

---

## Out of scope

- **Layer 2 (search)** stays window-level. `buildSearchDatabase()` still emits
  `window` + `whitelisted-app` entries, and `_executeSearch()` is unchanged.
  (Optionally, "running-app" entries could be added to search later so typing an
  app name surfaces a single app-group result — flagged, not done here.)
- **MRU tracking / event handlers** — untouched.
- **`mruMethod`** is already fully removed (see `HANDOFF.md`); no config changes
  to layer 0 grouping are needed beyond what exists.

---

## Files modified

| File | Change |
|---|---|
| `shell.qml` | Rewrite `buildLayer0()` to group by app; add `windowsOf()`; simplify `buildLayer1()`; pre-select by app count in `finishOpenSwitcher()`; restore-by-appId in `rebuildToLayer()`; update delegate badge/label logic |
| `binds.js` | `drillDown()` 1→0/2→0 select-by-appId; confirm `resolveTargetAddress()`/`closeSelection()` app branches |
| `hyprsphere.json` | Set `appCard.nonSelectedLayerLabels.layer_0` to `true`; optionally wire `windowCountBadge.nonSelected`/`.satellite` (TASKS #12) |

---

## Verification

### Automated checks (grep-based)

```bash
# C1: buildLayer0 no longer marks layer-0 nodes as windows
grep -A2 'function buildLayer0' shell.qml | grep -c 'isWindowNode: true'   # 0

# C2: appOrder is now actually called
grep -c 'appOrder()' shell.qml                                              # >= 1

# C3: windowsOf defined and used by buildLayer0/buildLayer1
grep -c 'function windowsOf' shell.qml                                      # == 1
grep -c 'windowsOf(' shell.qml                                              # >= 2

# C4: app-group nodes set address = MRU-most
grep -c 'address: wins\[0\].address' shell.qml                              # == 1

# C5: drillDown returns to layer 0 by appId, not address
grep -c 'returnAppId' binds.js                                              # >= 2

# C6: finishOpenSwitcher pre-selects by app count
grep -A2 'selectedAppIndex = ' shell.qml | grep -c 'sphereModel.length'     # >= 1
```

### Manual tests

| # | Scenario | Expected |
|---|---|---|
| M1 | Two apps, one window each | Layer 0 shows 2 nodes, one per app |
| M2 | One app with 3 windows | Layer 0 shows 1 app-group node (no badge) |
| M10 | Two apps, app names on cards | App names visible on all layer-0 cards by default |
| M11 | `;` drill into that app | Each window node shows a bracket glyph (recency within app) |
| M3 | Alt+Tab open | Pre-selected node = previous app |
| M4 | Tab through apps | Each app node peeks its MRU-most window |
| M5 | `;` drill-down | Layer 1 shows that app's windows, MRU-most first |
| M6 | Ctrl+C at layer 0 | Closes **all** windows of the selected app |
| M7 | Alt-release commit | Focuses the MRU-most window of the selected app |
| M8 | Close a background app externally | Layer 0 rebuilds; selection stays on the previously selected app (by appId) |
| M9 | Ctrl+Enter spawn | New app window appears; its app group is selected |

---

## Edge cases

| Scenario | Behavior |
|---|---|
| App has zero windows (shouldn't happen) | `windowsOf()` empty → `continue` skips it |
| Whitelist `appId` case-mismatch | Case-insensitive dedup prevents duplicate nodes |
| Only one app + several placeholders | `sphereModel = [app, wl1, wl2...]`; pre-select index 0 |
| App closed while drilled in (layer 1) | `rebuildToLayer` falls back to layer 0 (existing logic) |
| Selection index shifts after rebuild | Restored by `appId`, not index (§6) |
| App with a `special:*` window | `focusHistory` already excludes special workspaces, so layer 0 won't include them; layer 1 peek still captures them (per peek doc) |

---

## Risks / migration notes

1. **This partially reverts `HANDOFF.md`'s window-level pre-selection.** That
   refactor made layer 0 flat per-window *and* made pre-selection/commit target
   `globalWindowMru`. This patch restores app grouping at layer 0 while keeping
   `focusHistory` (window-level) intact underneath — the two are not in conflict,
   but be aware the commit target is now "MRU-most window of the selected app"
   (which `resolveTargetAddress` already computes from `windowsForApp`).
2. **`badgeIndex` becomes layer-1-only**, and `bracketIcon()` is now wired into
   the badge (it must be fixed first — see §8a). Nothing at layer 0 produces a
   per-window `badgeIndex` anymore.
3. **`node.windows` transitions from "always empty" to "populated."** Verify no
   code path assumed it was empty (the only consumer, `closeSelection`, is fixed
   in §7).
4. **Search layer 2 is deliberately unchanged.** Don't assume layer-0 grouping
   applies to search results — they remain window-level.

---

## Resolved decisions

1. **Drill-down start window** — **keep the existing "other window" behavior**
   (pre-select index 1, i.e. the second window) for quick intra-app selection.
   The current `drillDown()` 0→1 code needs **no change** (see §7).
2. **Badge** — use **12-step bracket glyphs instead of numbers**, on the
   **satellite (selected) card only**, for window nodes (layer 1/2). App-group
   nodes and non-selected cards have no badge. `bracketIcon()` must be fixed
   (see §8a).
3. **Non-selected labels at layer 0** — **show app names on all cards by
   default**: set `appCard.nonSelectedLayerLabels.layer_0` to `true` in
   `hyprsphere.json`, and relax the `labelBg.visible` condition (see §8).

## All decisions resolved

- Glyph set: Fira Code progress indicators (`U+F143F`–`U+F144A`); `bracketIcon()`'s
duplicate-glyph bug is fixed as part of this patch (§8a).
