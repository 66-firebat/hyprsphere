# PATCH_8 — Flat-list Layer 0: one sphere node per window

> **This patch changes layer 0 from an app-grouped list to a flat window list.**
> Each window in `focusHistory` becomes one node on the sphere. The app icon
> and label are shown on the node, but Tab cycles through INDIVIDUAL WINDOWS
> in MRU order — not deduplicated app groups.

---

## Motivation

### The problem

Layer 0 currently deduplicates `focusHistory` by `appId`. Consecutive windows
of the same app collapse into a single app group. This means Tab cycles
through APPLICATIONS, not windows:

```
focusHistory = [ghostty-a, ghostty-b, firefox]
        appOrder() = [ghostty, firefox]        ← deduplicated
   Tab cycles through: ghostty → firefox → ghostty → firefox
```

The user expects window-driven cycling:

```
focusHistory = [ghostty-a, ghostty-b, firefox]
   Tab cycles through: ghostty-a → ghostty-b → firefox → ghostty-a
```

### The solution

Replace the two-dimensional `appOrder()` / `windowsForApp(appId)` derivation
with a flat `buildLayer0()` that creates one sphere node per entry in
`focusHistory`. Each node carries the window's app icon, its individual
title, and a badge showing its index within its app's group.

The 2D data structure (`focusHistory` + derived dimensions) stays intact —
only the sphere MODEL changes. `windowsForApp(appId)` is still used by
layer 1 (drill-down) and `buildSearchDatabase()` (layer 2).

---

## Detailed behavior

### Layer 0 — Flat window list

| Aspect | Before (PATCH_7) | After (PATCH_8) |
|---|---|---|
| **One node =** | One app group | One window |
| **Tab cycles through** | `appOrder()` (deduplicated apps) | `focusHistory` (individual windows) |
| **Badge shows** | `+N` (total window count) | Window index (1st, 2nd, 3rd...) within its app |
| **Label shows** | App name (e.g., "Firefox") | Window title (e.g., "GitHub tab") |
| **Icon shows** | App icon | App icon (same for same-app windows) |
| **Pre-selection** | `appOrder()[1]` (previous app) | `focusHistory[1]` (previous window) |

### Example

```
focusHistory = [ghostty-a, ghostty-b, firefox]

Layer 0 sphere nodes:
  [0] icon=ghostty, label="bash",          badge=1
  [1] icon=ghostty, label="nvim session",  badge=2
  [2] icon=firefox, label="GitHub",        badge=1

Tab from [0]: → [1] ghostty-b
Tab from [1]: → [2] firefox
Tab from [2]: → [0] ghostty-a (wrap)
```

### Pre-selection on Alt+Tab

`selectedAppIndex = Math.min(1, focusHistory.length - 1)` which is index 1
(the previous window). In the example above, Alt+Tab from ghostty-a would
pre-select index 1 = **ghostty-b**.

### Drill-down (`;`)

