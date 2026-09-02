// ══════════════════════════════════════════════════════════════════════════════
// binds.qml — Key-triggered functions for hyprsphere
//
// Import in shell.qml:
//   import "binds.qml" as Binds
//
// All functions receive `window` as first parameter to access state.
// ══════════════════════════════════════════════════════════════════════════════

.pragma library

// ── Helpers ───────────────────────────────────────────────────────────────

function resolveTargetAddress(window, node) {
    if (!node || node.isPlaceholder || node.isWhitelistPlaceholder) return "";
    // Window nodes (layers 1/2) target the window itself. App-group nodes
    // (layer 0) target the MRU-most window.
    if (node.isWindowNode) {
        return node.address || "";
    }
    // App-group node: target MRU-most window
    var addrs = window.windowsForApp ? window.windowsForApp(node.appId) : [];
    return addrs.length >= 1 ? addrs[0] : "";
}

// ── Advance (Tab / Shift+Tab) ─────────────────────────────────────────────

function advance(window, dir) {
    if (window.sphereModel.length === 0) return;
    if (window.sphereModel[0].isPlaceholder) return;
    var count = window.sphereModel.length;
    var next = window.selectedAppIndex + dir;
    var wrap = window.cfg.cycling?.wrapAround !== false;
    if (next < 0) next = wrap ? count - 1 : 0;
    else if (next >= count) next = wrap ? 0 : count - 1;
    window.selectedAppIndex = next;
    window.centerOnApp(next);
    window.refreshPeek();
    window.log("advance: dir=" + dir + " idx=" + next + " app=" + window.sphereModel[next].appId + " layer=" + window.layer);
}

// ── Drill-Down (;) ────────────────────────────────────────────────────────

