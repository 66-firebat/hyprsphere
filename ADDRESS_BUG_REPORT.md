# Bug Report: Inconsistent window address format across Quickshell's Hyprland IPC module

**Note:** This is a **Quickshell** issue, not a Hyprland issue. The
underlying Hyprland APIs are consistent — it is Quickshell's IPC module
that introduces the inconsistency.

## Summary

Quickshell's `Quickshell.Hyprland._Ipc` module bridges between two
Hyprland subsystems: the **JSON IPC** (used by `j/clients` to enumerate
toplevels) and the **event socket** (used by `openwindow`/`closewindow`
events). These two subsystems return window addresses in different formats,
and Quickshell surfaces them both without normalisation, forcing
consumers to implement fragile ad-hoc format detection.

## Affected APIs within Quickshell

### 1. `Hyprland.activeToplevel.address` / `Hyprland.toplevels[].address`

Populated from Hyprland's `j/clients` JSON IPC response, which returns
addresses as **raw decimal strings** (no prefix, no hex indication):

```qml
Hyprland.activeToplevel.address → "101839840165184"
```

These are exposed via Quickshell's `HyprlandToplevel::addressStr()` C++
property, which reads the address directly from the parsed JSON without
transforming it.

### 2. `onRawEvent` event data (`openwindow`/`closewindow`)

Quickshell surfaces Hyprland's raw event socket data as-is. The Hyprland
event socket uses **0x-prefixed hexadecimal format**:

```qml
// openwindow event data:
"0x5cb8a4e2a040,0x5cb8a4e2a040,firefox"

// closewindow event data:
"0x5cb8a4e2a040"
```

### Root cause

Both formats originate from Hyprland and are internally consistent within
their respective subsystems:

| Hyprland subsystem | Address format | Example |
|---|---|---|
| `j/clients` JSON IPC | Decimal | `"101839840165184"` |
| Event socket | `0x`-prefixed hex | `"0x5cb8a4e2a040"` |

Quickshell's IPC module exposes both without normalising, so a QML
consumer that listens to both sources receives addresses in two different
formats.

## Impact

When a QML consumer maintains internal state by merging data from both
sources (e.g., building an MRU list from `j/clients` on startup,
tracking focus changes via `onActiveToplevelChanged`, and handling
window opens/closes via `onRawEvent`), the format mismatch causes
silent failures:

| Operation | Source format | Stored format | Comparison | Result |
|---|---|---|---|---|
| Add window from `openwindow` event | `0x`-prefixed | `0x`-prefixed | — | OK |
| Add window from `activeToplevel` change | raw decimal | stored as-is | — | OK in isolation |
| Match against stored list | depends on source | **mixed** | `===` | **Silent miss** |
| Remove window on `closewindow` event | `0x`-prefixed | mixed | `indexOf()` | **Silent miss** |

## Expected behaviour

`HyprlandToplevel::address()` should return addresses in `0x`-prefixed
hexadecimal format, matching the event socket format. This way all
addresses within Quickshell's Hyprland module use a single, consistent
format.

## Proposed fix

In Quickshell's `HyprlandToplevel` C++ class, normalise the address when
it is parsed from the `j/clients` JSON response:

```cpp
// In HyprlandToplevel::addressStr() or the JSON parse site:
QString address = obj["address"].toString();
if (!address.startsWith("0x"))
    address = "0x" + address;
```

This would make `t.address` consistent with `event.data` without
changing any consumer code — callers that already work with the decimal
form would need to remove their own normalisation, but that is a minor
cleanup compared to the silent bugs the mismatch currently causes.

## Workaround (for downstream QML consumers)

Until the fix is in Quickshell, consumers must normalise at every entry
point:

```javascript
function normaliseAddress(addr) {
    if (!addr) return "";
    return addr.indexOf("0x") === 0 ? addr : "0x" + addr;
}
```

| Entry point | Apply normalisation |
|---|---|
| `t.address` from toplevel properties | `normaliseAddress(t.address)` |
| `event.data` from raw events | No-op (already `0x`-prefixed) |
