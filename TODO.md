# TODO

## Peek: disambiguate identical-title windows (open item)

### Problem

The peek snapshot matches the selected window to a `ScreencopyView` capture
source by **`appId` + `title`** (see README "Known Limitations → Peek snapshot
matching is title-based"). Two windows of the *same app* with *identical
titles* cannot be distinguished, so the snapshot may show the wrong window.

### Root cause

Quickshell's `ScreencopyView` captures a window via
`hyprland-toplevel-export-v1`'s `capture_toplevel_with_wlr_toplevel_handle`
request, which requires a `zwlr_foreign_toplevel_handle_v1` (a
"foreign-toplevel handle"). That handle exposes `appId` + `title` (+ `parent`,
`activated`, `screens`, …) but **not** the window's unique `0x…` address. The
address only lives on `Hyprland.toplevels` (from `j/clients`), which
`ScreencopyView` rejects as a capture source. So the only overlapping fields
between the two sources are `appId` + `title`.

### Options

1. **Leave as-is** (current decision) — document the limitation.
   - Pros: zero work, no architecture change, daemon-free preserved.
   - Cons: wrong snapshot is possible in the (rare) identical-title case.

2. **Patch/fork Quickshell** to also implement the `capture_toplevel(…, handle)`
   (address) request and expose an address-based capture source on
   `ScreencopyView`.
   - Pros: exact address-based matching, no ambiguity.
   - Cons: must maintain a Quickshell fork/overlay (NixOS), coupled to
     Quickshell's release cadence.

3. **Helper process** that speaks `hyprland-toplevel-export-v1` directly with
   the window address, writes the frame to a shared buffer/PNG, and has
   Quickshell display it via an `Image`.
   - Pros: exact address-based matching, no Quickshell fork.
   - Cons: adds a long-running/helper process (breaks the current daemon-free
     property), more moving parts and lifecycle management.

4. **Smarter in-process matching** — use the foreign handle's extra fields
   (`activated`, `parent`, `screens`, or handle-list ordering) to disambiguate
   when `(appId, title)` collides.
   - Pros: stays in-process, no fork, no new process.
   - Cons: partial mitigation only — some collisions are genuinely
     indistinguishable without the address (ordering is not guaranteed to
     correlate with `Hyprland.toplevels`).

### Recommendation

Keep option **1** for now. If identical titles become a real problem, option
**3** is the clean *correct* fix at the cost of one helper process; option **2**
is the correct fix with no extra process but a Quickshell fork.

---

## `normalizeAddress()` mishandles non-finite address strings

### Bug

`shell.qml`'s `normalizeAddress()` treats `"Infinity"` (and `"-Infinity"`) as a
valid address:

```javascript
function normalizeAddress(addr) {
    if (!addr) return "";
    if (addr.indexOf("0x") === 0) return addr;
    var num = Number(addr);
    if (!isNaN(num)) return "0x" + num.toString(16);   // ← Number("Infinity") = Infinity
    return "0x" + addr;
}
```

`Number("Infinity")` → `Infinity`, and `isNaN(Infinity) === false`, so the
function returns `"0xInfinity"`. Observed in production: a Firefox toplevel in
`j/clients` reports an address that normalizes to a garbage value (logged as
`addr=finity`).

### Impact

The affected window gets a bogus address, so it never matches anything in
`focusHistory` — it's effectively skipped/treated as a ghost. Harmless in
practice, but incorrect.

### Fix

Use `isFinite()` instead of `!isNaN()`:

```javascript
function normalizeAddress(addr) {
    if (!addr) return "";
    if (addr.indexOf("0x") === 0) return addr;
    var num = Number(addr);
    if (isFinite(num)) return "0x" + num.toString(16);
    return "0x" + addr;
}
```

`isFinite()` rejects `NaN`, `Infinity`, and `-Infinity` in a single check.
