#!/usr/bin/env bash
# hexmap test script — exercises the toggle/swap IPC directly.
# Usage: bash prototypes/hexmap/test.sh [status|next|prev|toggle|open|close]
#
# This verifies the hexmap overlay's swap logic works via IPC, independent of
# the Hyprland keybind layer. If `next`/`prev` change the focused item here,
# then any keybind problem is in the Hyprland submap, not the QML.

set -e

IPATH="/home/fireshark/nixos-dotfiles/git_repositories/hyprsphere/prototypes/hexmap/shell.qml"

call() { qs ipc --path "$IPATH" call hexmap "$@"; }

case "${1:-status}" in
    toggle) call toggle ;;
    open)   call toggle ;;   # first toggle opens (overlay starts hidden)
    next)   call next ;;
    prev)   call prev ;;
    status) call status ;;
    commit) call commit ;;
    cancel) call cancel ;;
    # full cycle test: open, advance 4, back 1, print internal state each time
    cycle)
        call toggle; sleep 0.4; call status
        for i in 1 2 3 4; do call next; sleep 0.3; call status; done
        call prev; sleep 0.3; call status
        ;;
    *)
        echo "usage: $0 {toggle|open|next|prev|status|commit|cancel|cycle}"
        exit 1
        ;;
esac
