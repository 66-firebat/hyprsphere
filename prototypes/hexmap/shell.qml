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

    // ── Icon pack (dummy repetition for hexes beyond the set) ─────────────
    property string iconDir: "file:///home/fireshark/nixos-dotfiles/git_repositories/assets/icon_packs/fireshark/48/apps/"
    property var iconNames: [
        "com.mitchellh.ghostty.svg", "firefox.svg", "emacs.svg", "blender.svg",
        "kicad.svg", "gimp.svg", "sioyek-icon-linux.svg", "element.svg",
        "anki.svg", "org.pwmt.zathura.svg", "org.inkscape.Inkscape.svg",
        "org.telegram.desktop.svg", "discord.svg", "org.gnome.Settings.svg",
        "org.gnome.Extensions.svg", "swappy.svg", "document-viewer.svg",
        "main.svg", "gnome-extensions.svg"
    ]
    function iconFor(mruIdx) { return iconNames[mruIdx % iconNames.length] }

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

    // ── Flat-space extent control ─────────────────────────────────────────
    property real flatHalf: (rings + 2.2) * Math.sqrt(3)
    property real texSize: 1024

    // Offscreen FLAT hex grid canvas (icons baked in, unprojected).
    // Kept off-screen; sampled by flatSource.
    Canvas {
        id: flatCanvas
        x: -4096
        y: -4096
        width: root.texSize
        height: root.texSize
        renderStrategy: Canvas.Threaded

        function flatToTex(px, py) {
            var u = (px + root.flatHalf) / (2 * root.flatHalf)
            var v = (py + root.flatHalf) / (2 * root.flatHalf)
            return { x: u * width, y: v * height }
        }

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var g = root.grid
            for (var hi = 0; hi < g.length; hi++) {
                var it = root.slotItem(hi)
                if (it < 0) continue
                var h = g[hi]
                var fc = root.flatCorners(h.q, h.r)
                var p0 = flatToTex(fc[0].x, fc[0].y)
                ctx.beginPath()
                ctx.moveTo(p0.x, p0.y)
                for (var i = 1; i < 6; i++) {
                    var pi = flatToTex(fc[i].x, fc[i].y)
                    ctx.lineTo(pi.x, pi.y)
                }
                ctx.closePath()
                // clip to flat hex and draw the icon
                ctx.save()
                ctx.clip()
                var cx = flatToTex(Math.sqrt(3) * (h.q + h.r / 2), 1.5 * h.r)
                var c1 = flatToTex(Math.sqrt(3) * (h.q + h.r / 2) + 1.0, 1.5 * h.r)
                var sz = Math.abs(c1.x - cx.x) * 2.2
                var img = root.iconImg(it)
                if (img && img.status === Image.Ready)
                    ctx.drawImage(img, cx.x - sz / 2, cx.y - sz / 2, sz, sz)
                else
                    { ctx.fillStyle = "#ff4400"; ctx.fill() }
                ctx.restore()
                // crisp #ff4400 edge
                ctx.beginPath()
                ctx.moveTo(p0.x, p0.y)
                for (var j = 1; j < 6; j++) {
                    var pj = flatToTex(fc[j].x, fc[j].y)
                    ctx.lineTo(pj.x, pj.y)
                }
                ctx.closePath()
                ctx.strokeStyle = "#ff4400"
                ctx.lineWidth = 2.0
                ctx.stroke()
            }
        }

        Connections {
            target: root
            function onFocusedIdxChanged() { flatCanvas.requestPaint() }
        }
        Component.onCompleted: requestPaint()
    }

    // Texture source wrapping the flat canvas.
    ShaderEffectSource {
        id: flatSource
        sourceItem: flatCanvas
        hideSource: true
        smooth: true
    }

    // Preloaded icon images (one per MRU item).
    Repeater {
        id: iconRepeater
        model: root.mruCount
        delegate: Image {
            id: iconDelegate
            property int mruIdx: index
            source: root.iconDir + root.iconFor(index)
            sourceSize.width: 256
            sourceSize.height: 256
            smooth: true
            asynchronous: true
            onStatusChanged: if (status === Image.Ready) flatCanvas.requestPaint()
        }
    }

    function iconImg(mruIdx) {
        if (mruIdx < 0) return null
        var it = iconRepeater.itemAt(mruIdx)
        return it ? it : null
    }

    // ── Full-screen shader: inverse-map each pixel to flat grid, sample ───
    ShaderEffect {
        id: sphereShader
        anchors.fill: parent
        property var src: flatSource
        property real sphereR: root.sphereR
        property real hexScale: root.hexScale
        property real d: 1100.0
        property real rotX: root.rotX
        property real rotY: root.rotY
        property real flatHalf: root.flatHalf
        property real viewportX: width / 2
        property real viewportY: height / 2

        property real maxLat: (Math.PI / 2 - 0.18)

        fragmentShader: "
            varying highp vec2 qt_TexCoord0;
            uniform sampler2D src;
            uniform highp float sphereR;
            uniform highp float hexScale;
            uniform highp float d;
            uniform highp float rotX;
            uniform highp float rotY;
            uniform highp float flatHalf;
            uniform highp float viewportX;
            uniform highp float viewportY;

            void main() {
                // screen offset in px (relative to center)
                highp float X = (qt_TexCoord0.x - 0.5) * 2.0 * viewportX;
                highp float Y = (qt_TexCoord0.y - 0.5) * 2.0 * viewportY;

                highp float a = sphereR;
                highp float D = d;
                highp float R2 = X*X + Y*Y;

                // solve for rotated-space unit direction (rx,ry,rz):
                // forward: X = a*D*rx / (D - a*rz)
                //         Y = a*D*ry / (D - a*rz)
                // let t = D - a*rz  =>  rz = (D - t)/a
                //   rx = X*t/(a*D), ry = Y*t/(a*D)
                // unit sphere: rx^2+ry^2+rz^2 = 1
                highp float Aq = R2/(D*D) + 1.0;
                highp float Bq = -2.0*D;
                highp float Cq = D*D - a*a;
                highp float disc = Bq*Bq - 4.0*Aq*Cq;
                if (disc < 0.0) { gl_FragColor = vec4(0.0); return; }
                highp float sq = sqrt(disc);
                highp float t1 = (-Bq - sq)/(2.0*Aq);
                highp float t2 = (-Bq + sq)/(2.0*Aq);
                // pick root with more-positive rz (front)
                highp float t = ((D - t1)/a) > ((D - t2)/a) ? t1 : t2;
                highp vec3 r = vec3(X*t/(a*D), Y*t/(a*D), (D - t)/a);

                // cull back faces (rz <= ~0.22)
                if (r.z <= 0.22) { gl_FragColor = vec4(0.0); return; }

                // unrotate: yaw(-rotY) then pitch(-rotX)
                highp float cb = cos(-rotY), sb = sin(-rotY);
                highp float x1 = r.x*cb - r.z*sb;
                highp float z1 = r.x*sb + r.z*cb;
                highp float y1 = r.y;
                highp float ca = cos(-rotX), sa = sin(-rotX);
                highp float y2 = y1*ca - z1*sa;
                highp float z2 = y1*sa + z1*ca;
                highp float x2 = x1;
                highp vec3 s = vec3(x2, y2, z2);

                // sphere -> flat (inverse of toSphere)
                highp float lat = asin(clamp(s.y, -1.0, 1.0));
                highp float lon = atan(s.x, s.z);
                highp float px = lon * sphereR / hexScale;
                highp float py = lat * sphereR / hexScale;

                // flat coords -> texture UV [0,1]
                highp float u = (px + flatHalf) / (2.0 * flatHalf);
                highp float v = (py + flatHalf) / (2.0 * flatHalf);
                if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) {
                    gl_FragColor = vec4(0.0); return;
                }

                highp vec4 col = texture2D(src, vec2(u, v));

                // ring-based opacity falloff (based on flat distance)
                highp float dist = length(vec2(px, py));
                highp float ring = dist / (hexScale * 1.5);   // approx ring index
                highp float op = 1.0 - ring * 0.13;
                op = clamp(op, 0.12, 1.0);

                gl_FragColor = vec4(col.rgb, col.a * op);
            }
        "
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