**Layer 0 → Layer 1 (drill into app's windows):**
1. Take the selected window node's `appId` (e.g., "com.mitchellh.ghostty").
2. Build layer 1 from `windowsForApp("com.mitchellh.ghostty")` = `[ghostty-a, ghostty-b]`.
3. Pre-select the "other window": the window that is NOT the one we were
   just on at layer 0. Compare addresses: find the address in the layer 1
   list and select the OTHER entry.
   - Example: user was on ghostty-b at layer 0 → drill-down shows
     `[ghostty-a, ghostty-b]` → ghostty-b's address matches index 1 →
     select index 0 = **ghostty-a**.

**Layer 1 → Layer 0 (return):**
1. Rebuild layer 0 from `focusHistory` (flat window list).
2. Select the node whose address matches the window we JUST drilled from
   (the `drilledAppId`'s window, specifically the last viewed one).

**Layer 2 → Layer 0 (return from search):**
1. Rebuild layer 0 from `focusHistory`.
2. Select the node whose address matches the search result we were on.
   This is an address-based match, not appId-based.

---

## Implementation changes

### `shell.qml`

#### Change 1 — Rewrite `buildLayer0()` to produce flat window list

**Before:**
```javascript
function buildLayer0() {
    var order = appOrder();
    var result = [];
    var whitelist = cfg.whitelist || [];
    for (var i = 0; i < order.length; i++) {
        var appId = order[i];
        var winAddrs = windowsForApp(appId);
        var winData = [];
        for (var j = 0; j < winAddrs.length; j++) {
            var title = /* from focusHistory or _resolveTitle */;
            winData.push({ address: winAddrs[j], title: title });
        }
        result.push({
            appId: appId, label: resolveName(appId), icon: resolveIcon(appId),
            windows: winData, windowCount: winData.length,
        });
    }
    // Append whitelisted placeholders ...
    return result;
}
```

**After:**
```javascript
function buildLayer0() {
    var result = [];
    var seenCounts = {};   // { appId: count so far }

    for (var i = 0; i < focusHistory.length; i++) {
        var entry = focusHistory[i];
        var appId = entry.appId;
        if (!seenCounts[appId]) seenCounts[appId] = 0;
        seenCounts[appId]++;

        var title = entry.title || window._resolveTitle(entry.address) || appId;
        result.push({
            address: entry.address,
            appId: appId,
            title: title,
            label: window.resolveName(appId),
            icon: window.resolveIcon(appId),
            windowNode: true,          // ← layer 0 nodes are now window-level
            badgeIndex: seenCounts[appId],  // 1st, 2nd, 3rd... within this app
            windows: [],               // ← no longer used at layer 0
            windowCount: 0,            // ← no longer used at layer 0
        });
    }

    // Append whitelisted placeholders (still app-level)
    var whitelist = cfg.whitelist || [];
    for (var w = 0; w < whitelist.length; w++) {
        var entry2 = whitelist[w];
        var alreadyPresent = false;
        for (var j = 0; j < focusHistory.length; j++) {
            if (focusHistory[j].appId === entry2.appId) { alreadyPresent = true; break; }
        }
        if (!alreadyPresent) {
            result.push({
                appId: entry2.appId, label: entry2.label, icon: entry2.icon,
                exec: entry2.exec, isWhitelistPlaceholder: true,
                windows: [], windowCount: 0,
            });
        }
    }

    log("buildLayer0: " + result.length + " nodes, first="
        + (result.length > 0 ? result[0].appId + "(" + result[0].badgeIndex + ")" : "empty"));
    return result;
}
```

#### Change 2 — Update `finishOpenSwitcher()` pre-selection

**Before:**
```javascript
selectedAppIndex = appOrder().length >= 2 ? 1 : 0;
```

**After:**
```javascript
selectedAppIndex = focusHistory.length >= 2 ? 1 : 0;
```

#### Change 3 — Update `rebuildToLayer()` for layer 0

The layer 0 → layer 1 transition and layer 1 → layer 0 transition need to
use `focusHistory` indexes instead of `appOrder()`.

#### Change 4 — Update `scheduleRebuild()` spawn auto-selection

The spawn auto-selection searches `sphereModel` for the spawned address.
Since layer 0 now has one node per window, the address-based match
(`_n.address === window._pendingSpawnAddr`) should work directly without
needing the appId fallback.

#### Change 5 — Badge rendering in sphere delegate

The badge code currently has separate logic for `isWindowNode` vs app nodes.
Layer 0 nodes now have `windowNode: true` and `badgeIndex`. Update the badge
rendering to use `badgeIndex`:

```javascript
text: {
    var n = window.sphereModel[index];
    if (!n) return "";
    if (n.isWhitelistPlaceholder) return "";
    if (n.windowNode || n.isWindowNode) {
        // Show window index within its app (1st, 2nd, 3rd...)
        return String(n.badgeIndex || "");
    }
    // Fallback (should not reach here for layer 0)
    return "";
}
```

#### Change 6 — Remove unused properties

* `_preSelectedAppId` — no longer needed (pre-selection is `focusHistory[1]`)
* `appOrder()` function — can be removed or kept for debug logging
* `windowCount` on layer 0 nodes — replaced by `badgeIndex`

### `binds.js`

#### Change 7 — Update `drillDown()` layer 0 → layer 1 pre-selection

The "other window" rule selects the window that is NOT the one the user
was just on at layer 0:

```javascript
if (window.layer === 0) {
    var selNode = window.sphereModel[window.selectedAppIndex];
    if (!selNode || selNode.isPlaceholder || selNode.isWhitelistPlaceholder) return;

    window.layer = 1;
    window.drilledAppId = selNode.appId;
    window.drilledAddress = selNode.address;  // ← save for "other window" logic
    window.sphereModel = window.buildLayer1(selNode.appId);

    // Pre-select the "other window" — not the one we were just on
    window.selectedAppIndex = 0;
    if (window.sphereModel.length >= 2) {
        // Find which index in layer 1 matches the window we were on
        var wasIdx = -1;
        for (var i = 0; i < window.sphereModel.length; i++) {
            if (window.sphereModel[i].address === window.drilledAddress) {
                wasIdx = i;
                break;
            }
        }
        // Select the OTHER one
        if (wasIdx === 0) window.selectedAppIndex = 1;
        else if (wasIdx === 1) window.selectedAppIndex = 0;
        else window.selectedAppIndex = 1; // fallback
    }

    window.projDirty = true;
    window.rebuildProjCache();
    window.centerOnApp(window.selectedAppIndex);
    window.log("drillDown 0→1: app=" + selNode.appId + " was=" + selNode.address.substring(selNode.address.length-6) + " sel=" + window.selectedAppIndex);
}
```

#### Change 8 — Update `drillDown()` layer 1 → layer 0

When returning from layer 1 to layer 0, select the node whose address
matches the window we were last viewing in layer 1:

```javascript
// In layer 1 → 0 path:
var returnAddr = window.sphereModel[window.selectedAppIndex]
    ? window.sphereModel[window.selectedAppIndex].address : null;
var raw = window.buildLayer0();
// ...
// Select the node matching returnAddr
for (var _si = 0; _si < window.sphereModel.length; _si++) {
    if (window.sphereModel[_si].address === returnAddr) {
        window.selectedAppIndex = _si;
        window.centerOnApp(_si);
        break;
    }
}
```

#### Change 9 — Update `commitSelection()` for layer 0

The commit target for a window node at layer 0 is the **window itself**
(its own address), not the app's MRU-most window:

```javascript
if (window.layer === 0 || (window.layer === 2 && !node.isWindowNode)) {
    // Layer 0: each node IS a window → target is the node's own address
    addr = node.address || "";
}
```

---

## What stays the same

| Component | Unchanged | Reason |
|---|---|---|
| `focusHistory` | Yes | Still the single source of truth |
| `moveToFront()` | Yes | Still mutates focusHistory on focus/commit |
| `addToFront()` | Yes | Still adds new windows to focusHistory |
| `removeAddress()` | Yes | Still removes closed windows |
| `windowsForApp(appId)` | Yes | Still used by layer 1 and search |
| `buildLayer1(appId)` | Yes | Still shows per-app windows |
| `buildSearchDatabase()` | Yes | Still builds from focusHistory |
| `_executeSearch()` | Yes | Still runs Fuse.js on search database |
| All dispatch helpers | Yes | dispatchFocus, dispatchClose, etc. |
| Debug logging | Yes | log() function stays |
| Layer 2 / search | Yes | Unchanged behavior |
| Layer 1 / drill-down | Yes | Unchanged behavior (window list per app) |
| Keybindings | Yes | Tab, `\`, `;`, Ctrl+C, Ctrl+Enter, Escape |

---

## What changes

| Component | Changes |
|---|---|
| `buildLayer0()` | Complete rewrite: one node per `focusHistory` entry |
| `finishOpenSwitcher()` | Pre-select `focusHistory[1]` instead of `appOrder()[1]` |
| `rebuildToLayer()` | Update selection logic for flat list |
| `drillDown()` | 0→1: "other window" compares addresses, not appIds |
| `drillDown()` | 1→0: select by address, not appId |
| `commitSelection()` | Layer 0 commit target = node's own address |
| Badge rendering | Use `badgeIndex` instead of `windowCount` |
| `_preSelectedAppId` | Remove (unused) |
| `appOrder()` | Remove or keep only for debug |

---

## Behaviour matrix

### Scenario: Ghostty-A (current), Ghostty-B (previous), Firefox (older)

```
focusHistory = [ghostty-a, ghostty-b, firefox]
buildLayer0() = [
  { appId: ghostty, title: "bash",         badgeIndex: 1, address: 0xAAA },
  { appId: ghostty, title: "nvim session", badgeIndex: 2, address: 0xBBB },
  { appId: firefox, title: "GitHub",       badgeIndex: 1, address: 0xCCC },
]
```

| Action | Before (PATCH_7) | After (PATCH_8) |
|---|---|---|
| Alt+Tab | Pre-selects **Firefox** (appOrder[1]) | Pre-selects **ghostty-b** (focusHistory[1]) |
| Tab | Firefox → Ghostty → Firefox | ghostty-b → Firefox → ghostty-a |
| `;` on ghostty-b | Opens ghostty's windows, selects "other" | Opens ghostty's windows, selects ghostty-a (not ghostty-b) |
| `;` back | Returns to app list, ghostty selected | Returns to flat list, ghostty-b still selected |
| Commit ghostty-b | Focuses ghostty's MRU-most window (ghostty-a) | Focuses **ghostty-b** (the specific window) |
| Badge on ghostty-b | `+2` (total ghostty windows) | `2` (second ghostty window) |

---

## Edge cases

### Whitelisted apps with no windows

Whitelisted placeholders still appear as app-level nodes (no address, no
badge). They're appended after all window nodes.

### "No windows" placeholder

When `focusHistory` is empty AND no whitelisted apps are configured, show
the "No windows" placeholder.

### Drill-down from whitelisted placeholder

Whitelisted placeholders have no windows and no address. `;` on them is
a no-op (guarded by `isWhitelistPlaceholder` check).

### Search (layer 2) behavior unchanged

Layer 2 still shows windows + whitelisted placeholders filtered by Fuse.js.
When pressing `;` from a search result, return to layer 0 and select by
address (Q5 confirmed).

### `;` from layer 1 → layer 0 after window close

If the window that was selected at layer 1 was closed (via Ctrl+C or
externally), the return to layer 0 falls back to index 0.

---

## Verification

```bash
# C1: buildLayer0 creates one node per focusHistory entry
grep -c 'badgeIndex' shell.qml
# Expected: at least 2 (buildLayer0 + badge rendering)

# C2: Pre-selection uses focusHistory, not appOrder
grep 'focusHistory.length >= 2 ? 1 : 0' shell.qml | wc -l
# Expected: at least 1 (finishOpenSwitcher)

# C3: Layer 0 commit targets node's own address
grep -A 5 'window.layer === 0' binds.js | grep -c 'node.address'
# Expected: at least 1

# C4: Drill-down 1→0 selects by address
grep -c 'returnAddr' binds.js
# Expected: 1 (declaration)
```
