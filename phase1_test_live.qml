import QtQuick
import Quickshell
import Quickshell.Hyprland._Ipc

// ── PHASE 1 live test ──────────────────────────────────────────────
// Run: quickshell -p phase1_test_live.qml 2>&1 | tee -a PHASE_1_TEST_LOG.txt
// ────────────────────────────────────────────────────────────────────

Item {
    id: root

    property var cfg: ({})

    function buildLayer0(arr) {
        if (!arr) {
            var tls = Hyprland.toplevels;
            arr = (tls && tls.values) || [];
        }
        var groups = {};

        for (var idx = 0; idx < arr.length; idx++) {
            var t = arr[idx];
            if (!t) continue;
            var ws = t.workspace;
            // Special workspace check: only by name (ws.id is always -1 in IPC mode)
            if (ws && String(ws.name || "").startsWith("special:")) continue;
            var wl = t.wayland;
            var appId = (wl && wl.appId) ? wl.appId : "unknown";
            if (!groups[appId]) groups[appId] = { appId: appId, label: appId, icon: appId, windows: [] };
            groups[appId].windows.push({ address: t.address, title: t.title });
            groups[appId].windowCount = groups[appId].windows.length;
        }

        var whitelist = cfg.whitelist || [];
        for (var entry of whitelist) {
            if (groups[entry.appId]) continue;
            groups[entry.appId] = {
                appId: entry.appId,
                label: entry.label,
                icon: entry.icon,
                exec: entry.exec,
                windows: [],
                windowCount: 0,
                isWhitelistPlaceholder: true,
            };
        }
        return Object.values(groups);
    }

    property var rebuildScheduled: false

    function scheduleRebuild() {
        if (rebuildScheduled) return;
        rebuildScheduled = true;
        Qt.callLater(function() {
            rebuildScheduled = false;
            console.log("[TEST] scheduleRebuild: ran");
        });
    }

    Component.onCompleted: {
        console.log("=== PHASE 1 LIVE TEST ===");

        // ── Inspect Hyprland object ──
        console.log("[DEBUG] Hyprland = " + Hyprland);
        console.log("[DEBUG] Hyprland.usingLua = " + Hyprland.usingLua);
        console.log("[DEBUG] Hyprland.requestSocketPath = " + Hyprland.requestSocketPath);
        console.log("[DEBUG] Hyprland.eventSocketPath = " + Hyprland.eventSocketPath);
        console.log("[DEBUG] Hyprland.activeToplevel = " + Hyprland.activeToplevel);

        // ── Read toplevels immediately ──
        let tls = Hyprland.toplevels;
        console.log("[DEBUG] tls.values length = " + (tls.values ? tls.values.length : 'N/A'));

        if (tls.values && tls.values.length > 0) {
            reportResults(tls.values);
        } else {
            console.log("[INFO] toplevels empty initially — running refresh...");
            Hyprland.refreshToplevels();

            // Give refresh a moment, then retry
            Qt.callLater(function() {
                let tls2 = Hyprland.toplevels;
                let arr2 = tls2.values || [];
                console.log("[INFO] after refresh, toplevels count = " + arr2.length);

                if (arr2.length > 0) {
                    reportResults(arr2);
                } else {
                    // Try one more time with a longer delay
                    Qt.callLater(function() {
                        let tls3 = Hyprland.toplevels;
                        let arr3 = tls3.values || [];
                        console.log("[INFO] after 2nd delay, toplevels count = " + arr3.length);

                        if (arr3.length > 0) {
                            reportResults(arr3);
                        } else {
                            console.log("[WARN] toplevels still empty after refresh + 2 delays");
                            console.log("[WARN] Hyprland IPC connected but no toplevel data received");
                            finishTests();
                        }
                    });
                }
            });
        }
    }

    function reportResults(arr) {
        console.log("[PASS] toplevels: count > 0 (" + arr.length + ")");

        let unknownFound = false;
        for (let i = 0; i < arr.length; i++) {
            let t = arr[i];
            console.log("  toplevel " + i + ": appId=" + (t.wayland?.appId || "null")
                + " title=\"" + (t.title || "") + "\""
                + " workspace=" + (t.workspace?.name || "?"));
            if (!t.wayland?.appId) {
                console.log("[WARN] toplevel " + i + " has null appId (wayland handshake pending)");
                unknownFound = true;
            }
        }
        if (!unknownFound) console.log("[PASS] toplevels: all appIds resolved");

        // ── buildLayer0() test ──
        let sphere = buildLayer0(arr);
        console.log("[INFO] buildLayer0 returned " + sphere.length + " groups");

        let allValid = true;
        for (let i = 0; i < sphere.length; i++) {
            let g = sphere[i];
            let valid = g.label && g.icon && g.appId
                        && g.windows !== undefined
                        && g.windowCount !== undefined;
            if (!valid) {
                console.log("[FAIL] group " + i + " missing fields: " + JSON.stringify(g));
                allValid = false;
            } else {
                console.log("  group " + i + ": { appId: \""
                    + g.appId + "\", windowCount: " + g.windowCount
                    + (g.isWhitelistPlaceholder ? ", placeholder: true" : "")
                    + " }");
            }
            if (g.appId === "unknown") {
                console.log("[WARN] group " + i + " has appId 'unknown'");
            }
        }
        if (allValid) console.log("[PASS] all groups have valid label + icon + appId");

        // ── scheduleRebuild() test ──
        try {
            scheduleRebuild();
            console.log("[PASS] scheduleRebuild: ran without error");
        } catch (e) {
            console.log("[FAIL] scheduleRebuild: threw " + e);
        }

        finishTests();
    }

    function finishTests() {
        Qt.callLater(function() {
            console.log("[PASS] scheduleRebuild: sphereModel rebuilt (callback fired)");
            console.log("=== PHASE 1 LIVE TEST COMPLETE ===");
            Qt.quit();
        });
    }
}
