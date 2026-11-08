// ══════════════════════════════════════════════════════════════════════════════
// HYPRSPHERE — Hexagonal grid on a sphere (UI prototype, v5 — raw hexagons)
//
// A gap-free hexagonal mesh wrapped on a sphere, transparent background,
// opaque #ff4400 hexagons. Static at rest (dead-on front). Alt+Tab / Shift+Tab
// SPIN the sphere (combined pitch+yaw) so the next MRU item's face glides
// front-and-center over 300 ms.
//
// MRU placement (at rest):
//   item 0 = center hex (the focused target)
//   item 1 = ring 1 @ 12 o'clock, item 2 = @ 2 o'clock, ... clockwise
//   then ring 2 (12 hexes), ring 3, ... continuing the clockwise spiral.
//
// Opacity: full at center, diminishing with ring distance.
// Focus: the front-and-center hexagon gets an emissive orange glow.
//
// Run:  quickshell -p prototypes/hexmap/
// Controls: Tab / Shift+Tab move · Esc quit.
// ══════════════════════════════════════════════════════════════════════════════

import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root
    visible: true
    focusable: true
    color: "transparent"

    property int timeoutMs: 0          // 0 = don't auto-close during interactive use

    WlrLayershell.namespace: "hexmap-prototype"
    WlrLayershell.layer: WlrLayer.Overlay
    anchors.left: true; anchors.right: true; anchors.top: true; anchors.bottom: true
    exclusiveZone: 0
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: Screen.width
    implicitHeight: Screen.height

    // ── Sphere / grid parameters ───────────────────────────────────────────
    property real sphereR: 360
    property int  rings: 6
    property real hexScale: 40
    property real rotX: 0.0               // pitch — rest = 0 (dead-on front)
    property real rotY: 0.0               // yaw
    property real spinMs: 150

    // ── Selection state ────────────────────────────────────────────────────
    property int focusedIdx: 0            // MRU index currently front-and-center
    property int mruCount: 30             // number of MRU items (sample)

    // ── Hex corner helper (pointy-top, unit hex, size 1) ───────────────────
    function hexCorners(q, r) {
        var cx = Math.sqrt(3) * (q + r / 2)
        var cy = 1.5 * r
        var out = []
        for (var i = 0; i < 6; i++) {
            var a = Math.PI / 3 * i + Math.PI / 6
            out.push({ x: cx + Math.cos(a), y: cy + Math.sin(a) })
        }
        return out
    }

    // Ordered hex list: center, then ring-by-ring, each ring sorted clockwise
    // starting at 12 o'clock. This is the MRU spiral order.
    function buildGrid() {
        var list = []
        for (var k = 0; k <= rings; k++) {
            var ring = []
            for (var q = -k; q <= k; q++)
                for (var r = -k; r <= k; r++)
                    if (Math.max(Math.abs(q), Math.abs(r), Math.abs(-q - r)) === k)
                        ring.push({ q: q, r: r, ring: k })
            ring.sort(function(a, b) {
                var aa = Math.atan2(Math.sqrt(3) * (a.q + a.r / 2), -(1.5 * a.r))
                var ab = Math.atan2(Math.sqrt(3) * (b.q + b.r / 2), -(1.5 * b.r))
                if (aa < 0) aa += 2 * Math.PI
                if (ab < 0) ab += 2 * Math.PI
                return aa - ab
            })
            for (var i = 0; i < ring.length; i++) list.push(ring[i])
        }
        return list
    }
    property var grid: buildGrid()

    // MRU item index → hex slot index (identity: slot 0 = center = item 0,
    // slot 1 = 12 o'clock = item 1, etc.). An MRU item is shown only if it has
    // a hex slot; extra slots (more hexes than items) stay empty.
    function slotItem(slot) { return slot < mruCount ? slot : -1 }

    // ── Nerd Font glyph map: app index → glyph codepoint ─────────────────
    // Uses JetBrains Mono Nerd Font (private-use-area codepoints).
    property var appGlyphs: [
        { name: "Ghostty",  icon: "\uE795" },   // terminal
        { name: "Firefox",  icon: "\uF269" },   // firefox
        { name: "Emacs",    icon: "\uE7C5" },   // code/editor
        { name: "Blender",  icon: "\uF447" },   // cube/3d
        { name: "KiCad",    icon: "\uF11B" },   // sitemap/circuit
        { name: "GIMP",     icon: "\uF1FC" },   // paint-brush
        { name: "Sioyek",   icon: "\uF02D" },   // book
        { name: "Element",  icon: "\uF0E0" },   // envelope
        { name: "Anki",     icon: "\uF005" },   // star
        { name: "Zathura",  icon: "\uF518" },   // book-open
        { name: "Inkscape", icon: "\uF1FC" },   // paint-brush
        { name: "Telegram", icon: "\uF3FE" },   // telegram
        { name: "Discord",  icon: "\uF392" },   // discord
        { name: "Settings", icon: "\uF013" },   // gear
        { name: "Extensions", icon: "\uF12E" }, // puzzle-piece
        { name: "Swappy",   icon: "\uF03E" },   // image
        { name: "DocViewer", icon: "\uF15B" },  // file
        { name: "Main",     icon: "\uF111" },   // circle
        { name: "GnomeExt", icon: "\uF12E" }    // puzzle-piece
    ]

    function glyphFor(mruIdx) {
        var entry = appGlyphs[mruIdx % appGlyphs.length]
        return entry ? entry.icon : "\uF111"
    }

    // ── Flat tangent-plane point → unit sphere (continuous, no seams) ──────
    function toSphere(px, py) {
        var x = px * hexScale, y = py * hexScale, R = sphereR
        var lon = x / R
        var lat = y / R
        var maxLat = Math.PI / 2 - 0.18
        if (lat >  maxLat) lat =  maxLat
        if (lat < -maxLat) lat = -maxLat
        var clat = Math.cos(lat)
        return { x: Math.sin(lon) * clat, y: Math.sin(lat), z: Math.cos(lon) * clat }
    }

    // ── Rotate (pitch around X, then yaw around Y) + perspective ───────────
    function project(s) {
        var cx = Math.cos(rotX), sx = Math.sin(rotX)
        var cy = Math.cos(rotY), sy = Math.sin(rotY)
        var y1 = s.y * cx - s.z * sx
        var z1 = s.y * sx + s.z * cx
        var x2 = s.x * cy + z1 * sy
        var z2 = -s.x * sy + z1 * cy
        var d = 1100
        var persp = d / (d - z2 * sphereR)
        return { x: x2 * sphereR * persp, y: y1 * sphereR * persp, z: z2, s: persp }
    }

    function flatToScreen(px, py) { return project(toSphere(px, py)) }

    // Center of a given hex slot in *unrotated* sphere space.
    function slotCenterUnrotated(slot) {
        var h = grid[slot]
        if (!h) return null
        var cx = Math.sqrt(3) * (h.q + h.r / 2)
        var cy = 1.5 * h.r
        return toSphere(cx, cy)
    }

    // ── Spin to a target slot: rotate so that slot's hex face is front ─────
    // Verified math: to bring unrotated point c to screen center (x=0, y=0):
    //     rotX = atan2(c.y, c.z)
    //     z1   = c.y*sin(rotX) + c.z*cos(rotX)
    //     rotY = atan2(-c.x, z1)
    function spinTo(slot) {
        var h = grid[slot]
        if (!h) return
        var c = slotCenterUnrotated(slot)

        var targetPitch = Math.atan2(c.y, c.z)
        var z1 = c.y * Math.sin(targetPitch) + c.z * Math.cos(targetPitch)
        var targetYaw = Math.atan2(-c.x, z1)

        animateRot(root.rotY, targetYaw, root.rotX, targetPitch)
        focusedIdx = slot
    }

    // Animate rotY/rotX to targets over spinMs (shortest yaw path).
    function animateRot(fromYaw, toYaw, fromPitch, toPitch) {
        var diff = toYaw - fromYaw
        while (diff >  Math.PI) diff -= 2 * Math.PI
        while (diff < -Math.PI) diff += 2 * Math.PI
        var targetYaw = fromYaw + diff

        spinYawAnim.from = fromYaw
        spinYawAnim.to   = targetYaw
        spinPitchAnim.from = fromPitch
        spinPitchAnim.to   = toPitch
        spinYawAnim.restart()
        spinPitchAnim.restart()
    }

    NumberAnimation { id: spinYawAnim; target: root; property: "rotY"; duration: root.spinMs; easing.type: Easing.InOutCubic }
    NumberAnimation { id: spinPitchAnim; target: root; property: "rotX"; duration: root.spinMs; easing.type: Easing.InOutCubic }

    // ── Advance MRU selection ──────────────────────────────────────────────
    function advance(dir) {
        var next = focusedIdx + dir
        if (next < 0) next = mruCount - 1
        if (next >= mruCount) next = 0
        spinTo(next)
    }

    // ── Single full-scene canvas: draws every hexagon in one pass ──────────
    Canvas {
        id: scene
        anchors.fill: parent
        renderStrategy: Canvas.Threaded

        function ringOpacity(r) {
            if (r === 0) return 1.0
            return Math.max(0.12, 1.0 - r * 0.13)
        }

        function isFocused(slot) { return slot === root.focusedIdx }

        onPaint: {
            var W = width, H = height
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, W, H)

            var g = root.grid
            var ox = W / 2, oy = H / 2

            for (var hi = 0; hi < g.length; hi++) {
                var h = g[hi]
                var fc = root.hexCorners(h.q, h.r)

                var pts = []
                var zsum = 0
                var anyNaN = false
                for (var i = 0; i < 6; i++) {
                    var p = root.flatToScreen(fc[i].x, fc[i].y)
                    zsum += p.z
                    pts.push({ x: ox + p.x, y: oy + p.y, z: p.z })
                    if (!isFinite(p.x) || !isFinite(p.y)) anyNaN = true
                }
                if (anyNaN) continue
                var zc = zsum / 6
                if (zc <= 0.22) continue   // backface cull

                var it = root.slotItem(hi)
                if (it < 0) continue        // empty slot (no MRU item)

                // opacity: ring-based (focused full, diminishing outward);
                // additionally fade slightly by depth near the limb.
                var ring = h.ring
                var ro = ringOpacity(ring)
                var depth = 1.0 - Math.max(0, 1.0 - zc) * 0.35
                var alpha = ro * depth
                if (alpha <= 0.02) continue

                ctx.beginPath()
                ctx.moveTo(pts[0].x, pts[0].y)
                for (var j = 1; j < 6; j++) ctx.lineTo(pts[j].x, pts[j].y)
                ctx.closePath()

                ctx.save()
                ctx.clip()
                ctx.globalAlpha = alpha

                // opaque #ff4400 tile (the hexagon) — re-trace the path since
                // clip() consumed it
                ctx.beginPath()
                ctx.moveTo(pts[0].x, pts[0].y)
                for (var jj = 1; jj < 6; jj++) ctx.lineTo(pts[jj].x, pts[jj].y)
                ctx.closePath()
                ctx.fillStyle = "#ff4400"
                ctx.fill()

                // Draw a Nerd Font glyph centered in the hexagon. The glyph is
                // a plain text character, drawn at the hexagon's screen center,
                // scaled to the hex's projected size.
                var fcx = Math.sqrt(3) * (h.q + h.r / 2)
                var fcy = 1.5 * h.r
                var pC = root.flatToScreen(fcx, fcy)
                var gx = ox + pC.x
                var gy = oy + pC.y
                var gsz = root.hexPxSize(hi) * 0.42   // glyph font size relative to hex
                var glyph = root.glyphFor(it)

                ctx.font = "bold " + Math.round(gsz) + "px 'JetBrainsMono Nerd Font Mono'"
                ctx.textAlign = "center"
                ctx.textBaseline = "middle"
                ctx.fillStyle = "#1a0a00"   // dark glyph on the orange tile
                ctx.fillText(glyph, gx, gy)
                ctx.restore()

                // crisp #ff4400 edge (visible where the icon hex leaves a rim)
                ctx.globalAlpha = alpha
                ctx.beginPath()
                ctx.moveTo(pts[0].x, pts[0].y)
                for (var k3 = 1; k3 < 6; k3++) ctx.lineTo(pts[k3].x, pts[k3].y)
                ctx.closePath()
                ctx.strokeStyle = "#ff4400"
                ctx.lineWidth = 1.5
                ctx.stroke()

                // Emissive glow for the focused hexagon (soft radial orange halo)
                if (isFocused(hi)) {
                    var fx = 0, fy = 0
                    for (var k2 = 0; k2 < 6; k2++) { fx += pts[k2].x; fy += pts[k2].y }
                    fx /= 6; fy /= 6
                    var gsz = root.hexPxSize(hi) * 1.5
                    var grd = ctx.createRadialGradient(fx, fy, gsz * 0.1, fx, fy, gsz)
                    grd.addColorStop(0, "rgba(255,120,20,0.55)")
                    grd.addColorStop(0.5, "rgba(255,68,0,0.25)")
                    grd.addColorStop(1, "rgba(255,68,0,0.0)")
                    ctx.globalAlpha = 1.0
                    ctx.fillStyle = grd
                    ctx.beginPath()
                    ctx.arc(fx, fy, gsz, 0, 2 * Math.PI)
                    ctx.fill()
                }
            }
            ctx.globalAlpha = 1.0
        }

        Connections {
            target: root
            function onRotXChanged() { scene.requestPaint() }
            function onRotYChanged() { scene.requestPaint() }
            function onFocusedIdxChanged() { scene.requestPaint() }
        }
        Component.onCompleted: requestPaint()
    }

    // Current on-screen pixel size of a hexagon slot (approx. diameter).
    function hexPxSize(slot) {
        var h = grid[slot]
        if (!h) return 60
        var fx = Math.sqrt(3) * (h.q + h.r / 2), fy = 1.5 * h.r
        var c1 = root.flatToScreen(fx, fy)
        var c2 = root.flatToScreen(fx + 1.0, fy)
        var dx = c2.x - c1.x, dy = c2.y - c1.y
        var scale = Math.sqrt(dx * dx + dy * dy)
        return scale * 2.0
    }

    // ── HUD caption ────────────────────────────────────────────────────────
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        text: "node " + root.focusedIdx + " · Tab/Shift+Tab spin · Esc quit"
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
                root.advance(dir)
                event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
                Qt.quit()
                event.accepted = true
            }
        }
    }
}
