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
    property var cfg: ({"hexmap":{"hexScale":68,"rings":6,"swapMs":80},"appCard":{"glyphColor":"#1a0a00","fontFamily":"JetBrainsMono Nerd Font Mono"},"colors":{"accent":"#ff4400"}})

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
    property string iconDir: "file:///home/fireshark/nixos-dotfiles/git_repositories/assets/icon_packs/fireshark/48/apps/"

    property var apps: [
        { name: "Ghostty",  icon: "com.mitchellh.ghostty.svg", windows: 3 },
        { name: "Firefox",  icon: "firefox.svg",               windows: 1 },
        { name: "Emacs",    icon: "emacs.svg",                 windows: 4 },
        { name: "Blender",  icon: "blender.svg",               windows: 1 },
        { name: "KiCad",    icon: "kicad.svg",                 windows: 1 },
        { name: "GIMP",     icon: "gimp.svg",                  windows: 2 },
        { name: "Element",  icon: "element.svg",               windows: 1 },
        { name: "Anki",     icon: "anki.svg",                  windows: 1 },
        { name: "Zathura",  icon: "org.pwmt.zathura.svg",      windows: 2 },
        { name: "Telegram", icon: "org.telegram.desktop.svg",  windows: 1 },
        { name: "Discord",  icon: "discord.svg",               windows: 1 },
        { name: "Settings", icon: "org.gnome.Settings.svg",    windows: 1 },
        { name: "Inkscape", icon: "org.inkscape.Inkscape.svg", windows: 1 },
        { name: "Sioyek",   icon: "sioyek-icon-linux.svg",     windows: 2 },
        { name: "Swappy",   icon: "swappy.svg",                windows: 1 },
        { name: "Extensions", icon: "org.gnome.Extensions.svg", windows: 2 },
        { name: "DocViewer", icon: "document-viewer.svg",      windows: 1 },
        { name: "GnomeExt", icon: "gnome-extensions.svg",      windows: 1 },
        { name: "Main",     icon: "main.svg",                  windows: 1 }
    ]

    property int mruCount: apps.length

    function iconFor(item) { return apps[item % apps.length].icon }

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

    function appNameFor(item) { return apps[item % apps.length].name }

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
    property real fadeProgress: 0.0
    Behavior on fadeProgress { NumberAnimation { duration: 200; easing.type: Easing.InOutCubic } }

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
        fadeProgress = 1.0
        Qt.callLater(function() { focusGrabber.forceActiveFocus() })
        log("opened, " + mruCount + " nodes")
    }

    function closeSwitcher() {
        overlayActive = false
        fadeProgress = 0.0
        hideTimer.restart()
        log("closed")
    }

    // Defer hiding the window until the fade-out completes.
    Timer {
        id: hideTimer
        interval: 200
        repeat: false
        onTriggered: { window.visible = false }
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

    // ── Fade container: fades the whole overlay (grid + icons + HUD). ─────
    Item {
        id: fadeContainer
        anchors.fill: parent
        opacity: window.fadeProgress

        // ── Node rendering: Repeater of Items (SVG icon hex grid) ────────
        Repeater {
            id: nodeRepeater
            model: window.mruCount

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

                // Animate the glide between slots when the swap re-assigns
                // this item to a different hex cell.
                Behavior on x { NumberAnimation { duration: window.swapMs; easing.type: Easing.InOutCubic } }
                Behavior on y { NumberAnimation { duration: window.swapMs; easing.type: Easing.InOutCubic } }

                // Focused (slot 0) is full opacity; outer rings fade the
                // icon. The SVG icon IS the hexagonal node.
                visible: slot >= 0 && slot < window.grid.length
                opacity: slot === 0 ? 1.0 : window.ringOpacity(ring)

                // The app icon (already a flat-top hexagon SVG) is the node.
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
            }
        }

        // ── HUD caption (bottom) ──────────────────────────────────────────
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
    }

    // ── Load config at startup (mirrors shell.qml configReader) ────────────
    Component.onCompleted: {
        configReader.running = true
    }
}
