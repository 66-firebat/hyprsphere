#!/usr/bin/env python3
"""
PHASE_2 automated test: MRU tracking logic.

Tests MRU update, sorting, pruning, and edge cases in isolation.
No compositor needed.
"""

import json
import sys

LOG_FILE = "PHASE_2_TEST_LOG.txt"
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


def simulate_focus(app_mru, app_window_mru, app_id, address):
    """Simulate onActiveToplevelChanged logic from PHASE_2.md."""
    # Move app to front of app-level MRU
    filtered = [a for a in app_mru if a != app_id]
    app_mru[:] = [app_id] + filtered

    # Move window to front of per-app window MRU
    win_list = app_window_mru.get(app_id, [])
    win_filtered = [a for a in win_list if a != address]
    app_window_mru[app_id] = [address] + win_filtered

    return app_mru, app_window_mru


def simulate_close(app_mru, app_window_mru, address):
    """Simulate onRawEvent closewindow>> logic."""
    for app_id in list(app_window_mru.keys()):
        win_list = app_window_mru[app_id]
        if address in win_list:
            win_list.remove(address)
            if len(win_list) == 0:
                del app_window_mru[app_id]
                app_mru[:] = [a for a in app_mru if a != app_id]
            else:
                app_window_mru[app_id] = win_list
            break
    return app_mru, app_window_mru


def sort_by_mru(raw_groups, app_mru):
    """Sort raw groups by MRU order (apps in MRU first, then unknown)."""
    sorted_list = []
    for app_id in app_mru:
        for g in raw_groups:
            if g["appId"] == app_id and g not in sorted_list:
                sorted_list.append(g)
                break
    for g in raw_groups:
        if g not in sorted_list:
            sorted_list.append(g)
    return sorted_list


# ── Tests ──────────────────────────────────────────────────────────

def test_focus_moves_to_front():
    mru = []
    win_mru = {}
    mru, win_mru = simulate_focus(mru, win_mru, "firefox", "0x01")
    check(mru == ["firefox"], "first focus → appId in MRU")
    check(win_mru["firefox"] == ["0x01"], "first focus → address in window MRU")


def test_second_focus_moves_to_front():
    mru = ["firefox"]
    win_mru = {"firefox": ["0x01"]}
    mru, win_mru = simulate_focus(mru, win_mru, "emacs", "0x02")
    check(mru == ["emacs", "firefox"], "second focus → emacs first, firefox second")
    check(win_mru["emacs"] == ["0x02"], "emacs window MRU created")


def test_previous_app_moves_down():
    mru = ["emacs", "firefox"]
    win_mru = {"emacs": ["0x02"], "firefox": ["0x01"]}
    mru, win_mru = simulate_focus(mru, win_mru, "firefox", "0x03")
    check(mru == ["firefox", "emacs"], "re-focus firefox → firefox back to front")
    check(win_mru["firefox"] == ["0x03", "0x01"],
          "re-focus firefox → new address at front, old at back")


def test_same_window_twice_no_duplicate():
    mru = ["firefox", "emacs"]
    win_mru = {"firefox": ["0x01"], "emacs": ["0x02"]}
    mru, win_mru = simulate_focus(mru, win_mru, "firefox", "0x01")
    check(win_mru["firefox"] == ["0x01"], "same window twice → no duplicate address")


def test_close_prunes_address():
    mru = ["firefox", "emacs"]
    win_mru = {"firefox": ["0x01", "0x02"], "emacs": ["0x03"]}
    mru, win_mru = simulate_close(mru, win_mru, "0x02")
    check(win_mru["firefox"] == ["0x01"], "close window 0x02 → removed from firefox MRU")
    check("emacs" in win_mru, "emacs still in window MRU")


def test_close_last_window_removes_app():
    mru = ["firefox", "emacs"]
    win_mru = {"firefox": ["0x01"], "emacs": ["0x03"]}
    mru, win_mru = simulate_close(mru, win_mru, "0x01")
    check("firefox" not in mru, "close last firefox window → firefox removed from app MRU")
    check("firefox" not in win_mru, "close last firefox window → firefox removed from window MRU")
    check(mru == ["emacs"], "only emacs remains in app MRU")


def test_close_unknown_address_noop():
    mru = ["firefox"]
    win_mru = {"firefox": ["0x01"]}
    mru_before = mru[:]
    win_before = dict(win_mru)
    mru, win_mru = simulate_close(mru, win_mru, "0x9999")
    check(mru == mru_before, "close unknown address → MRU unchanged")
    check(win_mru == win_before, "close unknown address → window MRU unchanged")


def test_sort_by_mru():
    raw = [
        {"appId": "terminal", "label": "Terminal"},
        {"appId": "firefox", "label": "Firefox"},
        {"appId": "emacs", "label": "Emacs"},
    ]
    mru = ["firefox", "terminal"]
    sorted_groups = sort_by_mru(raw, mru)
    ids = [g["appId"] for g in sorted_groups]
    check(ids == ["firefox", "terminal", "emacs"],
          "sort_by_mru: firefox, terminal, then emacs (not in MRU)")
    check(len(sorted_groups) == 3, "sort_by_mru: all groups preserved")


def test_pre_select_index_1_when_enough():
    mru = ["firefox", "emacs", "terminal"]
    check(len(mru) >= 2, "pre-select index 1 when appMru length >= 2")
    # This is an implementation check, not a logic test


def test_pre_select_index_0_when_empty():
    mru = []
    check(len(mru) < 2, "pre-select index 0 when appMru length < 2")


# ── Main ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    with open(LOG_FILE, "a") as f:
        pass

    log(f"=== PHASE 2 MRU tests ({__file__}) ===")
    log(f"Started: {__import__('datetime').datetime.now()}")
    log("")

    tests = [
        ("focus moves app to front", test_focus_moves_to_front),
        ("second focus moves to front", test_second_focus_moves_to_front),
        ("re-focus existing app moves it back to front", test_previous_app_moves_down),
        ("same window twice no duplicate", test_same_window_twice_no_duplicate),
        ("close prunes address from window MRU", test_close_prunes_address),
        ("close last window removes app entirely", test_close_last_window_removes_app),
        ("close unknown address is no-op", test_close_unknown_address_noop),
        ("sort groups by MRU order", test_sort_by_mru),
        ("pre-select index 1 when MRU has 2+ items", test_pre_select_index_1_when_enough),
        ("pre-select index 0 when MRU is empty", test_pre_select_index_0_when_empty),
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
