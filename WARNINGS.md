# PolySphere — Considerations & Lessons Learned

This file documents the non-obvious issues, edge cases, and design decisions encountered during PolySphere development. Read this before making changes to avoid repeating the same mistakes.

---

## 1. Key Handling: Hyprland Eats Alt+Tab

**Issue:** Hyprland's `ALT + Tab` bind consumes the key event at the compositor level *before* the QML application ever sees it. `Keys.onPressed` for `Qt.Key_Tab` with `Qt.AltModifier` never fires.

**Fix:** Move Tab cycling into an **IPC function** (`cycle()`) that the Hyprland bind calls directly via `quickshell ipc call polysphere cycle`. The first call opens the overlay, subsequent calls cycle forward.

**Files:** `polysphere.qml` (IpcHandler.cycle), `keymaps.lua` (Hyprland bind)

**Lesson:** For keybindings consumed by the compositor, IPC is the only reliable communication channel. Don't rely on QML `Keys` handlers for keys the compositor owns.

---

## 2. Daemon cycle_next ≠ Visible Sphere Apps

**Issue:** The daemon's `cycle_next`/`cycle_prev` only iterate through its **internal MRU list** (apps activated via `hyprctl` focus events). But `get_mru` response includes a **larger combined list** with whitelist-backfilled launch targets. So Tab cycling only touched a subset of what was visible.

**Fix:** Cycle locally through `appModel` (the QML `ListModel` driving the Repeater), not through the daemon. No IPC needed for basic Tab cycling.

**Files:** `polysphere.qml` (cycleSelection, selectByIndex)

**Lesson:** The daemon's internal state and the visible UI state can diverge. Always cycle through the visible model, not the authoritative backend.

---

## 3. Hyprctl dispatch Requires Lua Syntax

**Issue:** The old `hyprctl dispatch focuswindow class:<app>` no longer works in modern Hyprland (0.55+). The dispatch system was rewritten to use Lua functions:

```
# OLD (broken):
hyprctl dispatch focuswindow class:kitty

# NEW (works):
hyprctl dispatch 'hl.dsp.focus({window="class:kitty"})'
```

**Fix:** Updated `focus-app` in `daemon.scm` to use the Lua dispatch format.

**Files:** `daemon.scm` (focus-app)

**Lesson:** Hyprland's CLI API changed with the Lua config migration. Always check the wiki for the current syntax.

---

## 4. Shell Interpretation of Parentheses and Braces

**Issue:** `run-hyprctl` runs commands via `/bin/sh -c`. The Lua command `hl.dsp.focus({window="class:kitty"})` contains `()` and `{}` which the shell interprets as subshell operators:

