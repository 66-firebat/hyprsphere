// ══════════════════════════════════════════════════════════════════════════════
// HYPRSPHERE — Hexagonal grid on a FLAT plane (v8 — swap-based focus)
//
// A gap-free hexagonal mesh on a flat 2D plane, transparent background,
// opaque #ff4400 hexagons with Nerd Font glyphs. No curvature/sphere: the
// focused item always sits in the CENTER hexagon, face-on and undistorted.
//
// Alt+Tab drives a SWAP animation (not a rotation): on the K-th press in a
// chain we right-rotate the ordered "spine" [center, slot1(12o'clock),
// slot2(2o'clock), ...] so a fresh item enters center and the prior centers
// walk outward (never returning). Items glide between cells over swapMs.
//
// Run:  quickshell -p prototypes/hexmap/
// Controls: Tab / Shift+Tab swap · Esc quit.
// ══════════════════════════════════════════════════════════════════════════════

import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root
    visible: true
    focusable: true
    color: "transparent"

    property int timeoutMs: 0

    WlrLayershell.namespace: "hexmap-prototype"
    WlrLayershell.layer: WlrLayer.Overlay
    anchors.left: true; anchors.right: true; anchors.top: true; anchors.bottom: true
    exclusiveZone: 0
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: Screen.width
    implicitHeight: Screen.height

    // ── Flat plane grid parameters ─────────────────────────────────────────
    property real hexScale: 34      // screen px per flat grid unit
    property int  rings: 6
    property real swapMs: 80
    property real animProgress: 1.0     // 1.0 = settled, 0..1 during a swap

    // ── Selection / chain state ────────────────────────────────────────────
    property int mruCount: 19         // MRU items (matches glyph set)
    property int pressCount: 0        // number of Tabs in current chain
    property var itemAtSlot: []       // itemAtSlot[slot] = item index (or -1)
    property var slotOfItem: []       // slotOfItem[item] = slot index

    // ── Hex corner helper (flat-top, unit hex, size 1) ────────────────────
    function hexCorners(q, r) {
        var cx = 1.5 * q
        var cy = Math.sqrt(3) * (r + q / 2)
        var out = []
        for (var i = 0; i < 6; i++) {
            var a = Math.PI / 3 * i
            out.push({ x: cx + Math.cos(a), y: cy + Math.sin(a) })
        }
        return out
    }

    // Ordered hex cell list: center, then rings clockwise from 12 o'clock.
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

    // ── Nerd Font glyph map: app index → glyph codepoint ─────────────────
    property var appGlyphs: [
        "\uE795", "\uF269", "\uE7C5", "\uF447", "\uF11B", "\uF1FC",
        "\uF02D", "\uF0E0", "\uF005", "\uF518", "\uF1FC", "\uF3FE",
        "\uF392", "\uF013", "\uF12E", "\uF03E", "\uF15B", "\uF111", "\uF12E"
    ]
    function glyphFor(item) {
        return appGlyphs[item % appGlyphs.length] || "\uF111"
    }

    // ── Flat orthogonal projection (no curvature, no sphere) ──────────────
    // Flat hex coords (px, py) map directly to screen at a uniform scale.
    function flatToScreen(px, py) {
        return { x: px * hexScale, y: py * hexScale, z: 1.0, s: 1.0 }
    }

    // Screen center of a given slot (relative to sphere center).
    function slotCenter(slot) {
        var h = grid[slot]
        if (!h) return { x: 0, y: 0, z: 1.0, s: 1.0 }
        var cx = 1.5 * h.q, cy = Math.sqrt(3) * (h.r + h.q / 2)
        return flatToScreen(cx, cy)
    }

    // On-screen pixel size of a hexagon slot (constant on a flat plane).
    function hexPxSize(slot) {
        return hexScale * 2.0
    }

    function ringOpacity(r) {
        if (r === 0) return 1.0
        return Math.max(0.12, 1.0 - r * 0.13)
    }

    // ── Init: item i owns slot i ───────────────────────────────────────────
    function initAssignment() {
        itemAtSlot = []
        slotOfItem = []
        for (var i = 0; i < grid.length; i++) itemAtSlot.push(i < mruCount ? i : -1)
        for (var j = 0; j < mruCount; j++) slotOfItem.push(j)
        pressCount = 0
        animProgress = 1.0
    }

    // ── Forward Tab: left-rotate spine [slot0..slotK] ──────────────────────
    // On press K (1-based after increment), rotate the first (K+1) slots.
    function advanceForward() {
        var maxK = mruCount - 1
        pressCount = pressCount + 1
        if (pressCount > maxK) pressCount = maxK
        var K = pressCount
        // RIGHT-rotate the spine [slot0..slotK] by 1: the fresh item at slot K
        // wraps to center, and everything else shifts one slot outward. This
        // guarantees a never-before-focused node enters center on each press.
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
        // LEFT-rotate the spine [slot0..slotK] by 1 (inverse of forward).
        var spine = []
        for (var s = 0; s <= K; s++) spine.push(itemAtSlot[s])
        var first = spine[0]
        for (var i = 0; i < K; i++) spine[i] = spine[i + 1]
        spine[K] = first
        for (var w = 0; w <= K; w++) itemAtSlot[w] = spine[w]
        rebuildSlots()
        pressCount = pressCount - 1
    }

    function rebuildSlots() {
        slotOfItem = []
        for (var j = 0; j < mruCount; j++) slotOfItem.push(-1)
        for (var s = 0; s < itemAtSlot.length; s++) {
            var it = itemAtSlot[s]
            if (it >= 0) slotOfItem[it] = s
        }
    }

    // ── Animation: animate animProgress 0→1; canvas lerps item positions ──
    NumberAnimation { id: swapAnim; target: root; property: "animProgress"; from: 0.0; to: 1.0; duration: root.swapMs; easing.type: Easing.InOutCubic }

    property var oldSlotOfItem: []

    function doAdvance(dir) {
        oldSlotOfItem = slotOfItem.slice()
        if (dir >= 1) advanceForward()
        else advanceBackward()
        animProgress = 0.0
        swapAnim.from = 0.0
        swapAnim.to = 1.0
        swapAnim.restart()
        scene.requestPaint()
    }

    // ── Canvas: draw hex wireframe (static) + items at interpolated slots ──
    Canvas {
        id: scene
        anchors.fill: parent
        renderStrategy: Canvas.Threaded

        onPaint: {
            var W = width, H = height
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, W, H)
            var ox = W / 2, oy = H / 2
            var t = root.animProgress   // 0..1

            // 1) draw hexagon wireframe (static, all slots)
            for (var hi = 0; hi < root.grid.length; hi++) {
                var h = root.grid[hi]
                var fc = root.hexCorners(h.q, h.r)
                var pts = []
                for (var i = 0; i < 6; i++) {
                    var p = root.flatToScreen(fc[i].x, fc[i].y)
                    pts.push({ x: ox + p.x, y: oy + p.y })
                }
                var alpha = root.ringOpacity(h.ring)
                // fill + stroke
                ctx.beginPath()
                ctx.moveTo(pts[0].x, pts[0].y)
                for (var j = 1; j < 6; j++) ctx.lineTo(pts[j].x, pts[j].y)
                ctx.closePath()
                ctx.globalAlpha = alpha
                ctx.fillStyle = "#ff4400"
                ctx.fill()
                ctx.strokeStyle = "#ff4400"
                ctx.lineWidth = 1.5
                ctx.stroke()
            }

            // 2) draw each item's glyph at its interpolated position
            for (var item = 0; item < root.mruCount; item++) {
                var oldS = root.oldSlotOfItem[item]
                var newS = root.slotOfItem[item]
                if (newS < 0) continue
                var oc = root.slotCenter(oldS >= 0 ? oldS : newS)
                var nc = root.slotCenter(newS)
                // lerp screen position
                var lx = ox + oc.x + (nc.x - oc.x) * t
                var ly = oy + oc.y + (nc.y - oc.y) * t
                // glyph size from target slot
                var gsz = root.hexPxSize(newS) * 0.42
                var glyph = root.glyphFor(item)
                var isFocus = (newS === 0)

                ctx.globalAlpha = isFocus ? 1.0 : root.ringOpacity(root.grid[newS].ring)
                ctx.font = "bold " + Math.round(gsz) + "px 'JetBrainsMono Nerd Font Mono'"
                ctx.textAlign = "center"
                ctx.textBaseline = "middle"
                ctx.fillStyle = "#1a0a00"
                ctx.fillText(glyph, lx, ly)

                // emissive glow on focused item (slot 0)
                if (isFocus) {
                    var gr = root.hexPxSize(0) * 1.5
                    var grd = ctx.createRadialGradient(lx, ly, gr * 0.1, lx, ly, gr)
                    grd.addColorStop(0, "rgba(255,120,20,0.55)")
                    grd.addColorStop(0.5, "rgba(255,68,0,0.25)")
                    grd.addColorStop(1, "rgba(255,68,0,0.0)")
                    ctx.globalAlpha = 1.0
                    ctx.fillStyle = grd
                    ctx.beginPath()
                    ctx.arc(lx, ly, gr, 0, 2 * Math.PI)
                    ctx.fill()
                }
            }
            ctx.globalAlpha = 1.0
        }

        Connections {
            target: root
            function onAnimProgressChanged() { scene.requestPaint() }
            function onItemAtSlotChanged() { scene.requestPaint() }
        }
        Component.onCompleted: { root.initAssignment(); requestPaint() }
    }

    // ── HUD caption ────────────────────────────────────────────────────────
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        text: "focus item " + (root.itemAtSlot[0] !== undefined ? root.itemAtSlot[0] : "0")
              + " · press " + root.pressCount + " · Tab/Shift+Tab swap · Esc quit"
        color: "#ff4400"
        font.pixelSize: 13
        font.family: "JetBrains Mono"
    }

    // ── Keyboard ───────────────────────────────────────────────────────────
    Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                var dir = (event.modifiers & Qt.ShiftModifier || event.key === Qt.Key_Backtab) ? -1 : 1
                root.doAdvance(dir)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
                Qt.quit()
                event.accepted = true
            }
        }
    }
}
