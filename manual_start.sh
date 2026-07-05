#!/usr/bin/env bash
# Start hyprsphere: kill old instances, symlink config, launch.
# After this, open the overlay with:  qs ipc call hyprsphere toggle

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kill any existing quickshell instances running our config
echo "Killing existing hyprsphere processes..."
pkill -f "quickshell.*shell.qml" 2>/dev/null || true
sleep 1

# Ensure the symlink exists for IPC discovery
mkdir -p "$HOME/.config/quickshell"
ln -sf "$SCRIPT_DIR/hyprsphere.qml" "$HOME/.config/quickshell/shell.qml"
echo "Symlink: $HOME/.config/quickshell/shell.qml -> hyprsphere.qml"

# Qt5Compat QML import path (may differ on your system)
export QML2_IMPORT_PATH="${QML2_IMPORT_PATH:+$QML2_IMPORT_PATH:}/nix/store/b542sz5kqs7kv3lqc8pl7id0rkk4ynmg-qt5compat-6.11.0/lib/qt-6/qml"

echo "Starting hyprsphere..."
quickshell &

# Wait for it to be ready
for i in $(seq 1 10); do
    if quickshell list --all 2>/dev/null | grep -q "shell.qml"; then
        echo "hyprsphere is running."
        echo "Open overlay:  qs ipc call hyprsphere toggle"
        exit 0
    fi
    sleep 1
done

echo "Timed out waiting for hyprsphere to start."
exit 1