function drillDown(window) {
    if (window.layer === 0) {
        // Layer 0 → Layer 1: drill into this app's windows
        var selNode = window.sphereModel[window.selectedAppIndex];
        if (!selNode || selNode.isPlaceholder || selNode.isWhitelistPlaceholder) return;
        var wasAddr = selNode.address;  // ← save for "other window" logic

        window.layer = 1;
        window.drilledAppId = selNode.appId;
        window.sphereModel = window.buildLayer1(selNode.appId);

        // Pre-select the "other window" — the one NOT matching the address
        // we were just on at layer 0.
        window.selectedAppIndex = 0;
        if (window.sphereModel.length >= 2 && wasAddr) {
            var wasIdx = -1;
            for (var i = 0; i < window.sphereModel.length; i++) {
                if (window.sphereModel[i].address === wasAddr) {
                    wasIdx = i;
                    break;
                }
            }
            if (wasIdx === 0) window.selectedAppIndex = 1;
            else if (wasIdx === 1) window.selectedAppIndex = 0;
            else window.selectedAppIndex = 1;
        }

        window.sphereZoom = window.cfg.sphere?.layer1Zoom ?? 0.5;
        window.projDirty = true;
        window.rebuildProjCache();
        window.centerOnApp(window.selectedAppIndex);
        window.refreshPeek();
        window.log("drillDown 0→1: app=" + selNode.appId + " wasAddr=" + (wasAddr ? wasAddr.substring(wasAddr.length-6) : "none") + " sel=" + window.selectedAppIndex);

    } else if (window.layer === 2) {
        // Layer 2 → Layer 0: return to layer 0, selecting the node matching
        // the window we were viewing (by appId when grouped, address when ungrouped).
        var searchNode = window.sphereModel[window.selectedAppIndex];
        if (!searchNode || searchNode.isPlaceholder) return;
        var grouped = window.isGroupedLayer0();
        var targetKey = grouped ? (searchNode.appId || "") : (searchNode.address || "");

        window.layer = 0;
        window.drilledAppId = "";
        window.searchQuery = "";
        var raw = window.buildLayer0();
        window.sphereModel = raw.length === 0
            ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
            : raw;
        window.projDirty = true;
        window.rebuildProjCache();
        window.sphereZoom = 1.0;

        // Select by appId (grouped) or address (ungrouped)
        var matched = false;
        if (targetKey) {
            for (var _si = 0; _si < window.sphereModel.length; _si++) {
                var n = window.sphereModel[_si];
                var hit = grouped ? (n.appId === targetKey) : (n.address === targetKey);
                if (hit) {
                    window.selectedAppIndex = _si;
                    window.centerOnApp(_si);
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            window.selectedAppIndex = 0;
            window.centerOnApp(0);
        }
        window.refreshPeek();
        window.log("drillDown 2→0: key=" + targetKey + (matched ? " selected" : " not found, fallback to 0"));

    } else {
        // Layer 1 → Layer 0: return to layer 0, selecting the window we were
        // viewing (by address when ungrouped, appId when grouped).
        var returnNode = window.sphereModel[window.selectedAppIndex];
        var grouped = window.isGroupedLayer0();
        var returnKey = returnNode
            ? (grouped ? returnNode.appId : returnNode.address)
            : null;
        window.layer = 0;
        window.drilledAppId = "";
        var raw = window.buildLayer0();
        window.sphereModel = raw.length === 0
            ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
            : raw;
        window.projDirty = true;
        window.rebuildProjCache();
        window.sphereZoom = 1.0;

        // Select by appId (grouped) or address (ungrouped)
        var matched = false;
        if (returnKey) {
            for (var _si = 0; _si < window.sphereModel.length; _si++) {
                var n = window.sphereModel[_si];
                var hit = grouped ? (n.appId === returnKey) : (n.address === returnKey);
                if (hit) {
                    window.selectedAppIndex = _si;
                    window.centerOnApp(_si);
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            window.selectedAppIndex = 0;
            window.centerOnApp(0);
        }
        window.refreshPeek();
        window.log("drillDown 1→0: key=" + returnKey + (matched ? " selected" : " not found, fallback to 0"));
    }
}

// ── Commit Selection (Alt release / double-click) ─────────────────────────

function commitSelection(window, closeSequence) {
    if (!window.overlayActive) return;
    if (closeSequence.running) return;
    if (window.commitFading) return;

    var node = window.sphereModel[window.selectedAppIndex];
    if (!node || node.isPlaceholder) {
        window.stopPerpetual();
        window.overlayActive = false;
        window.log("commitSelection: placeholder close");
        closeSequence.start();
        window.dispatchSubmap("reset");
        return;
    }

    if (node.isWhitelistPlaceholder) {
        window.focusable = false;
        window.stopPerpetual();
        window.overlayActive = false;
        window.log("commitSelection: whitelist placeholder close");
        if (window.cfg.fullscreenOnActivate) {
            window.dispatchExec(node.exec);
            window.dispatchFocusByClass(node.appId);
        } else {
            var sh = node.exec + ' & sleep 0.3 && hyprctl dispatch ' +
                "'hl.dsp.focus({window=\\\"class:" + node.appId + "\\\"})'" + ' &';
            Quickshell.execDetached(["bash", "-c", sh]);
        }
        closeSequence.start();
        window.dispatchSubmap("reset");
        return;
    }

    var addr = resolveTargetAddress(window, node);
    window.log("commitSelection: app=" + node.appId + " addr=" + (addr ? addr.substring(addr.length-6) : "none") + " layer=" + window.layer);

    // MRU is updated by onActiveToplevelChanged when the focus dispatch
    // arrives. No manual moveToFront here — it would fire before the
    // dispatches complete, and the fullscreen dispatch triggers a
    // secondary focus event that corrupts the MRU order.

    window.stopPerpetual();
    // Sentinel: only this address can update MRU. All other focus
    // changes (submap reset, surface unmap) are ignored.
    if (addr) {
        window._mruCommitAddr = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
    }
    // Disable input immediately (the fade is purely visual).
    window.focusable = false;
    // Dispatch focus immediately (async) — completes during the fade.
    window.dispatchCommit(addr);
    // Stop any in-flight idle fade, then fade the whole overlay out and close.
    window.cancelIdleFade();
    window.startCommitFade();
}

// ── Close Selection (Ctrl+C) ──────────────────────────────────────────────

function closeSelection(window) {
    var node = window.sphereModel[window.selectedAppIndex];
    if (!node || node.isPlaceholder) return;

    if (node.isWhitelistPlaceholder) {
        var spawnAddrs = window.windowsForApp ? window.windowsForApp(node.appId) : [];
        for (var si = 0; si < spawnAddrs.length; si++)
            window.dispatchClose(spawnAddrs[si]);
        return;
    }

    if (node.isWindowNode) {
        // Individual window node (layer 0, 1, or 2): close the specific window
        window.dispatchClose(node.address);
    } else {
        // App-group node (layer 0): close all windows
        for (var w = 0; w < node.windows.length; w++)
            window.dispatchClose(node.windows[w].address);
    }
    window.log("closeSelection: app=" + node.appId + " layer=" + window.layer);
}

// ── Open New Window (Ctrl+Enter) ──────────────────────────────────────────

function openNewWindow(window, closeSequence) {
    if (closeSequence.running) return;

    var node = window.sphereModel[window.selectedAppIndex];
    if (!node || node.isPlaceholder) return;

    var appId = node.appId;
    if (!appId) return;

    var execCmd = node.exec || window.resolveExec(appId) || appId;

    if (window.cfg.fullscreenOnActivate) {
        window.dispatchExec(execCmd);
    } else {
        Quickshell.execDetached(["bash", "-c", execCmd]);
    }

    window._pendingSpawnAppId = appId;
    window.log("openNewWindow: app=" + appId);
}

// ── Cancel Switch (Escape) ────────────────────────────────────────────────

function cancelSwitch(window, closeSequence) {
    if (closeSequence.running) return;
    window.layer = 0;
    window.drilledAppId = "";
    window.searchQuery = "";
    window.stopPerpetual();
    window.cancelIdleFade();
    window.log("cancelSwitch");
    window._mruCommitAddr = "";
    closeSequence.start();
    window.dispatchSubmap("reset");
    window.log("cancelSwitch done");
}
