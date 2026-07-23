#!/usr/bin/env bash
# Start hyprsphere: kill old instances, symlink config, launch.
# After this, open the overlay with:  qs ipc call hyprsphere toggle
#
# Run from anywhere — SCRIPT_DIR resolves to this file's location.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUICKSHELL_DIR="$HOME/.config/quickshell"

echo "=== hyprsphere manual start ==="

# ── Kill any existing quickshell instances ─────────────────────────────────

echo "Killing existing quickshell processes..."
pkill quickshell 2>/dev/null || true
pkill -f "/nix/store.*quickshell/bin/quickshell" 2>/dev/null || true
sleep 1

# ── Clean stale artifacts (old codebase, old nix-store symlinks) ─────────

echo "Cleaning stale artifacts..."
rm -f "$QUICKSHELL_DIR/binds.qml"           # old filename
rm -rf "$QUICKSHELL_DIR/shaders"            # old directory, no longer used

# ── Create fresh symlinks ─────────────────────────────────────────────────

mkdir -p "$QUICKSHELL_DIR"

# Files/directories that quickshell needs at runtime
ln -sf "$SCRIPT_DIR/shell.qml"        "$QUICKSHELL_DIR/shell.qml"
ln -sf "$SCRIPT_DIR/binds.js"         "$QUICKSHELL_DIR/binds.js"
ln -sf "$SCRIPT_DIR/effects.js"       "$QUICKSHELL_DIR/effects.js"
ln -sf "$SCRIPT_DIR/rotations.js"     "$QUICKSHELL_DIR/rotations.js"
ln -sf "$SCRIPT_DIR/hyprsphere.json"  "$QUICKSHELL_DIR/hyprsphere.json"
ln -sf "$SCRIPT_DIR/lib"              "$QUICKSHELL_DIR/lib"
ln -sf "$SCRIPT_DIR/assets"           "$QUICKSHELL_DIR/assets"

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
quickshell &

for i in $(seq 1 10); do
    if qs list --all 2>/dev/null | grep -q "shell.qml"; then
        echo
        echo "hyprsphere is running."
        echo "Open overlay:  qs ipc call hyprsphere toggle"
        exit 0
    fi
    sleep 1
done

echo "Timed out waiting for hyprsphere to start."
exit 1
