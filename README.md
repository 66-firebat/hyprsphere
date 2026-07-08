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
ln -sf /path/to/hyprsphere/shell.qml ~/.config/quickshell/shell.qml
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
        .. "ln -sf /path/to/hyprsphere/shell.qml $HOME/.config/quickshell/shell.qml; "
        .. "ln -sf /path/to/hyprsphere/lib $HOME/.config/quickshell/lib; "
        .. "export QML2_IMPORT_PATH=\"${QML2_IMPORT_PATH:+$QML2_IMPORT_PATH:}/path/to/qt5compat/lib/qt-6/qml\"; "
        .. "quickshell'")
end)
```

Or use your desktop environment's autostart mechanism with a desktop file
or startup script.

### 7. Using `manual_start.sh`

The repository includes a `manual_start.sh` script that handles everything
automatically — killing old instances, creating symlinks, and launching
quickshell:

```bash
cd /path/to/hyprsphere
bash manual_start.sh
```

After running, the overlay is ready. Open it with:

```bash
qs ipc call hyprsphere toggle
```

The script performs these steps:

1. **Kills** any existing quickshell processes
2. **Creates symlinks** in `~/.config/quickshell/` pointing to your
   repository files (`shell.qml`, `hyprsphere.json`, `lib/`)
3. **Auto-detects** the Qt5Compat QML import path on NixOS
4. **Starts** quickshell and waits for it to register for IPC

**NixOS note:** This script replaces any Nix-managed symlinks in
`~/.config/quickshell/` with direct symlinks to your repository.
To restore the Nix-generated symlinks (e.g., after rebuilding your
system or switching configurations), you need to:

```bash
rm -rf ~/.config/quickshell
# Then rebuild your Nix configuration:
nixos-rebuild switch  # or: darwin-rebuild, home-manager switch, etc.
```

---

## Configuration

All configurable settings are in `hyprsphere.json`. Below is every option
organized by section.

### `colors` — Catppuccin Mocha theme

| Field | Default | Description |
|---|---|---|
| `base` | `"#1e1e2e"` | Background color |
| `mantle` | `"#181825"` | Slightly darker background variant |
| `crust` | `"#11111b"` | Darkest background variant |
| `surface0` | `"#313244"` | Surface/raised element color |
| `surface1` | `"#45475a"` | Brighter surface variant |
| `surface2` | `"#585b70"` | Subtle/hover surface variant |
| `text` | `"#cdd6f4"` | Primary text color |
| `subtext0` | `"#a6adc8"` | Subdued text color |
| `blue` | `"#89b4fa"` | Blue accent |
| `mauve` | `"#cba6f7"` | Mauve/purple accent |
| `teal` | `"#94e2d5"` | Teal accent |
| `overlay0` | `"#6c7086"` | Overlay/subtle element color |
| `peach` | `"#fab387"` | Peach/orange accent |
| `yellow` | `"#f9e2af"` | Yellow accent |
| `sapphire` | `"#74c7ec"` | Sapphire/blue accent |

### `scaler` — Responsive scaling

| Field | Default | Description |
|---|---|---|
| `referenceWidth` | `1920` | Reference screen width for 1:1 scaling |
| `minRatio` | `0.5` | Minimum scale ratio (at very small screens) |
| `maxRatio` | `2.0` | Maximum scale ratio (at very large screens) |

### `sizes` — Base size tokens (used internally by the scaler)

| Field | Default | Description |
|---|---|---|
| `s2`–`s104` | various | Named sizes (2, 3, 4, 5, 8, 9, 10, 11, 12, 15, 16, 18, 20, 28, 40, 50, 55, 56, 63, 74, 104) used throughout the UI. All scaled by the responsive scaler. |

### `satellite` — Detail card (selected app/window)

| Field | Default | Description |
|---|---|---|
| `hullWidth` | `216` | Width of the satellite card background |
| `hullHeight` | `148` | Height of the satellite card background |
| `panelWidth` | `64` | Width of decorative solar panels |
| `panelHeight` | `51` | Height of decorative solar panels |
| `strutWidth` | `10` | Width of decorative struts |
| `strutHeight` | `4` | Height of decorative struts |
| `antennaHeight` | `16` | Height of decorative antenna |
| `thrusterHeight` | `11` | Height of decorative thruster |
| `radius12` | `10` | Corner radius (12px base) for hull elements |
| `radius8` | `7` | Corner radius (8px base) for panel elements |
| `radius4` | `3` | Corner radius (4px base) for fine details |
| `antBall` | `6` | Diameter of the antenna tip ball |
| `antStick` | `2` | Width of the antenna mast |
| `antOffX` | `14` | Horizontal offset of the antenna from center |
| `screenMargin` | `8` | Margin inside the card for screen content |
| `innerMargin` | `10` | Inner margin for content layout |
| `iconSize` | `160` | Size of the satellite card's app icon |
| `fontSize` | `10` | Font size of the satellite card label |
| `thrusterBase` | `16` | Width of the thruster base |
| `spacing` | `5` | Spacing between satellite card elements |
| `extraHeight` | `11` | Additional height above the hull for decorative elements |
| `hullBorderWidth` | `1.5` | Border width of the satellite card hull |
| `selectedBackground` | `false` | Show SVG decoration behind the satellite icon |

### `sphere` — 3D sphere layout

| Field | Default | Description |
|---|---|---|
| `baseRadius` | `360` | Base radius of the Fibonacci sphere in pixels |
| `initialZoom` | `1.0` | Initial zoom level when overlay opens |
| `zoomDurationMs` | `400` | Duration of zoom animations in ms |
| `zoomEasing` | `"OutCubic"` | Easing curve for zoom animations |
| `initialRotX` | `-0.2` | Initial X-axis rotation (radians) |
| `initialRotY` | `0` | Initial Y-axis rotation (radians) |
| `maxRotationX` | `2.5` | Maximum X-axis rotation limit (drag) |
| `maxRotationY` | `1.45` | Maximum Y-axis rotation limit (drag) |
| `zoomFactorWeight` | `0.45` | How much zoom affects node scale (0-1) |
| `normalizationConstant` | `310.5` | Tilt calculation normalization factor |
| `autoRadius.enabled` | `false` | Enable adaptive sphere radius based on node count |
| `autoRadius.minRadius` | `160` | Smallest sphere radius when adaptive (few nodes) |
| `autoRadius.maxNodeCount` | `20` | Node count at which adaptive radius reaches `baseRadius` |

### `animations` — Timing and easing

| Field | Default | Description |
|---|---|---|
| `searchRotateDurationMs` | `250` | Duration of sphere rotation to center on a search result (ms) |
| `sphereAutoRotateIntervalMs` | `16` | Interval of the auto-rotation timer (ms, ~60 FPS) |
| `sphereRotateSpeed` | `0.002` | Radians per tick for auto-rotation |
| `cardFadeDurationMs` | `200` | Duration of card opacity transitions (ms) |
| `cardScaleDurationMs` | `200` | Duration of card scale transitions (ms) |
| `satelliteFadeDurationMs` | `400` | Duration of satellite card fade-in/out (ms) |
| `satelliteScaleDurationMs` | `450` | Duration of satellite card scale-up animation (ms) |
| `satelliteInitialScale` | `0.4` | Starting scale of the satellite card (animates up) |
| `satelliteTargetScale` | `1.5` | Final scale of the satellite card |
| `entranceFadeDurationMs` | `800` | Duration of the overlay's entrance fade animation (ms) |
| `exitFadeDurationMs` | `400` | Duration of the overlay's exit fade animation (ms) |
| `borderColorDurationMs` | `150` | Duration of card border color transitions (ms) |

### `mouse` — Interaction

| Field | Default | Description |
|---|---|---|
| `dragSensitivity` | `0.005` | Mouse drag rotation sensitivity |

### `searchBar` — Search input appearance

| Field | Default | Description |
|---|---|---|
| `width` | `560` | Width of the search bar rectangle |
| `height` | `56` | Height of the search bar rectangle |
| `borderRadius` | `28` | Corner radius of the search bar (pill shape) |
| `bottomMargin` | `63` | Distance from the search bar to the bottom of the screen |
| `borderWidth` | `1.5` | Border width of the search bar |
| `backgroundColor` | `"#ff4400"` | Background color of the search bar (used with `backgroundOpacity`) |
| `backgroundOpacity` | `0.3` | Background opacity of the search bar (0-1) |
| `borderColor` | `"#2b2b2b"` | Border color when search is empty |
| `activeBorderColor` | `"#ff4400"` | Border color when search has text |
| `textColor` | `"#ff4400"` | Color of typed search text |
| `shadowOpacity` | `0.4` | Opacity of the drop shadow below the search bar |
| `shadowBlur` | `1.5` | Blur radius of the drop shadow |
| `placeholderText` | `"Search apps and windows..."` | Placeholder text when search is empty |
| `placeholderColor` | `"#ff4400"` | Color of the placeholder text |

### `search` — Fuse.js fuzzy search

| Field | Default | Description |
|---|---|---|
| `delayMs` | `150` | Debounce delay before executing search after keystroke (ms) |
| `maxResults` | `30` | Maximum results returned from Fuse.js |
| `fuseThreshold` | `0.4` | Fuse.js match threshold (0=perfect, 1=anything) |
| `fuseMinMatchCharLength` | `1` | Minimum character length for a Fuse.js match |
| `ignoreLocation` | `true` | When `true`, search terms can match anywhere in the text — no penalty for distance from the start of the string. Crucial for long window titles. |
| `layer2Zoom` | `1.5` | Zoom level applied to the sphere during search (layer 2) |

### `appCard` — Sphere card appearance

| Field | Default | Description |
|---|---|---|
| `labelBgOpacity` | `0.60` | Background opacity of the label rectangle on non-selected cards |
| `nonSelectedIconSize` | `110` | Size of the app icon on non-selected sphere cards |
| `appIconOpacity` | `1.0` | Opacity of app group icons on non-selected cards (layer 0). Range 0–1. |
| `cardBorderColor` | `"transparent"` | Border colour of non-selected cards on hover. Set to a hex like `"#45475a"` to show a coloured border on hover, or keep `"transparent"` for no border. |
| `windowIconOpacity` | `1.0` | Opacity of icons on window nodes (layer 1/layer 2) — app icons use `appIconOpacity` |
| `satelliteAppLabel` | `false` | Show label on the satellite card for app nodes (window nodes always show) |
| `labelBgColor` | `"#ff4400"` | Background color of the label rectangle on non-selected cards and satellite |
| `labelTextColor` | `"#2b2b2b"` | Text color of the label rectangle |
| `labelBgOpacity` | `0.5` | Opacity of the label background pill (0-1) |
| `nonSelectedLayerLabels.layer_0` | `false` | Show labels on non-selected cards at layer 0 (app list) |
| `nonSelectedLayerLabels.layer_1` | `true` | Show labels on non-selected cards at layer 1 (window drill-down) |
| `nonSelectedLayerLabels.layer_2` | `true` | Show labels on non-selected cards at layer 2 (search results) |
| `windowCountBadge.satellite` | `true` | Show badge on the satellite (selected) card |
| `windowCountBadge.nonSelected` | `false` | Show badge on non-selected sphere cards |
| `windowCountBadge.offsetY` | `55` | Vertical offset of the badge from icon center (negative = up) |
| `windowCountBadge.offsetX` | `0` | Horizontal offset of the badge from icon center (negative = left) |
| `windowCountBadge.fontSize` | `18` | Font size of the badge text |
| `windowCountBadge.padding` | `14` | Total extra space around badge text (symmetric, keeps it circular) |
| `windowCountBadge.color` | `"#ff4400"` | Foreground text color of app window-count badges (prepended with `+`) |
| `windowCountBadge.bgColor` | `"#2b2b2b"` | Background pill color of app window-count badges |
| `windowCountBadge.bgOpacity` | `1.0` | Background opacity of app window-count badges (0-1) |
| `windowCountBadge.windowColor` | `"#ff4400"` | Foreground text color of window index badges (plain number, no `+`) |
| `windowCountBadge.windowBgColor` | `"#2b2b2b"` | Background pill color of window index badges |
| `windowCountBadge.windowBgOpacity` | `1.0` | Background opacity of window index badges (0-1) |

### `cardTilt` — 3D card tilt effects

| Field | Default | Description |
|---|---|---|
| `maxAngleX` | `45` | Maximum X-axis tilt angle (degrees) for cards at sphere edges |
| `maxAngleY` | `35` | Maximum Y-axis tilt angle (degrees) for cards at sphere edges |
| `baseScaleAtEdge` | `0.78` | Scale of cards at the far edge of the sphere (z=0) |
| `scaleIncreaseTowardCenter` | `0.22` | Additional scale added as cards approach the front center (z=1) |
| `hoverScaleMultiplier` | `1.12` | Scale multiplier when hovering over a non-selected card |
| `depthOpacityMultiplier` | `4.0` | How quickly cards fade as they rotate behind the sphere (higher = sharper falloff) |
| `nonMatchOpacity` | `0.15` | Opacity of non-matching results during search |

### `whitelist` — Persistent app dock

Each entry is an object with the following fields. Whitelisted apps always
appear on the sphere even when not running. If they ARE running, the entry
is deduplicated and shown in its normal MRU position.

| Field | Description |
|---|---|
| `appId` | App identifier (must match Hyprland's `wayland.appId` for dedup) |
| `label` | Human-readable label displayed on the card |
| `icon` | Freedesktop icon name (fed to `image://icon/...`) |
| `exec` | Shell command to launch the app (e.g., `"firefox"`). This is the **primary** launch command — if the command contains double quotes, they must be escaped for Lua (`\"`) in the JSON value (see [Exec quoting for Lua dispatch](#exec-quoting-for-lua-dispatch) below). |

#### Example
```json
{
  "appId": "firefox",
  "label": "Firefox",
  "icon": "firefox",
  "exec": "firefox"
}
```

### Exec quoting for Lua dispatch

When a whitelisted entry is committed, the `exec` command is passed to
Hyprland's Lua API via `exec_cmd("...")`. This means the command string
appears inside Lua double-quote delimiters:

```lua
hl.dsp.exec_cmd("<command>", { maximize = true })
```

If your `exec` command contains **double quotes** (e.g., `"$XDG_RUNTIME_DIR"`
or `"(my/eat-new)"`), they must be escaped so Lua treats them as literal
characters rather than string terminators. In the JSON value, write `\\"`
for each embedded double quote:

| Intended character | Write in JSON | Lua sees |
|---|---|---|
| `"` (literal double quote) | `\\"` | `\"` (escaped, kept as part of string) |

**Example:** A desktop file `Exec=` line like:
```
Exec=ghostty -e bash -lc 'until [ -S "$XDG_RUNTIME_DIR/emacs/server" ]; ...'
```

Would be written in `hyprsphere.json` as:
```json
"exec": "ghostty -e bash -lc 'until [ -S \\\"$XDG_RUNTIME_DIR/emacs/server\\\" ]; ...'"
```

Where:
- `\\"` in JSON → `"` in the parsed JavaScript string
- `"` in the JavaScript string → terminated Lua string (WRONG)
- `\\"` in JSON → `\"` in JavaScript → Lua sees `\"` as escaped quote inside string (CORRECT)

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
   the repository's `shell.qml`
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
of the repository's `shell.qml`.

---

## Known Limitations

### Held Tab does not cycle when `focusOnTab` is enabled

When `focusOnTab: true`, each Tab press dispatches `hyprctl dispatch focus`
to preview the target window behind the overlay. To prevent the target window
from stealing keyboard focus from the overlay, the overlay briefly hides and
reappears via a visibility toggle (`visible=false` → `visible=true`). During
this toggle cycle, the compositor cannot deliver key events to the overlay
surface. Any Tab key events received during this window are either lost or
intercepted by Hyprland's global keybinds, causing the resulting IPC
`advance()` call to be blocked by the `_togglingVisibility` guard.

The practical effect is that **holding Tab to rapidly cycle through the
sphere does not work** when `focusOnTab` is enabled. Each advance requires
a distinct press-release-press cycle of the Tab key.

**Workaround:** Press and release Tab individually for each advance.
Or set `"focusOnTab": false` to disable live preview and restore
held-Tab cycling (at the cost of losing the live window preview).

---

## Fuzzy Searching Mechanism

hyprsphere uses **Fuse.js v7.0.0** (bundled at `lib/fuse.js`) for
client-side fuzzy matching. Fuse.js is a lightweight fuzzy-search library
tuned for approximate string matching — it handles typos, partial matches,
and out-of-order characters.

### Import

```qml
import "lib/fuse.js" as FuseJs
```

This is QML's **script import** syntax. The `.pragma library` directive at
the top of `fuse.js` tells the QML engine to load and cache the library
once, sharing it across all imports rather than re-executing the 2000-line
file on every access.

#### Path resolution

Quickshell resolves `lib/fuse.js` relative to the **symlink parent**
(`~/.config/quickshell/`), not the actual file location. The chain is:

```
~/.config/quickshell/shell.qml  →  /path/to/hyprsphere/shell.qml
~/.config/quickshell/lib        →  /path/to/hyprsphere/lib/
                                         └── fuse.js  ← resolved here
```

### Search database — `buildSearchDatabase()`

When the overlay opens, `initFuseIndex()` calls `buildSearchDatabase()` which
builds a flat array of every searchable item. It contains **three types of
entries**:

#### 1. Running apps (`type: "running-app"`)

One entry per unique `appId` from `Hyprland.toplevels` (the same data source
as the layer 0 sphere). Special workspace windows (`special:*`) are excluded.
Apps are grouped so that typing the app name surfaces a single result rather
than every window:

```qml
{ type: "running-app", appId: "firefox", label: "Firefox",
  icon: "firefox", windows: [{ address: "0x...", title: "Mozilla Firefox" }, ...] }
```

The `windows` array stores every individual window's address and title — used
by drill-down but not for Fuse matching.

#### 2. Individual windows (`type: "window"`)

A second pass over the same toplevel array adds a **separate entry per window**
for title-based search:

```qml
{ type: "window", appId: "firefox", label: "Firefox", icon: "firefox",
  address: "0x63d341ce8290", title: "Mozilla Firefox" }
```

This is what lets you type part of a window title and have that specific
window appear in results.

#### 3. Whitelisted placeholders (`type: "whitelisted-app"`)

Whitelist entries whose `appId` isn't currently running are added so they
appear in search results too:

```qml
{ type: "whitelisted-app", appId: "blender", label: "Blender",
  icon: "blender", exec: "blender", windows: [], windowCount: 0 }
```

**Yes — the search matches against ALL windows currently alive in Hyprland**
(plus whitelisted-but-dormant apps). The same `j/clients` data that powers
the sphere also feeds the search index.

### Fuse index construction

The flat database is passed to Fuse.js with weighted keys:

| Key | Weight | Purpose |
|---|---|---|
| `label` | 0.5 | Resolved display name (e.g. `"Firefox"`, `"Ghostty"`) |
| `title` | 0.4 | Window title (e.g. `"Mozilla Firefox"`, `"π - hyprsphere"`) |
| `appId` | 0.1 | Raw app identifier (e.g. `"com.mitchellh.ghostty"`) |

```qml
fuseIndex = new FuseJs.Fuse(db, {
    keys: [
        { name: "label", weight: 0.5 },
        { name: "title", weight: 0.4 },
        { name: "appId", weight: 0.1 }
    ],
    threshold: 0.4,
    minMatchCharLength: 1,
    ignoreLocation: true,   // ← match anywhere in the string, no distance penalty
    includeScore: true,
    shouldSort: true
});
```

Key settings:
- **`ignoreLocation: true`** — Crucial for window titles. Typing `"fox"` matches
  `"Firefox"` even though the match starts at character 4.
- **`threshold: 0.4`** — Fairly lenient. Allows typos and partial matches.
- **`weight`** — Labels are most important, then window titles, then raw appIds.

The Fuse index is built **once** when the overlay opens (in `finishOpenSwitcher()`)
and survives for the entire session. It is only rebuilt when:
- A window opens or closes while the overlay is open and layer 2 is active
  (`scheduleRebuild()` calls `initFuseIndex()` then re-runs the search)
- The overlay is closed and reopened (`openSwitcher()` →
  `finishOpenSwitcher()` → `initFuseIndex()`)

### Per-keystroke query (no new Fuse object)

Each keystroke calls `_executeSearch()` which runs:

```qml
function _executeSearch() {
    if (!fuseIndex) {
        initFuseIndex();  // safety net, usually skipped
        if (!fuseIndex) return;
    }
    var results = fuseIndex.search(searchQuery);
    // ... process results ...
}
```

`fuseIndex.search()` is a lightweight in-memory fuzzy match against the
already-built index. No new Fuse object is created per keystroke — typing
"firefox" character-by-character runs 7 `.search()` calls on the same
cached index.

### Building the layer 2 sphere

Results from Fuse arrive as `[{ item, score }, ...]` sorted by Fuse's
internal scoring. The pipeline transforms them into a layer 2 sphere:

```
fuseIndex.search("fox")
    │
    ▼
Results are sliced to maxResults (default 30)
    │
    ▼
Sorted into three buckets by item.type:
    ├── runApps[]        (type === "running-app")     ← app groups first
    ├── whitelistApps[]  (type === "whitelisted-app") ← then dormant apps
    └── winNodes[]       (type === "window")          ← individual windows last
    │
    ▼
layer2Model = runApps.concat(whitelistApps).concat(winNodes)
    │
    ▼
sphereModel = layer2Model              ← overwrites the layer 0 sphere
sphereZoom  = cfg.search.layer2Zoom     ← zooms in (default 1.5×)
```

The sort order is strict: **app groups first → whitelisted apps → individual
windows**. Within each bucket, Fuse's score order is preserved (best match
first). The `.score` metadata is discarded — only the raw `.item` data is
carried into the layer 2 model.

Each search result node gets `isSearchResult: true` so the sphere delegate
can distinguish it from layer 0 nodes. The sphere zoom increases to
`layer2Zoom` (configurable, default 1.5×) so fewer nodes are visible at
once, making the results easier to scan.

### Cancelling search

Backspace to empty or Escape calls `cancelSearch()`, which rebuilds
`buildLayer0()`, re-sorts by MRU, restores `sphereZoom` to 1.0, and
centres the sphere on the pre-selected app.

### Memory lifecycle per keystroke

After `_executeSearch()` returns, everything goes out of scope:
- `results` (Fuse result wrappers) → garbage collected
- `top` (sliced copy) → garbage collected
- `runApps`, `whitelistApps`, `winNodes` (temporary buckets) → garbage
  collected
- Previous `sphereModel` → garbage collected (replaced by new assignment)

The only persistent memory is the new `sphereModel` — roughly 30 small
node objects. On the next keystroke, a fresh pipeline runs and replaces
it.

### No server, no daemon, no IPC

The entire search pipeline runs inside QML's JavaScript engine. No
background process, no Unix socket, no subprocess spawn — every
keystroke is evaluated in-process.

---

## Closing Mechanism

**Keybind:** `Ctrl+C` while the overlay is open.

### Layer 0 (app list) or layer 2 (search — app nodes)

Closes **all windows** of the selected app. The function iterates through
every window in the app's `windows` array and sends a separate
`hyprctl dispatch closewindow` command for each one:

```js
for (var w = 0; w < node.windows.length; w++) {
    var a = node.windows[w].address;
    var p = a.indexOf("0x") === 0 ? "" : "0x";
    Quickshell.execDetached(["hyprctl", "dispatch",
        'hl.dsp.window.close({window="address:' + p + a + '"})']);
}
```

Each `closewindow` command triggers a Hyprland raw event, which the
`onRawEvent` handler picks up to:
1. Remove the window address from `appWindowMru` (per-app MRU)
2. If that was the app's last window, remove the app from `appMru`
3. Remove the address from `_appOpeningOrder` (compacting window indices)
4. Call `scheduleRebuild()` to refresh the sphere

### Layer 1 (drilled into app's windows) or layer 2 (search — window nodes)

Closes only the **single selected window** using its address:

```js
var p = node.address.indexOf("0x") === 0 ? "" : "0x";
Quickshell.execDetached(["hyprctl", "dispatch",
    'hl.dsp.window.close({window="address:' + p + node.address + '"})']);
```

### Aftermath

After closing:
- The sphere **automatically rebuilds** — closed windows disappear, and
  if an app's last window is closed, the entire app node disappears from
  the sphere (unless it's in the whitelist, in which case it reverts to
  a placeholder)
- **Window index badges compact** — if window #3 is closed, windows
  #4–8 shift down to become #3–7
- The overlay **stays open** so you can continue cycling
- **Guard:** `closeSequence.running` prevents double-firing during the
  exit animation sequence

---

## Considerations

### Ctrl+Enter MRU focus behavior

When spawning a new window with Ctrl+Enter, which window gets focus on
Alt release depends on where you spawned from:

- **Spawning from the app group (layer 0):** The **original MRU-most**
  window receives focus when you commit (Alt release). The newly spawned
  window is added to the app's window list but is not set as the active
  MRU target for that app.
- **Spawning from a specific window (layer 1):** The **newly spawned**
  window receives focus when you commit (Alt release). This is because
  the new window becomes the most recent window in that app's MRU list,
  and layer-1 commits use `appWindowMru[appId][0]` to determine focus
  target.

This is a natural consequence of how MRU tracking works — the act of
selecting a specific window and spawning from it makes the new window
the MRU-most, while spawning from the app group leaves the existing
MRU order intact.

### Whitelist entries and commit behavior

Whitelisted apps that are NOT running have `isWhitelistPlaceholder: true`.
Committing them (Alt release) launches the app via their configured
`exec` command rather than focusing an existing window.

### Desktop file multi-Exec lines

Some applications (notably Firefox) have multiple `Exec=` lines in their
.desktop file for different actions (normal launch, new window, private
window, profile manager). The icon reader only captures the **first**
`Exec=` line to avoid launching the wrong action.

### Window Address Normalization

Hyprland provides window addresses in **two different formats** depending on
the API, which caused subtle, hard-to-reproduce bugs throughout development.

#### The problem

| Source | Format | Example |
|---|---|---|
| `t.address` (toplevels / activeToplevel) | **Decimal string** | `"109758992184752"` |
| `event.data` (closewindow) | **Hex without 0x** | `"63d341b2fcf0"` |
| `event.data` (openwindow) | **Hex with 0x** | `"0x5cb8a4e2a040"` |
| `hyprctl clients -j` | **Hex** | `"0x63d341b2fcf0"` |

The critical mismatch: `t.address` from Quickshell's `j/clients` parser returns
a **decimal** string, while all event-socket data uses **hex**. Simply
prepending `"0x"` to the decimal string (e.g., `"0x109758992184752"`) produces
a **different address** than the correct hex (`"0x63d341b2fcf0"`), since
`0x109758992184752` in hex equals `4663441176908114` in decimal — not the
original `109758992184752`.

#### The fix: a shared `normalizeAddress()` function

A single entry point (`shell.qml` line ~89) handles all address ingestion:

```javascript
function normalizeAddress(addr) {
    if (!addr) return "";
    if (addr.indexOf("0x") === 0) return addr;
    // Quickshell may return address as decimal string (from j/clients)
    // OR as hex string without 0x prefix (from event-socket fallback).
    // Try decimal first; if it fails, treat as raw hex.
    var num = Number(addr);
    if (!isNaN(num)) return "0x" + num.toString(16);
    // Already hex without 0x — just add the prefix
    return "0x" + addr;
}
```

This properly converts decimal `"109758992184752"` → `"0x63d341b2fcf0"` by
parsing as a number and converting to hex, while also handling hex-without-0x
inputs gracefully via the `isNaN` fallback.

#### The five entry points (decimal ingest)

Every address from `t.address` (Quickshell's j/clients) now goes through
`normalizeAddress()`. The event-socket paths (openwindow / closewindow) keep
their simple `"0x" + addr` since they already receive hex data:

| # | Function | Before (broken) | After (fixed) |
|---|---|---|---|
| 1 | `initWindowIndices()` | `"0x" + addr` | `normalizeAddress(addr)` |
| 2 | `buildLayer0()` | `"0x" + wAddr` | `normalizeAddress(wAddr)` |
| 3 | `buildSearchDatabase()` (app) | `"0x" + sAddr1` | `normalizeAddress(sAddr1)` |
| 4 | `buildSearchDatabase()` (window) | ternary with `"0x"` | `normalizeAddress(t2.address)` |
| 5 | `onActiveToplevelChanged()` | `"0x" + addr` | `normalizeAddress(addr)` |

#### The rule

**Normalise on ingest, strip on dispatch.** Every address is converted to
`0x`-prefixed hex as soon as it enters the system — at the assignment, not
at the comparison site. This means:

- All internal containers (`globalWindowMru`, `appWindowMru`,
  `sphereModel[].address`, `_appOpeningOrder`) consistently store `0x`-prefixed
  hex addresses
- All comparisons are direct `===` matches with no ad-hoc normalisation
- Addresses are only stripped of `0x` when sent to Hyprland's IPC dispatcher
  (which expects raw addresses in certain contexts, though the dispatch calls
  in hyprsphere always ensure `0x` is present via the `prefix` pattern shown
  below)

```javascript
// hyprctl dispatch expects the address WITH 0x prefix:
var prefix = addr.indexOf("0x") === 0 ? "" : "0x";
Quickshell.execDetached(["hyprctl", "dispatch",
    'hl.dsp.focus({window="address:' + prefix + addr + '"})']);
```

#### Bug symptoms

If address normalisation is missing or inconsistent, you may see:

- **Stale windows accumulate as "unknown"** — the most visible symptom.
  Closewindow events can't match addresses in `appWindowMru`, so cleanup
  never runs. Stale entries persist in `globalWindowMru` and `appWindowMru`,
  while `buildLayer0()` sees windows in transitional closing states that fall
  through to `appId = "unknown"`. These appear with the purple/black QML
  broken-image icon (`"application-x-executable"` not found in icon theme).
- **Window close doesn't update MRU** — the closed address doesn't match any
  entry in `appWindowMru`, so the window is never removed from the per-app
  MRU list. Next overlay open may reference closed windows.
- **Drill-down selects the wrong window** — the second-MRU window isn't found,
  falls back to index 0 (MRU-most)
- **Opening-order badges are wrong** — the badge lookup against
  `_appOpeningOrder` fails due to format mismatch, showing incorrect window
  indices
- **Spawned window doesn't auto-select** — the pending spawn address doesn't
  match the sphere model entry

All of these manifest as intermittent, hard-to-reproduce failures because the
format an address arrives in depends on whether a window was opened vs.
focused, and whether it was present at startup vs. spawned later.

### Layer-0 vs layer-1/2 auto-selection

After any sphere rebuild, auto-selection uses different matching logic
by layer:
- **Layer 0** (app groups): matches by `appId` — app nodes don't have
  an `.address` property
- **Layers 1/2** (window nodes): matches by `address` — window nodes
  have `.address` but comparison must handle `0x` prefix
