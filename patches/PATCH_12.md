# PATCH 12 — Refactor Effects System: Remove Transitions, Extensible Perpetual API

## Motivation
Transition effects didn't look good and added complexity for marginal visual
impact. Strip them out. The perpetual effects system gets a proper extensible
API in effects.js so new effects can be added by simply calling `register()`.

## Changes

### 1. Config: Remove `transitionEffects`
The `sphere.transitionEffects` key is removed entirely. The NumberAnimations
for rotation use their declared defaults (Easing.OutCubic,
`cfg.animations.searchRotateDurationMs ?? 700`).

**File:** `hyprsphere.json`

### 2. effects.js — Perpetual-Only Extensible API
The entire file is rewritten. All transition-related functions are deleted:
`setAnimation`, `_applyDefault`, `_applyBounce`, `_applyLaunch`,
`resetAnimation`.

New API:
```
register(name, { start, stop, tick })  — Register a perpetual effect
start(window)                           — Start all registered effects
stop(window)                            — Stop all, reset state
tick(window)                            — Called every frame by timer
heartbeatAtPhase(t)                     — Cardiac waveform (internal)
```

The heartbeat effect self-registers via an IIFE at import time. Each effect
provides three lifecycle hooks:
- `start(window)`: called when perpetual effects begin
- `tick(window)`: called every ~16ms
- `stop(window)`: called when overlay closes, must reset visual state

**File:** `effects.js`

### 3. shell.qml — Simplified Perpetual Runner
Removed:
- `_perpEnabled`, `_perpOffset`, `_perpStartTime` properties
- `Effects.setAnimation()` calls in `centerOnApp()`
- `Effects.resetAnimation()` calls in `onOverlayActiveChanged`

Added:
- `_hbStartTime` property (used by heartbeat to track elapsed time)

Simplified:
- `perpetualTimer.onTriggered` → just calls `Effects.tick(window)`
- `startPerpetual()` → calls `Effects.start(window)`, starts timer
- `stopPerpetual()` → calls `Effects.stop(window)`, stops timer

The rotation NumberAnimations now use their declared defaults only. No config-
driven easing overrides.

**File:** `shell.qml`

### 4. binds.js — No Changes
The `window.stopPerpetual()` calls are still correct — they call the shell.qml
wrapper which delegates to `Effects.stop()`.

### Files Modified
| File | Change |
|---|---|
| `effects.js` | Full rewrite: remove transitions, add register/start/stop/tick API |
| `shell.qml` | Remove transition effect calls, simplify perpetual runner |
| `hyprsphere.json` | Remove `transitionEffects` key |
| `patches/PATCH_12.md` | This file |
