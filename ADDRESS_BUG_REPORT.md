# Bug Report: Inconsistent window address format across Hyprland IPC APIs

## Summary

Window addresses returned by different Hyprland IPC APIs use different
formats — some return the raw decimal form, others return the hexadecimal
form with a `0x` prefix. This forces consumers to implement fragile
ad-hoc normalisation that is easy to get wrong, leading to silent failures
in window matching, MRU tracking, and event handling.

## Affected APIs

### 1. Toplevel properties (`Hyprland.toplevels`, `Hyprland.activeToplevel`)

The `address` field of toplevel objects returns addresses in **raw decimal
format** (no prefix):

```
t.address → "101839840165184"
t.address → "108519689291328"
```

### 2. Raw events (`openwindow`, `closewindow`)

The `event.data` field for `openwindow` and `closewindow` events returns
addresses in **0x-prefixed hexadecimal format**:

```
openwindow event data  → "0x5cb8a4e2a040,0x5cb8a4e2a040,firefox"
closewindow event data → "0x5cb8a4e2a040"
```

### 3. `clients` IPC response (from `j/clients`)

Addresses in the `j/clients` Hyprland IPC response are in raw decimal
format (matching toplevel properties):

```json
{
  "address": "101839840165184",
  ...
}
```

## Impact

When a consumer maintains an internal MRU list by merging data from
multiple APIs (e.g., initialising from `j/clients` on startup, updating
from `openwindow` events for new windows, and from `activeToplevel`
changes for focus tracking), the format mismatch causes several classes
of silent failure:

| Operation | Source format | Stored format | Comparison | Result |
|---|---|---|---|---|
| Add window from `openwindow` event | `0x`-prefixed | `0x`-prefixed | — | OK |
| Add window from `activeToplevel` change | raw decimal | stored as-is (no prefix) | — | OK in isolation |
| Match against stored list | depends on source | **mixed** | `===` | **Silent miss** |
| Remove window on `closewindow` event | `0x`-prefixed | mixed | `indexOf()` | **Silent miss** |

The result is that windows may silently accumulate in MRU lists (never
removed on close), fail to match during search/drill-down, or cause
incorrect targeting when switching between windows.

## Expected behaviour

All IPC APIs should return window addresses in a **consistent format**.
The hexadecimal `0x`-prefixed format is preferred because:

1. It is the standard format used by Hyprland's own dispatch commands
   (`hl.dsp.focus({window="address:0x..."})`)
2. It is unambiguous about being a hex value
3. It is consistent with how addresses appear in `hyprctl` output

## Proposed fix

Normalise `t.address` and the address field in `j/clients` responses to
include the `0x` prefix, matching the format used by raw events and
dispatch commands. Alternatively, if the raw decimal format is preferred,
normalise `event.data` in the opposite direction.

The key requirement is **one format, everywhere** — consumers should not
need to inspect every address to determine which format it arrived in.

## Workaround (for downstream consumers)

```javascript
function normaliseAddress(addr) {
    if (!addr) return "";
    return addr.indexOf("0x") === 0 ? addr : "0x" + addr;
}
```

This must be applied at every point an address enters the system:

| Entry point | Source | Apply normalisation |
|---|---|---|
| Toplevel properties | `t.address` | `normaliseAddress(t.address)` |
| Raw events | `event.data` | Already `0x`-prefixed (no-op) |
| `j/clients` IPC response | `"address"` field | `normaliseAddress(item.address)` |

This is fragile — a new API endpoint or a change in an existing one would
require updating every normalisation site.
