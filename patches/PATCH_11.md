# PATCH 11 — Perpetual Effects: Heartbeat Radius Pulse

## Motivation
Add a perpetual (continuous) animation system that runs while the overlay is open,
independent of the one-shot transition animations on Tab presses. The first effect
is a **heartbeat** that pulses the sphere radius in a realistic cardiac waveform.

## Changes

### 1. Config Rename: `effects` → `transitionEffects`
The old `sphere.effects` key is renamed to `sphere.transitionEffects` for clarity,
making room for `sphere.perpetualEffects` alongside it.

**Files:**
- `hyprsphere.json` — key rename
- `shell.qml` — two `cfg.sphere?.effects` references updated

### 2. New Config Block: `sphere.perpetualEffects`
```json
"perpetualEffects": {
  "heartbeat": {
    "enabled": true,
    "bpm": 72,
    "amplitude": 8,
    "layers": {
      "layer_1": {
        "frequency": 1.5,
        "amplitude": 12
      },
      "layer_2": {
        "frequency": 2.0,
        "amplitude": 16
      }
    }
  }
}
```

| Field | Purpose |
|---|---|
| `bpm` | Beats per minute — base speed for layer 0 |
| `amplitude` | Radial dilation in pixels (layer 0) |
| `layers[].frequency` | Speed multiplier vs layer 0 BPM |
| `layers[].amplitude` | Per-layer radial dilation override |

### 3. Heartbeat Waveform (effects.js)
A realistic cardiac waveform implemented mathematically:
- **Lub** (systolic): sharp Gaussian spike at ~8% of the beat cycle
- **Dub** (diastolic): gentler Gaussian bump at ~28% of the beat cycle
- **Rest**: flat plateau from ~40% to 100%

Additional exported functions:
- `heartbeatValue(t, config)` — returns dilation offset at normalized time
- `heartbeatAtTime(elapsedMs, config)` — returns dilation at absolute elapsed time

### 4. Perpetual Effects Runner (shell.qml)
A single `Timer` (`perpetualTimer`, interval ~16ms) drives all active perpetual
effects on each tick. It reads `cfg.sphere?.perpetualEffects` at runtime and
applies the heartbeat radius offset.

**Lifecycle:**
- **Start**: called from `finishOpenSwitcher()` (overlay just opened)
- **Stop**: called from `stopDrift()` (overlay closed via cancel/commit)

Wait, there's no "drift" anymore — the stop is called from `stopPerpetual()` which
is invoked in `cancelSwitch()` and `commitSelection()`.

Actually, the heartbeat replaces the perlin drift concept entirely. The perpetual
effects timer starts in `openSwitcher()` (or `finishOpenSwitcher()`) and stops
in `cancelSwitch()` / `commitSelection()`.

### 5. Layered Speed & Amplitude
On each tick, the runner checks the current layer and picks the appropriate
frequency multiplier and amplitude:

```
effectiveBpm = baseBpm * (layerConfig.frequency || 1.0)
effectiveAmplitude = layerConfig.amplitude || baseAmplitude
beatDurationMs = 60000 / effectiveBpm
```

The heartbeat waveform is then evaluated at `(elapsed % beatDurationMs) / beatDurationMs`.

### Files Modified
| File | Change |
|---|---|
| `hyprsphere.json` | Rename `effects` → `transitionEffects`, add `perpetualEffects` |
| `shell.qml` | Update config path, add perpetual timer + lifecycle |
| `effects.js` | Add heartbeat waveform functions |
| `manual_start.sh` | Already updated in PATCH_10 (symlinks for binds.js, effects.js) |

### Testing
1. Set `"enabled": true` in `perpetualEffects.heartbeat`
2. Open overlay (Alt+Tab) — sphere should pulse with a realistic heartbeat rhythm
3. Switch layers (drill down) — speed and amplitude should change per layer config
4. Close overlay — pulsing stops, radius snaps back to `baseSphereRadius`
5. Set `"enabled": false` — no pulsing, normal behavior
