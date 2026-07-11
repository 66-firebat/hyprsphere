# PATCH 14 — NodePeek: Continuous Orbital Peek Effect

## Motivation
Add a perpetual effect that continuously rotates the sphere along a path that
intersects the "next" (Tab) and "previous" (Shift+Tab) nodes, with
configurable slowdowns at each node to let the user peeks at them.

## Design

### Rotation Path
- Compute the spherical (rotX, rotY) coordinates of the next and prev nodes
  using the same Fibonacci sphere math as `centerOnApp()`.
- Define a continuous 2π cycle in rotY that passes through both node positions.
- rotX is smoothly interpolated between the two node values as rotY progresses.
- The cycle repeats indefinitely while the overlay is open.

### Speed Profile
- Base angular velocity = 2π / periodMs.
- Near each node, the speed is reduced by `amplitude` (multiplier).
- The slowdown begins `padding` radians before the node and ends `padding`
  radians after it.
- Outside these zones, speed is 1.0 (base).
- A pre-computed lookup table maps time → angular position accounting for the
  variable speed.

### Lifecycle
- **start()**: initialise lookup table, set `_peekTime = 0`.
- **tick()**: advance `_peekTime`, compute progress, set rotX/rotY.
  Skips if a Tab-transition animation is running (`_animating` flag).
- **stop()**: clear state.
- **Restart**: when `centerOnApp()` fires, set `_peekRestart = true` on the
  window. The tick function detects this and recomputes targets for the new
  selection.
- **`_animating` flag**: set `true` in `centerOnApp()`, cleared when
  `searchRotXAnim.onFinished` fires (via Connections). Peek pauses during this
  interval to avoid racing the NumberAnimation.

### Config
```json
"perpetualEffects": {
  "nodePeek": {
    "enabled": true,
    "periodMs": 4000,
    "slowdownNext": { "amplitude": 0.3, "padding": 0.15 },
    "slowdownPrev": { "amplitude": 0.3, "padding": 0.15 }
  }
}
```

### Files Modified
| File | Change |
|---|---|
| `effects.js` | Add `register("nodePeek", {...})` with full implementation |
| `shell.qml` | Add `_peekRestart`, `_animating` flags, update in `centerOnApp()` |
| `hyprsphere.json` | Add `perpetualEffects.nodePeek` config section |
| `patches/PATCH_14.md` | This file |
