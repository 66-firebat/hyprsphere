# PATCH_5 — Window-based sphere ordering

> **This is a fundamental change to how the sphere is ordered.** Currently the
> sphere sorts app groups by `appMru` (app-level MRU). After this patch, the
> sphere sorts app groups by `globalWindowMru` (window-level MRU). Tab walks
> backward through window history, Shift+Tab walks forward. The sphere stays
> on the same app group when consecutive windows in the history belong to the
> same app.

---

## Motivation

### The problem

The current sphere ordering uses `appMru` — a list of app IDs sorted by which
app was most recently committed. This creates a disconnect between the
window-based MRU tracking (`globalWindowMru`) and what the user sees on the
sphere:

```
globalWindowMru = [Firefox, Ghostty_A, Ghostty_B, Blender]
appMru          = [ghostty, firefox, blender]  ← Ghostty is first!

Sphere sorted by appMru:
  index 0: Ghostty  ← committed most recently
  index 1: Firefox  ← committed before Ghostty
  index 2: Blender
```

When Alt+Tab pre-selects `globalWindowMru[1]` = Ghostty, Ghostty happens to
be at sphere index 0. Shift+Tab wraps to the last item (GIMP/Blender/etc.)
instead of going to Firefox (the current window).

### The solution

Sort the sphere directly by `globalWindowMru`. Each window address in
`globalWindowMru` maps to an app group on the sphere. Consecutive windows
that belong to the same app map to the same app group, so the sphere "stays"
on that app group until the window history moves to a different app.

```
globalWindowMru = [Firefox_addr, Ghostty_A_addr, Ghostty_B_addr, Blender_addr]

Sphere (deduplicated by app, preserving window MRU order):
  index 0: Firefox    ← globalWindowMru[0]: current window
  index 1: Ghostty    ← globalWindowMru[1] + [2]: two Ghostty windows
  index 2: Blender    ← globalWindowMru[3]

Tab (forward):    1 → 2 → ... (deeper into history)
Shift+Tab:        1 → 0 → end → end-1 → ... (back toward current, then wrap)
```

---

## The new ordering model

### `sortByWindowMru(raw)` — replaces `sortByMru(raw)`

```javascript
function sortByWindowMru(raw) {
    // Build a map: appId → app group object
    var rawByApp = {};
    for (var r = 0; r < raw.length; r++) {
        rawByApp[raw[r].appId] = raw[r];
    }

    // Walk globalWindowMru in order, collecting app groups in the
    // order their first window appears, deduplicating by appId.
    var seen = {};
    var sorted = [];
    for (var i = 0; i < globalWindowMru.length; i++) {
        var addr = globalWindowMru[i];
        var appId = _findAppForAddress(addr);
        if (appId && !seen[appId] && rawByApp[appId]) {
            seen[appId] = true;
            sorted.push(rawByApp[appId]);
        }
    }

    // Append any app not in globalWindowMru (e.g. whitelisted placeholders)
    // in their original order, preserving "whitelisted after running apps".
    for (var r = 0; r < raw.length; r++) {
        if (!seen[raw[r].appId]) {
            sorted.push(raw[r]);
        }
    }

    return sorted;
}
```

### Behaviour

| Scenario | Before (appMru) | After (globalWindowMru) |
|---|---|---|
| On Ghostty, Firefox was previous | sphere: [Ghostty, Firefox, ...] | sphere: [Ghostty, Firefox, ...] — same |
| On Ghostty, Firefox was previous; commit Firefox | sphere: [Ghostty, Firefox, ...] — Ghostty at 0 wraps | sphere: [Firefox, Ghostty, ...] — Ghostty at 1, Tab=deeper |
| Ghostty_A + Ghostty_B + Firefox | Depends on appMru order | sphere: [Ghostty, Firefox] — Ghostty at 0, Firefox at 1 |
| Two Ghostty windows, then Firefox, then Ghostty again | Depends on appMru order | sphere: [Ghostty, Firefox] — same app group for both Ghostty entries |

### Tab/Shift+Tab navigation

`advance()` already navigates through sphere items with wrapping at edges.
The new ordering changes which app is at which index, but the navigation
mechanics stay the same:

- Alt+Tab → `selectedAppIndex` set to the sphere index of the app owning
  `globalWindowMru[1]` (the previous window)
- **Tab (`advance(1)`):** forward through the sphere. Given the sphere is
  ordered by window MRU, forward = deeper into window history.
- **Shift+Tab (`advance(-1)`):** backward through the sphere with wrapping.
  Given the sphere is ordered by window MRU, backward = toward the current
  window, then wraps to the oldest.

