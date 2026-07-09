// ══════════════════════════════════════════════════════════════════════════════
// rotations.js — Sphere rotation functions for hyprsphere
//
// Import in shell.qml:
//   import "rotations.js" as Rotations
//
// All functions receive config from cfg.sphere.rotation and a tick counter.
// Returns { x, y, z } target deltas for the current tick.
// ══════════════════════════════════════════════════════════════════════════════

.pragma library

// ── Entry point ───────────────────────────────────────────────────────────

function compute(cfg, tick, dt) {
    var mode = (cfg && cfg.mode) || "constant";
    var config = (cfg && cfg.config) || {};

    switch (mode) {
        case "constant":   return constantRotation(config, tick, dt);
        case "figure8":    return figure8Rotation(config, tick, dt);
        case "random":     return randomWalkRotation(config, tick, dt);
        default:           return { x: 0, y: -0.002 * dt, z: 0 };
    }
}

// ── Constant rotation ─────────────────────────────────────────────────────

function constantRotation(config, tick, dt) {
    return {
        x: (config.speedX || 0) * dt,
        y: (config.speedY || -0.002) * dt,
        z: (config.speedZ || 0) * dt,
    };
}

// ── Figure-8 rotation (Lissajous curve) ───────────────────────────────────

function figure8Rotation(config, tick, dt) {
    var freq = config.frequency || 0.001;
    var ampX = config.amplitudeX || 1.5;
    var ampY = config.amplitudeY || 1.0;
    var t = tick * freq;

    // Figure-8 Lissajous: direct sine/cosine output per tick
    // The Timer accumulates these deltas via rotX += delta.x each tick
    return {
        x: Math.sin(t) * ampX * 0.005 * dt,
        y: Math.sin(t * 2) * ampY * 0.005 * dt,
        z: 0,
    };
}

// ── Random walk (Perlin-like smooth noise) ────────────────────────────────

// Internal state for smooth random walk
var _phase = [0, 1.7, 3.1, 5.7, 7.3, 11.2];
var _lastTarget = { x: 0, y: 0, z: 0 };

function randomWalkRotation(config, tick, dt) {
    var amp = config.amplitude || 1.0;
    var speed = config.speed || 0.0005;
    var t = tick * speed;

    // Multi-octave Perlin-like noise: sum of sine waves at different
    // frequencies and phase offsets. Produces smooth, organic wandering.
    var noiseX = 0, noiseY = 0, noiseZ = 0;
    for (var o = 0; o < 4; o++) {
        var f = (1 << o) * 0.5;
        noiseX += Math.sin(t * f + _phase[o * 2]) / (o + 1);
        noiseY += Math.cos(t * f + _phase[o * 2 + 1]) / (o + 1);
        noiseZ += Math.sin(t * f * 0.7 + _phase[o]) / (o + 1);
    }

    // Normalize and scale to amplitude
    noiseX = noiseX / 2.5 * amp;
    noiseY = noiseY / 2.5 * amp;
    noiseZ = noiseZ / 2.5 * amp * 0.3;  // z drift is subtle

    return { x: noiseX * 0.001 * dt, y: noiseY * 0.001 * dt, z: noiseZ * 0.001 * dt };
}

// ── Reset state (call when overlay opens to avoid position jumps) ─────────

function reset() {
    _lastTarget = { x: 0, y: 0, z: 0 };
}
