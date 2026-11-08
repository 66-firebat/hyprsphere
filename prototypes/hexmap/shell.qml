// ══════════════════════════════════════════════════════════════════════════════
// hexmap — Hexagonal MRU window switcher (fresh prototype)
//
// Architecture modelled on the main hyprsphere shell.qml:
//   * PanelWindow layer-shell overlay, starts HIDDEN, toggled via IPC.
//   * Nodes rendered as a Repeater of QML Items (no Canvas) — crisp, and
//     avoids the Canvas first-paint lifecycle bug.
//   * Each node is a Nerd Font glyph (Text) placed on a flat hexagonal grid.
//   * Alt/Super+Tab swap mechanism: every press brings a never-yet-focused
//     node to the CENTER (right-rotating the MRU "spine"), and the prior
//     centers walk outward.
//
// Sample MRU data (hardcoded) — live Hyprland wiring comes later.
// ══════════════════════════════════════════════════════════════════════════════

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: window
    focusable: true

    // The overlay is HIDDEN until toggled via IPC (qs ipc call hexmap toggle),
    // exactly like hyprsphere's shell.qml.
    // (No visible:true here — visible is driven by the toggle lifecycle.)

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
    property var cfg: ({"hexmap":{"hexScale":34,"rings":6,"swapMs":80},"appCard":{"glyphColor":"#1a0a00","fontFamily":"JetBrainsMono Nerd Font Mono"},"colors":{"accent":"#ff4400"}})

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
    property real hexScale: cfg.hexmap?.hexScale ?? 34
    property int  rings:     cfg.hexmap?.rings     ?? 6
    property real swapMs:    cfg.hexmap?.swapMs    ?? 80

    // ── State ──────────────────────────────────────────────────────────────
    property bool overlayActive: false
    property int  pressCount: 0          // Tabs pressed in the current chain
    property real animProgress: 1.0

    // ── Sample MRU list (hardcoded; live data wiring comes later) ──────────
    // Covers multiple apps and multiple windows per app to exercise the
    // eventual drill-down / search layers.
    property var apps: [
        { name: "Ghostty",  glyph: "\uE795", windows: 3 },   // terminal
        { name: "Firefox",  glyph: "\uF269", windows: 1 },   // firefox
        { name: "Emacs",    glyph: "\uE7C5", windows: 4 },   // editor
        { name: "Blender",  glyph: "\uF447", windows: 1 },   // cube
        { name: "KiCad",    glyph: "\uF11B", windows: 1 },   // circuit
        { name: "GIMP",     glyph: "\uF1FC", windows: 2 },   // paint
        { name: "Element",  glyph: "\uF0E0", windows: 1 },   // mail
        { name: "Anki",     glyph: "\uF005", windows: 1 },   // star
        { name: "Zathura",  glyph: "\uF518", windows: 2 },   // book
        { name: "Telegram", glyph: "\uF3FE", windows: 1 },   // telegram
        { name: "Discord",  glyph: "\uF392", windows: 1 },   // discord
        { name: "Settings", glyph: "\uF013", windows: 1 },   // gear
        { name: "Spotify",  glyph: "\uF001", windows: 1 },   // music
        { name: "VSCode",   glyph: "\uE70C", windows: 2 },   // code
        { name: "Steam",    glyph: "\uF1B6", windows: 1 },   // steam
        { name: "Obsidian", glyph: "\uF02D", windows: 2 },   // note
        { name: "Kitty",    glyph: "\uE795", windows: 1 },   // terminal
        { name: "Nautilus", glyph: "\uF07B", windows: 1 },   // folder
        { name: "Grafana",  glyph: "\uF201", windows: 1 }    // chart
    ]

    property int mruCount: apps.length

    // ── Hex grid (ordered: center, then rings clockwise from 12 o'clock) ───
    function hexCenter(q, r) {
        return { cx: 1.5 * q, cy: Math.sqrt(3) * (r + q / 2) }
    }

    function buildGrid() {
        var list = []
        for (var k = 0; k <= rings; k++) {
            var ring = []
            for (var q = -k; q <= k; q++)
                for (var r = -k; r <= k; r++)
                    if (Math.max(Math.abs(q), Math.abs(r), Math.abs(-q - r)) === k)
                        ring.push({ q: q, r: r, ring: k })
            ring.sort(function(a, b) {
                var aa = Math.atan2(1.5 * a.q, -(Math.sqrt(3) * (a.r + a.q / 2)))
                var ab = Math.atan2(1.5 * b.q, -(Math.sqrt(3) * (b.r + b.q / 2)))
                if (aa < 0) aa += 2 * Math.PI
                if (ab < 0) ab += 2 * Math.PI
                return aa - ab
            })
            for (var i = 0; i < ring.length; i++) list.push(ring[i])
        }
        return list
    }
    property var grid: buildGrid()

    // Slot i = grid[i] (center = slot 0, then 12 o'clock = slot 1, etc.).
    // slotOfItem[item] = which slot (grid index) this MRU item currently owns.
    // itemAtSlot[slot] = which MRU item is at this slot.
    property var slotOfItem: {
        var arr = []
        for (var j = 0; j < mruCount; j++) arr.push(j)
        return arr
    }
    property var itemAtSlot: {
        var arr = []
        var n = grid.length
        for (var i = 0; i < n; i++) arr.push(i < mruCount ? i : -1)
        return arr
    }
    property var oldSlotOfItem: []

    function glyphFor(item) { return apps[item % apps.length].glyph }
    function appNameFor(item) { return apps[item % apps.length].name }

    // Flat-top hexagon corners (6 vertices) in LOGICAL px, relative to the
    // hex cell center, for a given hex size.
    function hexVerts(size) {
        var R = size / 2   // circumradius = half the cell width
        var out = []
        for (var i = 0; i < 6; i++) {
            var a = Math.PI / 3 * i
            out.push({ x: R * Math.cos(a), y: R * Math.sin(a) })
        }
        return out
    }

    // Screen position (logical px) of a slot's center, relative to screen center.
    function slotCenter(slot) {
        var h = grid[slot]
        if (!h) return { x: 0, y: 0 }
        var c = hexCenter(h.q, h.r)
        return { x: c.cx * hexScale, y: c.cy * hexScale }
    }

    function ringOpacity(ring) {
        if (ring === 0) return 1.0
        return Math.max(0.25, 1.0 - ring * 0.10)
    }

    // ── Swap mechanism ─────────────────────────────────────────────────────
    function rebuildSlots() {
        // Build a fresh array and assign once, so QML sees ONE change
        // notification and re-binds the delegate `slot` properties.
        var arr = []
        for (var j = 0; j < mruCount; j++) arr.push(-1)
        for (var s = 0; s < itemAtSlot.length; s++) {
            var it = itemAtSlot[s]
            if (it >= 0 && it < mruCount) arr[it] = s
        }
        slotOfItem = arr
    }


    function advanceForward() {
        var maxK = mruCount - 1
        pressCount = Math.min(pressCount + 1, maxK)
        var K = pressCount
        // RIGHT-rotate spine [0..K]: the fresh item at slot K comes to center.
        var spine = []
        for (var s = 0; s <= K; s++) spine.push(itemAtSlot[s])
        var last = spine[K]
        for (var i = K; i > 0; i--) spine[i] = spine[i - 1]
        spine[0] = last
        for (var w = 0; w <= K; w++) itemAtSlot[w] = spine[w]
        rebuildSlots()
    }

    function advanceBackward() {
        if (pressCount === 0) return
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
        oldSlotOfItem = slotOfItem.slice()
        if (dir >= 1) advanceForward()
        else advanceBackward()
        window.log("doAdvance dir=" + dir + " -> focusItem=" + window.itemAtSlot[0])
    }

    // ── Open / Close ───────────────────────────────────────────────────────
    function openSwitcher() {
        overlayActive = true
        pressCount = 0
        animProgress = 1.0
        // reset mapping to identity on open
        slotOfItem = []
        for (var j = 0; j < mruCount; j++) slotOfItem.push(j)
        itemAtSlot = []
        for (var i = 0; i < grid.length; i++) itemAtSlot.push(i < mruCount ? i : -1)
        window.visible = true
        Qt.callLater(function() { focusGrabber.forceActiveFocus() })
        log("opened, " + mruCount + " nodes")
    }

    function closeSwitcher() {
        overlayActive = false
        window.visible = false
        log("closed")
    }

    // ── IPC handlers (SUPER+Tab drives these) ──────────────────────────────
    IpcHandler {
        target: "hexmap"
        function toggle(): void {
            window.log("IPC toggle, overlayActive=" + window.overlayActive)
            if (window.overlayActive) {
                window.doAdvance(1)
            } else {
                window.openSwitcher()
            }
        }
        function next(): void {
            window.log("IPC next")
            if (window.overlayActive) window.doAdvance(1)
        }
        function prev(): void {
            window.log("IPC prev")
            if (window.overlayActive) window.doAdvance(-1)
        }
        function commit(): void {
            window.closeSwitcher()
        }
        function cancel(): void {
            window.closeSwitcher()
        }
        function status(): void {
            window.log("STATUS overlayActive=" + window.overlayActive + " pressCount=" + window.pressCount + " focusItem=" + window.itemAtSlot[0] + " slots=" + JSON.stringify(window.slotOfItem))
        }
    }

    // ── Keyboard (Tab/Shift+Tab swap, Esc cancel) ──────────────────────────
    Item {
        id: focusGrabber
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: (event) => {
            // Note: Tab cycling is driven by the Hyprland global/submap binds
            // (SUPER+Tab -> toggle, SUPER+Tab in submap -> next/prev), NOT here.
            // Only Escape is handled locally as a fallback.
            if (event.key === Qt.Key_Escape) {
                window.closeSwitcher()
                event.accepted = true
            }
        }
    }

    // ── Node rendering: Repeater of Items (hex grid of Nerd Font glyphs) ───
    Item {
        id: origin
        anchors.centerIn: parent
        width: 1
        height: 1

        Repeater {
            id: nodeRepeater
            model: window.mruCount      // one node per MRU item

            delegate: Item {
                id: node
                property int item: index
                property var slotVar: window.slotOfItem[index] !== undefined ? window.slotOfItem[index] : index
                property int slot: slotVar >= 0 ? slotVar : index
                property var h: slot >= 0 && slot < window.grid.length ? window.grid[slot] : null
                property int ring: h ? h.ring : 99
                property var c: window.slotCenter(slot)

                x: c.x
                y: c.y
                width: window.hexScale * 2
                height: window.hexScale * 2
                z: slot === 0 ? 10 : 1

                // Animate the glide between slots when the swap re-assigns
                // this item to a different hex cell.
                Behavior on x { NumberAnimation { duration: window.swapMs; easing.type: Easing.InOutCubic } }
                Behavior on y { NumberAnimation { duration: window.swapMs; easing.type: Easing.InOutCubic } }

                // Focused (slot 0) is full opacity; outer rings fade the
                // HEXAGON only — the glyph stays at full #2b2b2b.
                visible: slot >= 0 && slot < window.grid.length

                // Hexagon background tile (#ff4400), opacity driven by ring.
                // The glyph is laid on top of this. Focused (slot 0) is full
                // opacity; each ring outward fades further.
                Shape {
                    id: hexShape
                    anchors.centerIn: parent
                    width: parent.width
                    height: parent.height
                    asynchronous: true
                    opacity: slot === 0 ? 1.0 : window.ringOpacity(ring)

                    ShapePath {
                        fillColor: window.cfg.colors?.accent ?? "#ff4400"
                        strokeColor: "transparent"
                        strokeWidth: 0

                        PathPolyline {
                            path: {
                                var v = window.hexVerts(window.hexScale * 2)
                                var pts = []
                                for (var i = 0; i < v.length; i++)
                                    pts.push(Qt.point(v[i].x, v[i].y))
                                // close the polygon
                                pts.push(Qt.point(v[0].x, v[0].y))
                                return pts
                            }
                        }
                    }
                }

                // Nerd Font glyph (fg #2b2b2b, transparent background).
                Text {
                    id: glyphText
                    anchors.centerIn: parent
                    text: window.glyphFor(item)
                    color: "#2b2b2b"
                    font.family: window.cfg.appCard?.fontFamily ?? "JetBrainsMono Nerd Font Mono"
                    font.pixelSize: window.hexScale * 1.4
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    // ── HUD caption (bottom) ──────────────────────────────────────────────
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        visible: window.overlayActive
        text: "focus: " + (window.itemAtSlot[0] !== undefined ? window.appNameFor(window.itemAtSlot[0]) : "")
        color: window.cfg.colors?.accent ?? "#ff4400"
        font.family: "JetBrains Mono"
        font.pixelSize: 14
    }

    // ── Load config at startup (mirrors shell.qml configReader) ────────────
    Component.onCompleted: {
        configReader.running = true
    }
}
