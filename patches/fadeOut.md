# PATCH — fadeConfig (idle fade-out of the whole overlay)

> After a short period of inactivity, fade the **entire hyprsphere UI** down to a
> configurable opacity so the apps underneath are visible. Any interaction fades
> it back in.

---

## Concept

While the overlay is open and the user stops interacting, the overlay (sphere
cards, satellite, search bar, and peek snapshot) fades to a low opacity after a
delay, letting the user see the real desktop/windows underneath. The moment the
user interacts again (keyboard, mouse movement, click, or hover), the overlay
fades back to full opacity.

This is a **pure opacity effect** — it does not change the sphere's scale or the
search bar's position, and it does not interfere with the existing open/commit/
cancel fades (which are driven by `introPhase`).

## Locked decisions

| # | Decision |
|---|---|
| 1 | **Trigger** — automatic on inactivity |
| 2 | **Interaction resets** — everything: keyboard, clicks, mouse movement, hover |
| 3 | `fadeOutOpacity` — **final opacity** (`0` = transparent, `1` = opaque); default `0.15` |
| 4 | `fadeOutDelay` — default **500 ms** |
| 5 | `fadeOutDuration` — default **300 ms** |
| 6 | **Scope** — everything (sphere + satellite + search bar + peek snapshot) |
| 7 | **Perpetual effects keep running** while faded |
| 8 | **All layers** (0 / 1 / 2) |
| 9 | **Easing** — `Easing.OutCubic` (ease-out) |
| 10 | **Timer starts immediately** on overlay open |
| 11 | **Commit/cancel independent** — closing still works while faded |
| 12 | **Opacity only** — no scale/position change |
| 13 | Add **`enabled`** flag (default `true`) |
| 14 | **`fadeInDuration`** — separate fade-back-in duration, default **100 ms** |
| 15 | **Interrupt mid-fade** — immediately reverse from current opacity |

---

## Config

Top-level object in `hyprsphere.json`:

```json
"fadeConfig": {
  "enabled": true,
  "fadeOutDelay": 500,
  "fadeOutDuration": 300,
  "fadeOutOpacity": 0.15,
  "fadeInDuration": 100
}
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master switch for the idle fade |
| `fadeOutDelay` | int (ms) | `500` | Idle time before the fade starts |
| `fadeOutDuration` | int (ms) | `300` | How long the fade-out takes |
| `fadeOutOpacity` | real (0–1) | `0.15` | Final opacity when faded |
| `fadeInDuration` | int (ms) | `100` | How long the fade-back-in takes |

---

## Implementation

### 1. Config (hyprsphere.json)

Add the `fadeConfig` object shown above.

### 2. State, timer, and fade animations (shell.qml)

```qml
    // Idle fade state — a multiplier on top of introPhase (1.0 = fully opaque).
    property real idleOpacity: 1.0

    NumberAnimation {
        id: idleFadeOutAnim
        target: window; property: "idleOpacity"
        to: cfg.fadeConfig?.fadeOutOpacity ?? 0.15
        duration: cfg.fadeConfig?.fadeOutDuration ?? 300
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: idleFadeInAnim
        target: window; property: "idleOpacity"
        to: 1.0
        duration: cfg.fadeConfig?.fadeInDuration ?? 100
        easing.type: Easing.OutCubic
    }

    Timer {
        id: idleTimer
        interval: cfg.fadeConfig?.fadeOutDelay ?? 500
        repeat: false
        onTriggered: idleFadeOutAnim.restart()
    }

    function notifyInteraction() {
        if (cfg.fadeConfig?.enabled !== true) return;
        idleFadeInAnim.restart();   // reverse in place (starts from current value)
        idleTimer.restart();        // re-arm the idle countdown
    }
