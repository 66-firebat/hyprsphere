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
import "binds.js" as Binds
import "effects.js" as Effects

// ══════════════════════════════════════════════════════════════════════════════
// hyprsphere — 3D window switcher for Hyprland/Quickshell
// Architecture: 2D focus tracking (dimension 1 = apps, dimension 2 = windows)
// ══════════════════════════════════════════════════════════════════════════════

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

    // ══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ══════════════════════════════════════════════════════════════════════════

    property string configPath: String(Qt.resolvedUrl("hyprsphere.json")).replace(/^file:\/\//, "")
    property var cfg: ({})

    Process {
        id: configReader
        command: ["cat", window.configPath]
        stdout: StdioCollector {
            onStreamFinished: {
                var txt = this.text.trim();
                if (txt.length > 0) {
                    try { window.cfg = JSON.parse(txt); }
                    catch(e) { console.log("[hyprsphere] Config parse error:", String(e)); }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DEBUG LOGGING (configurable via hyprsphere.json "debug": true)
    // ══════════════════════════════════════════════════════════════════════════

    function log(msg) {
        if (cfg.debug === true)
            console.log("[hyprsphere] " + msg);
    }

    function logObj(label, obj) {
        if (cfg.debug === true) {
            try { console.log("[hyprsphere] " + label + " " + JSON.stringify(obj)); }
            catch(e) { console.log("[hyprsphere] " + label + " [non-serializable]"); }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CENTRALIZED HYPCTL DISPATCH (eliminates ad-hoc prefix handling)
    // ══════════════════════════════════════════════════════════════════════════

    function _prefix(addr) { return addr.indexOf("0x") === 0 ? "" : "0x"; }

    function dispatchFocus(addr) {
        if (!addr) { log("dispatchFocus: no addr"); return; }
        var p = _prefix(addr);
        Quickshell.execDetached(["hyprctl", "dispatch",
            'hl.dsp.focus({window="address:' + p + addr + '"})']);
    }

    function dispatchFullscreen(addr) {
        if (!addr) return;
        var p = _prefix(addr);
        Quickshell.execDetached(["hyprctl", "dispatch",
            'hl.dsp.window.fullscreen({ mode = "maximized", action = "set", window = "address:' + p + addr + '" })']);
    }

    function dispatchClose(addr) {
        if (!addr) return;
        var p = _prefix(addr);
        Quickshell.execDetached(["hyprctl", "dispatch",
            'hl.dsp.window.close({window="address:' + p + addr + '"})']);
    }

    function dispatchExec(cmd) {
        Quickshell.execDetached(["hyprctl", "dispatch",
            'hl.dsp.exec_cmd("' + cmd + '", { maximize = true })']);
    }

    function dispatchFocusByClass(appId) {
        Quickshell.execDetached(["bash", "-c",
            'sleep 0.5 && hyprctl dispatch hl.dsp.focus({window="class:' + appId + '"}) &']);
    }

    function dispatchSubmap(name) {
        Quickshell.execDetached(["hyprctl", "eval",
            'hl.dispatch(hl.dsp.submap("' + name + '"))']);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 2D FOCUS TRACKING — Single Source of Truth
    //
    // focusHistory[] — ordered list of { address, appId, title }
    //   Each entry is one open window, sorted MRU-first.
    //   Mutations: moveToFront (focus/commit), add (open), remove (close).
    //
    // Dimension 1 — appOrder() → [appId, ...]
    //   Unique appIds in first-appearance order (for layer 0 navigation).
    //
    // Dimension 2 — windowsForApp(appId) → [address, ...]
    //   Filtered addresses for a specific app (for layer 1 drill-down).
    // ══════════════════════════════════════════════════════════════════════════

    property var focusHistory: []

    // --- Derivation: dimension 1 (app order) ---
    function appOrder() {
        var seen = {};
        var order = [];
        for (var i = 0; i < focusHistory.length; i++) {
            var appId = focusHistory[i].appId;
            if (!seen[appId]) {
                seen[appId] = true;
                order.push(appId);
            }
        }
        return order;
    }

    // --- Derivation: dimension 2 (window order per app) ---
    function windowsForApp(appId) {
        var result = [];
        for (var i = 0; i < focusHistory.length; i++) {
            if (focusHistory[i].appId === appId)
                result.push(focusHistory[i].address);
        }
        return result;
    }

    // --- Mutation: move to front (on focus or commit) ---
    function moveToFront(address) {
        if (!address) return;
        var normAddr = address.indexOf("0x") === 0 ? address : "0x" + address;
        for (var i = 0; i < focusHistory.length; i++) {
            if (focusHistory[i].address === normAddr) {
                var entry = focusHistory[i];
                focusHistory.splice(i, 1);
                focusHistory.unshift(entry);
                log("moveToFront: " + normAddr.substring(normAddr.length - 6) + " app=" + entry.appId + " order=[" + focusHistory.map(function(e){return e.appId.substring(0,8) + "-" + e.address.substring(e.address.length-4);}).join(",") + "]");
                return;
            }
        }
        log("moveToFront: address " + normAddr.substring(normAddr.length - 6) + " NOT FOUND in focusHistory");
    }

    // --- Mutation: add new entry (on window open) ---
    function addToFront(address, appId, title) {
        if (!address || !appId) return;
        var normAddr = address.indexOf("0x") === 0 ? address : "0x" + address;
        // Remove existing entry if present (dedup safeguard)
        for (var i = 0; i < focusHistory.length; i++) {
            if (focusHistory[i].address === normAddr) {
                focusHistory.splice(i, 1);
                break;
            }
        }
        focusHistory.unshift({ address: normAddr, appId: appId, title: title || "" });
        log("addToFront: " + normAddr.substring(normAddr.length - 6) + " app=" + appId);
    }

    // --- Mutation: remove entry (on window close) ---
    function removeAddress(address) {
        if (!address) return;
        var normAddr = address.indexOf("0x") === 0 ? address : "0x" + address;
        for (var i = 0; i < focusHistory.length; i++) {
            if (focusHistory[i].address === normAddr) {
                var appId = focusHistory[i].appId;
                focusHistory.splice(i, 1);
                log("removeAddress: " + normAddr.substring(normAddr.length - 6) + " app=" + appId);
                return;
            }
        }
        log("removeAddress: " + normAddr.substring(normAddr.length - 6) + " NOT FOUND in focusHistory");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TITLE RESOLUTION — look up window title from Hyprland.toplevels
    // ══════════════════════════════════════════════════════════════════════════

    function _resolveTitle(address) {
        if (!address) return "";
        var normAddr = address.indexOf("0x") === 0 ? address : "0x" + address;
        var tls = Hyprland.toplevels;
        var arr = (tls && tls.values) || [];
        for (var i = 0; i < arr.length; i++) {
            var t = arr[i];
            if (t && t.title && window.normalizeAddress(t.address) === normAddr)
                return t.title;
        }
        return "";
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ADDRESS NORMALIZATION
    // ══════════════════════════════════════════════════════════════════════════

    function normalizeAddress(addr) {
        if (!addr) return "";
        if (addr.indexOf("0x") === 0) return addr;
        var num = Number(addr);
        if (!isNaN(num)) return "0x" + num.toString(16);
        return "0x" + addr;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ICON & NAME RESOLUTION
    // ══════════════════════════════════════════════════════════════════════════

    property var iconMap: ({})
    property var nameMap: ({})
    property var execMap: ({})

    function resolveIcon(appId) {
        return (appId && iconMap[appId]) ? iconMap[appId] : "application-x-executable";
    }

    function resolveName(appId) {
        return (appId && nameMap[appId]) ? nameMap[appId] : (appId || "");
    }

    function resolveExec(appId) {
        return (appId && execMap[appId]) ? execMap[appId] : null;
    }

    function showNonSelectedLabel() {
        var layers = cfg.appCard?.nonSelectedLayerLabels;
        if (!layers) return true;
        return layers["layer_" + window.layer] !== false;
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
                log("Icon reader finished, got " + txt.length + " chars");
                if (txt.length > 0) window.parseIcons(txt);
            }
        }
    }

    function parseIcons(text) {
        var map = {}, nmap = {}, emap = {};
        var blocks = text.split('---');
        for (var b = 0; b < blocks.length; b++) {
            var lines = blocks[b].trim().split('\n');
            var id = null, icon = null, wmClass = null, name = null, exec = null;
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i].trim();
                if (line.startsWith('[ID]')) id = line.substring(4).trim();
                else if (line.startsWith('Name=')) name = line.substring(5).trim();
                else if (line.startsWith('Icon=')) icon = line.substring(5).trim();
                else if (line.startsWith('StartupWMClass=')) wmClass = line.substring(15).trim();
                else if (line.startsWith('Exec=') && exec === null) {
                    exec = line.substring(5).trim();
                    exec = exec.replace(/%[uUfFick]/g, '').trim();
                    exec = exec.replace(/%%/g, '%');
                }
            }
            if (id && icon) { map[id] = icon; if (wmClass) map[wmClass] = icon; }
            if (id && name) { nmap[id] = name; if (wmClass) nmap[wmClass] = name; }
            if (id && exec) { emap[id] = exec; if (wmClass) emap[wmClass] = exec; }
        }
        iconMap = map; nameMap = nmap; execMap = emap;
        log("Icon map: " + Object.keys(map).length + " Name map: " + Object.keys(nmap).length + " Exec map: " + Object.keys(emap).length);
        if (window.visible) scheduleRebuild();
    }

    function initWindowIndices() {
        var tls = Hyprland.toplevels;
        var arr = (tls && tls.values) || [];
        if (arr.length === 0) {
            Qt.callLater(function() { window.initWindowIndices(); });
            return;
        }
        var initList = [];
        for (var i = 0; i < arr.length; i++) {
            var t = arr[i];
            if (!t) continue;
            var ws = t.workspace;
            if (ws && String(ws.name || "").startsWith("special:")) continue;
            var wl = t.wayland;
            var appId = (wl && wl.appId) ? wl.appId : "unknown";
            var addr = window.normalizeAddress(t.address);
            // Only add if not already in focusHistory (safeguard)
            var found = false;
            for (var j = 0; j < focusHistory.length; j++) {
                if (focusHistory[j].address === addr) { found = true; break; }
            }
            if (!found) {
                initList.push({ address: addr, appId: appId, title: t.title });
            }
        }
        // Prepend in reverse order so first window (index 0) ends up first
        for (var k = initList.length - 1; k >= 0; k--) {
            focusHistory.unshift(initList[k]);
        }
        log("initWindowIndices: focusHistory now has " + focusHistory.length + " entries");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SPHERE BUILDING
    // ══════════════════════════════════════════════════════════════════════════

    property var sphereModel: []
    property var rebuildScheduled: false
    property int selectedAppIndex: -1
    property int layer: 0           // 0=apps, 1=windows, 2=search
    property string drilledAppId: ""

    function buildLayer0() {
        var result = [];
        var whitelist = cfg.whitelist || [];
        var seenCounts = {};

        // One node per entry in focusHistory
        for (var i = 0; i < focusHistory.length; i++) {
            var entry = focusHistory[i];
            var appId = entry.appId;
            if (!seenCounts[appId]) seenCounts[appId] = 0;
            seenCounts[appId]++;

            var title = entry.title || window._resolveTitle(entry.address) || appId;
            result.push({
                address: entry.address,
                appId: appId,
                title: title,
                label: window.resolveName(appId),
                icon: window.resolveIcon(appId),
                isWindowNode: true,
                badgeIndex: seenCounts[appId],
                windows: [],
                windowCount: 0,
            });
        }

        // Append whitelisted placeholders (not already in focusHistory)
        for (var w = 0; w < whitelist.length; w++) {
            var entry = whitelist[w];
            var alreadyPresent = false;
            for (var a = 0; a < focusHistory.length; a++) {
                if (focusHistory[a].appId === entry.appId) { alreadyPresent = true; break; }
            }
            if (!alreadyPresent) {
                result.push({
                    appId: entry.appId, label: entry.label, icon: entry.icon,
                    exec: entry.exec, windows: [], windowCount: 0,
                    isWhitelistPlaceholder: true,
                });
            }
        }

        log("buildLayer0: " + result.length + " flat nodes, first=" + (result.length > 0 ? result[0].appId + "#" + result[0].badgeIndex : "empty"));
        return result;
    }

    function buildLayer1(appId) {
        var winAddrs = windowsForApp(appId);
        var result = [];
        for (var i = 0; i < winAddrs.length; i++) {
            var title = "";
            for (var k = 0; k < focusHistory.length; k++) {
                if (focusHistory[k].address === winAddrs[i]) {
                    title = focusHistory[k].title;
                    break;
                }
            }
            if (!title) title = window._resolveTitle(winAddrs[i]);
            result.push({
                address: winAddrs[i], title: title,
                icon: window.resolveIcon(appId), label: window.resolveName(appId),
                appId: appId, isWindowNode: true,
            });
        }
        log("buildLayer1(" + appId + "): " + result.length + " windows");
        return result;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SEARCH (Layer 2) — Fuse.js fuzzy search
    // Layer 2 shows only individual windows + whitelisted placeholders.
    // No app groups in search results.
    // ══════════════════════════════════════════════════════════════════════════

    property string searchQuery: ""
    property var fuseIndex: null
    property var searchDatabase: []
    property var searchTimer: null

    function buildSearchDatabase() {
        var db = [];
        // Individual windows
        for (var i = 0; i < focusHistory.length; i++) {
            var entry = focusHistory[i];
            var sTitle = entry.title || window._resolveTitle(entry.address) || entry.appId;
            db.push({
                type: "window", appId: entry.appId,
                label: window.resolveName(entry.appId),
                icon: window.resolveIcon(entry.appId),
                address: entry.address, title: sTitle,
            });
        }
        // Whitelisted placeholders not in focusHistory
        var whitelist = cfg.whitelist || [];
        for (var e = 0; e < whitelist.length; e++) {
            var entry2 = whitelist[e];
            var found = false;
            for (var j = 0; j < focusHistory.length; j++) {
                if (focusHistory[j].appId === entry2.appId) { found = true; break; }
            }
            if (!found) {
                db.push({
                    type: "whitelisted-app", appId: entry2.appId,
                    label: entry2.label, icon: entry2.icon,
                    exec: entry2.exec, windows: [], windowCount: 0,
                });
            }
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
                ignoreLocation: cfg.search?.ignoreLocation ?? true,
                includeScore: true,
                shouldSort: true
            });
        } catch(e) {
            log("Fuse init error: " + String(e));
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
        if (!fuseIndex) { initFuseIndex(); if (!fuseIndex) return; }

        var results = fuseIndex.search(searchQuery);
        var maxResults = cfg.search?.maxResults ?? 30;
        var top = results.slice(0, maxResults);

        var layer2Model = [];

        for (var i = 0; i < top.length; i++) {
            var item = top[i].item;
            if (item.type === "window") {
                layer2Model.push({
                    appId: item.appId, label: item.label, icon: item.icon,
                    address: item.address, title: item.title,
                    isWindowNode: true, isSearchResult: true,
                });
            } else if (item.type === "whitelisted-app") {
                layer2Model.push({
                    appId: item.appId, label: item.label, icon: item.icon,
                    exec: item.exec, windows: [], windowCount: 0,
                    isWhitelistPlaceholder: true, isSearchResult: true,
                });
            }
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
        log("_executeSearch: " + layer2Model.length + " results for \"" + searchQuery + "\"");
    }

    function cancelSearch() {
        searchQuery = "";
        window.layer = 0;
        var raw = buildLayer0();
        sphereModel = raw.length === 0
            ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
            : raw;
        sphereZoom = 1.0;
        projDirty = true;
        rebuildProjCache();
        if (sphereModel.length > 0 && !sphereModel[0].isPlaceholder) {
            selectedAppIndex = 0;
            centerOnApp(0);
        }
        log("cancelSearch: returned to layer 0");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // OVERLAY STATE
    // ══════════════════════════════════════════════════════════════════════════

    property bool overlayActive: false
    property bool _togglingVisibility: false
    property bool _mruFrozen: false
    property string _commitAddr: ""
    property string _pendingSpawnAppId: ""
    property string _pendingSpawnAddr: ""

    // ══════════════════════════════════════════════════════════════════════════
    // OPEN / REBUILD
    // ══════════════════════════════════════════════════════════════════════════

    function openSwitcher() {
        log("openSwitcher()");
        window.layer = 0;
        window.drilledAppId = "";
        window.searchQuery = "";
        window.focusable = true;
        window.overlayActive = true;
        window._mruFrozen = true;
        window._commitAddr = "";
        window.log("openSwitcher: _mruFrozen=true");
        window._pendingSpawnAppId = "";
        window._pendingSpawnAddr = "";

        dispatchSubmap("hyprsphere");
        Hyprland.refreshToplevels();
        Qt.callLater(function() { finishOpenSwitcher(); });
    }

    function finishOpenSwitcher() {
        if (!window.overlayActive) return;

        var iconReady = Object.keys(iconMap).length > 0;
        if (!iconReady) {
            Qt.callLater(function() { finishOpenSwitcher(); });
            return;
        }

        var raw = buildLayer0();
        if (raw.length === 0) {
            Qt.callLater(function() { finishOpenSwitcher(); });
            return;
        }

        sphereModel = raw;
        if (sphereModel.length > 0 && !sphereModel[0].isPlaceholder) {
            // Pre-select index 1 (previous app) if available
            selectedAppIndex = focusHistory.length >= 2 ? 1 : 0;
            if (selectedAppIndex < sphereModel.length) {
                centerOnApp(selectedAppIndex);
            }
        }

        projDirty = true;
        rebuildProjCache();
        initFuseIndex();

        window.visible = true;
        Qt.callLater(function() { scheduleRebuild(); });

        log("finishOpenSwitcher: " + sphereModel.length + " nodes, pre-selected index " + selectedAppIndex);
        startPerpetual();
    }

    function scheduleRebuild() {
        if (rebuildScheduled) return;
        rebuildScheduled = true;
        Qt.callLater(function() {
            rebuildScheduled = false;
            Hyprland.refreshToplevels();
            var raw = buildLayer0();
            rebuildToLayer(raw);
            // Auto-select spawned window after rebuild
            if (window._pendingSpawnAppId) {
                log("spawnAutoSelect: pendingApp=" + window._pendingSpawnAppId + " pendingAddr=" + (window._pendingSpawnAddr ? window._pendingSpawnAddr.substring(window._pendingSpawnAddr.length-6) : "none") + " layer=" + window.layer + " sphereLen=" + window.sphereModel.length);
                var _found = false;
                for (var _si = 0; _si < window.sphereModel.length; _si++) {
                    var _n = window.sphereModel[_si];
                    if (_n.isPlaceholder || _n.isWhitelistPlaceholder) continue;
                    if (window._pendingSpawnAddr) {
                        if (_n.isWindowNode && _n.address === window._pendingSpawnAddr) {
                            log("spawnAutoSelect: FOUND by address at idx=" + _si);
                            window.selectedAppIndex = _si;
                            window.centerOnApp(_si);
                            _found = true;
                            break;
                        } else if (!_n.isWindowNode && _n.appId === window._pendingSpawnAppId) {
                            log("spawnAutoSelect: FOUND appNode by appId at idx=" + _si);
                            window.selectedAppIndex = _si;
                            window.centerOnApp(_si);
                            _found = true;
                            break;
                        }
                    } else if (_n.appId === window._pendingSpawnAppId) {
                        log("spawnAutoSelect: FOUND by appId at idx=" + _si);
                        window.selectedAppIndex = _si;
                        window.centerOnApp(_si);
                        _found = true;
                        break;
                    }
                }
                if (!_found) log("spawnAutoSelect: NOT FOUND in sphereModel");
                if (window.sphereModel.length > 0) {
                    var _s0 = window.sphereModel[0];
                    log("spawnAutoSelect: sphere[0] app=" + _s0.appId + " addr=" + (_s0.address ? _s0.address.substring(_s0.address.length-6) : "none") + " isWin=" + (_s0.isWindowNode ? "Y" : "N"));
                }
                window._pendingSpawnAddr = "";
                window._pendingSpawnAppId = "";
            }
            // Force QML to re-evaluate the sphere model binding
            window.projDirty = true;
            window.rebuildProjCache();
            projDirty = true;
            rebuildProjCache();
            focusGrabber.forceActiveFocus();
        });
    }

    function rebuildToLayer(raw) {
        if (window.layer === 2 && window.searchQuery !== "") {
            initFuseIndex();
            _executeSearch();
            return;
        }

        if (window.layer === 1 && window.drilledAppId) {
            var appExists = false;
            for (var i = 0; i < raw.length; i++) {
                if (raw[i].appId === window.drilledAppId && !raw[i].isWhitelistPlaceholder) {
                    appExists = true;
                    break;
                }
            }
            if (appExists) {
                var prevAddress = sphereModel[selectedAppIndex]
                    ? sphereModel[selectedAppIndex].address : null;
                sphereModel = buildLayer1(window.drilledAppId);
                var restoredIdx = -1;
                for (var si = 0; si < sphereModel.length; si++) {
                    if (sphereModel[si].address === prevAddress) { restoredIdx = si; break; }
                }
                selectedAppIndex = restoredIdx >= 0 ? restoredIdx : 0;
                centerOnApp(selectedAppIndex);
            } else {
                window.layer = 0;
                window.drilledAppId = "";
                sphereModel = raw.length === 0
                    ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
                    : raw;
                selectedAppIndex = 0;
                centerOnApp(0);
            }
        } else {
            sphereModel = raw.length === 0
                ? [{ label: "No windows", icon: "", appId: "", windows: [], isPlaceholder: true }]
                : raw;
            selectedAppIndex = Math.min(sphereModel.length - 1, selectedAppIndex);
            centerOnApp(selectedAppIndex);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EVENT HANDLERS
    // ══════════════════════════════════════════════════════════════════════════

    Connections {
        target: Hyprland
        function onActiveToplevelChanged() {
            var t = Hyprland.activeToplevel;
            if (!t) return;
            var appId = (t.wayland && t.wayland.appId) ? t.wayland.appId : "unknown";
            var addr = window.normalizeAddress(t.address);
            if (window._mruFrozen && addr !== window._commitAddr) {
                log("activeToplevelChanged: BLOCKED addr=" + addr.substring(addr.length-6) + " app=" + appId + " commitAddr=" + (window._commitAddr ? window._commitAddr.substring(window._commitAddr.length-6) : "none"));
                return;
            }
            // Committed window's focus arrived — unfreeze and clear guard
            if (window._mruFrozen && addr === window._commitAddr) {
                window._mruFrozen = false;
                window._commitAddr = "";
                log("activeToplevelChanged: UNFROZEN (commit arrived) addr=" + addr.substring(addr.length-6) + " app=" + appId);
            }
            var extra = window._mruFrozen ? " (ALLOWED commitAddr)" : "";
            log("activeToplevelChanged:" + extra + " addr=" + addr.substring(addr.length-6) + " app=" + appId);
            window.moveToFront(addr);
            log("focusHistory[0..3]: " + window.focusHistory.slice(0,4).map(function(e){return e.appId.substring(0,10) + "-" + e.address.substring(e.address.length-4)}).join(", "));
        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "openwindow") {
                var parts = (event.data || "").split(",");
                if (parts.length >= 3) {
                    var addr = parts[0];
                    if (addr.indexOf("0x") !== 0) addr = "0x" + addr;
                    var appId = parts[2];
                    if (!appId) return;
                    window.addToFront(addr, appId, "");
                    log("openwindow: addr=" + addr.substring(addr.length-6) + " app=" + appId);

                    // Spawn tracking
                    if (window._pendingSpawnAppId === appId) {
                        window._pendingSpawnAddr = addr;
                        if (window.visible) {
                            window.visible = false;
                            Qt.callLater(function() { window.visible = true; });
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
            log("closewindow: addr=" + addr.substring(addr.length-6));
            window.removeAddress(addr);

            // Remove from globalWindowMru equivalent (already handled by removeAddress)

            if (window.visible) {
                window.visible = false;
                Qt.callLater(function() { window.visible = true; });
                scheduleRebuild();
            }
        }
    }

    Connections {
        target: window
        function onVisibleChanged() {
            if (window.visible) {
                window.sphereZoom = 1.0;
                introPhaseAnim.restart();
                focusGrabber.forceActiveFocus();
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // IPC HANDLERS
    // ══════════════════════════════════════════════════════════════════════════

    IpcHandler {
        target: "hyprsphere"
        function toggle(): void {
            if (window.overlayActive && !window._togglingVisibility) {
                window.advance(1);
                return;
            }
            log("IPC toggle()");
            openSwitcher();
        }

        function commit(): void {
            if (window.overlayActive) window.commitSelection();
        }

        function cancel(): void {
            if (window.overlayActive) window.cancelSwitch();
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // INIT
    // ══════════════════════════════════════════════════════════════════════════

    Component.onCompleted: {
        configReader.running = true;
        iconReader.running = true;
        Hyprland.refreshToplevels();
        Qt.callLater(function() { window.initWindowIndices(); });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // RESPONSIVE SCALER
    // ══════════════════════════════════════════════════════════════════════════

    function s(val) {
        let ref = cfg.scaler?.referenceWidth ?? 1920;
        let minR = cfg.scaler?.minRatio ?? 0.5;
        let maxR = cfg.scaler?.maxRatio ?? 2.0;
        let scale = Math.max(minR, Math.min(maxR, window.width / ref));
        let res = val * scale;
        return res > 0 ? res : val;
    }

    // Colors from hyprsphere.json (Catppuccin Mocha fallback)
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
    // Perpetual effects offset — added to sphereRadius while overlay is active
    property real _perpOffset: 0
    property real _perpStartTime: 0
    property bool _perpEnabled: false
    Timer {
        id: perpetualTimer
        interval: 16  // ~60fps
        repeat: true
        running: false
        onTriggered: {
            if (!window._perpEnabled) { running = false; return; }
            var pe = window.cfg.sphere?.perpetualEffects;
            if (!pe || !pe.heartbeat || !pe.heartbeat.enabled) { running = false; return; }
            var hb = pe.heartbeat;
            var layerKey = "layer_" + window.layer;
            var lc = hb.layers ? hb.layers[layerKey] : null;
            var freqMult = (lc && lc.frequency !== undefined) ? lc.frequency : 1.0;
            var amp = (lc && lc.amplitude !== undefined) ? lc.amplitude : (hb.amplitude || 8);
            var bpm = (hb.bpm || 72) * freqMult;
            var beatMs = 60000 / bpm;
            var elapsed = Date.now() - window._perpStartTime;
            var t = (elapsed % beatMs) / beatMs;
            window._perpOffset = Effects.heartbeatAtPhase(t) * amp;
            window.sphereRadius = window.baseSphereRadius + window._perpOffset;
        }
    }

    function startPerpetual() {
        var pe = window.cfg.sphere?.perpetualEffects;
        if (!pe || !pe.heartbeat || !pe.heartbeat.enabled) return;
        window._perpStartTime = Date.now();
        window._perpOffset = 0;
        window._perpEnabled = true;
        perpetualTimer.start();
    }

    function stopPerpetual() {
        window._perpEnabled = false;
        perpetualTimer.running = false;
        window._perpOffset = 0;
        window.sphereRadius = window.baseSphereRadius;
    }

    property real rotX: cfg.sphere?.initialRotX ?? -0.2
    property real rotY: cfg.sphere?.initialRotY ?? 0

    NumberAnimation { id: searchRotXAnim; target: window; property: "rotX"; duration: cfg.animations?.searchRotateDurationMs ?? 700; easing.type: Easing.OutCubic }
    NumberAnimation { id: searchRotYAnim; target: window; property: "rotY"; duration: cfg.animations?.searchRotateDurationMs ?? 700; easing.type: Easing.OutCubic }

    property var projCache: []
    property bool projDirty: true

    function rebuildProjCache() {
        if (!projDirty) return;
        projDirty = false;

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

            let y1 = b_y * cosRx - b_z * sinRx;
            let z1 = b_y * sinRx + b_z * cosRx;
            let x2 = b_x * cosRy + z1 * sinRy;
            let z2 = -b_x * sinRy + z1 * cosRy;

            arr[i] = { x: x2, y: y1, z: z2 };
        }
        window.projCache = arr;
    }

    onRotXChanged: { projDirty = true; rebuildProjCache(); }
    onRotYChanged: { projDirty = true; rebuildProjCache(); }

    function project3D(bx, by, bz) {
        let rx = window.rotX, ry = window.rotY;
        let y1 = by * Math.cos(rx) - bz * Math.sin(rx);
        let z1 = by * Math.sin(rx) + bz * Math.cos(rx);
        let x2 = bx * Math.cos(ry) + z1 * Math.sin(ry);
        let z2 = -bx * Math.sin(ry) + z1 * Math.cos(ry);
        return { x: x2, y: y1, z: z2 };
    }

    onOverlayActiveChanged: {
        if (!window.overlayActive) {
            Effects.resetAnimation(searchRotXAnim);
            Effects.resetAnimation(searchRotYAnim);
        }
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
        Effects.setAnimation(searchRotXAnim, cfg.sphere?.transitionEffects);
        Effects.setAnimation(searchRotYAnim, cfg.sphere?.transitionEffects);
        searchRotXAnim.restart();
        searchRotYAnim.restart();
    }

    property real introPhase: 0.0
    NumberAnimation on introPhase {
        id: introPhaseAnim
        from: 0.0; to: 1.0; duration: cfg.animations?.entranceFadeDurationMs ?? 800; easing.type: Easing.OutExpo; running: true
    }

    SequentialAnimation {
        id: closeSequence
        NumberAnimation { target: window; property: "introPhase"; to: 0.0; duration: cfg.animations?.exitFadeDurationMs ?? 400; easing.type: Easing.OutQuint }
        ScriptAction { script: { window.overlayActive = false; window.visible = false; } }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // KEY HANDLERS — Focus Grabber
    // ══════════════════════════════════════════════════════════════════════════

    Item {
        id: focusGrabber
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                var dir = (event.modifiers & Qt.ShiftModifier || event.key === Qt.Key_Backtab) ? -1 : 1;
                Binds.advance(window, dir);
                event.accepted = true;
            } else if (event.key === Qt.Key_Backslash || event.key === Qt.Key_Bar) {
                var dir = (event.key === Qt.Key_Bar || (event.modifiers & Qt.ShiftModifier)) ? -1 : 1;
                Binds.slashPreview(window, dir);
                event.accepted = true;
            } else if (event.key === Qt.Key_Semicolon) {
                Binds.drillDown(window);
                event.accepted = true;
            } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
                Binds.closeSelection(window);
                event.accepted = true;
            } else if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) {
                Binds.openNewWindow(window, closeSequence);
                event.accepted = true;
            } else if (event.key === Qt.Key_Backspace && !event.isAutoRepeat) {
                if (window.searchQuery.length > 0)
                    window._handleSearchInput(window.searchQuery.slice(0, -1));
                event.accepted = true;
            } else if (!event.isAutoRepeat && event.text.length > 0
                       && event.text.match(/[a-zA-Z0-9 _.-]/)) {
                window._handleSearchInput(window.searchQuery + event.text);
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                Binds.cancelSwitch(window, closeSequence);
                event.accepted = true;
            }
        }

        Keys.onReleased: (event) => {
            if (event.key === Qt.Key_Alt) {
                Binds.commitSelection(window, closeSequence);
                event.accepted = true;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 3D SPHERE SCENE
    // ══════════════════════════════════════════════════════════════════════════

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

                        // Window count / index badge
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
                                        if (n.badgeIndex) return String(n.badgeIndex);
                                        var winList = window.windowsForApp ? window.windowsForApp(n.appId) : [];
                                        var oi = winList.indexOf(n.address || "");
                                        return String(oi >= 0 ? oi + 1 : "");
                                    }
                                    return "";
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

                    // ── Satellite (selected card) ──────────────────────
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

                                // Badge on satellite
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
                                                if (n.badgeIndex) return String(n.badgeIndex);
                                                var winList = window.windowsForApp ? window.windowsForApp(n.appId) : [];
                                                var oi = winList.indexOf(n.address || "");
                                                return String(oi >= 0 ? oi + 1 : "");
                                            }
                                            return "";
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

    // ══════════════════════════════════════════════════════════════════════════
    // SEARCH BAR
    // ══════════════════════════════════════════════════════════════════════════

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
