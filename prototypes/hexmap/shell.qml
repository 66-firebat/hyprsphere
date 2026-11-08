// ══════════════════════════════════════════════════════════════════════════════
// HYPRSPHERE — Hexagonal grid on a sphere (UI prototype, v4 — interactive)
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
    property real spinMs: 300

    // ── Selection state ────────────────────────────────────────────────────
    property int focusedIdx: 0            // MRU index currently front-and-center
    property int mruCount: 19             // number of MRU items (matches icons)

    // ── Icon directory ─────────────────────────────────────────────────────
    property string iconDir: "file:///home/fireshark/nixos-dotfiles/git_repositories/assets/icon_packs/fireshark/48/apps/"

    // ── MRU apps (name + matching icon filename) ──────────────────────────
    property var apps: [
        { name: "Ghostty",        icon: "com.mitchellh.ghostty.svg" },
        { name: "Firefox",        icon: "firefox.svg" },
        { name: "Emacs",          icon: "emacs.svg" },
        { name: "Blender",        icon: "blender.svg" },
        { name: "KiCad",          icon: "kicad.svg" },
        { name: "GIMP",           icon: "gimp.svg" },
        { name: "Sioyek",         icon: "sioyek-icon-linux.svg" },
        { name: "Element",        icon: "element.svg" },
        { name: "Anki",           icon: "anki.svg" },
        { name: "Zathura",        icon: "org.pwmt.zathura.svg" },
        { name: "Inkscape",       icon: "org.inkscape.Inkscape.svg" },
        { name: "Telegram",       icon: "org.telegram.desktop.svg" },
        { name: "Discord",        icon: "discord.svg" },
        { name: "Settings",       icon: "org.gnome.Settings.svg" },
        { name: "Extensions",     icon: "org.gnome.Extensions.svg" },
        { name: "Swappy",         icon: "swappy.svg" },
        { name: "DocViewer",      icon: "document-viewer.svg" },
        { name: "Main",           icon: "main.svg" },
        { name: "GnomeExt",       icon: "gnome-extensions.svg" }
    ]

    function appName(slot) { var it = slotItem(slot); return (it >= 0) ? apps[it].name : "" }
    function appIconName(slot) { var it = slotItem(slot); return (it >= 0) ? apps[it].icon : "" }

    // ── Flat-top axial hex corners (unit hex, size = 1) ────────────────────
    // ── Pointy-top axial hex corners (unit hex, size = 1) ────────────────
    // Icon SVGs are pointy-top hexagons already; match their orientation so
    // icons fill the cells exactly.
    function flatCorners(q, r) {
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

    // MRU item index → hex slot index (identity here: slot 0 = center = item 0,
    // slot 1 = 12 o'clock = item 1, etc.). An MRU item is only shown if it has
    // a hex slot; extra slots (more hexes than items) are left empty.
    function itemSlot(mru) { return mru }            // identity mapping
    function slotItem(slot) { return slot < mruCount ? slot : -1 }
    function slotLabel(slot) {
        var it = slotItem(slot)
        return (it >= 0) ? apps[it].name : ""
    }
    function slotRing(slot) { return grid[slot] ? grid[slot].ring : 99 }

    // Icon image element for a given MRU item (null if not loaded yet).
    function iconSource(mruIdx) {
        if (mruIdx < 0 || mruIdx >= apps.length) return null
        return iconImages.itemAt(mruIdx)
    }

    // Current on-screen pixel size of a hexagon slot (approx. inradius*2).
    function hexPxSize(slot) {
        var h = grid[slot]
        if (!h) return 60
        var fx = Math.sqrt(3) * (h.q + h.r / 2), fy = 1.5 * h.r
        // project two points ~hexScale apart along the local x axis to gauge scale
        var c1 = root.flatToScreen(fx, fy)
        var c2 = root.flatToScreen(fx + 1.0, fy)
        var dx = c2.x - c1.x, dy = c2.y - c1.y
        var scale = Math.sqrt(dx * dx + dy * dy)   // px per flat-space unit
        return scale * 2.0   // hex flat-to-flat ≈ 2 * unit-space
    }

    // ── Flat tangent-plane point → unit sphere (continuous) ────────────────
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

    // ── Rotate (yaw→pitch) then perspective-project ────────────────────────
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

    // Center of a given hex slot, in *unrotated* sphere space (for target
    // direction computation).
    function slotCenterUnrotated(slot) {
        var h = grid[slot]
        if (!h) return null
        var cx = Math.sqrt(3) * (h.q + h.r / 2)
        var cy = 1.5 * h.r
        return toSphere(cx, cy)
    }

    // ── Spin to a target slot: rotate so that slot's hex face is front ─────
    // Verified math (see /tmp/rotcheck.py): to bring unrotated point c to
    // screen center (x=0, y=0):
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

    // Animate rotY and rotX to targets over spinMs (shortest yaw path).
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

    // ── Single full-scene canvas ────────────────────────────────────────────
    Canvas {
        id: scene
        anchors.fill: parent
        renderStrategy: Canvas.Threaded

        function ringOpacity(r) {
            // full at center, diminishing outward
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
                var fc = root.flatCorners(h.q, h.r)

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

                ctx.globalAlpha = alpha
                ctx.fillStyle = "#ff4400"
                ctx.strokeStyle = "#ff4400"
                ctx.lineWidth = 1.0
                ctx.fill()
                ctx.stroke()

                // Draw the app icon (already a pointy-top hexagon) at full
                // cell size — no clip, so it fills the hexagon edge-to-edge.
                var iconImg = root.iconSource(it)
                if (iconImg && iconImg.status === Image.Ready) {
                    var avg = { x: 0, y: 0 }
                    for (var k = 0; k < 6; k++) { avg.x += pts[k].x; avg.y += pts[k].y }
                    avg.x /= 6; avg.y /= 6
                    var sz = root.hexPxSize(hi)
                    ctx.drawImage(iconImg, avg.x - sz / 2, avg.y - sz / 2, sz, sz)
                }

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

    // ── Hidden icon preloader: one Image per app icon (kept off-screen) ──
    Item {
        id: iconPreloader
        visible: false
        Repeater {
            id: iconImages
            model: root.apps
            delegate: Image {
                property string src: root.iconDir + (root.apps[index] ? root.apps[index].icon : "")
                source: src
                sourceSize.width: 512
                sourceSize.height: 512
                smooth: true
                asynchronous: true
                onStatusChanged: if (status === Image.Ready) scene.requestPaint()
            }
        }
    }

    // ── HUD caption ────────────────────────────────────────────────────────
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        text: root.appName(root.focusedIdx) + " · Tab/Shift+Tab spin · Esc quit"
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

    // ── No auto-timeout during interactive prototyping (Esc to quit) ───────
}
