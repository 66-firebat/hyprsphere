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

// ── Heartbeat Effect ─────────────────────────────────────────────────────

function heartbeatAtPhase(t) {
    // Systolic spike: sharp Gaussian at ~8%
    var lub = Math.exp(-Math.pow((t - 0.08) / 0.025, 2));
    // Diastolic bump: gentler 50%-height at ~28%
    var dub = 0.5 * Math.exp(-Math.pow((t - 0.28) / 0.045, 2));
    // Small tension ripple after dub
    var ripple = 0.12 * Math.exp(-Math.pow((t - 0.42) / 0.06, 2));
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
        var hbVal = heartbeatAtPhase(t);
        window.sphereRadius = window.baseSphereRadius + hbVal * amp;
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
