#!/usr/bin/env bash
# Start hyprsphere: kill old instances, symlink config, launch.
# After this, open the overlay with:  qs ipc call hyprsphere toggle
#
# This script uses relative paths — it must be run from within the
# hyprsphere repository directory.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Kill any existing quickshell instances running our config
echo "Killing existing hyprsphere processes..."
pkill quickshell 2>/dev/null; sleep 1
# Also clean up any orphaned quickshell-logged instances
pkill -f "/nix/store.*quickshell/bin/quickshell" 2>/dev/null || true
sleep 1

# Ensure the symlinks exist for IPC discovery
mkdir -p "$HOME/.config/quickshell"
ln -sf "$SCRIPT_DIR/shell.qml"        "$HOME/.config/quickshell/shell.qml"
ln -sf "$SCRIPT_DIR/binds.js"         "$HOME/.config/quickshell/binds.js"
ln -sf "$SCRIPT_DIR/effects.js"       "$HOME/.config/quickshell/effects.js"
rm -f  "$HOME/.config/quickshell/hyprsphere.json"
ln -sf "$SCRIPT_DIR/hyprsphere.json" "$HOME/.config/quickshell/hyprsphere.json"
rm -rf "$HOME/.config/quickshell/lib"
ln -sf "$SCRIPT_DIR/lib"              "$HOME/.config/quickshell/lib"
echo "Symlinks created:"
echo "  $HOME/.config/quickshell/shell.qml        -> shell.qml"
echo "  $HOME/.config/quickshell/binds.js         -> binds.js"
echo "  $HOME/.config/quickshell/effects.js       -> effects.js"
echo "  $HOME/.config/quickshell/hyprsphere.json  -> hyprsphere.json"
echo "  $HOME/.config/quickshell/lib              -> lib/"

# Locate the Qt5Compat QML import path for Quickshell
# This is typically provided by a system package (e.g. qt5compat on Nix).
# Falls back to QML2_IMPORT_PATH if already set.
if [ -z "$QML2_IMPORT_PATH" ]; then
    QT5COMPAT_PATH="$(ls -d /nix/store/*qt5compat*/lib/qt-6/qml 2>/dev/null | head -1)"
    if [ -n "$QT5COMPAT_PATH" ]; then
        export QML2_IMPORT_PATH="$QT5COMPAT_PATH"
        echo "Found Qt5Compat: $QML2_IMPORT_PATH"
    else
        echo "WARNING: QML2_IMPORT_PATH not set and couldn't find qt5compat in /nix/store."
        echo "Set QML2_IMPORT_PATH manually or the overlay may fail to render."
    fi
fi

echo "Starting hyprsphere..."
quickshell &

# Wait for it to be ready
for i in $(seq 1 10); do
    if qs list --all 2>/dev/null | grep -q "shell.qml"; then
        echo "hyprsphere is running."
        echo "Open overlay:  qs ipc call hyprsphere toggle"
        exit 0
    fi
    sleep 1
done

echo "Timed out waiting for hyprsphere to start."
exit 1
