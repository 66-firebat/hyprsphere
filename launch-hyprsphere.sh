#!/usr/bin/env bash
# Launch hyprsphere as a fullscreen overlay
# Requires: Quickshell + Qt Quick + Qt5Compat.GraphicalEffects

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Qt5Compat QML import path (may differ on your system)
export QML2_IMPORT_PATH="${QML2_IMPORT_PATH:+$QML2_IMPORT_PATH:}/nix/store/b542sz5kqs7kv3lqc8pl7id0rkk4ynmg-qt5compat-6.11.0/lib/qt-6/qml"

exec quickshell -p "$SCRIPT_DIR/hyprsphere.qml"
