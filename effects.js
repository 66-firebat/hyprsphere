// ══════════════════════════════════════════════════════════════════════════════
// effects.js — Perpetual effects for hyprsphere
//
// Each effect registers itself with register(name, { start, tick, stop }).
// The timer in shell.qml calls tick(window) every frame.
//
// Import in shell.qml:
//   import "effects.js" as Effects
// ══════════════════════════════════════════════════════════════════════════════

.pragma library

// ── Registry ──────────────────────────────────────────────────────────────

var _entries = [];   // { name, start, tick, stop }
var _running = false;

function register(name, hooks) {
    _entries.push({
        name: name,
        start: hooks.start || function(){},
        tick:  hooks.tick  || function(){},
        stop:  hooks.stop  || function(){}
    });
}

function start(window) {
    _running = true;
    for (var i = 0; i < _entries.length; i++) {
        _entries[i].start(window);
    }
}

function stop(window) {
    _running = false;
    for (var i = 0; i < _entries.length; i++) {
        _entries[i].stop(window);
    }
}

function tick(window) {
    if (!_running) return;
    for (var i = 0; i < _entries.length; i++) {
        _entries[i].tick(window);
    }
}

// ── Helpers for nodePeek ──────────────────────────────────────────────────

// Fibonacci-sphere target angles for a given index
function _peekTarget(window, idx) {
    var total = window.sphereModel.length;
    if (total < 2 || idx < 0 || idx >= total) return null;
    var phi = Math.PI * (3 - Math.sqrt(5));
    var by = 1.0 - (idx / Math.max(1, total - 1)) * 2.0;
    var br = Math.sqrt(1.0 - by * by);
    var bt = phi * idx;
    var bx = Math.cos(bt) * br;
    var bz = Math.sin(bt) * br;
    return {
        rx: Math.atan2(by, bz),
        ry: Math.atan2(-bx, Math.sqrt(by * by + bz * bz))
    };
}

// ── Heartbeat Effect ─────────────────────────────────────────────────────

function heartbeatAtPhase(t, lubPos, dubPos, lubWidth, dubWidth, lubDecay, dubDecay) {
    lubPos   = lubPos   || 0.08;
    dubPos   = dubPos   || 0.28;
    lubWidth = lubWidth || 0.025;
    dubWidth = dubWidth || 0.045;
    lubDecay = lubDecay || lubWidth;   // default: symmetric
    dubDecay = dubDecay || dubWidth;

    // Asymmetric Gaussian: attack uses width, decay uses decay
    var lubDiff = t - lubPos;
    var lub = Math.exp(-Math.pow(lubDiff / (lubDiff < 0 ? lubWidth : lubDecay), 2));

    var dubDiff = t - dubPos;
    var dub = 0.5 * Math.exp(-Math.pow(dubDiff / (dubDiff < 0 ? dubWidth : dubDecay), 2));

    // Small tension ripple shortly after dub (ripple width = dubDecay * 1.33)
    var ripPos = dubPos + 0.14;
    var ripple = 0.12 * Math.exp(-Math.pow((t - ripPos) / (dubDecay * 1.33), 2));
    return Math.max(0, lub + dub + ripple);
}

register("heartbeat", {
    start: function(window) {
        window._hbStartTime = Date.now();
    },
    tick: function(window) {
        var pe = window.cfg.sphere?.perpetualEffects;
        if (!pe || !pe.heartbeat || !pe.heartbeat.enabled) return;
        var hb = pe.heartbeat;
        var layerKey = "layer_" + window.layer;
        var lc = hb.layers ? hb.layers[layerKey] : null;
        var freqMult = (lc && lc.frequency !== undefined) ? lc.frequency : 1.0;
        var amp = (lc && lc.amplitude !== undefined) ? lc.amplitude : (hb.amplitude || 24);
        var bpm = (hb.bpm || 54) * freqMult;
        var beatMs = 60000 / bpm;
        var elapsed = Date.now() - window._hbStartTime;
        var t = (elapsed % beatMs) / beatMs;
        var lubPos   = hb.lubPos   || 0.08;
        var dubPos   = hb.dubPos   || 0.28;
        var lubWidth = hb.lubWidth || 0.025;
        var dubWidth = hb.dubWidth || 0.045;
        var lubDecay = hb.lubDecay || lubWidth;
        var dubDecay = hb.dubDecay || dubWidth;
        var hbVal = heartbeatAtPhase(t, lubPos, dubPos, lubWidth, dubWidth, lubDecay, dubDecay);
        window.sphereRadius = window.baseSphereRadius - hbVal * amp;
        window._hbIconScale = 1.0 + hbVal * (hb.scaleAmplitude || 0);
        window._hbIconOpacity = 1.0 - hbVal * (hb.opacityAmplitude || 0);
    },
    stop: function(window) {
        window._hbStartTime = 0;
        window._hbIconScale = 1.0;
        window._hbIconOpacity = 1.0;
        window.sphereRadius = window.baseSphereRadius;
    }
});

