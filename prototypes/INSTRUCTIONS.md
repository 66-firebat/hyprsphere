# hyprsphere — Hex Map Prototype

This directory contains an isolated **UI prototype** for a hexagonal-onsphere
window-switcher map (an experimental replacement for the sphere in the main
`hyprsphere` project). It is self-contained and does **not** touch the main
`shell.qml`.

## What it is

- `prototypes/hexmap/shell.qml` — a Quickshell `PanelWindow` overlay that renders
  a gap-free hexagonal grid wrapped onto a 3D sphere (transparent background,
  opaque `#ff4400` hex tiles).
- Each hexagon shows a **Nerd Font glyph** (single-cell "JetBrainsMono Nerd Font
  Mono") drawn via Canvas `fillText`.
- `Tab` / `Shift+Tab` **spin** the sphere so the next MRU item's face glides
  front-and-center (150 ms). `Esc` quits.
- It is a **UI-only** prototype: sample MRU data, no Hyprland focus/MRU/IPC
  wiring, no mouse, no search, no layers yet.

## How to run it

The prototype is a standalone Quickshell config, launched by **path** with
`quickshell -p`. It must NOT be confused with the default hyprsphere config
(`~/.config/quickshell/shell.qml`) or the DMS shell.

```bash
# 1. Ensure Qt5Compat QML import path is set (for GraphicalEffects etc.):
export QML2_IMPORT_PATH="$(ls -d /nix/store/*qt5compat*/lib/qt-6/qml 2>/dev/null | head -1)"

# 2. Launch the prototype (detached so you can keep using the terminal):
setsid quickshell -p prototypes/hexmap/ > /tmp/hexmap_proto.log 2>&1 < /dev/null &
echo $! > /tmp/hexmap_proto.pid
```

Or non-detached (foreground, for debugging):

```bash
QML2_IMPORT_PATH="$(ls -d /nix/store/*qt5compat*/lib/qt-6/qml 2>/dev/null | head -1)" \
  quickshell -p prototypes/hexmap/
```

### Stop it

```bash
kill "$(cat /tmp/hexmap_proto.pid)"    # if launched via the setsid pattern above
# or press Esc while the overlay has focus
```

`Esc` quits the prototype (it is wired to `Qt.quit()`). There is no auto-timeout
in the current version, so **always kill it when done** or press Esc.

### Notes / gotchas

- The process may appear to "die" — that is usually just the user pressing `Esc`
  (closing the overlay), not a crash. Check the log at `/tmp/hexmap_proto.log`
  for a real error before assuming a failure.
- `grim` screenshots show the overlay only when it is actually running/spawned;
  screenshot **after** the spawn (and confirm the PID is alive) or you will
  capture the bare desktop.
- Qt's Canvas 2D context resolves fonts by **family name**, not the QML alias:
  use `"JetBrainsMono Nerd Font Mono"` (verify with `fc-list | grep -i jetbrains`),
  not `"JetBrains Mono"`.
- The hexagons are drawn in **one Canvas** (gap-free, shared vertices); do NOT
  switch glyphs/faces to separate QML `Item`s — that reintroduces per-item
  animation drift and breaks the locked-together appearance. Keep all mesh +
  glyph drawing inside the single `Canvas.onPaint`.

## Controls

| Key | Action |
|-----|--------|
| `Tab` | spin to next MRU item (front-and-center) |
| `Shift+Tab` | spin to previous MRU item |
| `Esc` | quit (close overlay) |
