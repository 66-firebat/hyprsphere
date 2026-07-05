# PHASE_5 — Ctrl+C close windows ✅ COMPLETE

**Deliverable:** Ctrl+C at layer 0 closes all windows of the selected app,
moves selection to the next MRU app. Ctrl+C at layer 1 closes the selected
window, moves selection to the next MRU window (index 0). Overlay stays
open throughout. Whitelist placeholder entries are no-ops.

**Status:** Implemented and tested. Fixed focus-lost-after-close by
unmap/remap visible toggle. Fixed MRU ordering by handling `openwindow`
events and cleaning stale `"unknown"` appId entries. Fixed SHIFT+Tab
selecting same-as-current app.

---

## Implementation plan

### 0. Preconditions

The following already exist in `hyprsphere.qml`:
- `layer`, `drilledAppId`, `sphereModel`, `selectedAppIndex`
- `appMru`, `appWindowMru`
- `onRawEvent` handler for `closewindow>>` events (prunes MRU + calls `scheduleRebuild()`)
- `scheduleRebuild()` — layer-aware, address-preserving, falls back to index 0 if selection is gone
- `closeSequence.running` guard pattern
- `Quickshell.execDetached` pattern for Lua dispatch commands

### 1. Add close handler to Keys.onPressed

In the `focusGrabber` Item's `Keys.onPressed`, add a handler for
`Qt.Key_C` with `Qt.ControlModifier`:

```qml
Keys.onPressed: (event) => {
    // ... existing Tab/;/Escape handlers ...

    } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
        window.closeSelection();
        event.accepted = true;
    }
}
```

Place it between the `;` handler and the Escape handler so the priority
order is: Tab first, then `;` drill, then Ctrl+C close, then Escape.

### 2. Add `closeSelection()` function

Add a new function that handles closing at both layers:

```qml
function closeSelection() {
    // Guard: if the overlay is already closing, no-op
    if (closeSequence.running) return;

    var node = sphereModel[selectedAppIndex];
    if (!node || node.isPlaceholder || node.isWhitelistPlaceholder) return;

    if (window.layer === 0) {
        // Layer 0: close ALL windows of the selected app group
        var prefix = "";
        for (var w = 0; w < node.windows.length; w++) {
            var addr = node.windows[w].address;
            var pfx = addr.indexOf("0x") === 0 ? "" : "0x";
            Quickshell.execDetached(["hyprctl", "dispatch",
                'hl.dsp.window.close({window="address:' + pfx + addr + '"})']);
        }
        // Selection moves to index 0 on next rebuild (scheduleRebuild handles it)
    } else {
        // Layer 1: close the specific selected window
        var prefix = addr.indexOf("0x") === 0 ? "" : "0x";
        var addr = node.address;
        Quickshell.execDetached(["hyprctl", "dispatch",
            'hl.dsp.window.close({window="address:' + prefix + addr + '"})']);
        // Selection moves to index 0 on next rebuild
    }
}
```

Key behaviour:
- At **layer 0**: iterates all windows in the app group, dispatches close for each
- At **layer 1**: dispatches close for the single selected window
- After close: `closewindow>>` event fires → `onRawEvent` prunes MRU → `scheduleRebuild()` refreshes sphere
- `scheduleRebuild()` at layer 1: selected address is now gone → falls to index 0 (MRU-most remaining)
- `scheduleRebuild()` at layer 0: app may be gone entirely → clamps to `length - 1`
- Whitelist placeholder: `isWhitelistPlaceholder` guard returns early
- "No windows" placeholder: `isPlaceholder` guard returns early

### 3. No overlay state changes

Unlike `commitSelection()`, closing a window does NOT close or hide the
overlay. The overlay stays open, `overlayActive` stays `true`, and the
user can continue Tab-cycling, drilling down, or pressing Ctrl+C again.

The sphere refreshes naturally via the existing `scheduleRebuild()` path
when the `closewindow>>` event arrives.

### 4. Edge cases handled by existing code

