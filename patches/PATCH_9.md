# PATCH_9 — Bounce effect via `effects.js` + `centerOnApp()`

> **This patch replaces the continuous rotation system with an overshoot
> bounce effect on `centerOnApp()` that activates every time the user presses
> Tab, Shift+Tab, `\`, or `|`. The bounce is sourced from a new `effects.js`
> file and applied as an easing curve on the existing sphere rotation
> animation.**

---

## Motivation

The old rotation system (`rotY -= speed` every 16ms) ran constantly even
when the overlay was idle. The bounce effect ties sphere motion directly
to user interaction — every Tab press triggers a single, smooth animation
that overshoots the target position and springs back. No continuous CPU
usage, no fighting with other animations.

---

## Architecture

### How it works

```
Tab pressed → advance() → centerOnApp(nextIndex)
                              │
                              ▼
                  searchRotXAnim.restart()
                  searchRotYAnim.restart()
                              │
                              ▼
                  Effects.setAnimation(searchRotXAnim)
                  Effects.setAnimation(searchRotYAnim)
                              │
                              ▼
                  Animates with OutBack easing + overshoot
                  Single animation, runs once, done
```

The effect is NOT in a Timer. It's a one-shot animation on every key press.

### File: `effects.js`

A `.pragma library` script that configures QML NumberAnimation objects with
the appropriate easing curve, overshoot, and duration.

### Config: `hyprsphere.json`

Under the `sphere` section:

```json
{
  "sphere": {
    "effects": {
      "mode": "bounce",
      "durationMs": 400,
      "overshoot": 0.3
    }
  }
}
```

| Key | Type | Default | Description |
|---|---|---|---|
| `mode` | string | `"bounce"` | Effect type. `"bounce"` = OutBack with overshoot |
| `durationMs` | int | `400` | Duration of the animation in milliseconds |
| `overshoot` | real | `0.3` | How far past the target to go. 0.0 = no bounce (smooth ease), 1.0 = 100% past target |

### Removed files

- `rotations.js` — no longer needed

### Removed config

- `sphere.rotation` — removed entirely
- `animations.sphereLayer1Multiplier` — removed (was only for rotation speed)
- `animations.sphereLayer2Multiplier` — removed (was only for rotation speed)

---

## Implementation

### New file: `effects.js`

```javascript
.pragma library

// Configure a QML NumberAnimation with the current effect settings.
// Sets: easing.type, easing.overshoot, duration
function setAnimation(anim, config) {
    if (!config || config.mode !== "bounce") {
        // Default: smooth cubic ease, no overshoot
        anim.easing.type = 14;       // Easing.OutCubic
        anim.easing.overshoot = 0;
        anim.duration = 400;
        return;
    }

    var overshoot = config.overshoot !== undefined ? config.overshoot : 0.3;
    var duration = config.durationMs || 400;

    anim.easing.type = 6;            // Easing.OutBack
    anim.easing.overshoot = overshoot;
    anim.duration = duration;
}

// Reset animation to defaults (smooth ease, no bounce)
function resetAnimation(anim) {
    anim.easing.type = 14;           // Easing.OutCubic
    anim.easing.overshoot = 0;
    anim.duration = 400;
}
```

> **Note:** The easing types are referenced by their numeric enum values
> because `.pragma library` scripts cannot access QML's `Easing` namespace.
> `6` = `Easing.OutBack`, `14` = `Easing.OutCubic`.

### File: `shell.qml`

#### Change 1 — Replace imports

```javascript
// Remove:
import "rotations.js" as Rotations

// Add:
import "effects.js" as Effects
```

#### Change 2 — Remove rotation infrastructure

Remove:
- `_rotationTick` property
- `rotationSpeed` property  
- `updateRotateSpeed()` function
- `speedAnim` NumberAnimation
- `onLayerChanged: updateRotateSpeed()` binding
- The auto-rotation Timer

Replace with:

```javascript
// ── Auto-rotation disabled — effects are triggered on user actions ──
```

#### Change 3 — Update `centerOnApp()` to apply effects

**Before:**
```javascript
searchRotXAnim.to = targetRotX;
searchRotYAnim.to = window.rotY + diff;
searchRotXAnim.restart();
searchRotYAnim.restart();
```

**After:**
```javascript
searchRotXAnim.to = targetRotX;
searchRotYAnim.to = window.rotY + diff;
Effects.setAnimation(searchRotXAnim, cfg.sphere?.effects);
Effects.setAnimation(searchRotYAnim, cfg.sphere?.effects);
searchRotXAnim.restart();
searchRotYAnim.restart();
```

#### Change 4 — Update `onOverlayActiveChanged`

```javascript
onOverlayActiveChanged: {
    if (!window.overlayActive) {
        Effects.resetAnimation(searchRotXAnim);
        Effects.resetAnimation(searchRotYAnim);
    }
}
```

### File: `hyprsphere.json`

#### Change 5 — Remove rotation, add effects

```json
// Remove:
"sphere.rotation": { ... }
"animations.sphereLayer1Multiplier": 4,
"animations.sphereLayer2Multiplier": 16,

// Add under "sphere":
"effects": {
  "mode": "bounce",
  "durationMs": 400,
  "overshoot": 0.3
}
```

---

## Behaviour matrix

| Action | Before | After |
|---|---|---|
| Overlay opens | Sphere auto-rotates | Sphere is static |
| Tab | Advances + auto-rotation continues | Advances with overshoot bounce, then static |
| `\` | Advances + preview + auto-rotation | Advances + preview with overshoot bounce, then static |
| Shift+Tab | Backward advance + auto-rotation | Backward advance with overshoot bounce, then static |
| Mouse drag | Rotation pauses, resumes after | Drag works normally, no auto-rotation |
| Idle (no input) | Sphere spins forever | Sphere is completely still |
| CPU when idle | Timer fires every 16ms | Timer removed — zero CPU |

---

## Edge cases

### overshoot: 0.0

The animation behaves identically to the current `OutCubic` — smooth ease
with no overshoot. The sphere gracefully decelerates to the target position.

### overshoot > 0.5

The sphere overshoots significantly (50%+ past the target). This creates a
playful "boing" effect. At very high values (> 1.0), the sphere may appear
to bounce multiple times as the `OutBack` curve oscillates.

### Rapid Tab presses

Each Tab press restarts the animation. If the user presses Tab rapidly, the
previous animation is interrupted and the sphere immediately begins
animating toward the new target. The overshoot is always relative to the
full distance, so it works correctly regardless of interruptions.

### Drag during animation

If the user starts dragging the sphere while a bounce animation is running,
`sceneMouse.pressed` doesn't stop the animation — the NumberAnimation
continues. However, the drag handler also modifies `rotX`/`rotY` directly,
which can fight with the animation. This is the same behavior as the
current system (drag during `centerOnApp` animation).

---

## Verification

```bash
# C1: effects.js exists and has setAnimation function
grep -c "function setAnimation" effects.js
# Expected: 1

# C2: effects.js imported in shell.qml
grep -c "effects.js" shell.qml
# Expected: 1

# C3: rotations.js no longer imported
grep -c "rotations" shell.qml
# Expected: 0

# C4: centerOnApp calls Effects.setAnimation
grep -c "Effects.setAnimation" shell.qml
# Expected: 2 (searchRotXAnim + searchRotYAnim)

# C5: rotation config removed from hyprsphere.json
grep -c "rotation" hyprsphere.json
# Expected: 0 (or only in comments)

# C6: effects config in hyprsphere.json
grep -c "effects" hyprsphere.json
# Expected: at least 2 (effects block + mode key)
```
