#!/usr/bin/env python3
"""
PHASE_1 automated test: buildLayer0() grouping logic.

Tests the pure data-shaping logic in isolation with mock toplevel data.
No compositor needed.
"""

import json
import sys

LOG_FILE = "PHASE_1_TEST_LOG.txt"
passed = 0
failed = 0


def log(msg):
    with open(LOG_FILE, "a") as f:
        f.write(msg + "\n")
    print(msg)


def check(condition, name):
    global passed, failed
    if condition:
        log(f"[PASS] {name}")
        passed += 1
    else:
        log(f"[FAIL] {name}")
        failed += 1


# ── Mock data ──────────────────────────────────────────────────────

def make_toplevel(app_id, ws_id, ws_name="", address="0x01"):
    """Build a mock toplevel object matching HyprlandToplevel shape."""
    return {
        "wayland": {"appId": app_id} if app_id else None,
        "address": address,
        "title": f"{app_id} window",
        "workspace": {"id": ws_id, "name": ws_name or str(ws_id)},
    }


# ── Reference implementation of buildLayer0() ──────────────────────

def buildLayer0(toplevels, whitelist):
    """Matches the QML buildLayer0() from PLAN.md exactly."""
    groups = {}

    # 1. Build running-app groups
    for t in toplevels:
        ws = t.get("workspace", {})
        ws_id = ws.get("id", 0)
        ws_name = ws.get("name", "")
        is_special = ws_id < 0 or str(ws_name).startswith("special:")
        if is_special:
            continue
        app_id = t.get("wayland", {}) or {}
        app_id = app_id.get("appId", "unknown") if app_id else "unknown"
        if not groups.get(app_id):
            groups[app_id] = {
                "appId": app_id,
                "label": app_id,
                "icon": app_id,
                "windows": [],
            }
        groups[app_id]["windows"].append({
            "address": t.get("address", ""),
            "title": t.get("title", ""),
        })
        groups[app_id]["windowCount"] = len(groups[app_id]["windows"])

    # 2. Append whitelist
    for entry in (whitelist or []):
        if entry.get("appId") in groups:
            continue
        groups[entry["appId"]] = {
            "appId": entry["appId"],
            "label": entry["label"],
            "icon": entry["icon"],
            "exec": entry["exec"],
            "windows": [],
            "windowCount": 0,
            "isWhitelistPlaceholder": True,
        }

    return list(groups.values())


# ── Tests ──────────────────────────────────────────────────────────

def test_groups_by_app_id():
    """Two windows of the same app → one group with windowCount=2."""
    toplevels = [
        make_toplevel("firefox", 1, address="0x01"),
        make_toplevel("firefox", 2, address="0x02"),
        make_toplevel("emacs", 1, address="0x03"),
    ]
    result = buildLayer0(toplevels, [])
    groups = {g["appId"]: g for g in result}
    check(len(result) == 2, "two apps → two groups")
    check(groups["firefox"]["windowCount"] == 2, "firefox has 2 windows")
    check(groups["emacs"]["windowCount"] == 1, "emacs has 1 window")


def test_excludes_special_workspace():
    """Window on special:0 workspace is excluded."""
    toplevels = [
        make_toplevel("firefox", 1, address="0x01"),
        make_toplevel("kitty", -99, "special:test", address="0x02"),
    ]
    result = buildLayer0(toplevels, [])
    groups = {g["appId"]: g for g in result}
    check("kitty" not in groups, "kitty excluded from special workspace")
    check("firefox" in groups, "firefox still present on normal workspace")


def test_drops_app_with_only_special_window():
    """App whose only window is on a special workspace is dropped entirely."""
    toplevels = [
        make_toplevel("alacritty", -1, "special:hidden", address="0x01"),
    ]
    result = buildLayer0(toplevels, [])
    check(len(result) == 0, "no groups when only window is on special workspace")


def test_whitelist_appends_when_not_running():
    """Whitelist entry appears when that app has no windows."""
    toplevels = [make_toplevel("firefox", 1, address="0x01")]
    whitelist = [
        {"appId": "code", "label": "VS Code", "icon": "code", "exec": "code"},
    ]
    result = buildLayer0(toplevels, whitelist)
    groups = {g["appId"]: g for g in result}
    check("code" in groups, "code appears in groups")
    check(groups["code"].get("isWhitelistPlaceholder") is True,
          "code has isWhitelistPlaceholder")
    check(groups["code"]["windowCount"] == 0, "code has 0 windows")


def test_whitelist_dedup_when_running():
    """Whitelist entry is skipped when that app is already running."""
    toplevels = [make_toplevel("firefox", 1)]  # 3 windows
    whitelist = [
        {"appId": "firefox", "label": "Firefox", "icon": "firefox", "exec": "firefox"},
    ]
    result = buildLayer0(toplevels, whitelist)
    groups = {g["appId"]: g for g in result}
    check("firefox" in groups, "firefox still in groups")
    check(groups["firefox"].get("isWhitelistPlaceholder") is not True,
          "firefox is NOT a placeholder (real windows exist)")
    check(len(result) == 1, "only one group (no duplicate)")


def test_unknown_appId():
    """Toplevel with null wayland gets appId 'unknown'."""
    toplevels = [
        {
            "wayland": None,
            "address": "0x01",
            "title": "unknown window",
            "workspace": {"id": 1, "name": "1"},
        }
    ]
    result = buildLayer0(toplevels, [])
    groups = {g["appId"]: g for g in result}
    check("unknown" in groups, "null wayland → 'unknown' group")
    check(groups["unknown"]["windowCount"] == 1, "unknown has 1 window")


def test_empty_no_whitelist():
    """No toplevels and no whitelist → empty array."""
    result = buildLayer0([], [])
    check(len(result) == 0, "no toplevels + no whitelist → empty array")


def test_empty_with_whitelist():
    """No toplevels but whitelist entries → only whitelist entries."""
    whitelist = [
        {"appId": "code", "label": "VS Code", "icon": "code", "exec": "code"},
    ]
    result = buildLayer0([], whitelist)
    check(len(result) == 1, "no toplevels + whitelist → 1 group")
    check(result[0]["isWhitelistPlaceholder"] is True, "whitelist entry is placeholder")


# ── Main ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Clear log
    with open(LOG_FILE, "w") as f:
        pass

    log(f"=== PHASE 1 grouping tests ({__file__}) ===")
    log(f"Started: {__import__('datetime').datetime.now()}")
    log("")

    tests = [
        ("groups by appId", test_groups_by_app_id),
        ("excludes special workspace", test_excludes_special_workspace),
        ("drops app with only special window", test_drops_app_with_only_special_window),
        ("whitelist appends when not running", test_whitelist_appends_when_not_running),
        ("whitelist dedup when running", test_whitelist_dedup_when_running),
        ("unknown appId handling", test_unknown_appId),
        ("empty with no whitelist", test_empty_no_whitelist),
        ("empty with whitelist", test_empty_with_whitelist),
    ]

    for name, fn in tests:
        try:
            fn()
        except Exception as e:
            log(f"[FAIL] {name}: exception: {e}")
            failed += 1

    log("")
    log(f"Results: {passed} passed, {failed} failed, "
        f"{passed + failed} total")
    log("")

    sys.exit(0 if failed == 0 else 1)