```

Both `idleFadeOutAnim` and `idleFadeInAnim` have no `from`, so they always start
from `idleOpacity`'s **current** value — this is what gives the smooth
mid-fade reversal (decision 15).

### 3. Apply the opacity multiplier

Change the three top-level opacity bindings so `idleOpacity` composes with the
existing `introPhase` (scale/translate stay on `introPhase` only — decision 12):

```qml
// peekView (ScreencopyView)
opacity: window.introPhase * window.idleOpacity

// scene3D (sphere)
opacity: window.introPhase * window.idleOpacity
scale:  0.8 + (0.2 * window.introPhase)          // ← unchanged (no idle scale)

// searchContainer
opacity: window.introPhase * window.idleOpacity
transform: Translate { y: (1 - window.introPhase) * window._s40 }   // ← unchanged
```

The satellite card is a child of `scene3D`, so it inherits the sphere's fade.

Because `introPhase` still goes to `0` on commit/cancel, the overlay closes
normally while faded (decision 11).

### 4. Interaction detection (call `notifyInteraction()`)

- **Keyboard** — at the top of `focusGrabber`'s `Keys.onPressed` and
  `Keys.onReleased`, call `window.notifyInteraction()`.
- **Pointer movement + hover** — add a full-screen `HoverHandler` (passive, so it
  doesn't consume clicks/drag):

```qml
    // inside focusGrabber (anchors.fill: parent)
    HoverHandler {
        onPointChanged: window.notifyInteraction()
    }
```

- **Clicks / drag** — call `window.notifyInteraction()` in `sceneMouse.onPressed`
  and `sceneMouse.onPositionChanged` (drag), and in `nodeMa.onClicked`
  / `onDoubleClicked` (cards). This covers click-without-movement cases the
  `HoverHandler` might miss.

`HoverHandler` requires `import QtQuick` (already present).

### 5. Lifecycle

- **Open** — in `openSwitcher()` (or `finishOpenSwitcher()`), reset the state:

```javascript
    window.idleOpacity = 1.0;
    idleTimer.restart();
```

- **Close** — in `onOverlayActiveChanged`, when `overlayActive` becomes `false`,
  stop the timer and reset so the next open starts fresh:

```javascript
    if (!overlayActive) {
        idleTimer.stop();
        window.idleOpacity = 1.0;
        peekView.captureSource = null;   // (existing line)
    }
```

### 6. Perpetual effects

No change — `perpetualTimer` keeps running and driving `Effects.tick(window)`
while faded (decision 7). The perpetual timer is not "interaction" and must not
call `notifyInteraction()`.

---

## Edge cases

| Scenario | Behavior |
|---|---|
| Fade-out in progress, then interaction | `idleFadeInAnim` reverses from current opacity (no `from`) |
| Commit/cancel while faded | `introPhase → 0` still hides everything; overlay closes normally |
| `enabled: false` | `notifyInteraction` no-ops; `idleOpacity` stays `1.0`; no fade |
| `fadeOutOpacity: 0` | Overlay becomes fully invisible when idle (still interactive) |
| Overlay opens, no interaction for 500 ms | Fades to `0.15` even if entrance animation is still finishing (decision 10) |
| Special/perpetual effects | Unaffected (separate timer) |

## Files modified

| File | Change |
|---|---|
| `hyprsphere.json` | Add `fadeConfig` object |
| `shell.qml` | Add `idleOpacity`, `idleFadeOutAnim`, `idleFadeInAnim`, `idleTimer`, `notifyInteraction()`; apply `* idleOpacity` to the 3 opacity bindings; hook interaction + lifecycle |

## Verification

- Manual: open the overlay, stop moving the mouse for ~0.5 s → it fades to ~15% opacity; move the mouse → it snaps back to full in ~0.1 s.
- Manual: type / Tab / click / hover → overlay fades back in.
- Manual: release Alt while faded → overlay closes normally.
- Manual: Escape while faded → overlay closes normally.
- Manual: with `enabled: false` → no idle fade at all.
- Grep: `idleOpacity` appears in `peekView`, `scene3D`, and `searchContainer` opacity bindings; `notifyInteraction()` is called from the keyboard + pointer handlers.
