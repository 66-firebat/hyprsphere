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
    if (window.layer === 0 || (window.layer === 2 && !node.isWindowNode)) {
        // App node: target is the MRU-most window of this app
        var addrs = window.windowsForApp ? window.windowsForApp(node.appId) : [];
        return addrs.length >= 1 ? addrs[0] : "";
    }
    // Window node: target is the window itself
    return node.address || "";
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
        var appNode = window.sphereModel[window.selectedAppIndex];
        if (!appNode || appNode.isPlaceholder || appNode.isWhitelistPlaceholder) return;
        if (appNode.windowCount === 0) return;

        window.layer = 1;
        window.drilledAppId = appNode.appId;
        window.sphereModel = window.buildLayer1(appNode.appId);

        window.selectedAppIndex = 0;
        if (window.sphereModel.length >= 2) {
            var commitAddr = window.windowsForApp ? window.windowsForApp(appNode.appId)[0] : "";
            if (window.sphereModel[0].address === commitAddr)
                window.selectedAppIndex = 1;
            else
                window.selectedAppIndex = 1;
        }

        window.projDirty = true;
        window.rebuildProjCache();
        window.centerOnApp(window.selectedAppIndex);
        window.log("drillDown 0→1: app=" + appNode.appId + " windows=" + window.sphereModel.length);

    } else if (window.layer === 2) {
        // Layer 2 → Layer 0: return to app list, select the app node
        // corresponding to the search result we were on.
        var searchNode = window.sphereModel[window.selectedAppIndex];
        if (!searchNode || searchNode.isPlaceholder) return;
        var targetAppId = searchNode.appId;

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

        // Select the app node matching the search result's appId
        var matched = false;
        if (targetAppId) {
            for (var _si = 0; _si < window.sphereModel.length; _si++) {
                if (window.sphereModel[_si].appId === targetAppId) {
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
        window.log("drillDown 2→0: app=" + targetAppId + (matched ? " selected" : " not found, fallback to 0"));

    } else {
        // Layer 1 → Layer 0: return to app list, select the app we drilled from
        var returnAppId = window.drilledAppId;
        window.layer = 0;
        window.drilledAppId = "";
        var raw = window.buildLayer0();
        window.sphereModel = raw.length === 0
            ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
            : raw;
        window.projDirty = true;
        window.rebuildProjCache();
        window.sphereZoom = 1.0;

        // Select the app node we were drilled into
        var matched = false;
        if (returnAppId) {
            for (var _si = 0; _si < window.sphereModel.length; _si++) {
                if (window.sphereModel[_si].appId === returnAppId) {
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
        window.log("drillDown 1→0: app=" + (returnAppId || "none") + (matched ? " selected" : " not found, fallback to 0"));
    }
}

// ── Commit Selection (Alt release / double-click) ─────────────────────────

function commitSelection(window, closeSequence) {
    if (!window.overlayActive) return;
    if (closeSequence.running) return;

    var node = window.sphereModel[window.selectedAppIndex];
    if (!node || node.isPlaceholder) {
        window.overlayActive = false;
        closeSequence.start();
        window.dispatchSubmap("reset");
        return;
    }

    if (node.isWhitelistPlaceholder) {
        window.focusable = false;
        window.overlayActive = false;
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

    if (addr) window.moveToFront(addr);

    window.overlayActive = false;
    window.visible = false;
    window.dispatchFocus(addr);
    if (window.cfg.fullscreenOnActivate) window.dispatchFullscreen(addr);
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

    if (window.layer === 0 || (window.layer === 2 && !node.isWindowNode)) {
        for (var w = 0; w < node.windows.length; w++)
            window.dispatchClose(node.windows[w].address);
    } else {
        window.dispatchClose(node.address);
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
    closeSequence.start();
    window.dispatchSubmap("reset");
    window.log("cancelSwitch");
}