**Key difference from today:** Today, `appMru` puts the most recently
committed app first, so the pre-selected app is often at index 0 and
Shift+Tab wraps to the last whitelisted app. After the change, the sphere
ordering matches `globalWindowMru`, so the pre-selected app (`[1]`) is
always at a position with the current window (`[0]`) before it and history
(`[2]`, `[3]`, ...) after it.

**Wrapping:** `advance()` wraps at sphere edges regardless of ordering.
From the last sphere item, Tab goes to the first (current window).
From the first sphere item, Shift+Tab goes to the last (oldest history).

| Sphere index | globalWindowMru index | Meaning |
|---|---|---|
| 0 | `[0]` | Current window (the one you were on before Alt+Tab) |
| 1 | `[1]` | Previous window → **pre-selected by Alt+Tab** |
| 2 | `[2]` | Window before that |
| ... | ... | Deeper history |
| N | last | Oldest tracked window |

---

## Implementation changes

### File: `shell.qml`

#### Change 1 — Replace `sortByMru()` with `sortByWindowMru()`

Replace the function definition entirely. The new function iterates
`globalWindowMru` and deduplicates app groups.

#### Change 2 — Update all call sites

`sortByMru` is called in:

| Location | Change |
|---|---|
| `finishOpenSwitcher()` — building initial sphere | `sortByMru(raw)` → `sortByWindowMru(raw)` |
| `cancelSearch()` — returning from layer 2 to layer 0 | `sortByMru(raw)` → `sortByWindowMru(raw)` |
| `drillDown()` — layer 1 → layer 0 return path | `sortByMru(raw)` → `sortByWindowMru(raw)` |
| `rebuildToLayer0()` — layer 0 rebuild | `sortByMru(raw)` → `sortByWindowMru(raw)` |

#### Change 3 — Remove `_findAppForAddress()` dependency issue

`_findAppForAddress()` searches `sphereModel` for the address. But
`sortByWindowMru()` needs to search BEFORE the sphere is built. We need
`_findAppForAddress` to search the raw data (`buildLayer0` output) instead
of `sphereModel`.

**Fix:** Add a parameter `_findAppForAddress(addr, source)` where `source`
defaults to `window.sphereModel` but can be set to the raw array.

OR: Build a temporary `appIdByAddress` map in `sortByWindowMru()` from the
raw input, avoiding `_findAppForAddress` entirely.

```javascript
function sortByWindowMru(raw) {
    // Build address → appId lookup from raw data
    var addrToApp = {};
    for (var r = 0; r < raw.length; r++) {
        var app = raw[r];
        for (var w = 0; w < (app.windows || []).length; w++) {
            var a = app.windows[w].address || "";
            if (a.indexOf("0x") !== 0) a = "0x" + a;
            addrToApp[a] = app.appId;
        }
    }

    // Build rawByApp lookup
    var rawByApp = {};
    for (var r = 0; r < raw.length; r++) {
        rawByApp[raw[r].appId] = raw[r];
    }

    // Walk globalWindowMru
    var seen = {};
    var sorted = [];
    for (var i = 0; i < globalWindowMru.length; i++) {
        var addr = globalWindowMru[i];
        var appId = addrToApp[addr];
        if (appId && !seen[appId] && rawByApp[appId]) {
            seen[appId] = true;
            sorted.push(rawByApp[appId]);
        }
    }

    // Append unseen (whitelisted placeholders, etc.)
    for (var r = 0; r < raw.length; r++) {
        if (!seen[raw[r].appId]) {
            sorted.push(raw[r]);
        }
    }

    return sorted;
}
```

This avoids `_findAppForAddress` entirely and builds the lookup from the
raw data that's already available.

---

## Behaviour matrix

### Scenario 1: Ghostty (current), Firefox (previous)

```
globalWindowMru = [Ghostty, Firefox]
sphere = [Ghostty, Firefox]
```

| Key | Action | Result |
|---|---|---|
| Alt+Tab | pre-select `globalWindowMru[1]`=Firefox | Firefox at index 1 |
| Tab | forward from 1 → 0 (wrap) | Or: stay at 1 if end? |
| Shift+Tab | backward from 1 → 0 | **Ghostty** (current window) ✅ |

Actually wait — the sphere is `[Ghostty, Firefox]`. Alt+Tab pre-selects
Firefox at index 1. Tab from 1 → 2 wraps to 0 (Ghostty). Shift+Tab from
1 → 0 (Ghostty). Both Tab and Shift+Tab go to Ghostty from index 1... 
that's because there are only 2 items. With 3+:

### Scenario 2: Ghostty (current), Firefox (previous), Blender (older)

```
globalWindowMru = [Ghostty, Firefox, Blender]
sphere = [Ghostty, Firefox, Blender]
```

