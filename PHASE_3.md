# PHASE_3 — Key handling (Tab, `;`, Escape, Alt release)

**Deliverable:** The overlay becomes keyboard-interactive. Tab cycles
the sphere, `;` drills into an app's windows (no-op until Phase 4),
Escape closes the overlay, and Alt release calls commit (no-op until
Phase 4).

---

## Steps

### 1. Add the `focusGrabber` Item

Insert a full-screen Item with `focus: true` and
`Keys.priority: Keys.BeforeItem` inside the PanelWindow. It captures
keyboard focus and handles keys that Hyprland doesn't consume:
- `Qt.Key_Tab` / `Qt.Key_Backtab` for Shift+Tab (Tab alone is consumed
  by Hyprland — see step 4)
- `Qt.Key_Semicolon` for drill-down
- `Qt.Key_Escape` for cancel
- `Qt.Key_Alt` released for commit

```qml
Item {
    id: focusGrabber
    anchors.fill: parent
    focus: true
    Keys.priority: Keys.BeforeItem

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            if (event.modifiers & Qt.ShiftModifier || event.key === Qt.Key_Backtab)
                window.advance(-1);
            else window.advance(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Semicolon) {
            window.drillDown();
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            window.cancelSwitch();
            event.accepted = true;
        }
    }

    Keys.onReleased: (event) => {
        if (event.key === Qt.Key_Alt) {
            window.commitSelection();
            event.accepted = true;
        }
    }
}
```

### 2. Remove the old `Shortcut { sequence: "Escape" }`

The old launcher prototype had a `Shortcut` for Escape that calls
`closeSequence.start()`. This conflicts with the new `Keys.onPressed`
handler — both would fire on Escape press. Delete the `Shortcut` block.

### 3. Update `onVisibleChanged` to set focus

```qml
Connections {
    target: window
    function onVisibleChanged() {
        if (window.visible) {
            window.sphereZoom = 1.0;
            focusGrabber.forceActiveFocus();
            introPhaseAnim.restart();
        }
    }
}
```

### 4. Fix Tab cycling when Hyprland consumes the key event

**The problem:** Hyprland's `ALT + Tab` bind grabs the Tab key at the
compositor level. When the user holds Alt and presses Tab a second time
(expecting it to cycle forward), Hyprland's bind fires again. The
`focusGrabber`'s `Keys.onPressed` for `Qt.Key_Tab` **never executes**
because Hyprland consumed the event first.

Shift+Tab works fine because there's no Hyprland bind for
`ALT + SHIFT + Tab`, so the key event passes through to the overlay.

**The fix — IPC advance in `toggle()`:**

Step 1 — Track whether the overlay is active with a boolean flag:
```qml
property bool overlayActive: false
```
Set to `true` in `openSwitcher()`, set to `false` in `cancelSwitch()`
and in the `closeSequence`'s `ScriptAction`.

Step 2 — In the IpcHandler's `toggle()` function, check the flag.
If the overlay is already open, call `advance(1)` directly instead of
rebuilding the sphere:
```qml
function toggle(): void {
    if (window.overlayActive) {
        // Alt is still held, Tab was pressed again → cycle forward
        window.advance(1);
        return;
    }
    // First press — open the overlay
    openSwitcher();
}
```

**Why this works:** The `qs ipc call hyprsphere toggle` command reaches
the running Quickshell instance via Unix socket regardless of whether
Hyprland consumed the key event. The IPC server is always listening.
So the `toggle()` function body executes, sees the overlay is already
open, and calls `advance(1)` — no per-keystroke subprocess overhead
since `qs ipc call` is a local socket write, not a `/bin/sh` spawn.

### 5. Hyprland bind (already done)

```lua
hl.bind(mainMod .. " + Tab", hl.dsp.exec_cmd("qs ipc call hyprsphere toggle"))
```

---

## Design decisions

| Decision | Choice |
|---|---|
| Escape behavior | `cancelSwitch()` → hides overlay, resets `overlayActive` |
| Focus on open | Always `forceActiveFocus()` on `focusGrabber` |
| Alt release detection | `Keys.onReleased` with `event.key === Qt.Key_Alt` |
| Tab while Alt held | IPC `advance(1)` from toggle (Hyprland consumes the key) |
| Shift+Tab while Alt held | `Keys.onPressed` via focusGrabber (passes through Hyprland) |
| CancelSwitch state reset | Sets `overlayActive = false`, next open starts fresh |

---

## Late fixes applied during implementation

### `closewindow>>` pruning fix (from Phase 2)

The original code checked `event.name.startsWith("closewindow>>")` but
Quickshell's `HyprlandEvent` has separate `name` (`"closewindow"`) and
`data` (the address) properties. Changed to `event.name === "closewindow"`
and `event.data` for the address.

### ScriptAction syntax

`ScriptAction { script: ... }` in QML requires a single expression.
Multiple statements need `{ }` wrapping:
```qml
ScriptAction { script: { window.overlayActive = false; window.visible = false; } }
```

---

## Exit criteria

- Pressing Alt+Tab opens the overlay (first press) or cycles forward
  (subsequent presses while Alt is held)
- Pressing Shift+Tab while Alt is held cycles backward
- Pressing `;` calls `drillDown()` (no-op until Phase 4)
- Pressing Escape hides the overlay and resets state
- Releasing Alt calls `commitSelection()` (no-op until Phase 4)
- No `Shortcut`/`Keys` conflict on Escape
