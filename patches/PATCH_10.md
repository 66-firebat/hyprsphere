# PATCH_10 — "Launch" easing effect via `effects.js`

> **This patch adds a new `"launch"` mode to the effects system that creates
> a slingshot motion: the sphere briefly rotates in the opposite direction
> (pull back), then launches forward past the target with a soft bounce at
> arrival. All aspects of the motion are configurable.**

---

## Motivation

The existing `"bounce"` mode (OutBack easing) overshoots past the target
and springs back, but it starts moving in the correct direction immediately.
The "launch" mode adds a dramatic anticipatory pull-back — the sphere
first moves *away* from the target, building visual tension, before
slingshotting forward with a bounce at the end.

---

## Visual curve

```
Animation progress (y)
    ↑
1.2 ┤                          ● ← arrival bounce (landBounce)
1.0 ┼───────●─────────────────── target value
    │       ↙
0.5 ┤  ●
    │ ↙
0.0 ┼──●────────────────────────────→ Time (x)
    │  ↑
-0.5 ┤──● ← slingshot pull back (slingDistance)
      ↑
    slingDuration
```

The y-axis is animation progress (0 = start, 1 = target). Values below 0
mean the sphere rotates *past* the start position in the opposite direction.
Values above 1 mean it overshoots past the target.

This is achieved using Qt's `Easing.BezierSpline` with dynamically computed
control points from the config parameters.

---

## Bezier spline math

A cubic bezier spline is defined by 4 points: `P0, P1, P2, P3`.

```
P0 = (0, 0)                          // start
P1 = (slingDuration, slingDistance)  // pull-back control point
P2 = (1 - tBounce, 1 + landBounce)  // overshoot control point
P3 = (1, 1)                          // end
```

Where `tBounce = landBounce * 0.3` — the overshoot peak occurs slightly
before the end of the animation.

Qt's `Easing.BezierSpline` accepts `anim.easing.bezierCurve` as a list of
4 QPointF objects: `[P0, P1, P2, P3]`.

---

## Config

### `hyprsphere.json`

```json
{
  "sphere": {
    "effects": {
      "mode": "launch",
      "durationMs": 500,
      "slingDistance": -0.5,
      "slingDuration": 0.3,
      "landBounce": 0.2
    }
  }
}
```

| Key | Type | Default | Description |
|---|---|---|---|
| `mode` | string | `"bounce"` | Set to `"launch"` to enable this effect |
| `durationMs` | int | `500` | Total animation time in milliseconds |
| `slingDistance` | real | `-0.5` | How far backward the sphere goes during pull-back. Range: -1.0 to 0. -0.5 = 50% of the rotation distance backward |
| `slingDuration` | real | `0.3` | Fraction of total animation time spent pulling back. Range: 0.0 to 0.5 |
| `landBounce` | real | `0.2` | How much the sphere overshoots past the target on arrival. Range: 0 to 0.5 |

---

## Implementation

### File: `effects.js`

#### Change 1 — Add `"launch"` mode to `setAnimation()`

**Before:**
```javascript
function setAnimation(anim, config) {
    if (!config || config.mode !== "bounce") {
        // Default: smooth cubic ease
        anim.easing.type = 6;
        anim.easing.overshoot = 0;
        anim.duration = 400;
        return;
    }
    // bounce mode...
}
```

**After:**
```javascript
function setAnimation(anim, config) {
    if (!config) {
        anim.easing.type = 6;
        anim.easing.overshoot = 0;
        anim.duration = 400;
        return;
    }

    if (config.mode === "launch") {
        _applyLaunch(anim, config);
        return;
    }

    if (config.mode === "bounce") {
        _applyBounce(anim, config);
        return;
    }

    // Default fallback
    anim.easing.type = 6;
    anim.easing.overshoot = 0;
    anim.duration = 400;
}

function _applyBounce(anim, config) {
    var overshoot = config.overshoot !== undefined ? config.overshoot : 4.0;
    var duration = config.durationMs || 400;
    anim.easing.type = 34;           // Easing.OutBack
    anim.easing.overshoot = overshoot;
    anim.duration = duration;
}

function _applyLaunch(anim, config) {
    var dur = config.durationMs || 500;
    var sd = config.slingDistance !== undefined ? config.slingDistance : -0.5;
    var sDur = config.slingDuration !== undefined ? config.slingDuration : 0.3;
    var lb = config.landBounce !== undefined ? config.landBounce : 0.2;

    // Clamp values
    if (sd > 0) sd = -0.01;
    if (sd < -1.0) sd = -1.0;
    if (sDur < 0.01) sDur = 0.01;
    if (sDur > 0.5) sDur = 0.5;
    if (lb < 0) lb = 0;
    if (lb > 0.5) lb = 0.5;

    var tBounce = lb * 0.3;

    // Bezier control points for the slingshot curve
    anim.easing.type = 45;           // Easing.BezierSpline
    anim.easing.bezierCurve = [
        Qt.point(0, 0),                     // P0: start
        Qt.point(sDur, sd),                 // P1: pull back
        Qt.point(1 - tBounce, 1 + lb),      // P2: overshoot
        Qt.point(1, 1)                      // P3: end
    ];
    anim.duration = dur;
}
```

Note: `Qt.point()` is used to create QPointF values for the bezier curve.
This requires `import QtQuick` which is already in `shell.qml`. The
`effects.js` is a `.pragma library` script and cannot directly call
`Qt.point()`, so the function should receive pre-constructed points or
use numeric arrays instead.

**Alternative approach (avoiding Qt.point):** Pass the bezier curve as
a flat array of 8 numbers:

```javascript
anim.easing.bezierCurve = [
    sDur, sd,
    1 - tBounce, 1 + lb
];
```

Qt's BezierSpline accepts `[x1, y1, x2, y2]` as control points (P0 and P3
are implicitly (0,0) and (1,1)).

#### Change 2 — Update `resetAnimation()`

No changes needed — `resetAnimation()` sets `type = 6` (OutCubic) which
is independent of the bezier curve data.

### File: `hyprsphere.json`

#### Change 3 — Update mode to `"launch"`

```json
"effects": {
  "mode": "launch",
  "durationMs": 500,
  "slingDistance": -0.5,
  "slingDuration": 0.3,
  "landBounce": 0.2
}
```

---

## Behaviour

| Parameter | value -0.1 | value -0.5 | value -1.0 |
|---|---|---|---|
| `slingDistance` | Subtle flinch back | Dramatic pull-back, half the distance | Full pull-back to the previous node's position |
| `slingDuration` (at 0.3) | Quick 30% of time spent pulling back | — | Slow 50% pull-back, fast launch |
| `landBounce` (0.1) | Tiny arrival ring | — | Strong bounce, 50% past target |

---

## Verification

```bash
# C1: Launch mode implemented in effects.js
grep -c "_applyLaunch\|'launch'\|launch" effects.js
# Expected: at least 2 (function + mode check)

# C2: BezierSpline numeric type used
grep -c "BezierSpline\|bezierCurve" effects.js
# Expected: at least 1

# C3: Config has launch parameters
grep -c "slingDistance\|slingDuration\|landBounce" hyprsphere.json
# Expected: 3
```
