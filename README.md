# hyprsphere

A 3D window switcher for Hyprland/Quickshell. Running apps and windows are
arranged on a Fibonacci sphere with drag-to-rotate, search, keyboard-driven
selection animation, and a satellite detail view.

**Runtime:** [Quickshell](https://github.com/Quickshell/Quickshell) + Qt Quick

---

## Features

- **Alt+Tab** — open the sphere overlay with all running apps grouped by
  application ID. Pre-selects the previously focused app (MRU index 1).
- **Tab / Shift+Tab** — cycle forward/backward through sphere nodes while
  holding Alt. Wraps around at the edges.
- **`;` (semicolon)** — drill down into an app's individual windows (layer 1).
  Press `;` again to return to the app list.
- **Type any letter** while holding Alt — enters search mode (layer 2).
  Fuzzy-filters across all running apps, whitelisted apps, and window
  titles using Fuse.js. Results ordered: running apps → whitelisted apps
  → windows.
- **Backspace** — remove last search character. Empty field returns to app
  list (layer 0).
- **Escape** — close overlay without switching.
- **Alt release** — commit the selected app or window and focus it.
- **Ctrl+C** — close the selected window(s). At layer 0, closes all windows
  of the selected app. At layer 1, closes the specific window.
- **Mouse drag** — rotate the sphere.
- **Click** — select a node and center the sphere on it.
- **Double-click** — commit the selected node (same as Alt release).

---

## Requirements

- Hyprland 0.55+ (Lua config)
- Quickshell 0.3.0+
- Qt 6 + Qt5Compat (`qt5compat`)
- Fuse.js v7.0.0 (bundled in `lib/fuse.js`)

On NixOS, Quickshell and Qt5Compat are typically provided by the system
or via `nix-shell`.

---

## Installation

### 1. Clone the repository

```bash
git clone <repo-url> /home/fireshark/hyprsphere
cd /home/fireshark/hyprsphere
```

### 2. Create symlinks for Quickshell

Quickshell requires the config file to be in `~/.config/quickshell/` for
IPC (`qs ipc call`) to work. The `-p` flag breaks IPC, so we use symlinks:

```bash
mkdir -p ~/.config/quickshell
ln -sf /home/fireshark/hyprsphere/hyprsphere.qml ~/.config/quickshell/shell.qml
ln -sf /home/fireshark/hyprsphere/lib ~/.config/quickshell/lib
```

Replace `/home/fireshark/hyprsphere` with the actual path to your clone.

### 3. Qt5Compat QML import path

Quickshell needs the Qt5Compat QML module (specifically
`Qt5Compat.GraphicalEffects`) for certain visual effects. Set the
`QML2_IMPORT_PATH` environment variable to point to the Qt5Compat QML
directory before starting Quickshell:

```bash
export QML2_IMPORT_PATH="/path/to/qt5compat/lib/qt-6/qml"
```

#### Finding your Qt5Compat path

**NixOS / Nix:**
```bash
ls -d /nix/store/*qt5compat*/lib/qt-6/qml 2>/dev/null
```
This lists all Qt5Compat QML paths in your Nix store. Pick one and set
it as `QML2_IMPORT_PATH`.

**Arch Linux (qt5compat from AUR or extra):**
```bash
pacman -Ql qt5compat 2>/dev/null | grep 'qt-6/qml' | head -1 | cut -d' ' -f2
# or find the installed path:
pkg-config --variable=libdir Qt5Compat 2>/dev/null
# common path:
ls -d /usr/lib/qt6/qml/Qt5Compat* 2>/dev/null
```

**Debian/Ubuntu (qt6-base-dev or similar):**
```bash
dpkg -L qt6-base-dev 2>/dev/null | grep 'qt5compat' | head -1
# or check common locations:
ls -d /usr/lib/*/qt6/qml/Qt5Compat* 2>/dev/null
ls -d /usr/lib/qt6/qml/Qt5Compat* 2>/dev/null
```

**Fedora (qt6-qt5compat):**
```bash
rpm -ql qt6-qt5compat 2>/dev/null | grep qt-6/qml | head -1
# or:
ls -d /usr/lib64/qt6/qml/Qt5Compat* 2>/dev/null
```

**Manual search (any distro):**
```bash
find /usr -path '*/Qt5Compat*' -type d 2>/dev/null | head -5
```

If all else fails, look for any directory named `Qt5Compat` or
`qt5compat` under your Qt QML installation and point
`QML2_IMPORT_PATH` to its parent chain ending in `qt-6/qml`.
The `manual_start.sh` script included in this repo will attempt to
auto-detect the path on NixOS, but for other distros you'll need to
set it yourself.

### 4. Add required keybinds to `keymaps.lua`

In your Hyprland Lua config file (typically `~/.config/hypr/keymaps.lua`
or similar), add the following:

```lua
-- =============================================================================
-- hyprsphere — Alt+Tab overlay window switcher
-- =============================================================================

-- Open overlay and enter submap (blocks global ALT+letter binds during search)
hl.bind("ALT + Tab", function()
    hl.dispatch(hl.dsp.submap("hyprsphere"))
    hl.dispatch(hl.dsp.exec_cmd("qs ipc call hyprsphere toggle"))
end)

-- Submap definition — active while hyprsphere overlay is open.
-- Inside the submap, only Alt release and Escape are bound.
-- All other keys (including letter keys for search) pass through to QML.
hl.define_submap("hyprsphere", function()
    -- Alt release: commit the selected node (focus window or launch app)
    -- Submap reset is handled by QML via hyprctl eval
    hl.bind("ALT + Alt_L", function()
        hl.dispatch(hl.dsp.exec_cmd("qs ipc call hyprsphere commit"))
    end, { release = true })
    hl.bind("ALT + Alt_R", function()
        hl.dispatch(hl.dsp.exec_cmd("qs ipc call hyprsphere commit"))
    end, { release = true })

    -- Escape: close overlay without switching, reset submap
    hl.bind("Escape", function()
        hl.dispatch(hl.dsp.exec_cmd("qs ipc call hyprsphere cancel"))
        hl.dispatch(hl.dsp.submap("reset"))
    end)
end)

-- IMPORTANT: Remove or comment out any existing ALT + Alt_L / ALT + Alt_R
-- release binds from the global scope. They are now handled by the submap:
--   hl.bind("ALT + Alt_L", ..., { release = true })  -- REMOVE from global scope
--   hl.bind("ALT + Alt_R", ..., { release = true })  -- REMOVE from global scope
```

Make sure no other bind in your config uses `ALT + Tab` — it will conflict.

### 5. Start Quickshell

```bash
QML2_IMPORT_PATH="/path/to/qt5compat/lib/qt-6/qml" quickshell &
```

Quickshell loads `~/.config/quickshell/shell.qml` automatically. No flags
needed. The overlay starts invisible and waits for the first `ALT + Tab`.

### 6. Autostart at login

Add to your Hyprland Lua config:

```lua
hl.on("hyprland.start", function()
    hl.exec_cmd("bash -c '"
        .. "ln -sf /path/to/hyprsphere/hyprsphere.qml $HOME/.config/quickshell/shell.qml; "
        .. "ln -sf /path/to/hyprsphere/lib $HOME/.config/quickshell/lib; "
        .. "export QML2_IMPORT_PATH=\"${QML2_IMPORT_PATH:+$QML2_IMPORT_PATH:}/path/to/qt5compat/lib/qt-6/qml\"; "
        .. "quickshell'")
end)
```

Or use your desktop environment's autostart mechanism with a desktop file
or startup script.

---

## Configuration

All configurable settings are in `hyprsphere.json`:

- **`colors`** — Catppuccin Mocha theme colors (customizable)
- **`scaler`** — Responsive scaling reference width and limits
- **`sizes`** — Various UI element sizes
- **`satellite`** — Satellite detail card dimensions
- **`sphere`** — Sphere radius, rotation limits, zoom settings
- **`animations`** — Animation durations and easing curves
- **`mouse`** — Drag sensitivity
- **`searchBar`** — Search bar dimensions, colors, opacity, shadow
- **`search`** — Fuse.js fuzzy search parameters and debounce delay
- **`appCard`** — App card label background opacity
- **`cardTilt`** — Tilt angles, scale, and opacity for sphere cards
- **`stars`** — Background stars count and opacity range
- **`whitelist`** — Apps that always appear on the sphere even when not
  running (e.g., blender, kicad, sioyek). Committing launches them.

### Search config reference

```json
{
  "searchBar": {
    "width": 560,
    "height": 56,
    "borderRadius": 28,
    "bottomMargin": 63,
    "borderWidth": 1.5,
    "backgroundOpacity": 0.92,
    "shadowOpacity": 0.4,
    "shadowBlur": 1.5,
    "placeholderText": "Search apps and windows...",
    "placeholderColor": "#6c7086"
  },
  "search": {
    "delayMs": 150,
    "maxResults": 30,
    "fuseThreshold": 0.4,
    "fuseMinMatchCharLength": 1,
    "layer2Zoom": 1.5
  }
}
```

---

## Usage

| Key | Action |
|---|---|
| `ALT + Tab` | Open overlay / cycle forward |
| `Shift + Tab` (while Alt held) | Cycle backward |
| `;` | Drill down into app's windows / toggle back |
| Any letter/digit | Search (layer 2) |
| `Backspace` | Remove last search char / return to layer 0 |
| `Ctrl + C` | Close selected window(s) |
| `Escape` | Close overlay |
| `Alt` (release) | Commit selection |
| Mouse click | Select node |
| Mouse double-click | Commit selection |
| Mouse drag | Rotate sphere |

---

## Troubleshooting

### "Could not load icon"
This is harmless. It means the icon theme doesn't have an icon for a
particular appId. The app still works — it just shows a generic fallback
icon.

### IPC doesn't work (`qs ipc call` fails)
Make sure:
1. Quickshell was started **without** the `-p` flag
2. The symlink `~/.config/quickshell/shell.qml` exists and points to
   `hyprsphere.qml`
3. Quickshell is running (`qs list --all`)

### ALT + Tab opens overlay but letter keys still trigger Hyprland binds
The submap is not being entered. Check:
1. The `ALT + Tab` bind in `keymaps.lua` is a Lua **function** (not a direct
   dispatcher)
2. It calls `hl.dispatch(hl.dsp.submap("hyprsphere"))` before the IPC command
3. The `hyprsphere` submap is defined with `hl.define_submap("hyprsphere",
   function() ... end)`
4. Run `hyprctl configerrors` to check for Lua syntax errors

### After committing a whitelisted app or placeholder, ALT + Tab doesn't work
The submap wasn't reset. This was a known bug fixed by adding `hyprctl eval`
calls in the QML commit paths. Make sure you're running the latest version
of `hyprsphere.qml`.