| Key | Action | Result |
|---|---|---|
| Alt+Tab | pre-select Firefox (index 1) | Firefox at index 1 |
| Tab | forward 1 → 2 | **Blender** ✅ (older history) |
| Shift+Tab | backward 1 → 0 | **Ghostty** ✅ (current window) |
| Tab, Tab | 1 → 2 → 0 (wrap) | Ghostty again |
| Shift+Tab, Shift+Tab | 1 → 0 → 2 (wrap) | Blender (oldest) |

### Scenario 3: Ghostty (current), Firefox (previous), committed Firefox

After committing Firefox:
```
globalWindowMru = [Firefox, Ghostty]
sphere = [Firefox, Ghostty]
```

| Key | Action | Result |
|---|---|---|
| Alt+Tab | pre-select Ghostty (index 1) | Ghostty at index 1 |
| Tab | forward 1 → 0 (wraps) or stays | (depends on wrap behavior) |
| Shift+Tab | backward 1 → 0 | **Firefox** ✅ (current window) |
| Tab, Tab | 1 → 0 → 1 (full cycle) | Back to Ghostty |

### Scenario 4: Two Ghostty windows

```
globalWindowMru = [Ghostty_A, Firefox, Ghostty_B]
sphere = [Ghostty, Firefox]  ← Ghostty_B maps to same app
```

| Key | Action | Result |
|---|---|---|
| Alt+Tab | pre-select `globalWindowMru[1]`=Firefox | Firefox at index 1 |
| Tab | forward 1 → 0? | Ghostty (only 2 items) |
| Shift+Tab | backward 1 → 0 | Ghostty |

Wait — `globalWindowMru[1]` is Firefox, which maps to sphere index 1.
`globalWindowMru[0]` is Ghostty_A, which maps to sphere index 0.
`globalWindowMru[2]` is Ghostty_B, which ALSO maps to sphere index 0.

So from Firefox (index 1):
- Tab (forward) → next in window history is Ghostty_B → maps to sphere index 0 → **Ghostty**
- Shift+Tab (backward) → prev in window history is Ghostty_A → maps to sphere index 0 → **Ghostty**

Both Tab and Shift+Tab go to Ghostty because the same app owns both the
previous and next window addresses. The sphere can't differentiate between
them at layer 0 — that's what drill-down (layer 1) is for.

---

## Edge cases

| Scenario | Expected behaviour |
|---|---|
| `globalWindowMru` empty (first launch) | Fall back to raw order (whitelisted placeholders) |
| No windows match `globalWindowMru` (special workspaces) | Show whitelisted placeholders only |
| `globalWindowMru[0]` address not in raw data | Skip it, continue to next address |
| Whitelisted app with no windows | Appended at end of sorted list |
| Consecutive same-app windows in MRU | Deduplicated — sphere stays on same app group |
| Window close during overlay | `scheduleRebuild` picks up updated `globalWindowMru` |
| After commit (MRU unfrozen) | `globalWindowMru` already updated by sync in `commitSelection` |

---

## Files to change

| File | Changes |
|---|---|
| `shell.qml` | Replace `sortByMru()` with `sortByWindowMru()`; update 4 call sites |
| `patches/PATCH_5.md` | This document |

---

## Verification

```bash
# C1: sortByWindowMru function exists
grep -c 'function sortByWindowMru' shell.qml
# Expected: 1

# C2: No references to old sortByMru remain
grep -c 'sortByMru' shell.qml
# Expected: 0

# C3: All call sites updated
grep -c 'sortByWindowMru' shell.qml
# Expected: at least 4 (definition + 4 call sites = 5)
```

---

## Manual tests

### W1. Basic window ordering
**Setup:** Ghostty (current), Firefox (previous).
1. Alt+Tab → sphere shows [Ghostty, Firefox] (window MRU order)
2. Satellite shows Firefox (index 1)
3. Shift+Tab → satellite shows Ghostty (index 0)

### W2. Deeper history
**Setup:** Ghostty (current), Firefox (previous), Blender (older).
1. Alt+Tab → satellite shows Firefox
2. Tab → satellite shows Blender
3. Tab → wraps to Ghostty
4. Shift+Tab from Ghostty → wraps to Blender

### W3. Commit then reopen
**Setup:** Ghostty (current), Firefox (previous).
1. Alt+Tab → commit Firefox
2. Alt+Tab → sphere shows [Firefox, Ghostty]
3. Satellite shows Ghostty (index 1)
4. Shift+Tab → satellite shows Firefox (index 0)

### W4. Same-app windows
**Setup:** Ghostty_A, Ghostty_B, Firefox.
1. Focus Ghostty_A → Focus Firefox → Focus Ghostty_B
2. Alt+Tab → satellite shows Firefox (globalWindowMru[1])
3. Tab → Ghostty (same app for [2] = Ghostty_B)
4. Shift+Tab → Ghostty (same app for [0] = Ghostty_A)
5. Drill-down to verify both windows are in the list
