#!/usr/bin/env bash
# Start/restart the hexmap prototype (hexagonal MRU window switcher).
#
# This prototype lives in this repo and runs via `quickshell -p <this dir>`.
# Two things are set up here:
#
#   1. The Hyprland keybinds. The live ~/.config/hypr/*.lua files are normally
#      managed by home-manager (symlinks into /nix/store), so edits to the
#      git repo hyprland/ dir are NOT live until `home-manager switch`. To use
#      the hexmap SUPER+Tab bind immediately, this script REPLACES the
#      home-manager symlinks with symlinks pointing at this repo's hyprland/
#      files, then reloads Hyprland.
#
#   2. The Quickshell instance (the hexmap overlay), launched via `-p`.
#
# After running, open/cycle the overlay with:  SUPER + Tab
#   (also via IPC: qs ipc --path <shell.qml> call hexmap toggle)
#
# Run from anywhere — SCRIPT_DIR resolves to this file's location.

# no `set -e` / `set -u` — backgrounding quickshell and the IPC wait loop
# need permissive mode (see notes below).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTO_DIR="$SCRIPT_DIR"                                   # prototypes/hexmap (absolute)
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"              # git_repositories
HYPRLAND_REPO="$REPO_ROOT/hyprland"                       # the hyprland config repo

HYPR_CONFIG_DIR="$HOME/.config/hypr"
QUICKSHELL_DIR="$HOME/.config/quickshell"
HEXMAP_QML="$PROTO_DIR/shell.qml"

echo "=== hexmap manual start ==="

# ── 1. Re-point ~/.config/hypr/*.lua at THIS repo (break nix symlinks) ────
# The live hyprland config is home-manager managed (symlinks -> /nix/store).
# We replace the keymaps.lua / hyprland-user.lua (and their deps) with symlinks
# to the git repo so the hexmap SUPER+Tab bind is live without a full rebuild.
#
# NOTE: This OVERRIDES the home-manager symlinks until the next
# `home-manager switch` (which will re-point them at /nix/store). If you want
# to undo this manually later, run `home-manager switch` or delete these
# symlinks and let home-manager recreate them.

echo "Re-pointing hyprland config symlinks → $HYPRLAND_REPO ..."

# The hyprland-user.lua dofile()s monitors.lua and keymaps.lua from ~/.config/hypr.
# Point all of them at the repo so the whole config is coherent and matches git.
for f in hyprland.lua hyprland-user.lua keymaps.lua monitors.lua autocmds.lua; do
    if [ -f "$HYPRLAND_REPO/$f" ]; then
        # break existing symlink/file, then symlink to repo
        rm -f "$HYPR_CONFIG_DIR/$f"
        ln -sfn "$HYPRLAND_REPO/$f" "$HYPR_CONFIG_DIR/$f"
        echo "  linked $f → $HYPRLAND_REPO/$f"
    fi
done

# Reload Hyprland so the new keybinds (SUPER+Tab for hexmap) take effect.
echo "Reloading Hyprland config..."
hyprctl reload >/dev/null 2>&1 || echo "  (hyprctl reload returned non-zero; check hyprland logs)"

# ── 2. Stop only an existing hexmap instance (by its -p config path) ──────
echo "Stopping any existing hexmap instance..."

find_hexmap_pids() {
    {
        qs list --all 2>/dev/null | awk -v want="$HEXMAP_QML" '
            /^[[:space:]]*Process ID:/ { pid = $3 }
            /^[[:space:]]*Config path:/ { if (index($0, want) > 0) print pid }' || true
        for p in $(pgrep quickshell 2>/dev/null || true); do
            if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "prototypes/hexmap"; then
                echo "$p"
            fi
        done
    } | sort -u | grep -E '^[0-9]+$' || true
}

OLD_PIDS="$(find_hexmap_pids)"
if [ -n "$OLD_PIDS" ]; then
    echo "  stopping: $OLD_PIDS"
    kill $OLD_PIDS 2>/dev/null || true
    sleep 0.5
    REMAIN="$(find_hexmap_pids)"
    if [ -n "$REMAIN" ]; then
        echo "  force-killing: $REMAIN"
        kill -9 $REMAIN 2>/dev/null || true
        sleep 0.5
    fi
else
    echo "  no running hexmap instance."
fi

# ── 3. Locate Qt5Compat QML import path ────────────────────────────────────
if [ -z "$QML2_IMPORT_PATH" ]; then
    QT5COMPAT_PATH="$(ls -d /nix/store/*qt5compat*/lib/qt-6/qml 2>/dev/null | head -1)"
    if [ -n "$QT5COMPAT_PATH" ]; then
        export QML2_IMPORT_PATH="$QT5COMPAT_PATH"
        echo "Qt5Compat: $QML2_IMPORT_PATH"
    else
        echo "WARNING: QML2_IMPORT_PATH not set and qt5compat not found."
    fi
fi

# ── 4. Launch the hexmap Quickshell instance ───────────────────────────────
echo "Launching hexmap overlay..."
LOG_FILE="$PROTO_DIR/hexmap.log"
nohup quickshell -p "$PROTO_DIR" > "$LOG_FILE" 2>&1 < /dev/null &
echo "Logs: $LOG_FILE"

# Wait for the instance to register over IPC.
set +e   # `qs list | grep` can exit non-zero while still progressing
for i in $(seq 1 15); do
    if qs list --all 2>/dev/null | grep -q "$HEXMAP_QML"; then
        echo
        echo "hexmap is running (starts hidden)."
        echo "Open / cycle:  SUPER + Tab"
        echo "Direct IPC:    qs ipc --path '$HEXMAP_QML' call hexmap toggle"
        exit 0
    fi
    sleep 1
done

echo "Timed out waiting for hexmap to register over IPC."
exit 1