// ── NodePeek Effect ───────────────────────────────────────────────────────
// Continuously rotates the sphere through a 2π cycle: current → next → prev → back.
// Starts from the camera's current position. Smooth slowdown at next and prev nodes.

register("nodePeek", {
    start: function(window) {
        window._peekTime = 0;
        window._peekTargets = null;
        window._peekInitialized = false;
    },
    tick: function(window) {
        var cfg = window.cfg.sphere?.perpetualEffects?.nodePeek;
        if (!cfg || !cfg.enabled) return;
        if (window._animating) return;
        if (window.sphereModel.length < 2) return;

        if (window._peekRestart || !window._peekInitialized) {
            window._peekRestart = false;
            if (!_peekBuild(window, cfg)) return;
            window._peekInitialized = true;
            window._peekTime = 0;
        }

        var tgt = window._peekTargets;
        if (!tgt || !tgt.cur || !tgt.prev) return;

        window._peekTime += 16;
        var period = cfg.periodMs || 3000;
        var pause1 = cfg.pauseNode1 || 500;
        var pause2 = cfg.pauseNode2 || 500;
        var moveTime = (period - pause1 - pause2) / 2;
        if (moveTime < 1) moveTime = 1;
        var t = window._peekTime % period;
        var progress;
        if (t < pause1) {
            progress = 0;
        } else if (t < pause1 + moveTime) {
            progress = (t - pause1) / moveTime;
        } else if (t < pause1 + moveTime + pause2) {
            progress = 1;
        } else {
            progress = 1 - (t - pause1 - moveTime - pause2) / moveTime;
        }

        var ry1 = tgt.cur.ry;
        var rx1 = tgt.cur.rx;
        var ry2 = tgt.prev.ry;
        var rx2 = tgt.prev.rx;

        // Shortest angular distance from cur to prev (Y)
        var dy = ry2 - ry1;
        if (dy > Math.PI) dy -= 2 * Math.PI;
        if (dy < -Math.PI) dy += 2 * Math.PI;

        // Shortest angular distance from cur to prev (X)
        var dx = rx2 - rx1;
        if (dx > Math.PI) dx -= 2 * Math.PI;
        if (dx < -Math.PI) dx += 2 * Math.PI;

        window.rotY = ry1 + dy * progress;
        window.rotX = rx1 + dx * progress;
    },
    stop: function(window) {
        window._peekInitialized = false;
        window._peekTargets = null;
        window._peekTime = 0;
    }
});

// ── Peek initializer ──────────────────────────────────────────────────────
// Stores current and next node targets.

function _peekBuild(window, cfg) {
    var total = window.sphereModel.length;
    var cur = window.selectedAppIndex;
    if (total < 2 || cur < 0) return false;
    var prv = (cur - 1 + total) % total;

    var tgtCur  = _peekTarget(window, cur);
    var tgtPrev = _peekTarget(window, prv);
    if (!tgtCur || !tgtPrev) return false;

    window._peekTargets = { cur: tgtCur, prev: tgtPrev };
    return true;
}

// ── Expand Trail Effect ────────────────────────────────────────────────────
// Marches a dilation pulse through the sphereModel list one node at a time.
// Each icon briefly swells to trailScale, then returns to 1.0 as the wave
// moves to the next node. Cycles back to the front after a configurable delay.

register("expandTrail", {
    start: function(window) {
        window._trailTime = 0;
    },
    tick: function(window) {
        var cfg = window.cfg.sphere?.perpetualEffects?.expandTrail;
        if (!cfg || !cfg.enabled) return;
        window._trailTime += 16;
        // Expose config values for QML bindings
        window._trailStepTime = cfg.stepTime || 200;
        window._trailBumpDuration = cfg.bumpDuration || 600;
        window._trailScale = cfg.scale || 1.5;
        window._trailDelay = cfg.delayBetweenWaves || 0;
    },
    stop: function(window) {
        window._trailTime = 0;
    }
});
