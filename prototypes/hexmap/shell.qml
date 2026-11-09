// ══════════════════════════════════════════════════════════════════════════════
// hexmap — Hexagonal MRU window switcher (fresh prototype)
//
// Layered (modelled on hyprsphere shell.qml):
//   * Layer 0: one hexagon per APP GROUP (MRU-first), + whitelist placeholders.
//   * Layer 1: one hexagon per WINDOW of a drilled app (MRU-first).
//   * Layer 2: search (deferred — next step).
//   * `;` drills 0→1 and back; SUPER+Tab bubble-rotates in every layer.
//
// Sample data (contrived) — live Hyprland wiring comes later.
// ══════════════════════════════════════════════════════════════════════════════

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "lib/fuse.js" as FuseJs

PanelWindow {
    id: window
    focusable: true

    WlrLayershell.namespace: "hexmap-overlay"
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

    // ── Config ─────────────────────────────────────────────────────────────
    property string configPath: String(Qt.resolvedUrl("config.json")).replace(/^file:\/\//, "")
    property var cfg: ({"hexmap":{"hexScale":30,"rings":6,"swapMs":80},"colors":{"accent":"#ff4400","badgeBg":"#ff4400","badgeFg":"#2b2b2b"}})

    property string logPrefix: "[hexmap] "
    function log(msg) { console.log(logPrefix + msg) }

    Process {
        id: configReader
        command: ["cat", window.configPath]
        stdout: StdioCollector {
            onStreamFinished: {
                var txt = this.text.trim()
                if (txt.length > 0) {
                    try { window.cfg = JSON.parse(txt) }
                    catch(e) { window.log("config parse error: " + e) }
                }
            }
        }
    }

    // ── Hex grid geometry (flat-top) ───────────────────────────────────────
    property real hexScale: cfg.hexmap?.hexScale ?? 68
    property int  rings:     cfg.hexmap?.rings     ?? 6
    property real swapMs:    cfg.hexmap?.swapMs    ?? 80

    // ── State / layer machinery ────────────────────────────────────────────
    property bool overlayActive: false
    property int  pressCount: 0
    property real animProgress: 1.0

    // Badge metrics — responsively scaled to hexScale (≈12px font + 7px pad
    // at the default hexScale 68, matching hyprsphere's proportions).
    readonly property real _badgeFontSize: hexScale * 0.18
    readonly property real _badgePad: hexScale * 0.10

    // Curved-label metrics (proportional to the hex array size).
    // The array's outer edge (half-height, incl. icon overhang) =
    // (rings * sqrt(3) + 1) * hexScale. The top-left arc hugs just outside it.
    readonly property real _arrayOuterRadius: (rings * Math.sqrt(3) + 1) * hexScale
    readonly property real _curveRadius: _arrayOuterRadius * 1.10
    readonly property real _curveFontSize: hexScale * 0.42

    property var sphereModel: []       // current node list (per layer)
    property int layer: 0              // 0=apps, 1=windows, 2=search
    property string drilledAppId: ""   // which app is drilled into (layer 1)
    property int selectedAppIndex: 0   // MRU index currently focused (center)

    // ── Search (layer 2) state ────────────────────────────────────────────
    property string searchQuery: ""
    property var fuseIndex: null
    property var searchDatabase: []
    property var searchTimer: null

    // ── Sample data — focusHistory is the single source of truth ───────────
    // MRU-first ordered list of { address, appId, title }.
    property string iconDir: "file:///home/fireshark/nixos-dotfiles/git_repositories/assets/icon_packs/fireshark/48/apps/"

    property var appMeta: {
        var m = {}
        m["com.mitchellh.ghostty"] = { name: "Ghostty",  icon: "com.mitchellh.ghostty.svg" }
        m["firefox"]               = { name: "Firefox",  icon: "firefox.svg" }
        m["emacs"]                 = { name: "Emacs",    icon: "emacs.svg" }
        m["blender"]               = { name: "Blender",  icon: "blender.svg" }
        m["kicad"]                 = { name: "KiCad",    icon: "kicad.svg" }
        m["gimp"]                  = { name: "GIMP",     icon: "gimp.svg" }
        m["element"]               = { name: "Element",  icon: "element.svg" }
        m["anki"]                  = { name: "Anki",     icon: "anki.svg" }
        m["org.pwmt.zathura"]      = { name: "Zathura",  icon: "org.pwmt.zathura.svg" }
        m["org.telegram.desktop"]  = { name: "Telegram", icon: "org.telegram.desktop.svg" }
        m["discord"]               = { name: "Discord",  icon: "discord.svg" }
        m["org.gnome.Settings"]    = { name: "Settings", icon: "org.gnome.Settings.svg" }
        m["org.inkscape.Inkscape"] = { name: "Inkscape", icon: "org.inkscape.Inkscape.svg" }
        m["sioyek"]                = { name: "Sioyek",   icon: "sioyek-icon-linux.svg" }
        m["swappy"]                = { name: "Swappy",   icon: "swappy.svg" }
        m["org.gnome.Extensions"]  = { name: "Extensions", icon: "org.gnome.Extensions.svg" }
        m["org.gnome.Nautilus"]    = { name: "Files",    icon: "document-viewer.svg" }
        m["signal"]                = { name: "Signal",   icon: "main.svg" }
        return m
    }

    // Whitelist: dormant (launchable) apps shown as placeholders.
    property var whitelist: [
        { appId: "org.gnome.Nautilus", exec: "nautilus" },
        { appId: "signal",             exec: "signal-desktop" },
        { appId: "blender",            exec: "blender" }
    ]

    // Contrived focusHistory (MRU-first).
    property var focusHistory: [
        { address: "0x1001", appId: "firefox",               title: "GitHub — Mozilla Firefox" },
        { address: "0x1002", appId: "com.mitchellh.ghostty", title: "hx · ~/src" },
        { address: "0x1003", appId: "emacs",                 title: "scratch.org" },
        { address: "0x1004", appId: "firefox",               title: "Reddit — r/unixporn" },
        { address: "0x1005", appId: "org.telegram.desktop",  title: "Telegram" },
        { address: "0x1006", appId: "firefox",               title: "YouTube — Mozilla Firefox" },
        { address: "0x1007", appId: "emacs",                 title: "*scratch*" },
        { address: "0x1008", appId: "com.mitchellh.ghostty", title: "btop" },
        { address: "0x1009", appId: "discord",               title: "Discord" },
        { address: "0x100A", appId: "org.pwmt.zathura",      title: "paper.pdf" },
        { address: "0x100B", appId: "kicad",                 title: "pcb.kicad_pcb" },
        { address: "0x100C", appId: "gimp",                  title: "texture.xcf" },
        { address: "0x100D", appId: "element",               title: "Element" },
        { address: "0x100E", appId: "anki",                  title: "Anki" },
        { address: "0x100F", appId: "emacs",                 title: "init.el" },
        { address: "0x1010", appId: "org.inkscape.Inkscape", title: "logo.svg" },
        { address: "0x1011", appId: "sioyek",                title: "thesis.pdf" },
        { address: "0x1012", appId: "swappy",                title: "screenshot.png" },
        { address: "0x1013", appId: "org.gnome.Settings",    title: "Settings" }
    ]

    function resolveName(appId) { return appMeta[appId] ? appMeta[appId].name : appId }
    function resolveIcon(appId) { return appMeta[appId] ? appMeta[appId].icon : "main.svg" }

    // Dimension 1: unique appIds in first-appearance (MRU) order.
    function appOrder() {
        var seen = {}, order = []
        for (var i = 0; i < focusHistory.length; i++) {
            var id = focusHistory[i].appId
            if (!seen[id]) { seen[id] = true; order.push(id) }
        }
        return order
    }

    // Dimension 2: windows of one app, in MRU order.
    function windowsOf(appId) {
        var out = []
        for (var i = 0; i < focusHistory.length; i++)
            if (focusHistory[i].appId === appId)
                out.push(focusHistory[i])
        return out
    }

    // ── Layer builders ─────────────────────────────────────────────────────
    function buildLayer0() {
        var result = []
        var order = appOrder()
        for (var i = 0; i < order.length; i++) {
            var appId = order[i]
            var wins = windowsOf(appId)
            if (wins.length === 0) continue
            result.push({
                appId: appId,
                name: resolveName(appId),
                icon: resolveIcon(appId),
                address: wins[0].address,
                windows: wins,
                windowCount: wins.length,
                isAppGroup: true
            })
        }
        // Append whitelist placeholders (dormant apps not currently running).
        for (var w = 0; w < whitelist.length; w++) {
            var e = whitelist[w]
            var present = false
            for (var a = 0; a < order.length; a++)
                if (order[a] === e.appId) { present = true; break }
            if (!present) {
                result.push({
                    appId: e.appId,
                    name: resolveName(e.appId),
                    icon: resolveIcon(e.appId),
                    exec: e.exec,
                    windows: [],
                    windowCount: 0,
                    isAppGroup: true,
                    isWhitelistPlaceholder: true
                })
            }
        }
        return result
    }

    function buildLayer1(appId) {
        var wins = windowsOf(appId)
        var result = []
        for (var i = 0; i < wins.length; i++) {
            result.push({
                address: wins[i].address,
                appId: appId,
                name: resolveName(appId),
                icon: resolveIcon(appId),
                title: wins[i].title,
                windowCount: wins.length,
                windowIndex: i,       // 0 = MRU-most
                isWindowNode: true
            })
        }
        return result
    }

    // ── SEARCH (Layer 2) — Fuse.js fuzzy search ───────────────────────────
    function buildSearchDatabase() {
        var db = []
        // individual windows
        for (var i = 0; i < focusHistory.length; i++) {
            var entry = focusHistory[i]
            if (!entry.appId) continue
            db.push({
                type: "window", appId: entry.appId,
                label: resolveName(entry.appId),
                icon: resolveIcon(entry.appId),
                address: entry.address, title: entry.title
            })
        }
        // whitelisted placeholders not in focusHistory
        for (var e = 0; e < whitelist.length; e++) {
            var wlEntry = whitelist[e]
            var found = false
            for (var j = 0; j < focusHistory.length; j++) {
                if (focusHistory[j].appId === wlEntry.appId) { found = true; break }
            }
            if (!found) {
                db.push({
                    type: "whitelisted-app", appId: wlEntry.appId,
                    label: resolveName(wlEntry.appId), icon: resolveIcon(wlEntry.appId),
                    exec: wlEntry.exec, windows: [], windowCount: 0
                })
            }
        }
        return db
    }

    function initFuseIndex() {
        var db = buildSearchDatabase()
        searchDatabase = db
        try {
            fuseIndex = new FuseJs.Fuse(db, {
                keys: [
                    { name: "label", weight: 0.5 },
                    { name: "title", weight: 0.4 },
                    { name: "appId", weight: 0.1 }
                ],
                threshold: 0.4,
                minMatchCharLength: 1,
                ignoreLocation: true,
                includeScore: true,
                shouldSort: true
            })
        } catch (e) {
            log("Fuse init error: " + e)
            fuseIndex = null
        }
    }

    function _handleSearchInput(text) {
        searchQuery = text
        if (searchQuery === "" && window.layer === 2) {
            cancelSearch()
            return
        }
        if (searchTimer) searchTimer.running = false
        searchTimer = Qt.createQmlObject(
            'import QtQuick; Timer { interval: 150; running: true; repeat: false; onTriggered: window._executeSearch(); }',
            window
        )
    }

    function _executeSearch() {
        if (searchQuery === "") return
        if (!fuseIndex) { initFuseIndex(); if (!fuseIndex) return }

        var results = fuseIndex.search(searchQuery)
        var top = results.slice(0, 30)
        var layer2Model = []

        for (var i = 0; i < top.length; i++) {
            var item = top[i].item
            if (item.type === "window") {
                layer2Model.push({
                    appId: item.appId, name: item.label, icon: item.icon,
                    address: item.address, title: item.title,
                    isWindowNode: true, isSearchResult: true,
                    windowCount: 0,
                })
            } else if (item.type === "whitelisted-app") {
                layer2Model.push({
                    appId: item.appId, name: item.label, icon: item.icon,
                    exec: item.exec, windows: [], windowCount: 0,
                    isWhitelistPlaceholder: true, isSearchResult: true,
                })
            }
        }

        setLayer(layer2Model.length === 0
            ? [{ name: "No results", icon: "", appId: "", isPlaceholder: true }]
            : layer2Model, 2)
        log("_executeSearch: " + layer2Model.length + " results for \"" + searchQuery + "\"")
    }

    function cancelSearch() {
        searchQuery = ""
        var m = buildLayer0()
        setLayer(m, 0)
        log("cancelSearch: returned to layer 0")
    }

    // ── Hex grid (ordered: center, then rings clockwise from 12 o'clock) ───
    function hexCenter(q, r) {
        return { cx: 1.5 * q, cy: Math.sqrt(3) * (r + q / 2) }
    }

    function buildGrid() {
        var list = []
        for (var k = 0; k <= rings; k++) {
            var ringArr = []
            for (var q = -k; q <= k; q++)
                for (var r = -k; r <= k; r++)
                    if (Math.max(Math.abs(q), Math.abs(r), Math.abs(-q - r)) === k)
                        ringArr.push({ q: q, r: r, ring: k })
            ringArr.sort(function(a, b) {
                var aa = Math.atan2(1.5 * a.q, -(Math.sqrt(3) * (a.r + a.q / 2)))
                var ab = Math.atan2(1.5 * b.q, -(Math.sqrt(3) * (b.r + b.q / 2)))
                if (aa < 0) aa += 2 * Math.PI
                if (ab < 0) ab += 2 * Math.PI
                return aa - ab
            })
            for (var i = 0; i < ringArr.length; i++) list.push(ringArr[i])
        }
        return list
    }
    property var grid: buildGrid()

    // nodeCount = number of items in the CURRENT layer's sphereModel.
    property int nodeCount: sphereModel.length

    // slotOfItem[item] = which grid slot this sphereModel index currently owns.
    // itemAtSlot[slot] = which sphereModel index is at this slot.
    property var slotOfItem: {
        var arr = []
        for (var j = 0; j < nodeCount; j++) arr.push(j)
        return arr
    }
    property var itemAtSlot: {
        var arr = []
        var n = grid.length
        for (var i = 0; i < n; i++) arr.push(i < nodeCount ? i : -1)
        return arr
    }
    property var oldSlotOfItem: []

    function appNameFor(item) { return sphereModel[item] ? sphereModel[item].name : "" }
    function iconFor(item) { return sphereModel[item] ? sphereModel[item].icon : "main.svg" }
    function hasBadge(item) { return sphereModel[item] ? sphereModel[item].windowCount > 0 : false }

    // Curved-label (arc) geometry.
    // The focused node's name is rendered as per-character glyphs along a
    // circular arc in the array's top-left, arching upward (∩). The arc spans
    // from 9 o'clock (left, 180°) to 12 o'clock (top, 90°), centered on 45°.
    function curveLabel() { return itemAtSlot[0] !== undefined ? appNameFor(itemAtSlot[0]) : "" }
    function curveCharCount() { return curveLabel().length }

    // For a character at index i of n total, returns { x, y, angle } where
    // (x,y) is the glyph position (absolute logical px) and angle is the
    // tangent rotation (degrees) so the glyph sits on the arc.
    function curveChar(i, n) {
        var cx = Screen.width / 2
        var cy = Screen.height / 2
        var R = _curveRadius
        // Arc end angles (degrees): 180 (left) .. 90 (top).
        var startA = 180
        var endA   = 90
        var span   = startA - endA   // 90 degrees total
        // Fraction along the arc for this character, centered.
        var total = n
        var t = total === 1 ? 0.0 : (i / (total - 1))   // 0..1
        // Map t so the string is centered on the arc midpoint (45° span).
        // We want the string centered, so distribute chars across a sub-span
        // proportional to (n-1) * charAngleStep. Simpler: place char i at
        // angle = midAngle + (t - 0.5) * span.
        var angleDeg = startA - t * span
        var rad = angleDeg * Math.PI / 180
        var x = cx + R * Math.cos(rad)
        var y = cy - R * Math.sin(rad)   // screen y down
        // Tangent rotation: the glyph's baseline is tangent to the circle.
        // For arch (∩), the glyph rotates by -(angle from vertical).
        var rot = (90 - angleDeg)
        return { x: x, y: y, angle: rot }
    }
    function badgeText(item) {
        var n = sphereModel[item]
        if (!n) return ""
        // Match hyprsphere's badge format: window nodes show " N/Total ",
        // app groups show " +N " (both with padding spaces like hyprsphere's
        // " " + (idx+1) + "/" + total + " " pattern).
        if (n.isAppGroup) return " +" + n.windowCount + " "
        if (n.isWindowNode) return " " + (n.windowIndex + 1) + "/" + n.windowCount + " "
        return ""
    }

    // Screen position (absolute logical px) of a slot's center.
    function slotCenter(slot) {
        var h = grid[slot]
        if (!h) return { x: Screen.width / 2, y: Screen.height / 2 }
        var c = hexCenter(h.q, h.r)
        return { x: Screen.width / 2 + c.cx * hexScale, y: Screen.height / 2 + c.cy * hexScale }
    }

    function ringOpacity(ring) {
        if (ring === 0) return 1.0
        return Math.max(0.25, 1.0 - ring * 0.10)
    }

    // ── Swap mechanism ─────────────────────────────────────────────────────
    function rebuildSlots() {
        var arr = []
        for (var j = 0; j < nodeCount; j++) arr.push(-1)
        for (var s = 0; s < itemAtSlot.length; s++) {
            var it = itemAtSlot[s]
            if (it >= 0 && it < nodeCount) arr[it] = s
        }
        slotOfItem = arr
    }

    function resetAssignment() {
        // item i owns slot i (identity).
        var soi = [], ias = []
        for (var j = 0; j < nodeCount; j++) soi.push(j)
        for (var i = 0; i < grid.length; i++) ias.push(i < nodeCount ? i : -1)
        slotOfItem = soi
        itemAtSlot = ias
        pressCount = 0
    }

    function advanceForward() {
        if (nodeCount === 0) return
        var maxK = nodeCount - 1
        pressCount = Math.min(pressCount + 1, maxK)
        var K = pressCount
        var spine = []
        for (var s = 0; s <= K; s++) spine.push(itemAtSlot[s])
        var last = spine[K]
        for (var i = K; i > 0; i--) spine[i] = spine[i - 1]
        spine[0] = last
        for (var w = 0; w <= K; w++) itemAtSlot[w] = spine[w]
        rebuildSlots()
    }

    function advanceBackward() {
        if (pressCount === 0 || nodeCount === 0) return
        var K = pressCount
        var spine = []
        for (var s = 0; s <= K; s++) spine.push(itemAtSlot[s])
        var first = spine[0]
        for (var i = 0; i < K; i++) spine[i] = spine[i + 1]
        spine[K] = first
        for (var w = 0; w <= K; w++) itemAtSlot[w] = spine[w]
        rebuildSlots()
        pressCount = pressCount - 1
    }

    function doAdvance(dir) {
        if (!window.overlayActive) return
        if (nodeCount === 0) return
        if (dir >= 1) advanceForward()
        else advanceBackward()
        selectedAppIndex = itemAtSlot[0]     // center = focused item
        window.log("doAdvance dir=" + dir + " -> focusItem=" + window.itemAtSlot[0] + " layer=" + window.layer)
    }

    // ── Layer transition: rebuild sphereModel + reset swap ─────────────────
    function setLayer(model, newLayer) {
        sphereModel = model
        layer = newLayer
        selectedAppIndex = 0
        resetAssignment()
    }

    // Drill down from layer 0 → layer 1 (windows of the selected app).
    function drillToLayer1(appId) {
        var m = buildLayer1(appId)
        if (m.length === 0) return
        drilledAppId = appId
        setLayer(m, 1)
        log("drillToLayer1: " + appId + " -> " + m.length + " windows")
    }

    // Drill back from layer 1 → layer 0 (re-select the app we were on).
    function drillToLayer0() {
        var targetApp = drilledAppId
        drilledAppId = ""
        var m = buildLayer0()
        setLayer(m, 0)
        // re-select the app we drilled into
        for (var i = 0; i < m.length; i++) {
            if (m[i].appId === targetApp && !m[i].isWhitelistPlaceholder) {
                // put it at the center (slot 0) by swapping it to front
                var it = itemAtSlot.indexOf(i)
                if (it > 0) {
                    // simple: rotate so item i is at slot 0
                    var tmp = itemAtSlot[0]; itemAtSlot[0] = i; itemAtSlot[it] = tmp
                    rebuildSlots()
                }
                selectedAppIndex = i
                break
            }
        }
        log("drillToLayer0: back to " + sphereModel.length + " apps")
    }

    function drillDown() {
        if (layer === 0) {
            var n = sphereModel[selectedAppIndex]
            if (!n || n.isWhitelistPlaceholder) return
            drillToLayer1(n.appId)
        } else if (layer === 2) {
            // Search result drill-down (mirrors hyprsphere 2→1):
            // a search-result WINDOW drills into its app's windows (layer 1),
            // discarding the search. Whitelist placeholders pop back to layer 0.
            var s = sphereModel[selectedAppIndex]
            if (!s || s.isPlaceholder) return
            if (s.isWindowNode && !s.isWhitelistPlaceholder) {
                searchQuery = ""
                drillToLayer1(s.appId)
                log("drillDown 2→1: " + s.appId + " windows=" + sphereModel.length)
            } else {
                // whitelist placeholder → pop back to layer 0
                searchQuery = ""
                var m = buildLayer0()
                setLayer(m, 0)
                // select by appId
                for (var i = 0; i < m.length; i++) {
                    if (m[i].appId === s.appId) { selectedAppIndex = i; break }
                }
                log("drillDown 2→0: " + s.appId)
            }
        } else if (layer === 1) {
            drillToLayer0()
        }
    }

    // ── Open / Close ───────────────────────────────────────────────────────
    property real fadeProgress: 0.0
    Behavior on fadeProgress { NumberAnimation { duration: 200; easing.type: Easing.InOutCubic } }

    function openSwitcher() {
        overlayActive = true
        searchQuery = ""
        drilledAppId = ""
        var m = buildLayer0()
        setLayer(m, 0)
        pressCount = 0
        window.visible = true
        fadeProgress = 1.0
        initFuseIndex()
        Qt.callLater(function() { focusGrabber.forceActiveFocus() })
        log("opened, " + sphereModel.length + " app groups")
    }

    function closeSwitcher() {
        overlayActive = false
        fadeProgress = 0.0
        hideTimer.restart()
        log("closed")
    }

    Timer {
        id: hideTimer
        interval: 200
        repeat: false
        onTriggered: { window.visible = false }
    }

    // ── IPC handlers ───────────────────────────────────────────────────────
    IpcHandler {
        target: "hexmap"
        function toggle(): void {
            if (window.overlayActive) window.doAdvance(1)
            else window.openSwitcher()
        }
        function next(): void { if (window.overlayActive) window.doAdvance(1) }
        function prev(): void { if (window.overlayActive) window.doAdvance(-1) }
        function commit(): void { window.closeSwitcher() }
        function cancel(): void { window.closeSwitcher() }
        function drill(): void { if (window.overlayActive) window.drillDown() }
        function status(): void {
            window.log("STATUS layer=" + window.layer + " pressCount=" + window.pressCount + " focusItem=" + window.itemAtSlot[0] + " n=" + window.nodeCount)
        }
    }

    // ── Keyboard: Esc cancel, ; drill-down ─────────────────────────────────
    Item {
        id: focusGrabber
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                // Escape: if searching, cancel search; otherwise close overlay.
                if (window.layer === 2 && window.searchQuery !== "") {
                    window.cancelSearch()
                } else {
                    window.closeSwitcher()
                }
                event.accepted = true
            } else if (event.key === Qt.Key_Semicolon) {
                window.drillDown()
                event.accepted = true
            } else if (event.key === Qt.Key_Backspace) {
                if (window.searchQuery.length > 0)
                    window._handleSearchInput(window.searchQuery.slice(0, -1))
                event.accepted = true
            } else if (!event.isAutoRepeat && event.text.length > 0
                       && event.text.match(/[a-zA-Z0-9 _.-]/)) {
                window._handleSearchInput(window.searchQuery + event.text)
                event.accepted = true
            }
        }
    }

    // ── Fade container ─────────────────────────────────────────────────────
    Item {
        id: fadeContainer
        anchors.fill: parent
        opacity: window.fadeProgress

        Repeater {
            id: nodeRepeater
            model: window.nodeCount

            delegate: Item {
                id: node
                property int item: index
                property var slotVar: window.slotOfItem[index] !== undefined ? window.slotOfItem[index] : index
                property int slot: slotVar >= 0 ? slotVar : index
                property var h: slot >= 0 && slot < window.grid.length ? window.grid[slot] : null
                property int ring: h ? h.ring : 99
                property var c: window.slotCenter(slot)

                x: c.x - width / 2
                y: c.y - height / 2
                width: window.hexScale * 2
                height: window.hexScale * 2
                z: slot === 0 ? 10 : 1

                Behavior on x { NumberAnimation { duration: window.swapMs; easing.type: Easing.InOutCubic } }
                Behavior on y { NumberAnimation { duration: window.swapMs; easing.type: Easing.InOutCubic } }

                visible: slot >= 0 && slot < window.grid.length
                opacity: slot === 0 ? 1.0 : window.ringOpacity(ring)

                // App icon (flat-top hexagon SVG) is the node.
                Image {
                    id: iconImage
                    anchors.fill: parent
                    source: window.iconDir + window.iconFor(item)
                    sourceSize.width: 256
                    sourceSize.height: 256
                    smooth: true
                    mipmap: true
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                }

                // Window-count badge centered on the bottom edge (6 o'clock).
                // Responsively sized: font + padding scale with hexScale.
                Rectangle {
                    id: badge
                    anchors.horizontalCenter: parent.horizontalCenter
                    // Vertical midpoint above the hexagon's bottom edge.
                    // Proportional to hexScale so alignment is invariant across
                    // screen sizes (20px at hexScale 68 == 0.294x).
                    y: parent.height - height / 2 - window.hexScale * 0.294
                    width: badgeText.width + window._badgePad * 2
                    height: badgeText.height + window._badgePad * 2
                    radius: height / 2
                    color: "#2b2b2b"
                    visible: window.hasBadge(item)

                    Text {
                        id: badgeText
                        anchors.centerIn: parent
                        text: window.badgeText(item)
                        color: "#ff4400"
                        font.family: "JuliaMono"
                        font.pixelSize: window._badgeFontSize
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        // ── Curved label: focused node name around the top-left arc ───────
        Repeater {
            id: curveRepeater
            model: window.curveCharCount()

            delegate: Text {
                property var cc: window.curveChar(index, window.curveCharCount())
                property int charIdx: index
                text: window.curveLabel().charAt(index)
                x: cc.x - width / 2
                y: cc.y - height / 2
                z: 20
                visible: window.overlayActive
                color: window.cfg.colors?.accent ?? "#ff4400"
                font.family: "JetBrains Mono"
                font.pixelSize: window._curveFontSize
                font.bold: true
                transform: Rotation {
                    origin.x: width / 2
                    origin.y: height / 2
                    angle: cc.angle
                }
            }
        }

        // HUD caption (bottom) — shows the focused node name + layer.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: window.overlayActive && window.layer === 2 ? 90 : 20
            visible: window.overlayActive && window.layer !== 2
            text: (window.layer === 0 ? "apps · " : "windows · ")
                  + (window.itemAtSlot[0] !== undefined ? window.appNameFor(window.itemAtSlot[0]) : "")
            color: window.cfg.colors?.accent ?? "#ff4400"
            font.family: "JetBrains Mono"
            font.pixelSize: 14
        }

        // ── Search bar (layer 2) — replica of hyprsphere's bar ────────────
        Rectangle {
            id: searchContainer
            visible: window.overlayActive
            width:  560
            height: 56
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 63
            anchors.horizontalCenter: parent.horizontalCenter
            radius: 28
            color: Qt.rgba(1.0, 0.267, 0.0, 0.3)          // #ff4400 @ 30%
            border.color: window.searchQuery.length > 0 ? "#ff4400" : "#2b2b2b"
            border.width: 1.5

            // Read-only search text (mirrors hyprsphere's read-only TextField).
            Text {
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                text: window.searchQuery.length > 0 ? window.searchQuery : "Search apps and windows..."
                color: window.searchQuery.length > 0 ? "#ff4400" : Qt.rgba(1.0, 0.267, 0.0, 0.6)
                font.family: "JuliaMono"
                font.pixelSize: 18
                font.weight: Font.Medium
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
    }

    // ── Load config at startup ─────────────────────────────────────────────
    Component.onCompleted: {
        configReader.running = true
    }
}
