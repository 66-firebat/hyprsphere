import QtQuick
import Qt5Compat.GraphicalEffects
import QtQuick.Window
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

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

    // Paths helper — set these to match your system, or override via env vars
    Item {
        id: paths
        visible: false
        property string qsDir:        "/home/fireshark/hyprsphere"
        property string serpantinumDir: "/home/fireshark/hyprsphere"
    }

    // Config loaded from hyprsphere.json
    property var cfg: ({})

    Process {
        id: configReader
        command: ["cat", paths.qsDir + "/hyprsphere.json"]
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

    Component.onCompleted: { configReader.running = true; }

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

        let phi   = Math.PI * (3 - Math.sqrt(5));
        let total = appModel.count;
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
        if (index < 0 || index >= appModel.count) return;

        let phi    = Math.PI * (3 - Math.sqrt(5));
        let total  = appModel.count;
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

        let maxRX = cfg.sphere?.maxRotationX ?? 1.45;
        searchRotXAnim.to = Math.max(-maxRX, Math.min(maxRX, targetRotX));
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
                searchInput.text    = "";
                window.searchQuery  = "";
                window.selectedAppIndex = -1;
                window.sphereZoom   = 1.0;
                searchInput.forceActiveFocus();
                introPhaseAnim.restart();
            }
        }
    }

    Shortcut {
        sequence: "Escape"
        onActivated: closeSequence.start()
    }

    SequentialAnimation {
        id: closeSequence
        NumberAnimation { target: window; property: "introPhase"; to: 0.0; duration: cfg.animations?.exitFadeDurationMs ?? 400; easing.type: Easing.OutQuint }
        ScriptAction { script: window.visible = false; }
    }

    property var    allApps: []
    property string searchQuery: ""
    property int    selectedAppIndex: -1

    property string selectedAppName: ""
    property string selectedAppIcon: ""
    property string selectedAppExec: ""

    Process {
        id: appFetcher
        running: true
        command: ["bash", "-c", "python3 " + paths.qsDir + "/applauncher/app_fetcher.py"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    if (this.text && this.text.trim().length > 0) {
                        window.allApps = JSON.parse(this.text);
                        // Batch-append in chunks to avoid a single long block on
                        // the main thread that freezes the intro animation.
                        let apps  = window.allApps;
                        let chunk = cfg.misc?.appFetchChunkSize ?? 40;
                        let idx   = 0;
                        function appendChunk() {
                            let end = Math.min(idx + chunk, apps.length);
                            for (; idx < end; idx++) appModel.append(apps[idx]);
                            if (idx < apps.length) Qt.callLater(appendChunk);
                            else { window.projDirty = true; window.rebuildProjCache(); }
                        }
                        appendChunk();
                    }
                } catch(e) { console.log(e); }
            }
        }
    }

    ListModel { id: appModel }

    function handleSearch(query) {
        window.searchQuery = query.toLowerCase();
        if (window.searchQuery === "") {
            window.selectedAppIndex = -1;
            window.selectedAppName  = "";
            window.selectedAppIcon  = "";
            window.selectedAppExec  = "";
            window.sphereZoom       = 1.0;
            return;
        }
        let found = false;
        for (let i = 0; i < appModel.count; i++) {
            if (appModel.get(i).name.toLowerCase().includes(window.searchQuery)) {
                window.selectedAppIndex = i;
                window.selectedAppName  = appModel.get(i).name;
                window.selectedAppIcon  = appModel.get(i).icon || "";
                window.selectedAppExec  = appModel.get(i).exec || "";
                centerOnApp(i);
                window.sphereZoom = cfg.sphere?.searchZoom ?? 1.65;
                found = true;
                break;
            }
        }
        if (!found) {
            window.selectedAppIndex = -1;
            window.sphereZoom       = 1.0;
        }
    }

    function launchApp(appName, execStr) {
        Quickshell.execDetached(["python3", paths.qsDir + "/applauncher/app_fetcher.py", "--log", appName]);
        Quickshell.execDetached(["bash", "-c", execStr]);
        closeSequence.start();
    }
    Item {
        anchors.fill: parent
        opacity: window.introPhase

        Repeater {
            model: cfg.stars?.count ?? 50
            Rectangle {
                property real seed: Math.random()
                x: seed * window.width
                y: Math.random() * window.height
                width:  window._s2 + Math.random() * window._s2
                height: width
                radius: width / 2
                color:  window.text
                opacity: (cfg.stars?.opacityMin ?? 0.08) + Math.random() * ((cfg.stars?.opacityMax ?? 0.12) - (cfg.stars?.opacityMin ?? 0.08))
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
                let maxRX = cfg.sphere?.maxRotationX ?? 1.45;
                window.rotX = Math.max(-maxRX, Math.min(maxRX, newRotX));
                lastX = mouse.x;
                lastY = mouse.y;
            }
            onClicked: searchInput.forceActiveFocus()
        }

        Item {
            id: origin
            anchors.centerIn: parent
            width:  window.baseSphereRadius * 2
            height: window.baseSphereRadius * 2

            Repeater {
                id: appRepeater
                model: appModel

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

                    property bool isMatch:    window.searchQuery === "" || model.name.toLowerCase().includes(window.searchQuery)
                    property bool isSelected: index === window.selectedAppIndex

                    // Collapsed opacity expression — avoids redundant sub-property
                    property real _hz: Math.max(0.0, Math.min(1.0, proj.z * (cfg.cardTilt?.depthOpacityMultiplier ?? 4.0)))
                    opacity: proj.z > 0.0 ? (isMatch ? _hz : _hz * (cfg.cardTilt?.nonMatchOpacity ?? 0.15)) : 0.0
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
                        border.color: nodeMa.containsMouse && !appNode.isSelected ? window.surface2 : "transparent"
                        border.width: window._s2
                        Behavior on color { ColorAnimation { duration: cfg.animations?.cardFadeDurationMs ?? 200 } }

                        // Completely skip rendering when satellite is shown
                        visible: !appNode.isSelected

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: window._s5
                            spacing: window._s5

                            Image {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth:  window._s55
                                Layout.preferredHeight: window._s55
                                source: model.icon
                                    ? (model.icon.startsWith("/") ? "file://" + model.icon : "image://icon/" + model.icon)
                                    : "image://icon/application-x-executable"
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                                smooth: true
                                // Cache decoded images — avoids re-decode on every
                                // Repeater recycle pass.
                                cache: true
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: labelText.implicitHeight + window._s4
                                radius: window._s4
                                color: Qt.rgba(window.crust.r, window.crust.g, window.crust.b, cfg.appCard?.labelBgOpacity ?? 0.60)

                                Text {
                                    id: labelText
                                    anchors.fill: parent
                                    anchors.leftMargin:  window._s3
                                    anchors.rightMargin: window._s3
                                    text: model.name
                                    font.family: "JetBrains Mono"
                                    font.pixelSize: window._s11
                                    font.weight: Font.DemiBold
                                    color: window.text
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment:   Text.AlignVCenter
                                    elide: Text.ElideRight
                                }
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
                                // Satellite total dimensions (20 % smaller than original)
                                readonly property real satW: window._sat_panelW + window._sat_strutW
                                                           + window._sat_hullW
                                                           + window._sat_strutW + window._sat_panelW
                                readonly property real satH: window._sat_hullH
                                                           + window._sat_antennaH
                                                           + window._sat_thrusterH
                                                           + window.s(11)

                                width:  satW
                                height: satH

                                // Left solar panel
                                Rectangle {
                                    id: lPanel
                                    width:  window._sat_panelW
                                    height: window._sat_panelH
                                    anchors.right: lStrut.left
                                    anchors.verticalCenter: hull.verticalCenter
                                    color: window.mantle
                                    border.color: Qt.alpha(window.surface2, 0.4)
                                    border.width: 1
                                    radius: window._sat_radius4

                                    Grid {
                                        anchors.fill: parent
                                        anchors.margins: window._sat_screenM * 0.5
                                        columns: 4; rows: 4
                                        spacing: window._s2
                                        Repeater {
                                            model: 16
                                            Rectangle {
                                                width:  (lPanel.width  - window._sat_screenM - 3 * window._s2) / 4
                                                height: (lPanel.height - window._sat_screenM - 3 * window._s2) / 4
                                                color: Qt.alpha(window.blue, index % 3 === 0 ? 0.15 : 0.05)
                                                radius: 1
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    id: lStrut
                                    width:  window._sat_strutW
                                    height: window._sat_strutH
                                    anchors.right: hull.left
                                    anchors.verticalCenter: hull.verticalCenter
                                    color: Qt.alpha(window.surface2, 0.5)
                                }

                                // Central hull
                                Rectangle {
                                    id: hull
                                    width:  window._sat_hullW
                                    height: window._sat_hullH
                                    anchors.centerIn: parent
                                    anchors.verticalCenterOffset: (window._sat_antennaH - window._sat_thrusterH) * 0.5
                                    color: window.base
                                    border.color: Qt.alpha(window.surface1, 0.6)
                                    border.width: cfg.satellite?.hullBorderWidth ?? 1.5
                                    radius: window._sat_radius12

                                    // Antenna
                                    Rectangle {
                                        width:  window._sat_antStick
                                        height: window._sat_antennaH
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.horizontalCenterOffset: -window._sat_antOffX
                                        anchors.bottom: parent.top
                                        color: Qt.alpha(window.surface2, 0.7)
                                        radius: 1
                                        Rectangle {
                                            width:  window._sat_antBall
                                            height: window._sat_antBall
                                            radius: width / 2
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            anchors.bottom: parent.top
                                            color: window.blue
                                        }
                                    }

                                    // Screen showing selected app
                                    Rectangle {
                                        id: notifScreen
                                        anchors.fill: parent
                                        anchors.margins: window._sat_screenM
                                        color: window.mantle
                                        radius: window._sat_radius8
                                        border.color: Qt.alpha(window.surface0, 0.5)
                                        border.width: 1

                                        ColumnLayout {
                                            anchors.fill: parent
                                            anchors.margins: window._sat_innerM
                                            spacing: window._sat_spacing

                                            Image {
                                                Layout.alignment: Qt.AlignHCenter
                                                Layout.preferredWidth:  window._sat_iconSz
                                                Layout.preferredHeight: window._sat_iconSz
                                                source: window.selectedAppIcon
                                                    ? (window.selectedAppIcon.startsWith("/")
                                                       ? "file://" + window.selectedAppIcon
                                                       : "image://icon/" + window.selectedAppIcon)
                                                    : "image://icon/application-x-executable"
                                                fillMode: Image.PreserveAspectFit
                                                smooth: true
                                                cache: true
                                            }

                                            Text {
                                                Layout.alignment: Qt.AlignHCenter
                                                Layout.fillWidth: true
                                                text: window.selectedAppName
                                                font.family: "JetBrains Mono"
                                                font.pixelSize: window._sat_fontSize
                                                font.weight: Font.Bold
                                                color: window.text
                                                horizontalAlignment: Text.AlignHCenter
                                                elide: Text.ElideRight
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                    }

                                    // Thruster
                                    Rectangle {
                                        width:  window._sat_thrBase
                                        height: window._sat_thrusterH * 0.5
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.top: parent.bottom
                                        color: window.surface1
                                        radius: 2
                                        Rectangle {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            anchors.top: parent.bottom
                                            width:  parent.width * 0.6
                                            height: window._sat_thrusterH
                                            radius: width / 2
                                            color: Qt.alpha(window.sapphire, 0.35)
                                        }
                                    }
                                }

                                // Right solar panel
                                Rectangle {
                                    id: rPanel
                                    width:  window._sat_panelW
                                    height: window._sat_panelH
                                    anchors.left: rStrut.right
                                    anchors.verticalCenter: hull.verticalCenter
                                    color: window.mantle
                                    border.color: Qt.alpha(window.surface2, 0.4)
                                    border.width: 1
                                    radius: window._sat_radius4

                                    Grid {
                                        anchors.fill: parent
                                        anchors.margins: window._sat_screenM * 0.5
                                        columns: 4; rows: 4
                                        spacing: window._s2
                                        Repeater {
                                            model: 16
                                            Rectangle {
                                                width:  (rPanel.width  - window._sat_screenM - 3 * window._s2) / 4
                                                height: (rPanel.height - window._sat_screenM - 3 * window._s2) / 4
                                                color: Qt.alpha(window.blue, index % 3 === 0 ? 0.15 : 0.05)
                                                radius: 1
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    id: rStrut
                                    width:  window._sat_strutW
                                    height: window._sat_strutH
                                    anchors.left: hull.right
                                    anchors.verticalCenter: hull.verticalCenter
                                    color: Qt.alpha(window.surface2, 0.5)
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: nodeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: window.launchApp(model.name, model.exec)
                    }
                }
            }
        }
    }

    Rectangle {
        id: searchContainer
        width:  window.s(cfg.searchBar?.width ?? 560)
        height: window._s56
        anchors.bottom: parent.bottom
        anchors.bottomMargin: window._s63
        anchors.horizontalCenter: parent.horizontalCenter

        radius: window._s28
        color: Qt.rgba(window.mantle.r, window.mantle.g, window.mantle.b, cfg.searchBar?.backgroundOpacity ?? 0.92)
        border.color: searchInput.activeFocus ? window.mauve : window.surface1
        border.width: window.s(cfg.searchBar?.borderWidth ?? 1.5)

        opacity: window.introPhase
        transform: Translate { y: (1 - window.introPhase) * window._s40 }
        Behavior on border.color { ColorAnimation { duration: cfg.animations?.borderColorDurationMs ?? 150 } }

        // layer.enabled only when the shadow actually matters (saves an FBO
        // on every frame when the bar is offscreen / fading in).
        layer.enabled: window.introPhase > 0.01
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#000000"
            shadowOpacity: cfg.searchBar?.shadowOpacity ?? 0.4
            shadowBlur: cfg.searchBar?.shadowBlur ?? 1.5
            shadowVerticalOffset: window._s4
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin:  window._s20
            anchors.rightMargin: window._s20
            spacing: window._s12

            Text {
                text: ""
                font.family: "Iosevka Nerd Font"
                font.pixelSize: window._s18
                color: searchInput.activeFocus ? window.mauve : window.subtext0
                Behavior on color { ColorAnimation { duration: cfg.animations?.borderColorDurationMs ?? 150 } }
            }

            TextField {
                id: searchInput
                Layout.fillWidth: true
                Layout.fillHeight: true
                background: Item {}
                color: window.text
                font.family: "JetBrains Mono"
                font.pixelSize: window._s15
                font.weight: Font.Medium
                selectByMouse: true

                placeholderText: "Search applications..."
                placeholderTextColor: window.overlay0
                verticalAlignment: TextInput.AlignVCenter

                onTextChanged: window.handleSearch(text)

                Keys.onDownPressed: {
                    for (let i = window.selectedAppIndex + 1; i < appModel.count; i++) {
                        if (appModel.get(i).name.toLowerCase().includes(window.searchQuery)) {
                            window.selectedAppIndex = i;
                            window.selectedAppName  = appModel.get(i).name;
                            window.selectedAppIcon  = appModel.get(i).icon || "";
                            window.selectedAppExec  = appModel.get(i).exec || "";
                            window.centerOnApp(i);
                            window.sphereZoom = cfg.sphere?.searchZoom ?? 1.65;
                            break;
                        }
                    }
                    event.accepted = true;
                }
                Keys.onUpPressed: {
                    for (let i = window.selectedAppIndex - 1; i >= 0; i--) {
                        if (appModel.get(i).name.toLowerCase().includes(window.searchQuery)) {
                            window.selectedAppIndex = i;
                            window.selectedAppName  = appModel.get(i).name;
                            window.selectedAppIcon  = appModel.get(i).icon || "";
                            window.selectedAppExec  = appModel.get(i).exec || "";
                            window.centerOnApp(i);
                            window.sphereZoom = cfg.sphere?.searchZoom ?? 1.65;
                            break;
                        }
                    }
                    event.accepted = true;
                }
                Keys.onReturnPressed: {
                    if (window.selectedAppIndex >= 0 && window.selectedAppIndex < appModel.count) {
                        window.launchApp(
                            appModel.get(window.selectedAppIndex).name,
                            appModel.get(window.selectedAppIndex).exec
                        );
                    }
                    event.accepted = true;
                }
                Keys.onEscapePressed: {
                    closeSequence.start();
                    event.accepted = true;
                }
            }

            Text {
                visible: searchInput.text.length > 0
                text: ""
                font.family: "Iosevka Nerd Font"
                font.pixelSize: window._s16
                color: window.subtext0
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        searchInput.text = "";
                        searchInput.forceActiveFocus();
                    }
                }
            }
        }
    }
}
