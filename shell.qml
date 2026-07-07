import QtQuick
import Qt5Compat.GraphicalEffects
import QtQuick.Window
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland._Ipc
import "lib/fuse.js" as FuseJs

PanelWindow {
    id: window
    focusable: true

    WlrLayershell.namespace: "applauncher-overlay"
    WlrLayershell.layer: WlrLayer.Overlay

    anchors.left: true
    anchors.right: true
    anchors.top: true
    anchors.bottom: true

    exclusiveZone: 0
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    implicitWidth: Screen.width
    implicitHeight: Screen.height

    // Config file path — resolved relative to shell.qml's directory
    property string configPath: String(Qt.resolvedUrl("hyprsphere.json")).replace(/^file:\/\//, "")

    // Config loaded from hyprsphere.json
    property var cfg: ({})

    Process {
        id: configReader
        command: ["cat", window.configPath]
        stdout: StdioCollector {
            onStreamFinished: {
                var txt = this.text.trim();
                if (txt.length > 0) {
                    try { window.cfg = JSON.parse(txt); }
                    catch(e) { console.log("Config parse error:", String(e)); }
                }
            }
        }
    }

    // ── Phase 1: app grouping ──
    property var sphereModel: []
    property var rebuildScheduled: false
    property int selectedAppIndex: -1

    // ── Phase 4: two-layer state machine ──
    property int layer: 0
    property string drilledAppId: ""

    // ── Phase 2: MRU tracking ──
    property var appMru: []
    property var appWindowMru: ({})
    property var _appOpeningOrder: ({})

    // ── Phase 7: Icon & name resolution ──
    property var iconMap: ({})
    property var nameMap: ({})
    property var execMap: ({})

    function resolveIcon(appId) {
        if (!appId) return "application-x-executable";
        return iconMap[appId] || "application-x-executable";
    }

    function resolveName(appId) {
        if (!appId) return appId;
        return nameMap[appId] || appId;
    }

    function resolveExec(appId) {
        if (!appId) return null;
        return execMap[appId] || null;
    }

    function showNonSelectedLabel() {
        var layers = cfg.appCard?.nonSelectedLayerLabels;
        if (!layers) return true;
        var key = "layer_" + window.layer;
        return layers[key] !== false;
    }

    Process {
        id: iconReader
        command: ["bash", "-c",
            "for f in /run/current-system/sw/share/applications/*.desktop " +
            "$HOME/.local/share/applications/*.desktop; do " +
            "[ -f \"$f\" ] || continue; " +
            "echo \"[ID]$(basename \"$f\" .desktop)\"; " +
            "grep -E '^(Name=|Icon=|StartupWMClass=|Exec=)' \"$f\" 2>/dev/null; " +
            "echo '---'; done"
        ]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var txt = this.text.trim();
                console.log("[hyprsphere] Icon reader finished, got " + txt.length + " chars");
                if (txt.length > 0) window.parseIcons(txt);
            }
        }
    }

    function parseIcons(text) {
        var map = {};
        var nmap = {};
        var emap = {};
        var blocks = text.split('---');
        for (var b = 0; b < blocks.length; b++) {
            var lines = blocks[b].trim().split('\n');
            var id = null, icon = null, wmClass = null, name = null, exec = null;
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i].trim();
                if (line.startsWith('[ID]')) {
                    id = line.substring(4).trim();
                } else if (line.startsWith('Name=')) {
                    name = line.substring(5).trim();
                } else if (line.startsWith('Icon=')) {
                    icon = line.substring(5).trim();
                } else if (line.startsWith('StartupWMClass=')) {
                    wmClass = line.substring(15).trim();
                } else if (line.startsWith('Exec=') && exec === null) {
                    // Only use the first Exec= line (the default action)
                    exec = line.substring(5).trim();
                    // Strip freedesktop field codes: %u %U %f %F %i %c %k %%
                    exec = exec.replace(/%[uUfFick]/g, '').trim();
                    exec = exec.replace(/%%/g, '%');
                }
            }
            if (id && icon) {
                map[id] = icon;
                if (wmClass) map[wmClass] = icon;
            }
            if (id && name) {
                nmap[id] = name;
                if (wmClass) nmap[wmClass] = name;
            }
            if (id && exec) {
                emap[id] = exec;
                if (wmClass) emap[wmClass] = exec;
            }
        }
        iconMap = map;
        nameMap = nmap;
        execMap = emap;
        console.log("[hyprsphere] Icon map built: " + Object.keys(map).length + " entries, Name map built: " + Object.keys(nmap).length + " entries, Exec map built: " + Object.keys(emap).length + " entries");
        // If overlay is already visible, refresh sphere with correct icons
        if (window.visible) scheduleRebuild();
    }

    function initWindowIndices() {
        var tls = Hyprland.toplevels;
        var arr = (tls && tls.values) || [];
        if (arr.length === 0) {
            // Toplevels not populated yet — retry on next tick
            Qt.callLater(function() { window.initWindowIndices(); });
            return;
        }
        window._appOpeningOrder = {};
        for (var i = 0; i < arr.length; i++) {
            var t = arr[i];
            if (!t) continue;
            var addr = t.address || "";
            if (!addr) continue;
            if (addr.indexOf("0x") !== 0) addr = "0x" + addr;
            var appId = (t.wayland && t.wayland.appId) ? t.wayland.appId : "unknown";
            if (!window._appOpeningOrder[appId]) window._appOpeningOrder[appId] = [];
            if (window._appOpeningOrder[appId].indexOf(addr) === -1) {
                window._appOpeningOrder[appId].push(addr);
            }
        }
        console.log("[hyprsphere] Per-app opening order initialized for " + Object.keys(window._appOpeningOrder).length + " apps");
    }

    // ── Phase 6: Search / Layer 2 ──
    property string searchQuery: ""
    property var fuseIndex: null
    property var searchDatabase: []
    property var searchTimer: null
    property var savedLayer2Model: []
    property string savedLayer2Query: ""
    property bool searchFocused: false
    property string _pendingSpawnAppId: ""
    property string _pendingSpawnAddr: ""


    // ── Global window-level MRU tracking ──
    property var globalWindowMru: []
    property string _preSelectedAppId: ""

    function _findAppForAddress(addr) {
        if (!addr) return "";
        var normAddr = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
        for (var i = 0; i < (window.sphereModel || []).length; i++) {
            var app = window.sphereModel[i];
            if (app.isPlaceholder || app.isWhitelistPlaceholder) continue;
            for (var j = 0; j < (app.windows || []).length; j++) {
                var wAddr = app.windows[j].address || "";
                if (wAddr.indexOf("0x") !== 0) wAddr = "0x" + wAddr;
                if (wAddr === normAddr) return app.appId;
            }
        }
        return "";
    }

    function buildLayer0() {
        var groups = {};
        var tls = Hyprland.toplevels;
        var arr = (tls && tls.values) || [];
        for (var idx = 0; idx < arr.length; idx++) {
            var t = arr[idx];
            if (!t) continue;
            var ws = t.workspace;
            // Special ws check by name only (ws.id is -1 in IPC mode)
            if (ws && String(ws.name || "").startsWith("special:")) continue;
            var wl = t.wayland;
            var appId = (wl && wl.appId) ? wl.appId : "unknown";
            if (!groups[appId]) groups[appId] = { appId: appId, label: window.resolveName(appId), icon: window.resolveIcon(appId), windows: [] };
            var wAddr = t.address || "";
            if (wAddr.indexOf("0x") !== 0) wAddr = "0x" + wAddr;
            groups[appId].windows.push({ address: wAddr, title: t.title });
            groups[appId].windowCount = groups[appId].windows.length;
        }
        var whitelist = cfg.whitelist || [];
        for (var entry of whitelist) {
            if (groups[entry.appId]) continue;
            groups[entry.appId] = {
                appId: entry.appId, label: entry.label, icon: entry.icon,
                exec: entry.exec, windows: [], windowCount: 0,
                isWhitelistPlaceholder: true,
            };
        }
        return Object.values(groups);
    }

    function openSwitcher() {
        console.log("[hyprsphere] openSwitcher() called");

        window.layer = 0;
        window.drilledAppId = "";
        window.searchQuery = "";
        window.savedLayer2Model = [];
        window.savedLayer2Query = "";

        window.focusable = true;
        window.overlayActive = true;
        window._pendingSpawnAppId = "";
        window._preSelectedAppId = "";

        // Enter Hyprland submap so letter keys pass through to QML
        // NOTE: must use hyprctl eval, not dispatch (submap is Lua-only)
        Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("hyprsphere"))']);

        // Toplevel IPC data is not available synchronously (confirmed by
        // Phase 1 testing: 2 event-loop ticks needed after refresh).
        // Build asynchronously with retry.
        Hyprland.refreshToplevels();
        Qt.callLater(function() { finishOpenSwitcher(); });
    }

    function finishOpenSwitcher() {
        // Guard: if the overlay was cancelled during async data gathering, abort
        if (!window.overlayActive) return;

        // Wait for icon map to be built before building sphere
        // (iconReader Process runs async at startup)
        var iconReady = Object.keys(iconMap).length > 0;
        if (!iconReady) {
            Qt.callLater(function() { finishOpenSwitcher(); });
            return;
        }

        var raw = buildLayer0();
        console.log("[hyprsphere] buildLayer0 returned " + raw.length + " groups");

        if (raw.length === 0) {
            // No data yet — retry on next tick
            Qt.callLater(function() { finishOpenSwitcher(); });
            return;
        }

        var mruSorted = sortByMru(raw);
        sphereModel = mruSorted.length === 0
            ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
            : mruSorted;

        if (sphereModel.length > 0 && !sphereModel[0].isPlaceholder) {
            window._preSelectedAppId = "";
            if (window.globalWindowMru.length >= 2) {
                window._preSelectedAppId = window._findAppForAddress(window.globalWindowMru[1]);
            }
            if (window._preSelectedAppId) {
                for (var wsi = 0; wsi < sphereModel.length; wsi++) {
                    if (sphereModel[wsi].appId === window._preSelectedAppId) {
                        selectedAppIndex = wsi;
                        break;
                    }
                }
            } else {
                selectedAppIndex = 0;
            }
            if (selectedAppIndex < sphereModel.length) {
                centerOnApp(selectedAppIndex);
            }
        }

        projDirty = true;
        rebuildProjCache();

        // Initialize Fuse index for search
        initFuseIndex();

        // Make overlay visible now that sphere data is ready.
        // The entrance fade animation and focus grab are triggered
        // automatically by the onVisibleChanged handler.
        window.visible = true;

        // Refresh on next tick to catch pending appId resolutions.
        Qt.callLater(function() { scheduleRebuild(); });
    }

    function sortByMru(raw) {
        var sorted = [];
        for (var m = 0; m < appMru.length; m++) {
            for (var r = 0; r < raw.length; r++) {
                if (raw[r].appId === appMru[m]) {
                    sorted.push(raw[r]);
                    break;
                }
            }
        }
        for (var r2 = 0; r2 < raw.length; r2++) {
            if (sorted.indexOf(raw[r2]) === -1) sorted.push(raw[r2]);
        }
        return sorted;
    }

    // ── Phase 6: Search / Layer 2 ──
    function buildSearchDatabase() {
        var db = [];
        var tls = Hyprland.toplevels;
        var arr = (tls && tls.values) || [];
        var seenApps = {};

        // Collect running apps grouped
        for (var i = 0; i < arr.length; i++) {
            var t = arr[i];
            if (!t) continue;
            var ws = t.workspace;
            if (ws && String(ws.name || "").startsWith("special:")) continue;
            var wl = t.wayland;
            var appId = (wl && wl.appId) ? wl.appId : "unknown";
            if (!seenApps[appId]) {
                seenApps[appId] = true;
                db.push({ type: "running-app", appId: appId, label: window.resolveName(appId), icon: window.resolveIcon(appId), windows: [] });
            }
            for (var d = 0; d < db.length; d++) {
                if (db[d].appId === appId && db[d].type === "running-app") {
                    var sAddr1 = t.address || "";
                    if (sAddr1.indexOf("0x") !== 0) sAddr1 = "0x" + sAddr1;
                    db[d].windows.push({ address: sAddr1, title: t.title });
                    break;
                }
            }
        }

        // Add window-level entries for title search
        for (var i2 = 0; i2 < arr.length; i2++) {
            var t2 = arr[i2];
            if (!t2) continue;
            var ws2 = t2.workspace;
            if (ws2 && String(ws2.name || "").startsWith("special:")) continue;
            var wl2 = t2.wayland;
            var appId2 = (wl2 && wl2.appId) ? wl2.appId : "unknown";
            db.push({
                type: "window", appId: appId2, label: window.resolveName(appId2), icon: window.resolveIcon(appId2),
                address: (t2.address && t2.address.indexOf("0x") === 0 ? t2.address : "0x" + (t2.address || "")), title: t2.title || appId2
            });
        }

        // Add whitelisted placeholder apps (not already running)
        var whitelist = cfg.whitelist || [];
        for (var e = 0; e < whitelist.length; e++) {
            var entry = whitelist[e];
            if (seenApps[entry.appId]) continue;
            db.push({
                type: "whitelisted-app", appId: entry.appId, label: entry.label,
                icon: entry.icon, exec: entry.exec, windows: [], windowCount: 0
            });
        }

        return db;
    }

    function initFuseIndex() {
        var db = buildSearchDatabase();
        searchDatabase = db;
        try {
            fuseIndex = new FuseJs.Fuse(db, {
                keys: [
                    { name: "label", weight: 0.5 },
                    { name: "title", weight: 0.4 },
                    { name: "appId", weight: 0.1 }
                ],
                threshold: cfg.search?.fuseThreshold ?? 0.4,
                minMatchCharLength: cfg.search?.fuseMinMatchCharLength ?? 1,
                includeScore: true,
                shouldSort: true
            });
        } catch (e) {
            console.log("[hyprsphere] Fuse init error:", String(e));
            fuseIndex = null;
        }
    }

    function _handleSearchInput(text) {
        searchQuery = text;

        if (searchQuery === "" && window.layer === 2) {
            cancelSearch();
            return;
        }

        if (searchTimer) searchTimer.running = false;
        searchTimer = Qt.createQmlObject(
            'import QtQuick; Timer { interval: ' + (cfg.search?.delayMs ?? 150)
            + '; running: true; repeat: false; onTriggered: window._executeSearch(); }',
            window
        );
    }

    function _executeSearch() {
        if (searchQuery === "") return;
        if (!fuseIndex) {
            initFuseIndex();
            if (!fuseIndex) return;
        }

        var results = fuseIndex.search(searchQuery);
        var maxResults = cfg.search?.maxResults ?? 30;
        var top = results.slice(0, maxResults);

        var runApps = [];
        var whitelistApps = [];
        var winNodes = [];

        for (var i = 0; i < top.length; i++) {
            var item = top[i].item;
            if (item.type === "running-app") {
                runApps.push(item);
            } else if (item.type === "whitelisted-app") {
                whitelistApps.push(item);
            } else if (item.type === "window") {
                winNodes.push(item);
            }
        }

        // Build layer 2 model: running apps → whitelisted apps → windows
        var layer2Model = [];

        for (var r = 0; r < runApps.length; r++) {
            var ra = runApps[r];
            layer2Model.push({
                appId: ra.appId, label: ra.label, icon: ra.icon,
                windows: ra.windows, windowCount: ra.windows.length,
                isSearchResult: true
            });
        }

        for (var w = 0; w < whitelistApps.length; w++) {
            var wa = whitelistApps[w];
            layer2Model.push({
                appId: wa.appId, label: wa.label, icon: wa.icon,
                exec: wa.exec, windows: [], windowCount: 0,
                isWhitelistPlaceholder: true, isSearchResult: true
            });
        }

        for (var w2 = 0; w2 < winNodes.length; w2++) {
            var wn = winNodes[w2];
            layer2Model.push({
                appId: wn.appId, label: wn.label, icon: wn.icon,
                address: wn.address, title: wn.title,
                isWindowNode: true, isSearchResult: true
            });
        }

        window.layer = 2;
        sphereModel = layer2Model.length === 0
            ? [{ label: "No results", icon: "", appId: "", isPlaceholder: true }]
            : layer2Model;
        selectedAppIndex = 0;
        projDirty = true;
        rebuildProjCache();
        centerOnApp(0);
        sphereZoom = cfg.search?.layer2Zoom ?? 1.5;
    }

    function cancelSearch() {
        searchQuery = "";
        savedLayer2Model = [];
        savedLayer2Query = "";
        var raw = buildLayer0();
        window.layer = 0;
        sphereModel = raw.length === 0
            ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
            : sortByMru(raw);
        sphereZoom = 1.0;
        projDirty = true;
        rebuildProjCache();
        if (sphereModel.length > 0 && !sphereModel[0].isPlaceholder) {
            selectedAppIndex = Math.min(sphereModel.length - 1, selectedAppIndex);
            centerOnApp(selectedAppIndex);
        }
    }

    function scheduleRebuild() {
        if (rebuildScheduled) return;
        rebuildScheduled = true;
        Qt.callLater(function() {
            rebuildScheduled = false;
            // Run regardless of visibility — sphere data is cheap to rebuild
            // and may be needed when overlay reappears after visible toggle.
            Hyprland.refreshToplevels();
            var raw = buildLayer0();

            // If waiting for a spawned window and the data isn't ready yet, retry
            if (window._pendingSpawnAddr && raw.length > 0) {
                var spawnReady = false;
                for (var ri = 0; ri < raw.length; ri++) {
                    if (raw[ri].appId === window._pendingSpawnAppId
                        && !raw[ri].isWhitelistPlaceholder) {
                        // Verify the specific pending address is in the window list
                        // (normalize both sides to handle 0x prefix mismatch)
                        for (var wj = 0; wj < (raw[ri].windows || []).length; wj++) {
                            var winAddr = raw[ri].windows[wj].address || "";
                            if (winAddr.indexOf("0x") !== 0) winAddr = "0x" + winAddr;
                            if (winAddr === window._pendingSpawnAddr) {
                                spawnReady = true;
                                break;
                            }
                        }
                        break;
                    }
                }
                if (!spawnReady) {
                    // Toplevel data not yet updated — retry on next tick
                    window.rebuildScheduled = false;
                    window.scheduleRebuild();
                    return;
                }
            }

if (window.layer === 2 && window.searchQuery !== "") {
                // Layer 2 active: re-init Fuse index and re-run search
                initFuseIndex();
                _executeSearch();
                return;
            }

            if (window.layer === 1 && window.drilledAppId) {
                var prevAddress = sphereModel[selectedAppIndex]
                    ? sphereModel[selectedAppIndex].address
                    : null;

                var app = null;
                for (var i = 0; i < raw.length; i++) {
                    if (raw[i].appId === window.drilledAppId) { app = raw[i]; break; }
                }

                if (app && app.windowCount >= 1) {
                    var winMru = appWindowMru[app.appId] || [];
                    sphereModel = app.windows.slice().map(function(w) {
                        return {
                            address: w.address,
                            title:   w.title,
                            icon:    app.icon,
                            label:   app.label,
                            appId:   app.appId,
                            isWindowNode: true,
                        };
                    }).sort(function(a, b) {
                        var ia = winMru.indexOf(a.address);
                        var ib = winMru.indexOf(b.address);
                        return (ia === -1 ? 999 : ia) - (ib === -1 ? 999 : ib);
                    });

                    var restoredIdx = -1;
                    for (var si = 0; si < sphereModel.length; si++) {
                        if (sphereModel[si].address === prevAddress) { restoredIdx = si; break; }
                    }
                    selectedAppIndex = restoredIdx >= 0 ? restoredIdx : 0;
                    centerOnApp(selectedAppIndex);
                } else {
                    window.layer = 0;
                    window.drilledAppId = "";
                    rebuildToLayer0(raw);
                }
            } else {
                rebuildToLayer0(raw);
            }

            projDirty = true;
            rebuildProjCache();
            // If we just spawned a new window, select it
            if (window._pendingSpawnAddr) {
                var found = false;
                if (window.layer === 0) {
                    // Layer 0: match by appId (app nodes don't have .address)
                    for (var si = 0; si < window.sphereModel.length; si++) {
                        if (window.sphereModel[si].appId === window._pendingSpawnAppId
                            && !window.sphereModel[si].isWhitelistPlaceholder) {
                            window.selectedAppIndex = si;
                            window.centerOnApp(si);
                            found = true;
                            break;
                        }
                    }
                } else {
                    // Layer 1/2: match by address (normalize 0x prefix)
                    for (var si = 0; si < window.sphereModel.length; si++) {
                        var sa = window.sphereModel[si].address || "";
                        if (sa.indexOf("0x") !== 0) sa = "0x" + sa;
                        if (sa === window._pendingSpawnAddr) {
                            window.selectedAppIndex = si;
                            window.centerOnApp(si);
                            found = true;
                            break;
                        }
                    }
                }
                if (!found && window.layer === 0 && window.sphereModel.length > 0) {
                    // Fallback: select the first non-placeholder node
                    for (var si = 0; si < window.sphereModel.length; si++) {
                        if (!window.sphereModel[si].isPlaceholder) {
                            window.selectedAppIndex = si;
                            window.centerOnApp(si);
                            break;
                        }
                    }
                }
                window._pendingSpawnAddr = "";
            }
            // Recalculate pre-selection so the sphere follows window opens/closes.
            // Don't override the spawn auto-selection though.
            if (window.visible && !window._pendingSpawnAppId) {
                window._preSelectedAppId = "";
                if (window.globalWindowMru.length >= 2) {
                    window._preSelectedAppId = window._findAppForAddress(window.globalWindowMru[1]);
                }
                // If the current selection is no longer valid, update to the pre-selected app.
                var curApp = window.sphereModel && window.sphereModel.length > window.selectedAppIndex
                    ? window.sphereModel[window.selectedAppIndex] : null;
                if (window._preSelectedAppId && (!curApp || curApp.appId !== window._preSelectedAppId)) {
                    for (var rsi = 0; rsi < (window.sphereModel || []).length; rsi++) {
                        if (window.sphereModel[rsi].appId === window._preSelectedAppId) {
                            window.selectedAppIndex = rsi;
                            window.centerOnApp(rsi);
                            break;
                        }
                    }
                }
            }
            // After any sphere rebuild, ensure overlay still has keyboard focus
            focusGrabber.forceActiveFocus();
        });
    }

    function drillDown() {
        if (window.layer === 0) {
            // Layer 0 → Layer 1 (existing behavior)
            var app = sphereModel[selectedAppIndex];
            if (!app || app.isPlaceholder || app.isWhitelistPlaceholder) return;
            if (app.windowCount === 0) return;

            window.layer = 1;
            window.drilledAppId = app.appId;

            var winMru = appWindowMru[app.appId] || [];
            sphereModel = app.windows.slice().map(function(w) {
                return {
                    address: w.address,
                    title:   w.title,
                    icon:    app.icon,
                    label:   app.label,
                    appId:   app.appId,
                    isWindowNode: true,
                };
            }).sort(function(a, b) {
                var ia = winMru.indexOf(a.address);
                var ib = winMru.indexOf(b.address);
                return (ia === -1 ? 999 : ia) - (ib === -1 ? 999 : ib);
            });

            selectedAppIndex = 0;
            // Pre-select the second MRU-most window (index 1) so the drill-down
            // shows the window the user is likely to switch to, not the one
            // they're already on (which is what they'd get at layer 0).
            if (winMru.length >= 2) {
                var secondTarget = winMru[1];
                if (secondTarget.indexOf("0x") !== 0) secondTarget = "0x" + secondTarget;
                for (var di = 0; di < sphereModel.length; di++) {
                    var dAddr = sphereModel[di].address || "";
                    if (dAddr.indexOf("0x") !== 0) dAddr = "0x" + dAddr;
                    if (dAddr === secondTarget) {
                        selectedAppIndex = di;
                        break;
                    }
                }
            }
            projDirty = true;
            rebuildProjCache();
            centerOnApp(selectedAppIndex);
        } else if (window.layer === 2) {
            // Layer 2 → drill into app → Layer 1
            var node = sphereModel[selectedAppIndex];
            if (!node || node.isPlaceholder || node.isWhitelistPlaceholder) return;
            if (node.isWindowNode) return;  // no-op on window nodes
            if (!node.windows || node.windowCount === 0) return;

            // Save layer 2 state for restoration
            savedLayer2Model = sphereModel.slice();
            savedLayer2Query = searchQuery;

            window.layer = 1;
            window.drilledAppId = node.appId;

            var winMru = appWindowMru[node.appId] || [];
            sphereModel = node.windows.slice().map(function(w) {
                return {
                    address: w.address,
                    title:   w.title,
                    icon:    node.icon,
                    label:   node.label,
                    appId:   node.appId,
                    isWindowNode: true,
                };
            }).sort(function(a, b) {
                var ia = winMru.indexOf(a.address);
                var ib = winMru.indexOf(b.address);
                return (ia === -1 ? 999 : ia) - (ib === -1 ? 999 : ib);
            });

            selectedAppIndex = 0;
            // Same second-MRU rule for layer-2 drill-down
            if (winMru.length >= 2) {
                var secondTarget = winMru[1];
                if (secondTarget.indexOf("0x") !== 0) secondTarget = "0x" + secondTarget;
                for (var di = 0; di < sphereModel.length; di++) {
                    var dAddr = sphereModel[di].address || "";
                    if (dAddr.indexOf("0x") !== 0) dAddr = "0x" + dAddr;
                    if (dAddr === secondTarget) {
                        selectedAppIndex = di;
                        break;
                    }
                }
            }
            projDirty = true;
            rebuildProjCache();
            centerOnApp(0);
            sphereZoom = 1.0;
        } else {
            // Layer 1 → back to previous layer
            if (savedLayer2Model.length > 0) {
                // Return to layer 2 (search results preserved)
                window.layer = 2;
                searchQuery = savedLayer2Query;
                sphereModel = savedLayer2Model;
                savedLayer2Model = [];
                savedLayer2Query = "";
                projDirty = true;
                rebuildProjCache();

                var prevIdx = -1;
                for (var i = 0; i < sphereModel.length; i++) {
                    if (sphereModel[i].appId === window.drilledAppId) { prevIdx = i; break; }
                }
                selectedAppIndex = prevIdx >= 0 ? prevIdx : 0;
                centerOnApp(selectedAppIndex);
                window.drilledAppId = "";
                sphereZoom = cfg.search?.layer2Zoom ?? 1.5;
            } else {
                // Normal layer 1 → layer 0
                window.layer = 0;
                var raw = buildLayer0();
                sphereModel = raw.length === 0
                    ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
                    : sortByMru(raw);
                projDirty = true;
                rebuildProjCache();

                var prevIdx = -1;
                for (var i = 0; i < sphereModel.length; i++) {
                    if (sphereModel[i].appId === window.drilledAppId) { prevIdx = i; break; }
                }
                selectedAppIndex = prevIdx >= 0 ? prevIdx : 0;
                centerOnApp(selectedAppIndex);
                window.drilledAppId = "";
            }
        }
    }

    function commitSelection() {
        // Guard: sphere not ready yet (buildLayer0 hasn't returned data)
        if (!window.overlayActive) return;
        if (closeSequence.running) return;

        var node = sphereModel[selectedAppIndex];
        if (!node || node.isPlaceholder) {
            window.overlayActive = false;
            closeSequence.start();
            // Reset Hyprland submap so next ALT+Tab works
            Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("reset"))']);
            return;
        }

        if (node.isWhitelistPlaceholder) {
            window.focusable = false;
            window.overlayActive = false;

            // Keep fade animation — overlay can't steal focus since
            // focusable is false. Dispatch by class to ensure focus.
            if (cfg.fullscreenOnActivate) {
                // Launch via exec_cmd with a PID-tracked maximize rule
                Quickshell.execDetached(["hyprctl", "dispatch",
                    'hl.dsp.exec_cmd("' + node.exec + '", { maximize = true })']);
                // Focus by class after a small delay
                Quickshell.execDetached(["bash", "-c",
                    'sleep 0.5 && hyprctl dispatch hl.dsp.focus({window="class:' + node.appId + '"}) &']);
            } else {
                // Original shell chain: launch + focus
                var sh = node.exec + ' & sleep 0.3 && hyprctl dispatch ' + "'hl.dsp.focus({window=\\\"class:" + node.appId + "\\\"})'" + ' &';
                Quickshell.execDetached(["bash", "-c", sh]);
            }
            closeSequence.start();
            // Reset Hyprland submap so next ALT+Tab works
            Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("reset"))']);
            return;
        }

        var addr;
        if (window.layer === 0 || (window.layer === 2 && !node.isWindowNode)) {
            // Spawn override: if a window was just spawned for this app,
            // focus it directly. appWindowMru is updated immediately by
            // the openwindow handler, unlike node.windows in the sphere
            // model which depends on async toplevel refresh.
            if (window._pendingSpawnAppId === node.appId) {
                var spawnMru = appWindowMru[node.appId] || [];
                addr = spawnMru.length >= 1 ? spawnMru[0] : "";
            } else if (node.appId === window._preSelectedAppId) {
                // Target the previous window (globalWindowMru[1])
                addr = window.globalWindowMru.length >= 2
                    ? window.globalWindowMru[1]
                    : (node.windows[0] ? node.windows[0].address : "");
            } else {
                // Layer 0 or layer 2 app node: focus MRU-most window
                var winMru = appWindowMru[node.appId] || [];
                var best = null;
                for (var m = 0; m < winMru.length; m++) {
                    for (var w = 0; w < node.windows.length; w++) {
                        if (node.windows[w].address === winMru[m]) {
                            best = winMru[m];
                            break;
                        }
                    }
                    if (best) break;
                }
                addr = best || node.windows[0].address;
            }
        } else {
            // Layer 1 or layer 2 window node: focus specific address
            addr = node.address;
        }

        // Update globalWindowMru synchronously before hiding overlay —
        // onActiveToplevelChanged may not fire until overlay reopens.
        if (addr) {
            var commitNorm = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
            var commitFiltered = [];
            for (var ci = 0; ci < globalWindowMru.length; ci++) {
                if (globalWindowMru[ci] !== commitNorm) commitFiltered.push(globalWindowMru[ci]);
            }
            globalWindowMru = [commitNorm].concat(commitFiltered);
        }
        window.overlayActive = false;
        window.visible = false;

        // Focus the target window using Lua dispatch format.
        var prefix = addr.indexOf("0x") === 0 ? "" : "0x";
        Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.focus({window="address:' + prefix + addr + '"})']);

        // Fullscreen on activate (if configured)
        if (cfg.fullscreenOnActivate) {
            Quickshell.execDetached(["hyprctl", "dispatch",
                'hl.dsp.window.fullscreen({ mode = "maximized", action = "set", window = "address:' + prefix + addr + '" })']);
        }

        // Reset Hyprland submap so normal bindings work again
        // NOTE: must use hyprctl eval, not dispatch (submap is Lua-only)
        Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("reset"))']);
    }

    // ── Phase 5: Ctrl+C close ──
    function closeSelection() {
        if (closeSequence.running) return;

        var node = sphereModel[selectedAppIndex];
        if (!node || node.isPlaceholder) return;

        // If the node is still a whitelisted placeholder but windows have
        // been spawned (e.g. Ctrl+Enter before the sphere rebuilds), close
        // via appWindowMru which is updated immediately by openwindow.
        if (node.isWhitelistPlaceholder) {
            var spawnAddrs = appWindowMru[node.appId] || [];
            for (var si = 0; si < spawnAddrs.length; si++) {
                var sa = spawnAddrs[si];
                var sp = sa.indexOf("0x") === 0 ? "" : "0x";
                Quickshell.execDetached(["hyprctl", "dispatch",
                    'hl.dsp.window.close({window="address:' + sp + sa + '"})']);
            }
            return;
        }

        if (window.layer === 0 || (window.layer === 2 && !node.isWindowNode)) {
            // Layer 0 or layer 2 app node: close all windows of this app
            for (var w = 0; w < node.windows.length; w++) {
                var a = node.windows[w].address;
                var p = a.indexOf("0x") === 0 ? "" : "0x";
                Quickshell.execDetached(["hyprctl", "dispatch",
                    'hl.dsp.window.close({window="address:' + p + a + '"})']);
            }
        } else {
            // Layer 1 or layer 2 window node: close specific window
            var p = node.address.indexOf("0x") === 0 ? "" : "0x";
            Quickshell.execDetached(["hyprctl", "dispatch",
                'hl.dsp.window.close({window="address:' + p + node.address + '"})']);
        }
    }

    function openNewWindow() {
        if (closeSequence.running) return;

        var node = sphereModel[selectedAppIndex];
        if (!node || node.isPlaceholder) return;

        // Resolve appId — for window nodes, use the parent appId
        var appId = node.appId;
        if (!appId) return;

        // Build exec command: whitelist exec → execMap → appId fallback
        var execCmd = node.exec || window.resolveExec(appId) || appId;

        // If fullscreen on activate is on, use exec_cmd with a PID-tracked
        // maximize rule (same as the whitelist commit path). Some apps like
        // Blender override our one-shot openwindow dispatch during init, but
        // the compositor-enforced rule persists through their entire startup.
        // Otherwise, launch via bash -c (original behaviour).
        if (cfg.fullscreenOnActivate) {
            Quickshell.execDetached(["hyprctl", "dispatch",
                'hl.dsp.exec_cmd("' + execCmd + '", { maximize = true })']);
        } else {
            Quickshell.execDetached(["bash", "-c", execCmd]);
        }

        // Launch tracking for auto-selection
        window._pendingSpawnAppId = appId;
    }

    function rebuildToLayer0(raw) {
        if (raw.length === 0) {
            sphereModel = [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }];
            selectedAppIndex = 0;
            return;
        }
        sphereModel = sortByMru(raw);
        selectedAppIndex = Math.min(sphereModel.length - 1, selectedAppIndex);
        centerOnApp(selectedAppIndex);
    }

    // ── Phase 2: MRU tracking ──
    Connections {
        target: Hyprland
        function onActiveToplevelChanged() {
            var t = Hyprland.activeToplevel;
            if (!t) return;
            var appId = (t.wayland && t.wayland.appId) ? t.wayland.appId : "unknown";

            var addr = t.address || "";
            if (addr.indexOf("0x") !== 0) addr = "0x" + addr;

            // When a real appId resolves, clean up any stale "unknown" entry
            if (appId !== "unknown") {
                var cleaned = [];
                for (var ci = 0; ci < appMru.length; ci++) {
                    if (appMru[ci] !== "unknown") cleaned.push(appMru[ci]);
                }
                appMru = cleaned;
            }

            // Move app to front of app-level MRU
            var filtered = [];
            for (var i = 0; i < appMru.length; i++) {
                if (appMru[i] !== appId) filtered.push(appMru[i]);
            }
            appMru = [appId].concat(filtered);

            // Move window to front of this app's per-app window MRU
            var winList = appWindowMru[appId] || [];
            var winFiltered = [];
            for (var j = 0; j < winList.length; j++) {
                if (winList[j] !== addr) winFiltered.push(winList[j]);
            }
            appWindowMru[appId] = [addr].concat(winFiltered);

            // Maintain global window MRU on every focus change
            if (addr) {
                var gwFiltered = [];
                for (var gi = 0; gi < globalWindowMru.length; gi++) {
                    if (globalWindowMru[gi] !== addr) gwFiltered.push(globalWindowMru[gi]);
                }
                globalWindowMru = [addr].concat(gwFiltered);
            }


        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            // Handle openwindow: track new windows in MRU immediately
            if (event.name === "openwindow") {
                var parts = (event.data || "").split(",");
                if (parts.length >= 3) {
                    var addr = parts[0];
                    if (addr.indexOf("0x") !== 0) addr = "0x" + addr;
                    var appId = parts[2];
                    if (!appId) return;
                    // Track per-app opening order
                    if (!window._appOpeningOrder[appId]) window._appOpeningOrder[appId] = [];
                    if (window._appOpeningOrder[appId].indexOf(addr) === -1) {
                        window._appOpeningOrder[appId].push(addr);
                    }
                    var filtered = [];
                    for (var i = 0; i < appMru.length; i++) {
                        if (appMru[i] !== appId) filtered.push(appMru[i]);
                    }
                    appMru = [appId].concat(filtered);
                    appWindowMru[appId] = [addr].concat(appWindowMru[appId] || []);

                    // If this is a spawned window, save info for auto-selection
                    if (window._pendingSpawnAppId === appId) {
                        window._pendingSpawnAddr = addr;
                        if (window.visible) {
                            // Cycle visibility to force the compositor to
                            // re-grant keyboard focus to the overlay layer.
                            // Some apps (Blender) steal focus on open.
                            window.visible = false;
                            Qt.callLater(function() {
                                window.visible = true;
                                // onVisibleChanged → forceActiveFocus
                            });
                            window.scheduleRebuild();
                        }
                    }


                }
                return;
            }

            if (event.name !== "closewindow") return;
            var addr = event.data || "";
            if (!addr) return;
            if (addr.indexOf("0x") !== 0) addr = "0x" + addr;

            // Remove from per-app opening order (compacts that app's indices)
            for (var aid in window._appOpeningOrder) {
                var list = window._appOpeningOrder[aid];
                var oi = list.indexOf(addr);
                if (oi !== -1) {
                    list.splice(oi, 1);
                    if (list.length === 0) delete window._appOpeningOrder[aid];
                    break;
                }
            }

            for (var appId in appWindowMru) {
                var list = appWindowMru[appId];
                var idx = -1;
                for (var k = 0; k < list.length; k++) {
                    if (list[k] === addr) { idx = k; break; }
                }
                if (idx !== -1) {
                    var newList = [];
                    for (var k2 = 0; k2 < list.length; k2++) {
                        if (k2 !== idx) newList.push(list[k2]);
                    }
                    if (newList.length === 0) {
                        delete appWindowMru[appId];
                        var newMru = [];
                        for (var m = 0; m < appMru.length; m++) {
                            if (appMru[m] !== appId) newMru.push(appMru[m]);
                        }
                        appMru = newMru;
                    } else {
                        appWindowMru[appId] = newList;
                    }
                    break;
                }
            }

            // Remove closed address from global window MRU
            var gwNew = [];
            for (var gi = 0; gi < globalWindowMru.length; gi++) {
                if (globalWindowMru[gi] !== addr) gwNew.push(globalWindowMru[gi]);
            }
            globalWindowMru = gwNew;

            if (window.visible) {
                // Unmap and remap overlay to force compositor to re-grant
                // keyboard focus to the exclusive layer surface.
                window.visible = false;
                Qt.callLater(function() {
                    window.visible = true;
                    // onVisibleChanged fires → forceActiveFocus
                });
                scheduleRebuild();
            }
        }
    }

    function advance(dir) {
        if (sphereModel.length === 0) return;
        if (sphereModel[0].isPlaceholder) return;
        var count = sphereModel.length;
        var next = selectedAppIndex + dir;
        if (next < 0) {
            next = cfg.cycling?.wrapAround !== false ? count - 1 : 0;
        } else if (next >= count) {
            next = cfg.cycling?.wrapAround !== false ? 0 : count - 1;
        }
        selectedAppIndex = next;
        centerOnApp(next);
    }

    property bool overlayActive: false

    IpcHandler {
        target: "hyprsphere"
        function toggle(): void {
            if (window.overlayActive) {
                // Hyprland consumed the Tab key (ALT+Tab bind), so focusGrabber
                // never saw it. Advance via IPC instead.
                window.advance(1);
                return;
            }
            console.log("[hyprsphere] IPC toggle() called");
            openSwitcher();
        }

        function commit(): void {
            if (window.overlayActive) {
                window.commitSelection();
            }
        }

        function cancel(): void {
            if (window.overlayActive) {
                window.cancelSwitch();
            }
        }
    }

    Component.onCompleted: {
        configReader.running = true;
        iconReader.running = true;
        Hyprland.refreshToplevels();
        // After toplevels populate, assign static indices to existing windows
        Qt.callLater(function() { window.initWindowIndices(); });
    }

    // Responsive scaler — scales values proportionally to window width
    function s(val) {
        let ref = cfg.scaler?.referenceWidth ?? 1920;
        let minR = cfg.scaler?.minRatio ?? 0.5;
        let maxR = cfg.scaler?.maxRatio ?? 2.0;
        let scale = Math.max(minR, Math.min(maxR, window.width / ref));
        let res = val * scale;
        return res > 0 ? res : val;
    }

    // Colors from hyprsphere.json (Catppuccin Mocha fallback defaults)
    readonly property color base:      cfg.colors?.base      ?? "#1e1e2e"
    readonly property color mantle:    cfg.colors?.mantle    ?? "#181825"
    readonly property color crust:     cfg.colors?.crust     ?? "#11111b"
    readonly property color surface0:  cfg.colors?.surface0  ?? "#313244"
    readonly property color surface1:  cfg.colors?.surface1  ?? "#45475a"
    readonly property color surface2:  cfg.colors?.surface2  ?? "#585b70"
    readonly property color text:      cfg.colors?.text      ?? "#cdd6f4"
    readonly property color subtext0:  cfg.colors?.subtext0  ?? "#a6adc8"
    readonly property color blue:      cfg.colors?.blue      ?? "#89b4fa"
    readonly property color mauve:     cfg.colors?.mauve     ?? "#cba6f7"
    readonly property color teal:      cfg.colors?.teal      ?? "#94e2d5"
    readonly property color overlay0:  cfg.colors?.overlay0  ?? "#6c7086"
    readonly property color peach:     cfg.colors?.peach     ?? "#fab387"
    readonly property color yellow:    cfg.colors?.yellow    ?? "#f9e2af"
    readonly property color sapphire:  cfg.colors?.sapphire  ?? "#74c7ec"

    // Design sizes from config
    readonly property real _s2:   window.s(cfg.sizes?.s2   ?? 2)
    readonly property real _s3:   window.s(cfg.sizes?.s3   ?? 3)
    readonly property real _s4:   window.s(cfg.sizes?.s4   ?? 4)
    readonly property real _s5:   window.s(cfg.sizes?.s5   ?? 5)
    readonly property real _s8:   window.s(cfg.sizes?.s8   ?? 8)
    readonly property real _s9:   window.s(cfg.sizes?.s9   ?? 9)
    readonly property real _s10:  window.s(cfg.sizes?.s10  ?? 10)
    readonly property real _s11:  window.s(cfg.sizes?.s11  ?? 11)
    readonly property real _s12:  window.s(cfg.sizes?.s12  ?? 12)
    readonly property real _s15:  window.s(cfg.sizes?.s15  ?? 15)
    readonly property real _s16:  window.s(cfg.sizes?.s16  ?? 16)
    readonly property real _s18:  window.s(cfg.sizes?.s18  ?? 18)
    readonly property real _s20:  window.s(cfg.sizes?.s20  ?? 20)
    readonly property real _s28:  window.s(cfg.sizes?.s28  ?? 28)
    readonly property real _s40:  window.s(cfg.sizes?.s40  ?? 40)
    readonly property real _s50:  window.s(cfg.sizes?.s50  ?? 50)
    readonly property real _s55:  window.s(cfg.sizes?.s55  ?? 55)
    readonly property real _s56:  window.s(cfg.sizes?.s56  ?? 56)
    readonly property real _s63:  window.s(cfg.sizes?.s63  ?? 63)
    readonly property real _s74:  window.s(cfg.sizes?.s74  ?? 74)
    readonly property real _s104: window.s(cfg.sizes?.s104 ?? 104)

    // Satellite dimensions from config
    readonly property real _sat_hullW:     window.s(cfg.satellite?.hullWidth     ?? 216)
    readonly property real _sat_hullH:     window.s(cfg.satellite?.hullHeight    ?? 148)
    readonly property real _sat_panelW:    window.s(cfg.satellite?.panelWidth    ?? 64)
    readonly property real _sat_panelH:    window.s(cfg.satellite?.panelHeight   ?? 51)
    readonly property real _sat_strutW:    window.s(cfg.satellite?.strutWidth    ?? 10)
    readonly property real _sat_strutH:    window.s(cfg.satellite?.strutHeight   ?? 4)
    readonly property real _sat_antennaH:  window.s(cfg.satellite?.antennaHeight ?? 16)
    readonly property real _sat_thrusterH: window.s(cfg.satellite?.thrusterHeight ?? 11)
    readonly property real _sat_radius12:  window.s(cfg.satellite?.radius12      ?? 10)
    readonly property real _sat_radius8:   window.s(cfg.satellite?.radius8       ?? 7)
    readonly property real _sat_radius4:   window.s(cfg.satellite?.radius4       ?? 3)
    readonly property real _sat_antBall:   window.s(cfg.satellite?.antBall       ?? 6)
    readonly property real _sat_antStick:  window.s(cfg.satellite?.antStick      ?? 2)
    readonly property real _sat_antOffX:   window.s(cfg.satellite?.antOffX       ?? 14)
    readonly property real _sat_screenM:   window.s(cfg.satellite?.screenMargin  ?? 8)
    readonly property real _sat_innerM:    window.s(cfg.satellite?.innerMargin   ?? 10)
    readonly property real _sat_iconSz:    window.s(cfg.satellite?.iconSize      ?? 40)
    readonly property real _sat_fontSize:  window.s(cfg.satellite?.fontSize      ?? 10)
    readonly property real _sat_thrBase:   window.s(cfg.satellite?.thrusterBase  ?? 16)
    readonly property real _sat_spacing:   window.s(cfg.satellite?.spacing       ?? 5)

    property real baseSphereRadius: window.s(cfg.sphere?.baseRadius ?? 368)
    property real sphereZoom: cfg.sphere?.initialZoom ?? 1.0
    Behavior on sphereZoom { NumberAnimation { duration: cfg.sphere?.zoomDurationMs ?? 400; easing.type: Easing.OutCubic } }

    property real sphereRadius: baseSphereRadius

    property real rotX: cfg.sphere?.initialRotX ?? -0.2
    property real rotY: cfg.sphere?.initialRotY ?? 0

    NumberAnimation { id: searchRotXAnim; target: window; property: "rotX"; duration: cfg.animations?.searchRotateDurationMs ?? 700; easing.type: Easing.OutCubic }
    NumberAnimation { id: searchRotYAnim; target: window; property: "rotY"; duration: cfg.animations?.searchRotateDurationMs ?? 700; easing.type: Easing.OutCubic }

    property var projCache: []
    property bool projDirty: true

    function rebuildProjCache() {
        if (!projDirty) return;
        projDirty = false;

        // Auto-adjust sphere radius based on node count
        var auto = cfg.sphere?.autoRadius;
        if (auto && auto.enabled !== false) {
            var minR = auto.minRadius ?? 160;
            var maxN = auto.maxNodeCount ?? 20;
            var t = Math.min(1, sphereModel.length / maxN);
            window.sphereRadius = window.s(minR + (baseSphereRadius - minR) * t);
        } else {
            window.sphereRadius = baseSphereRadius;
        }

        let phi   = Math.PI * (3 - Math.sqrt(5));
        let total = sphereModel.length;
        let rx    = window.rotX;
        let ry    = window.rotY;
        let cosRx = Math.cos(rx), sinRx = Math.sin(rx);
        let cosRy = Math.cos(ry), sinRy = Math.sin(ry);

        let arr = new Array(total);
        for (let i = 0; i < total; i++) {
            let b_y      = 1.0 - (i / Math.max(1, total - 1)) * 2.0;
            let b_radius = Math.sqrt(1.0 - b_y * b_y);
            let b_theta  = phi * i;
            let b_x      = Math.cos(b_theta) * b_radius;
            let b_z      = Math.sin(b_theta) * b_radius;

            // Rotate X
            let y1 = b_y * cosRx - b_z * sinRx;
            let z1 = b_y * sinRx + b_z * cosRx;

            // Rotate Y
            let x2 = b_x * cosRy + z1 * sinRy;
            let z2 = -b_x * sinRy + z1 * cosRy;

            arr[i] = { x: x2, y: y1, z: z2 };
        }
        window.projCache = arr;
    }

    // Invalidate cache whenever rotation changes
    onRotXChanged: { projDirty = true; rebuildProjCache(); }
    onRotYChanged: { projDirty = true; rebuildProjCache(); }

    // Keep the original project3D for centerOnApp (called rarely)
    function project3D(bx, by, bz) {
        let rx = window.rotX;
        let ry = window.rotY;
        let y1 = by * Math.cos(rx) - bz * Math.sin(rx);
        let z1 = by * Math.sin(rx) + bz * Math.cos(rx);
        let x2 = bx * Math.cos(ry) + z1 * Math.sin(ry);
        let z2 = -bx * Math.sin(ry) + z1 * Math.cos(ry);
        return { x: x2, y: y1, z: z2 };
    }

    Timer {
        interval: cfg.animations?.sphereAutoRotateIntervalMs ?? 16
        running: !sceneMouse.pressed && !searchRotXAnim.running && !searchRotYAnim.running
        repeat: true
        onTriggered: window.rotY -= cfg.animations?.sphereRotateSpeed ?? 0.002
    }

    function centerOnApp(index) {
        if (index < 0 || index >= sphereModel.length) return;

        let phi    = Math.PI * (3 - Math.sqrt(5));
        let total  = sphereModel.length;
        let b_y    = 1.0 - (index / Math.max(1, total - 1)) * 2.0;
        let b_radius = Math.sqrt(1.0 - b_y * b_y);
        let b_theta  = phi * index;
        let b_x    = Math.cos(b_theta) * b_radius;
        let b_z    = Math.sin(b_theta) * b_radius;

        let targetRotX = Math.atan2(b_y, b_z);
        let z1         = Math.sqrt(b_y * b_y + b_z * b_z);
        let targetRotY = Math.atan2(-b_x, z1);

        let currentRotYMod = ((window.rotY % (Math.PI * 2)) + Math.PI * 2) % (Math.PI * 2);
        let targetRotYNorm = ((targetRotY % (Math.PI * 2)) + Math.PI * 2) % (Math.PI * 2);

        let diff = targetRotYNorm - currentRotYMod;
        if (diff >  Math.PI) diff -= Math.PI * 2;
        if (diff < -Math.PI) diff += Math.PI * 2;

        searchRotXAnim.to = targetRotX;
        searchRotYAnim.to = window.rotY + diff;

        searchRotXAnim.restart();
        searchRotYAnim.restart();
    }

    property real introPhase: 0.0
    NumberAnimation on introPhase {
        id: introPhaseAnim
        from: 0.0; to: 1.0; duration: cfg.animations?.entranceFadeDurationMs ?? 800; easing.type: Easing.OutExpo; running: true
    }

    Connections {
        target: window
        function onVisibleChanged() {
            if (window.visible) {
                window.sphereZoom   = 1.0;
                introPhaseAnim.restart();
                focusGrabber.forceActiveFocus();
            }
        }
    }



    SequentialAnimation {
        id: closeSequence
        NumberAnimation { target: window; property: "introPhase"; to: 0.0; duration: cfg.animations?.exitFadeDurationMs ?? 400; easing.type: Easing.OutQuint }
        ScriptAction { script: { window.overlayActive = false; window.visible = false; } }
    }

    function cancelSwitch() {
        if (closeSequence.running) return;  // guard against double-fire
        window.layer = 0;
        window.drilledAppId = "";
        window.searchQuery = "";
        window.savedLayer2Model = [];
        window.savedLayer2Query = "";
        window.overlayActive = false;
        closeSequence.start();
        // Reset Hyprland submap so normal bindings work again
        // NOTE: must use hyprctl eval, not dispatch (submap is Lua-only)
        Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("reset"))']);
    }

    // ── Phase 3: key handling ──
    Item {
        id: focusGrabber
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                if (event.modifiers & Qt.ShiftModifier || event.key === Qt.Key_Backtab) window.advance(-1);
                else window.advance(1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Semicolon) {
                window.drillDown();
                event.accepted = true;
            } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
                window.closeSelection();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) {
                window.openNewWindow();
                event.accepted = true;
            } else if (event.key === Qt.Key_Backspace && !event.isAutoRepeat) {
                if (window.searchQuery.length > 0) {
                    window._handleSearchInput(window.searchQuery.slice(0, -1));
                }
                event.accepted = true;
            } else if (!event.isAutoRepeat && event.text.length > 0
                       && event.text.match(/[a-zA-Z0-9 _.-]/)) {
                window._handleSearchInput(window.searchQuery + event.text);
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                window.cancelSwitch();
                event.accepted = true;
            }
        }

        Keys.onReleased: (event) => {
            if (event.key === Qt.Key_Alt) {
                window.commitSelection();
                event.accepted = true;
            }
        }
    }

    Item {
        id: scene3D
        anchors.fill: parent
        opacity: window.introPhase
        scale: 0.8 + (0.2 * window.introPhase)

        MouseArea {
            id: sceneMouse
            anchors.fill: parent
            property real lastX: 0
            property real lastY: 0
            onPressed: mouse => {
                searchRotXAnim.stop();
                searchRotYAnim.stop();
                lastX = mouse.x;
                lastY = mouse.y;
            }
            onPositionChanged: mouse => {
                if (!pressed) return;
                let dx = mouse.x - lastX;
                let dy = mouse.y - lastY;
                let dragSens = cfg.mouse?.dragSensitivity ?? 0.005;
                window.rotY += dx * dragSens;
                let newRotX = window.rotX - dy * dragSens;
                window.rotX = newRotX;
                lastX = mouse.x;
                lastY = mouse.y;
            }
        }

        Item {
            id: origin
            anchors.centerIn: parent
            width:  window.baseSphereRadius * 2
            height: window.baseSphereRadius * 2

            Repeater {
                id: appRepeater
                model: sphereModel

                delegate: Item {
                    id: appNode

                    // Read pre-computed projection from the cache array.
                    // The cache is a plain JS array; QML won't auto-bind to its
                    // contents, so we use a property alias that updates whenever
                    // projCache itself is reassigned (the whole array is replaced
                    // on every cache rebuild, which triggers change notification).
                    property var proj: (window.projCache && window.projCache.length > index)
                                       ? window.projCache[index]
                                       : { x: 0, y: 0, z: 0 }

                    property real zoomFactor: 1.0 + (window.sphereZoom - 1.0) * 0.45

                    x: (origin.width  / 2) + (proj.x * window.sphereRadius * zoomFactor) - width  / 2
                    y: (origin.height / 2) + (proj.y * window.sphereRadius * zoomFactor) - height / 2

                    z: Math.round(proj.z * 1000)

                    property bool isSelected: index === window.selectedAppIndex
                    property real _hz: Math.max(0.0, Math.min(1.0, proj.z * (cfg.cardTilt?.depthOpacityMultiplier ?? 4.0)))
                    opacity: proj.z > 0.0 ? _hz : 0.0
                    Behavior on opacity { NumberAnimation { duration: cfg.animations?.cardFadeDurationMs ?? 200; easing.type: Easing.OutCubic } }

                    visible: opacity > 0.01

                    property real _baseScale: (cfg.cardTilt?.baseScaleAtEdge ?? 0.78) + (Math.max(0.0, proj.z) * (cfg.cardTilt?.scaleIncreaseTowardCenter ?? 0.22))
                    scale: isSelected ? 1.0 : (_baseScale * ((nodeMa.containsMouse && !isSelected) ? (cfg.cardTilt?.hoverScaleMultiplier ?? 1.12) : 1.0))
                    Behavior on scale { NumberAnimation { duration: cfg.animations?.cardScaleDurationMs ?? 200; easing.type: Easing.OutCubic } }

                    // Tilt angles — used only for the non-selected card face
                    property real _xNorm: proj.x / (window.sphereRadius / window.s(cfg.sphere?.normalizationConstant ?? 310.5))
                    property real _yNorm: proj.y / (window.sphereRadius / window.s(cfg.sphere?.normalizationConstant ?? 310.5))

                    transform: [
                        Rotation {
                            axis { x: 1; y: 0; z: 0 }
                            angle: appNode.isSelected ? 0 : -appNode._yNorm * (cfg.cardTilt?.maxAngleX ?? 45)
                            origin.x: appNode.width  / 2
                            origin.y: appNode.height / 2
                        },
                        Rotation {
                            axis { x: 0; y: 1; z: 0 }
                            angle: appNode.isSelected ? 0 : appNode._xNorm * (cfg.cardTilt?.maxAngleY ?? 35)
                            origin.x: appNode.width  / 2
                            origin.y: appNode.height / 2
                        }
                    ]

                    width:  window._s74
                    height: window._s104

                    // ── Normal app card (hidden while selected) ───────────────
                    Rectangle {
                        anchors.fill: parent
                        radius: window._s12
                        color:  "transparent"
                        border.color: nodeMa.containsMouse && !appNode.isSelected ? (cfg.appCard?.cardBorderColor ?? "transparent") : "transparent"
                        border.width: window._s2
                        Behavior on color { ColorAnimation { duration: cfg.animations?.cardFadeDurationMs ?? 200 } }

                        // Completely skip rendering when satellite is shown
                        visible: !appNode.isSelected

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: window._s5
                            spacing: window._s5

                            Image {
                                id: cardIcon
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth:  window.s(cfg.appCard?.nonSelectedIconSize ?? 55)
                                Layout.preferredHeight: window.s(cfg.appCard?.nonSelectedIconSize ?? 55)
                                source: {
                                    var ic = window.sphereModel[index] ? window.sphereModel[index].icon : "";
                                    return ic ? (ic.startsWith("/") ? "file://" + ic : "image://icon/" + ic) : "image://icon/application-x-executable";
                                }
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                cache: true
                                opacity: {
                                    var n = window.sphereModel[index];
                                    if (!n) return 1.0;
                                    if (n.isWindowNode) return cfg.appCard?.windowIconOpacity ?? 0.75;
                                    return cfg.appCard?.appIconOpacity ?? 1.0;
                                }
                                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                            }

                            Rectangle {
                                id: labelBg
                                Layout.fillWidth: true
                                implicitHeight: labelText.implicitHeight + window._s4
                                radius: window._s4
                                visible: {
                                    if (!window.showNonSelectedLabel()) return false;
                                    var n = window.sphereModel[index];
                                    return n && n.isWindowNode;
                                }
                                color: Qt.rgba(
                                    (parseInt((cfg.appCard?.labelBgColor ?? "#ff4400").substring(1,3),16)/255),
                                    (parseInt((cfg.appCard?.labelBgColor ?? "#ff4400").substring(3,5),16)/255),
                                    (parseInt((cfg.appCard?.labelBgColor ?? "#ff4400").substring(5,7),16)/255),
                                    cfg.appCard?.labelBgOpacity ?? 0.5)

                                Text {
                                    id: labelText
                                    anchors.fill: parent
                                    anchors.leftMargin:  window._s3
                                    anchors.rightMargin: window._s3
                                    text: {
                                        var n = window.sphereModel[index];
                                        if (!n) return "";
                                        return n.title ? n.title : (n.label || "");
                                    }
                                    font.family: "JetBrains Mono"
                                    font.pixelSize: window.s(14)
                                    font.weight: Font.DemiBold
                                    color: cfg.appCard?.labelTextColor ?? "#2b2b2b"
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment:   Text.AlignVCenter
                                    elide: Text.ElideRight
                                }
                            }

                        }

                        // Window count / index badge (over icon)
                        Item {
                            id: windowBadge
                            anchors.horizontalCenter: cardIcon.horizontalCenter
                            anchors.verticalCenter: cardIcon.verticalCenter
                            anchors.horizontalCenterOffset: window.s(cfg.appCard?.windowCountBadge?.offsetX ?? -60)
                            anchors.verticalCenterOffset: window.s(cfg.appCard?.windowCountBadge?.offsetY ?? 0)
                            width: badgeLabel.width + window.s(cfg.appCard?.windowCountBadge?.padding ?? 14)
                            height: badgeLabel.height + window.s(cfg.appCard?.windowCountBadge?.padding ?? 14)
                            visible: {
                                if (cfg.appCard?.windowCountBadge?.nonSelected === false) return false;
                                var n = window.sphereModel[index];
                                if (!n || n.isPlaceholder || n.isWhitelistPlaceholder) return false;
                                if (n.isWindowNode) return true;
                                return (n.windowCount || 0) >= 1;
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: height / 2
                                color: {
                                    var n = window.sphereModel[index];
                                    return n && n.isWindowNode
                                        ? (cfg.appCard?.windowCountBadge?.windowBgColor ?? "#ff4400")
                                        : (cfg.appCard?.windowCountBadge?.bgColor ?? "#2b2b2b");
                                }
                                opacity: {
                                    var n = window.sphereModel[index];
                                    return n && n.isWindowNode
                                        ? (cfg.appCard?.windowCountBadge?.windowBgOpacity ?? 0.5)
                                        : (cfg.appCard?.windowCountBadge?.bgOpacity ?? 0.5);
                                }
                            }

                            Text {
                                id: badgeLabel
                                anchors.centerIn: parent
                                text: {
                                    var n = window.sphereModel[index];
                                    if (!n) return "";
                                    if (n.isWindowNode) {
                                        var a = n.address || "";
                                        if (a.indexOf("0x") !== 0) a = "0x" + a;
                                        var appList = window._appOpeningOrder[n.appId];
                                        if (!appList) return "";
                                        var oi = appList.indexOf(a);
                                        return String(oi >= 0 ? oi + 1 : "");
                                    }
                                    return "+" + String(n.windowCount || 0);
                                }
                                font.family: "JetBrains Mono"
                                font.pixelSize: window.s(cfg.appCard?.windowCountBadge?.fontSize ?? 18)
                                font.weight: Font.Bold
                                color: {
                                    var n = window.sphereModel[index];
                                    return n && n.isWindowNode
                                        ? (cfg.appCard?.windowCountBadge?.windowColor ?? "#2b2b2b")
                                        : (cfg.appCard?.windowCountBadge?.color ?? "#ff4400");
                                }
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }

                    Loader {
                        id: satLoader
                        anchors.centerIn: parent
                        active: appNode.isSelected
                        opacity: appNode.isSelected ? 1.0 : 0.0
                        scale:   appNode.isSelected ? (cfg.animations?.satelliteTargetScale ?? 1.5) : (cfg.animations?.satelliteInitialScale ?? 0.4)

                        Behavior on opacity { NumberAnimation { duration: cfg.animations?.satelliteFadeDurationMs ?? 400; easing.type: Easing.OutCubic } }
                        Behavior on scale   { NumberAnimation { duration: cfg.animations?.satelliteScaleDurationMs ?? 450; easing.type: Easing.OutBack  } }

                        sourceComponent: Component {
                            Item {
                                width:  window._sat_hullW
                                height: window._sat_hullH

                                Image {
                                    id: satIcon
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.top: parent.top
                                    anchors.topMargin: window._s5
                                    width:  window._sat_iconSz
                                    height: window._sat_iconSz
                                    source: {
                                        var node = window.sphereModel[window.selectedAppIndex];
                                        var ic = node ? node.icon : "";
                                        ic ? (ic.startsWith("/") ? "file://" + ic : "image://icon/" + ic) : "image://icon/application-x-executable";
                                    }
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true
                                    opacity: {
                                        var n = window.sphereModel[window.selectedAppIndex];
                                        if (!n) return 1.0;
                                        if (n.isWindowNode) return cfg.appCard?.windowIconOpacity ?? 0.75;
                                        return cfg.appCard?.appIconOpacity ?? 1.0;
                                    }
                                    Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                                }

                                Rectangle {
                                    id: satLabelBg
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.top: satIcon.bottom
                                    anchors.topMargin: window._s5
                                    width: parent.width * 0.8
                                    implicitHeight: satLabelText.implicitHeight + window._s4
                                    radius: window._s4
                                    visible: {
                                        var n = window.sphereModel[window.selectedAppIndex];
                                        if (!n) return false;
                                        if (n.isWindowNode) return true;
                                        return cfg.appCard?.satelliteAppLabel === true;
                                    }
                                    color: Qt.rgba(
                                        (parseInt((cfg.appCard?.labelBgColor ?? "#ff4400").substring(1,3),16)/255),
                                        (parseInt((cfg.appCard?.labelBgColor ?? "#ff4400").substring(3,5),16)/255),
                                        (parseInt((cfg.appCard?.labelBgColor ?? "#ff4400").substring(5,7),16)/255),
                                        cfg.appCard?.labelBgOpacity ?? 0.5)

                                    Text {
                                        id: satLabelText
                                        anchors.fill: parent
                                        anchors.leftMargin: window._s3
                                        anchors.rightMargin: window._s3
                                        text: {
                                            var n = window.sphereModel[window.selectedAppIndex];
                                            if (!n) return "";
                                            return n && n.title ? n.title : (n && n.label || "");
                                        }
                                        font.family: "JetBrains Mono"
                                        font.pixelSize: window._sat_fontSize
                                        font.weight: Font.Bold
                                        color: cfg.appCard?.labelTextColor ?? "#2b2b2b"
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        elide: Text.ElideRight
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                // Window count / index badge (over icon)
                                Item {
                                    id: satBadge
                                    anchors.horizontalCenter: satIcon.horizontalCenter
                                    anchors.verticalCenter: satIcon.verticalCenter
                                    anchors.horizontalCenterOffset: window.s(cfg.appCard?.windowCountBadge?.offsetX ?? -60)
                                    anchors.verticalCenterOffset: window.s(cfg.appCard?.windowCountBadge?.offsetY ?? 0)
                                    width: satBadgeLabel.width + window.s(cfg.appCard?.windowCountBadge?.padding ?? 14)
                                    height: satBadgeLabel.height + window.s(cfg.appCard?.windowCountBadge?.padding ?? 14)
                                    visible: {
                                        if (cfg.appCard?.windowCountBadge?.satellite === false) return false;
                                        var n = window.sphereModel[window.selectedAppIndex];
                                        if (!n || n.isPlaceholder || n.isWhitelistPlaceholder) return false;
                                        if (n.isWindowNode) return true;
                                        return (n.windowCount || 0) >= 1;
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: height / 2
                                        color: {
                                            var n = window.sphereModel[window.selectedAppIndex];
                                            return n && n.isWindowNode
                                                ? (cfg.appCard?.windowCountBadge?.windowBgColor ?? "#ff4400")
                                                : (cfg.appCard?.windowCountBadge?.bgColor ?? "#2b2b2b");
                                        }
                                        opacity: {
                                            var n = window.sphereModel[window.selectedAppIndex];
                                            return n && n.isWindowNode
                                                ? (cfg.appCard?.windowCountBadge?.windowBgOpacity ?? 0.5)
                                                : (cfg.appCard?.windowCountBadge?.bgOpacity ?? 0.5);
                                        }
                                    }

                                    Text {
                                        id: satBadgeLabel
                                        anchors.centerIn: parent
                                        text: {
                                            var n = window.sphereModel[window.selectedAppIndex];
                                            if (!n) return "";
                                            if (n.isWindowNode) {
                                                var a = n.address || "";
                                                if (a.indexOf("0x") !== 0) a = "0x" + a;
                                                var appList = window._appOpeningOrder[n.appId];
                                                if (!appList) return "";
                                                var oi = appList.indexOf(a);
                                                return String(oi >= 0 ? oi + 1 : "");
                                            }
                                            return "+" + String(n.windowCount || 0);
                                        }
                                        font.family: "JetBrains Mono"
                                        font.pixelSize: window.s(cfg.appCard?.windowCountBadge?.fontSize ?? 18)
                                        font.weight: Font.Bold
                                        color: {
                                            var n = window.sphereModel[window.selectedAppIndex];
                                            return n && n.isWindowNode
                                                ? (cfg.appCard?.windowCountBadge?.windowColor ?? "#2b2b2b")
                                                : (cfg.appCard?.windowCountBadge?.color ?? "#ff4400");
                                        }
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: nodeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            window.selectedAppIndex = index;
                            window.centerOnApp(index);
                        }

                        onDoubleClicked: {
                            window.selectedAppIndex = index;
                            window.commitSelection();
                        }
                    }
                }
            }
        }
    }

    // ── Phase 6: Search bar ──
    Rectangle {
        id: searchContainer
        visible: window.overlayActive
        width:  window.s(cfg.searchBar?.width ?? 560)
        height: window.s(cfg.searchBar?.height ?? 56)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: window.s(cfg.searchBar?.bottomMargin ?? 63)
        anchors.horizontalCenter: parent.horizontalCenter
        radius: window.s(cfg.searchBar?.borderRadius ?? 28)
        color: Qt.rgba(
            (parseInt((cfg.searchBar?.backgroundColor ?? "#ff4400").substring(1,3),16)/255),
            (parseInt((cfg.searchBar?.backgroundColor ?? "#ff4400").substring(3,5),16)/255),
            (parseInt((cfg.searchBar?.backgroundColor ?? "#ff4400").substring(5,7),16)/255),
            cfg.searchBar?.backgroundOpacity ?? 0.3)
        border.color: window.searchQuery.length > 0
            ? (cfg.searchBar?.activeBorderColor ?? "#ff4400")
            : (cfg.searchBar?.borderColor ?? "#2b2b2b")
        border.width: window.s(cfg.searchBar?.borderWidth ?? 1.5)
        opacity: window.introPhase
        transform: Translate { y: (1 - window.introPhase) * window._s40 }
        layer.enabled: window.introPhase > 0.01
        layer.effect: MultiEffect {
            shadowEnabled: true; shadowColor: "#000000"
            shadowOpacity: cfg.searchBar?.shadowOpacity ?? 0.4
            shadowBlur: cfg.searchBar?.shadowBlur ?? 1.5
            shadowVerticalOffset: window._s4
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: window._s20
            anchors.rightMargin: window._s20
            spacing: window._s12

            TextField {
                id: searchInput
                Layout.fillWidth: true
                Layout.fillHeight: true
                background: Item {}
                color: cfg.searchBar?.textColor ?? "#ff4400"
                font.family: "JetBrains Mono"
                font.pixelSize: window._s15
                font.weight: Font.Medium
                selectByMouse: true
                selectionColor: Qt.rgba(
                    (parseInt((cfg.searchBar?.textColor ?? "#ff4400").substring(1,3),16)/255),
                    (parseInt((cfg.searchBar?.textColor ?? "#ff4400").substring(3,5),16)/255),
                    (parseInt((cfg.searchBar?.textColor ?? "#ff4400").substring(5,7),16)/255),
                    0.3)
                readOnly: true
                text: window.searchQuery
                placeholderText: cfg.searchBar?.placeholderText ?? "Search apps and windows..."
                placeholderTextColor: cfg.searchBar?.placeholderColor
                    ? Qt.rgba(
                        (parseInt(cfg.searchBar.placeholderColor.substring(1,3),16)/255),
                        (parseInt(cfg.searchBar.placeholderColor.substring(3,5),16)/255),
                        (parseInt(cfg.searchBar.placeholderColor.substring(5,7),16)/255),
                        1.0)
                    : window.overlay0
                verticalAlignment: TextInput.AlignVCenter
            }
        }
    }
}
