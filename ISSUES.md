# Issues

Known bugs, edge cases, and limitations of hyprsphere.

---

## Issue 1: ~~Overlay loses keyboard focus after window close~~ **(RESOLVED)**

**Fix:** Brief `visible = false; Qt.callLater(function() { visible = true; })`
toggle in the `closewindow` event handler unmaps and remaps the overlay
surface, forcing the compositor to re-grant keyboard focus to the exclusive
layer surface. Flicker is imperceptible (both changes within one frame).

~~**Severity:** High — breaks all keyboard interaction after Ctrl+C when overlay is open.~~

### The problem

When `closeSelection()` dispatches `hl.dsp.window.close(...)` via `hyprctl`, Hyprland
closes the target window and immediately moves keyboard focus to the next available
XDG toplevel in its internal focus stack (usually the most recently focused window
before the closed one, e.g. Ghostty). The overlay — a `zwlr_layer_surface_v1` with
`keyboard_interactivity = exclusive` — should logically receive focus when on the
topmost layer, but Hyprland does not re-evaluate layer surface focus after
programmatic window closes.

The result: the overlay remains visible but the compositor sends keyboard events
to Ghostty. Escape, Tab, `;`, Alt release — all go to Ghostty, not the overlay.
The user must Alt+Tab again to get focus back, which reopens the cycle.

### What's been tried (and why it didn't fully work)

| Attempt | Result |
|---|---|
| `focusGrabber.forceActiveFocus()` in `closewindow` event handler | QML reports `activeFocus=true` but this only sets focus within the QML scene graph — it does not translate to a Wayland `wl_surface` activation request. The compositor continues sending keyboard events to the XDG toplevel. |
| `window.focusable = false; window.focusable = true;` then `forceActiveFocus()` | Changing `focusable` sends a `zwlr_layer_surface_v1.set_keyboard_interactivity` request to the compositor, but Hyprland does not re-evaluate layer surface focus just because the property changed — it only checks this at surface map time. |
| `hyprctl dispatch focuswindow pid:$PPID` (re-focus by PID) | Layer surfaces are not XDG toplevels — they don't appear in `hyprctl clients -j` and can't be focused by PID. `hl.dsp.focus({window="pid:..."})` returns "window not found". |
| Deferred `forceActiveFocus` via `Qt.callLater` (next event loop tick) | Same as first attempt — QML focus ≠ Wayland surface activation, regardless of timing. |
| `WlrLayershell.layer` flip (`Overlay → Top → Overlay`) | Changing the layer sends a `zwlr_layer_surface_v1.set_layer` request, which should trigger the compositor to re-arrange layer surfaces and reassess keyboard focus. *Not yet confirmed working — needs testing.* |
| `window.visible = false; window.visible = true` (unmap/remap) | Forces the compositor to re-map the surface and re-evaluate focus, but causes a visible black frame flicker as the surface is momentarily destroyed and recreated. |

### Why this is hard

The fundamental issue is a gap between Qt/QML's focus model and Wayland's focus model:

- **Qt/QML:** `Item.forceActiveFocus()` sets the active focus item within a window's
  QML scene. It works across siblings and FocusScopes within the same window.
  It does NOT request surface-level activation from the Wayland compositor.

- **Wayland:** Keyboard focus is managed by the compositor. A `wl_surface` receives
  keyboard enter/leave events based on the compositor's focus policy. For layer
  surfaces with `keyboard_interactivity = exclusive`, the compositor SHOULD give
  focus when the surface is on the topmost layer — but only at surface map time,
  not when focus is moved away by a window close event.

- **Hyprland:** After `closewindow`, Hyprland walks its internal XDG toplevel stack
  and focuses the next window. It does not re-check whether an exclusive layer
  surface wants focus. This appears to be a Hyprland-specific behavior; other
  compositors (e.g. KWin) may handle this differently.

### What is needed

A reliable Wayland-level mechanism to tell Hyprland "give keyboard focus back to
this layer surface." Options to explore:

1. **Confirm if `WlrLayershell.layer` flip works** — may need more careful testing
   (e.g., longer delay between layer changes, or a different layer combination)
2. **Use `window.visible` toggle with a `Timer` to hide the flicker** — if the
   unmap/remap happens at 60fps, the flicker might be imperceptible with proper
   double-buffering
3. **Use a Wayland protocol extension** — `ext_session_lock_manager_v1`,
   `wp_activation_v1`, or similar to request surface activation
4. **Make the close not trigger focus loss** — close windows indirectly (e.g.,
   use `killactive` on a temporarily-focused window, or use a different approach
   entirely)
5. **Accept the limitation** — document that after Ctrl+C, the user must tap
   Alt+Tab once to re-focus the overlay
