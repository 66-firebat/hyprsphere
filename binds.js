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
    // Layer 0 and layer 2 now have individual window nodes (isWindowNode=true).
    // For window nodes, target is the window itself. For app group nodes
    // (layer 2 only, whitelisted placeholders), target is MRU-most window.
    if (node.isWindowNode) {
        return node.address || "";
    }
    // App-level node (whitelisted placeholder at layer 2): target MRU-most
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
    window.log("advance: dir=" + dir + " idx=" + next + " app=" + window.sphereModel[next].appId + " layer=" + window.layer);
}

// ── Slash Preview (\ key) ─────────────────────────────────────────────────

function slashPreview(window, dir) {
    advance(window, dir);
    var node = window.sphereModel[window.selectedAppIndex];
    var addr = resolveTargetAddress(window, node);
    if (addr) {
        window.dispatchFocus(addr);
        if (window.visible) {
            window._togglingVisibility = true;
            window.visible = false;
            Qt.callLater(function() {
                window.visible = true;
                window._togglingVisibility = false;
            });
        }
        if (window.cfg.maximizeOnSlash && addr) window.dispatchFullscreen(addr);
    }
    window.log("slashPreview: dir=" + dir + " addr=" + (addr ? addr.substring(addr.length-6) : "none"));
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
        window.log("drillDown 0→1: app=" + selNode.appId + " wasAddr=" + (wasAddr ? wasAddr.substring(wasAddr.length-6) : "none") + " sel=" + window.selectedAppIndex);

    } else if (window.layer === 2) {
        // Layer 2 → Layer 0: return to flat window list, select the same
        // window by address that we were on in the search results.
        var searchNode = window.sphereModel[window.selectedAppIndex];
        if (!searchNode || searchNode.isPlaceholder) return;
        var targetAddr = searchNode.address || "";

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

        // Select by address (exact window match)
        var matched = false;
        if (targetAddr) {
            for (var _si = 0; _si < window.sphereModel.length; _si++) {
                if (window.sphereModel[_si].address === targetAddr) {
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
        window.log("drillDown 2→0: addr=" + (targetAddr ? targetAddr.substring(targetAddr.length-6) : "none") + (matched ? " selected" : " not found, fallback to 0"));

    } else {
        // Layer 1 → Layer 0: return to flat window list, select the same
        // window we were viewing by address.
        var returnAddr = window.sphereModel[window.selectedAppIndex]
            ? window.sphereModel[window.selectedAppIndex].address : null;
        window.layer = 0;
        window.drilledAppId = "";
        var raw = window.buildLayer0();
        window.sphereModel = raw.length === 0
            ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
            : raw;
        window.projDirty = true;
        window.rebuildProjCache();
        window.sphereZoom = 1.0;

        // Select by address (exact window match)
        var matched = false;
        if (returnAddr) {
            for (var _si = 0; _si < window.sphereModel.length; _si++) {
                if (window.sphereModel[_si].address === returnAddr) {
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
        window.log("drillDown 1→0: addr=" + (returnAddr ? returnAddr.substring(returnAddr.length-6) : "none") + (matched ? " selected" : " not found, fallback to 0"));
    }
}

// ── Commit Selection (Alt release / double-click) ─────────────────────────

function commitSelection(window, closeSequence) {
    if (!window.overlayActive) return;
    if (closeSequence.running) return;

    var node = window.sphereModel[window.selectedAppIndex];
    if (!node || node.isPlaceholder) {
        window.overlayActive = false;
        window.log("commitSelection: placeholder unfreeze");
    window._mruFrozen = false;
        closeSequence.start();
        window.dispatchSubmap("reset");
        return;
    }

    if (node.isWhitelistPlaceholder) {
        window.focusable = false;
        window.overlayActive = false;
        window.log("commitSelection: whitelist placeholder unfreeze");
    window._mruFrozen = false;
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

    if (addr) {
        window._commitAddr = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
        window.log("commitSelection: _commitAddr=" + window._commitAddr.substring(window._commitAddr.length-6) + " mruFrozen=" + window._mruFrozen);
        window.moveToFront(window._commitAddr);
        window.log("commitSelection: focusHistory[0..3] after moveToFront: " + window.focusHistory.slice(0,4).map(function(e){return e.appId.substring(0,10) + "-" + e.address.substring(e.address.length-4)}).join(", "));
    }

    window.overlayActive = false;
    window.visible = false;
    window.dispatchFocus(addr);
    if (window.cfg.fullscreenOnActivate) window.dispatchFullscreen(addr);
    // onActiveToplevelChanged unfreezes when the committed window's focus
    // event arrives. No deferred unfreeze needed — the guard blocks
    // auto-restore and lets only the committed window's event through.
    window.dispatchSubmap("reset");
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
        // App-level node (layer 2 whitelisted placeholder): close all windows
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
    window.overlayActive = false;
    window.visible = false;
    window.log("cancelSwitch: unfreeze MRU");
    window._mruFrozen = false;
    closeSequence.start();
    window.dispatchSubmap("reset");
    window.log("cancelSwitch");
}
