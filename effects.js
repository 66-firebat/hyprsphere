// ══════════════════════════════════════════════════════════════════════════════
// effects.js — Animation effects for hyprsphere
//
// Import in shell.qml:
//   import "effects.js" as Effects
//
// Easing type numeric values (QML Easing enum not accessible from .js):
//   OutCubic     = 6
//   InBack       = 33
//   OutBack      = 34
//   BezierSpline = 45
// ══════════════════════════════════════════════════════════════════════════════

.pragma library

// ── Main entry point ──────────────────────────────────────────────────────

function setAnimation(anim, config) {
    if (!config) {
        _applyDefault(anim);
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

    _applyDefault(anim);
}

// ── Default: smooth cubic ease ────────────────────────────────────────────

function _applyDefault(anim) {
    anim.easing.type = 6;           // Easing.OutCubic
    anim.easing.overshoot = 0;
    anim.duration = 400;
}

// ── Bounce mode: OutBack overshoot ────────────────────────────────────────

function _applyBounce(anim, config) {
    var overshoot = config.overshoot !== undefined ? config.overshoot : 4.0;
    var duration = config.durationMs || 400;
    anim.easing.type = 34;           // Easing.OutBack
    anim.easing.overshoot = overshoot;
    anim.duration = duration;
}

// ── Launch mode: InBack pull-back ─────────────────────────────────────────
// InBack goes briefly in the opposite direction (pull-back / slingshot),
// then accelerates toward the target. The overshoot parameter controls
// how far back it goes.

function _applyLaunch(anim, config) {
    var dur = config.durationMs || 500;
    var sd = config.slingDistance !== undefined ? config.slingDistance : -5.0;
    var lb = config.landBounce !== undefined ? config.landBounce : 0.3;

    // Clamp
    if (sd > -0.01) sd = -0.01;
    if (sd < -10.0) sd = -10.0;
    if (lb < 0) lb = 0;
    if (lb > 1.0) lb = 1.0;

    // InBack: pull back then go forward. Overshoot controls pull-back distance.
    // Higher overshoot = more dramatic pull-back. We chain InBack (pull-back)
    // followed by OutBack (arrival bounce) using the ratio of the two.
    // InBack gets (1 - lb) fraction of the time, OutBack gets lb fraction.
    anim.easing.type = 33;           // Easing.InBack
    anim.easing.overshoot = -sd;     // Negative sd = positive overshoot
    anim.duration = Math.floor(dur * (1 - lb * 0.5));
}

// ── Reset animation to defaults ───────────────────────────────────────────

function resetAnimation(anim) {
    anim.easing.type = 6;           // Easing.OutCubic
    anim.easing.overshoot = 0;
    anim.duration = 400;
}