```
/bin/sh: -c: line 1: syntax error near unexpected token `('
```

**Fix:** Wrap the Lua command in **single quotes** so the shell passes it literally:

```scheme
;; Broken — shell sees () as subshell
(run-hyprctl "dispatch" "hl.dsp.focus({window=\"class:kitty\"})")

;; Fixed — single quotes protect from shell interpretation
(run-hyprctl "dispatch" "'hl.dsp.focus({window=\"class:kitty\"})'")
```

**Files:** `daemon.scm` (focus-app)

**Lesson:** Any string passed through a shell pipe (`open-input-pipe`) is vulnerable to shell metacharacter interpretation. Always quote aggressively.

---

## 5. QML Process Stops When Parent Is Invisible

**Issue:** When `window.visible = false` is set on the root Item, child `Process` elements (like `daemonProcess`) may not execute. `daemonProcess.running = true` becomes a no-op because the QML engine pauses execution for invisible subtrees.

**Fix:** For commands that must run *after* the overlay is hidden, use `Quickshell.execDetached` instead of a `Process`:

```qml
// Broken — Process may not run when parent is invisible
daemonProcess.running = true;

// Fixed — execDetached spawns independent process
Quickshell.execDetached(["bash", "-c", cmd]);
```

**Files:** `polysphere.qml` (triggerActivate)

**Lesson:** `Process` is part of the QML scene graph and respects visibility. `execDetached` is a process-level call outside the scene graph.

---

## 6. PanelWindow Visibility Breaks IPC

**Issue:** Setting `visible: false` on the `PanelWindow` (in `shell.qml`) causes Quickshell to pause the QML engine for that window. IPC calls like `quickshell ipc call polysphere cycle` stop working because the `IpcHandler` is no longer active.

**Fix:** The `PanelWindow` must remain **always visible**. To prevent it from intercepting clicks when the overlay is closed, set `panelWindow.visible = false` directly from `polysphere.qml` via a property reference (passed through `loader.item.panelWindow = root`).

**Files:** `shell.qml` (onItemChanged sets the reference), `polysphere.qml` (panelWindow property)

**Lesson:** Never hide a Quickshell PanelWindow if you need IPC to reach it. The QML engine for invisible windows may be paused.

---

## 7. WlrLayer.Background Kills Keyboard Events

**Issue:** Moving the PanelWindow to `WlrLayer.Background` (to stop click interception) also prevents it from receiving keyboard events. `Keys.onPressed` for Escape and `Keys.onReleased` for Alt stop firing because the compositor doesn't deliver keyboard input to Background-layer windows.

**Fix:** Keep the PanelWindow on `WlrLayer.Overlay` at all times. Control click interception by enabling/disabling the full-screen `MouseArea`.

**Files:** `shell.qml` (WlrLayershell.layer, MouseArea.enabled)

**Lesson:** Layer switching affects both input AND rendering. Background-layer windows receive no keyboard events.

---

## 8. Delegate TypeErrors During Model Clear

**Issue:** `appModel.clear()` destroys all Repeater delegates. During destruction, QML re-evaluates delegate bindings (x, y, opacity, scale, etc.) with a partially-invalid context. This floods the console with "TypeError: Value is undefined" for every delegate property.

**Fix:** Use **in-place updates** instead of clear/append. `appModel.set(index, {...})` updates existing entries without destroying delegates. Only remove excess items if the new list is shorter:

```qml
// Broken — destroys and recreates all delegates
appModel.clear();
for (var i = 0; i < mru.length; i++) appModel.append(mru[i]);

// Fixed — updates in-place, preserves delegates
for (; i < appModel.count && i < mru.length; i++) appModel.set(i, {...});
for (; i < mru.length; i++) appModel.append({...});
while (appModel.count > mru.length) appModel.remove(appModel.count - 1, 1);
```

**Also:** Wrap `model` access in safe wrapper properties in the delegate:

```qml
readonly property var _m: model || {}
readonly property string _name: String(_m.name || "")
readonly property string _icon: String(_m.icon || "")
```

**Files:** `polysphere.qml` (populateSphereFromMru, delegate properties)

**Lesson:** ListModel.clear() + append() causes delegate churn. In-place updates avoid TypeErrors from stale bindings.

---

## 9. `window.appModel` vs Bare `appModel` in IpcHandler

**Issue:** Inside the `IpcHandler` block, `window.appModel` returns `undefined` even though `appModel` is a well-known child of the root Item. This is because `appModel` is defined as `ListModel { id: appModel }` — it's an `id`, not a named `property`. QML doesn't expose child IDs as properties of the parent.

**Fix:** Access `appModel` directly without the `window.` prefix. The QML scope chain resolves it from the root Item's context:

```qml
// Broken — window.appModel is undefined
window.appModel.count

// Fixed — direct access works via scope chain
appModel.count
```

**Files:** `polysphere.qml` (IpcHandler.cycle)

**Lesson:** `id:` creates a QML-scoped reference, not a property. References by `id` work from child objects, but NOT via `parent.id` syntax.

---

## 10. openOverlay Resets altHeld/tabWasPressed

**Issue:** When `cycle()` opens the overlay via IPC, it sets `altHeld = true` and `tabWasPressed = true` to simulate the Alt+Tab hold. But `openOverlay()` (called by `onVisibleChanged`) was resetting these to `false`, so when the user released Alt, `triggerActivate()` checked `tabWasPressed` — which was `false` — and did nothing.

**Fix:** Remove `altHeld = false` and `tabWasPressed = false` from `openOverlay()`. These flags are only set by `cycle()` and `Keys.onPressed`; `openOverlay()` should not touch them.

**Files:** `polysphere.qml` (openOverlay)

**Lesson:** Pay attention to initialization order. `onVisibleChanged` → `openOverlay()` runs after `cycle()` sets tracking flags. Don't zero out state that was just set.

---

## 11. Guile Caches Compiled Bytecode

**Issue:** After editing `daemon.scm`, Guile may continue running the **old compiled version** from `~/.cache/guile/ccache/`. Changes to the source file don't take effect until the cache is invalidated.

**Fix:** Use `guile --no-auto-compile` to skip the cache, or delete cached files:

```bash
find ~/.cache/guile -name "daemon.scm*" -delete
guile --no-auto-compile daemon.scm
```

**Files:** `daemon.scm`

**Lesson:** Guile's bytecode cache is persistent. Source edits don't automatically invalidate it. Always use `--no-auto-compile` during development.

---

## 13. `-p` (--path) Flag Breaks IPC Discovery

**Issue:** Running quickshell with `-p /path/to/file.qml` starts the config
but does NOT register it under `~/.config/quickshell/`. When `qs ipc call`
(or `quickshell ipc call`) runs, it looks for instances registered in the
standard config directory — instances started with `-p` are invisible to
it.

```bash
# This starts the file, but IPC can't find it:
quickshell -p hyprsphere.qml

# This fails even though the instance is running:
qs ipc call hyprsphere show
# -> "Could not find default config directory..."
```

**Fix:** Symlink the QML file into the standard config directory and run
quickshell without `-p`:

```bash
mkdir -p ~/.config/quickshell
ln -sf /path/to/hyprsphere.qml ~/.config/quickshell/shell.qml
quickshell
# Now IPC works:
qs ipc call hyprsphere show  # succeeds
```

**Files:** `manual_start.sh`, `hyprsphere.qml`

**Lesson:** `-p` is fine for one-off testing but prevents IPC from
finding the instance. For production use where Hyprland triggers the
overlay via `qs ipc call`, always register the config in the standard
directory.

---

## 12. MouseArea Enabled vs PanelWindow Input Region

**Issue:** Setting `enabled: false` on the `MouseArea` doesn't prevent the `PanelWindow` from intercepting input. The Wayland surface itself has an input region covering the entire screen. MouseArea.enabled only controls whether that specific MouseArea receives events — the window still blocks clicks below.

**Fix:** Hide the PanelWindow (`panelWindow.visible = false`) to unmap the Wayland surface entirely. This stops ALL input interception. The PanelWindow is made visible again when the overlay reopens.

**Files:** `shell.qml` (MouseArea.enabled), `polysphere.qml` (closeSequence, openOverlay)

**Lesson:** MouseArea.enabled ≠ input pass-through. The Wayland surface's input region is independent of any single QML element.

---

## Summary: Quick Reference

| # | Problem | Fix |
|---|---|---|---|
| 1 | Hyprland eats Alt+Tab | Use IPC `cycle()` instead of QML Keys |
| 2 | Daemon cycle_next skips whitelist apps | Cycle locally through appModel |
| 3 | hyprctl dispatch syntax changed | Use `hl.dsp.focus({window="class:x"})` |
| 4 | Shell interprets () as subshell | Wrap Lua commands in single quotes |
| 5 | Process stops when parent invisible | Use execDetached |
| 6 | PanelWindow invisible = IPC dead | Keep PanelWindow always visible |
| 7 | Background layer = no keyboard | Stay on Overlay layer |
| 8 | Model.clear() causes TypeError flood | Use in-place appModel.set() |
| 9 | window.appModel is undefined | Use bare appModel in scope chain |
| 10 | openOverlay resets tracking flags | Don't clear altHeld/tabWasPressed in openOverlay |
| 11 | Guile caches old bytecode | Use --no-auto-compile |
| 12 | MouseArea doesn't stop input | Hide PanelWindow to unmap surface |
| 13 | `-p` flag breaks IPC discovery | Use standard config directory for IPC |