| Case | How it's handled |
|---|---|
| Rapid Ctrl+C | Hyprland ignores close on already-closing window. Existing `scheduleRebuild()` refresh race is noted (same as Phase 4). |
| Last window of app closed (layer 1) | `scheduleRebuild()` finds app gone → bounces to layer 0, clamps to `length - 1` |
| App completely disappears | `rebuildToLayer0()` clamps selectedAppIndex to `length - 1`. If only whitelist entries remain, they show as normal. |
| Close at layer 0 with 1 window | Same as closing last window — app disappears from layer 0. |
| Ctrl+C while already in closeSequence (Escape pressed) | `closeSequence.running` guard returns early. |

---

## Exit criteria

1. **Ctrl+C at layer 0** closes all windows of the selected app group,
   app disappears from sphere, selection moves to next MRU app
2. **Ctrl+C at layer 1** closes the selected window, sphere rebuilds,
   selection moves to index 0 (MRU-most remaining window)
3. **Ctrl+C on whitelist placeholder** is a no-op (nothing to close)
4. **Ctrl+C on "No windows" placeholder** is a no-op (nothing to close)
5. **Rapid Ctrl+C** doesn't crash or get stuck — second press on an
   already-closing window is harmless
6. **Overlay stays open** after close — no fade, no `visible = false`
7. **Sphere refresh** happens automatically via `closewindow>>` event →
   `scheduleRebuild()`
8. **Layer 1 → single window remains** stays at layer 1 (consistent with
   Phase 4 drill-down rule)

---

## Implementation notes (discovered during coding)

### Bug 1: Overlay loses Wayland keyboard focus after window close

When `hl.dsp.window.close()` is dispatched, Hyprland closes the target
window and moves keyboard focus to the next XDG toplevel in its focus
stack (e.g., Ghostty). The overlay — a `zwlr_layer_surface_v1` with
`keyboard_interactivity = exclusive` — should receive focus when on the
topmost layer, but Hyprland does not re-evaluate layer surface focus
after programmatic window closes.

**Attempted fixes that did NOT work:**
- `focusGrabber.forceActiveFocus()` — only sets QML-internal focus, does
  not activate Wayland surfaces
- `window.focusable = false; true` — toggling keyboard_interactivity does
  not trigger compositor re-evaluation
- `hyprctl dispatch focuswindow pid:$PPID` — layer surfaces can't be
  focused by PID (they're not XDG toplevels)
- `WlrLayershell.layer` flip (Overlay → Top → Overlay) — may trigger
  re-evaluation but wasn't confirmed

**Working fix:** Briefly unmap and remap the overlay surface:
```qml
window.visible = false;
Qt.callLater(function() {
    window.visible = true;
    // onVisibleChanged fires → forceActiveFocus
});
```
When the surface is destroyed and re-created, the compositor processes
the new layer surface with `exclusive` keyboard interactivity and grants
it keyboard focus. The flicker is imperceptible because the unmap/remap
happens within a single frame (both property changes commit on the same
event loop tick).

### Bug 2: `scheduleRebuild()` skipped when overlay is hidden

`scheduleRebuild()` checked `if (!window.visible) return;` at the start
of its deferred callback. When the visible toggle set `visible = false`,
the pending rebuild was silently skipped, leaving stale sphere data.

**Fix:** Removed the visibility check from `scheduleRebuild()`. The
rebuild is cheap (just iterating `Hyprland.toplevels`) and should run
regardless of overlay visibility — the sphere data may be needed when
the overlay reappears.

### Bug 3: MRU misordered after whitelist launch

When `onActiveToplevelChanged` skipped null `wayland.appId` values,
newly launched windows (e.g., Kicad from whitelist) were never tracked
in MRU because their appId was null during the Wayland handshake.

**Fix:** Reverted to the original `"unknown"` fallback for unresolved
appIds, plus added cleanup: when `onActiveToplevelChanged` fires with
a real appId, any stale `"unknown"` entry is removed from `appMru`.
This prevents `"unknown"` from polluting the MRU order.

### Bug 4: `hl.dsp.window.close` silently returns "ok" without closing

The `closewindow` dispatcher (and the deprecated `hyprctl dispatch
closewindow address:0x...`) fails with a Lua syntax error due to the
colon in `address:` when used in raw dispatch mode. The correct Lua
dispatch format `hl.dsp.window.close({window="address:0x..."})` must
be used.

Also discovered: the address from `HyprlandToplevel.address` does NOT
include the `0x` prefix, but `hyprctl` dispatches expect `0x`. The
`0x` prefix must be added explicitly.
