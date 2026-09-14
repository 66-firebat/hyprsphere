#!/usr/bin/env bash
# Start/restart hyprsphere: symlink config, stop ONLY the hyprsphere
# quickshell instance, launch. Other quickshell configs (e.g.
# DankMaterialShell, which runs with `-p <dir>`) are left running.
# After this, open the overlay with:  qs ipc call hyprsphere toggle
#
# Run from anywhere — SCRIPT_DIR resolves to this file's location.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUICKSHELL_DIR="$HOME/.config/quickshell"

echo "=== hyprsphere manual start ==="

# ── Stop ONLY the hyprsphere quickshell instance ───────────────────────────
# hyprsphere is the 'default' quickshell config (~/.config/quickshell/shell.qml)
# and runs with no --path/-p argument. Other instances (e.g. DankMaterialShell
# runs `quickshell -p .../dms`) must NOT be killed.

HYPRSPHERE_QML="$QUICKSHELL_DIR/shell.qml"

find_hyprsphere_pids() {
    {
        # (a) instances registered over IPC for our config path
        qs list --all 2>/dev/null | awk -v want="$HYPRSPHERE_QML" '
            /^[[:space:]]*Process ID:/ { pid = $3 }
            /^[[:space:]]*Config path:/ { if (index($0, want) > 0) print pid }' || true
        # (b) fallback for an unregistered/orphaned default-config instance:
        #     a quickshell process with no "-" argument (DMS has `-p`).
        for p in $(pgrep quickshell 2>/dev/null || true); do
            if ! tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- ' -'; then
                echo "$p"
            fi
        done
    } | sort -u | grep -E '^[0-9]+$' || true
}

OLD_PIDS="$(find_hyprsphere_pids)"
if [ -n "$OLD_PIDS" ]; then
    echo "Stopping existing hyprsphere instance(s): $OLD_PIDS"
    kill $OLD_PIDS 2>/dev/null || true
    for i in $(seq 1 20); do
        if [ -z "$(find_hyprsphere_pids)" ]; then break; fi
        sleep 0.25
    done
    REMAIN="$(find_hyprsphere_pids)"
    if [ -n "$REMAIN" ]; then
        echo "Force-killing unresponsive instance(s): $REMAIN"
        kill -9 $REMAIN 2>/dev/null || true
        sleep 0.5
    fi
else
    echo "No running hyprsphere instance found."
fi

# ── Clean stale artifacts (old codebase, old nix-store symlinks) ─────────

echo "Cleaning stale artifacts..."
rm -f "$QUICKSHELL_DIR/binds.qml"           # old filename
rm -rf "$QUICKSHELL_DIR/shaders"            # old directory, no longer used

# ── Create fresh symlinks ─────────────────────────────────────────────────

mkdir -p "$QUICKSHELL_DIR"

# Files/directories that quickshell needs at runtime.
# lib/ and assets/ are directories (or symlinks to directories). `ln -sf`
# follows an existing symlink-to-directory and creates a nested link inside
# it instead of replacing it, which leaves a stale path in ~/.config.
# Remove them first and use `ln -sfn` (-n treats a symlink-to-dir as a file).
rm -rf "$QUICKSHELL_DIR/lib" "$QUICKSHELL_DIR/assets"
ln -sfn "$SCRIPT_DIR/shell.qml"        "$QUICKSHELL_DIR/shell.qml"
ln -sfn "$SCRIPT_DIR/binds.js"         "$QUICKSHELL_DIR/binds.js"
ln -sfn "$SCRIPT_DIR/effects.js"       "$QUICKSHELL_DIR/effects.js"
ln -sfn "$SCRIPT_DIR/rotations.js"     "$QUICKSHELL_DIR/rotations.js"
ln -sfn "$SCRIPT_DIR/hyprsphere.json"  "$QUICKSHELL_DIR/hyprsphere.json"
ln -sfn "$SCRIPT_DIR/lib"              "$QUICKSHELL_DIR/lib"
ln -sfn "$SCRIPT_DIR/assets"           "$QUICKSHELL_DIR/assets"

echo "Symlinks → $QUICKSHELL_DIR/:"
echo "  shell.qml  effects.js  binds.js  rotations.js  hyprsphere.json  lib/  assets/"

# ── Locate Qt5Compat QML import path ──────────────────────────────────────

if [ -z "$QML2_IMPORT_PATH" ]; then
    QT5COMPAT_PATH="$(ls -d /nix/store/*qt5compat*/lib/qt-6/qml 2>/dev/null | head -1)"
    if [ -n "$QT5COMPAT_PATH" ]; then
        export QML2_IMPORT_PATH="$QT5COMPAT_PATH"
        echo "Qt5Compat: $QML2_IMPORT_PATH"
    else
        echo "WARNING: QML2_IMPORT_PATH not set and qt5compat not found in /nix/store."
        echo "Set it manually or the overlay may fail to render."
    fi
fi

# ── Launch ────────────────────────────────────────────────────────────────

echo "Launching quickshell..."
LOG_FILE="$QUICKSHELL_DIR/hyprsphere.log"
quickshell > "$LOG_FILE" 2>&1 &
echo "Logs: $LOG_FILE"

for i in $(seq 1 15); do
    # match the hyprsphere config path specifically (DMS is also *.qml)
    if qs list --all 2>/dev/null | awk -v want="$HYPRSPHERE_QML" '
        /^[[:space:]]*Config path:/ { if (index($0, want) > 0) found = 1 }
        END { exit !found }'; then
        echo
        echo "hyprsphere is running."
        echo "Open overlay:  qs ipc call hyprsphere toggle"
        exit 0
    fi
    sleep 1
done

echo "Timed out waiting for hyprsphere to start."
exit 1
