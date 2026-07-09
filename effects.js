// ══════════════════════════════════════════════════════════════════════════════
// effects.js — Animation effects for hyprsphere
//
// Import in shell.qml:
//   import "effects.js" as Effects
//
// Provides functions to configure QML NumberAnimation objects with
// different easing curves and parameters for a bounce/overshoot effect.
// ══════════════════════════════════════════════════════════════════════════════

.pragma library

// ── Easing type numeric values (QML Easing enum not accessible from .js) ──
// Easing.OutBack  = 34
// Easing.OutCubic = 6

// ── Configure a NumberAnimation with the current effect ───────────────────
// anim: a QML NumberAnimation object
// config: cfg.sphere?.effects from hyprsphere.json

function setAnimation(anim, config) {
    if (!config || config.mode !== "bounce") {
        // Default: smooth cubic ease, no overshoot
        anim.easing.type = 6;        // Easing.OutCubic
        anim.easing.overshoot = 0;
        anim.duration = 400;
        return;
    }

    var overshoot = config.overshoot !== undefined ? config.overshoot : 4.0;
    var duration = config.durationMs || 400;

    anim.easing.type = 34;           // Easing.OutBack
    anim.easing.overshoot = overshoot;
    anim.duration = duration;
}

// ── Reset animation to defaults ───────────────────────────────────────────

function resetAnimation(anim) {
    anim.easing.type = 6;           // Easing.OutCubic
    anim.easing.overshoot = 0;
    anim.duration = 400;
}
