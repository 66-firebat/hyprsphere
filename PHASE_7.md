# PHASE_7 — Icon & display name resolution via .desktop file scanning

**Deliverable:** Every sphere node shows the correct freedesktop icon and
readable display name for its app, instead of the raw `appId` string and
generic fallback icon. Non-selected card labels can be shown/hidden per
layer via config.

---

## Problem

Hyprland's `wayland.appId` is often a reverse-DNS string like
`"com.mitchellh.ghostty"` or `"org.mozilla.firefox"`, while the
freedesktop icon theme knows them as `"ghostty"` or `"firefox"`.

Originally, `buildLayer0()` set both `icon: appId` and `label: appId`.
This meant:
- Icons: `image://icon/com.mitchellh.ghostty` — only works if the icon
  theme happens to have an icon matching the raw appId.
- Labels: shown as `"com.mitchellh.ghostty"` on cards — not human-readable.

Whitelist entries in `hyprsphere.json` specify their own `icon` and
`label`, so they were not affected.

---

## Solution

A one-shot `Process` scans `.desktop` files at startup and builds two
lookup tables: `iconMap` (for freedesktop icon names) and `nameMap` (for
human-readable display names).

### The bash script

Iterates `/run/current-system/sw/share/applications/*.desktop` and
`~/.local/share/applications/*.desktop`, extracting four fields:

| Field | Source | Purpose |
|---|---|---|
| Desktop file ID | `$(basename "$f" .desktop)` | Primary key (e.g. `"firefox"`) |
| `Name=` | Freedesktop `Name` field | Display name (e.g. `"Firefox"`) |
| `Icon=` | Freedesktop `Icon` field | Icon theme name (e.g. `"firefox"`) |
| `StartupWMClass=` | WMClass hint | Secondary key matching `wayland.appId` |

### The lookup tables

```js
iconMap = {
  "firefox": "firefox",
  "com.mitchellh.ghostty": "com.mitchellh.ghostty",
  "blender": "blender",
  ...
}

nameMap = {
  "firefox": "Firefox",
  "com.mitchellh.ghostty": "Ghostty",
  "blender": "Blender",
  ...
}
```

### Resolution chain

```
resolveIcon(appId):
    iconMap[appId]  →  "firefox"
    ??  "application-x-executable"

resolveName(appId):
    nameMap[appId]  →  "Firefox"
    ??  appId  (raw fallback)
```

---

## Steps

### 1. Add `iconMap`, `nameMap` properties and resolver functions

```qml
property var iconMap: ({})
property var nameMap: ({})

function resolveIcon(appId) {
    if (!appId) return "application-x-executable";
    return iconMap[appId] || "application-x-executable";
}

function resolveName(appId) {
    if (!appId) return appId;
    return nameMap[appId] || appId;
}

function showNonSelectedLabel() {
    var layers = cfg.appCard?.nonSelectedLayerLabels;
    if (!layers) return true;
    var key = "layer_" + window.layer;
    return layers[key] !== false;
}
```

### 2. Add the `iconReader` Process with `Name=` extraction

```qml
Process {
    id: iconReader
    command: ["bash", "-c",
        "for f in /run/current-system/sw/share/applications/*.desktop " +
        "$HOME/.local/share/applications/*.desktop; do " +
        "[ -f \"$f\" ] || continue; " +
        "echo \"[ID]$(basename \"$f\" .desktop)\"; " +
        "grep -E '^(Name=|Icon=|StartupWMClass=)' \"$f\" 2>/dev/null; " +
        "echo '---'; done"
    ]
    running: false
    stdout: StdioCollector {
        onStreamFinished: {
            var txt = this.text.trim();
            if (txt.length > 0) window.parseIcons(txt);
        }
    }
}
```

### 3. Add `parseIcons()` — builds both `iconMap` and `nameMap`

```qml
function parseIcons(text) {
    var map = {};
    var nmap = {};
    var blocks = text.split('---');
    for (var b = 0; b < blocks.length; b++) {
        var lines = blocks[b].trim().split('\n');
        var id = null, icon = null, wmClass = null, name = null;
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (line.startsWith('[ID]')) id = line.substring(4).trim();
            else if (line.startsWith('Name=')) name = line.substring(5).trim();
            else if (line.startsWith('Icon=')) icon = line.substring(5).trim();
            else if (line.startsWith('StartupWMClass=')) wmClass = line.substring(15).trim();
        }
        if (id && icon) {
            map[id] = icon;
            if (wmClass) map[wmClass] = icon;
        }
        if (id && name) {
            nmap[id] = name;
            if (wmClass) nmap[wmClass] = name;
        }
    }
    iconMap = map;
    nameMap = nmap;
}
```

### 4. Start the reader at startup

In `Component.onCompleted`, add `iconReader.running = true;`.

### 5. Wait for icon map before first sphere build

In `finishOpenSwitcher()`, check that `iconMap` is populated before
proceeding (retry via `Qt.callLater` if not ready).

### 6. Update `buildLayer0()` and `buildSearchDatabase()`

Replace:
- `icon: appId` → `icon: window.resolveIcon(appId)`
- `label: appId` → `label: window.resolveName(appId)`

### 7. Update non-selected card label rendering

Both the icon `Image` and label `Text` on non-selected cards now use
direct array access instead of the QML model wrapper:
```qml
// Before (broken — model properties unreliable with JS array models):
source: model.icon ? ...
text: model.title ? model.title : model.label

// After (direct array access — always correct):
source: { var ic = window.sphereModel[index].icon; ... }
text: { var n = window.sphereModel[index]; return n.title ? n.title : n.label; }
```

The label `Rectangle` is hidden entirely when `showNonSelectedLabel()`
returns false for the current layer.

### 8. Add `nonSelectedLayerLabels` config to `hyprsphere.json`

```json
{
  "appCard": {
    "labelBgOpacity": 0.60,
    "nonSelectedLayerLabels": {
      "layer_0": false,
      "layer_1": true,
      "layer_2": true
    }
  }
}
```

When a layer's flag is `false`, both the label text AND its translucent
gray background rectangle are hidden for all non-selected cards.

---

## Config additions

### `appCard.nonSelectedLayerLabels`

| Field | Default | Description |
|---|---|---|
| `layer_0` | `true` | Show labels on non-selected cards at layer 0 (app groups) |
| `layer_1` | `true` | Show labels on non-selected cards at layer 1 (drilled windows) |
| `layer_2` | `true` | Show labels on non-selected cards at layer 2 (search results) |

---

## Notes

- The `[ -f "$f" ] || continue` guard skips unmatched glob patterns
  (e.g., when `~/.local/share/applications/*.desktop` is empty).
- Both the desktop file ID AND `StartupWMClass` are added as keys
  in both maps. This ensures that apps like `com.mitchellh.ghostty`
  resolve even when their `.desktop` filename doesn't match the appId.
- The overlay auto-refreshes with correct icons/names if it's visible
  when the reader finishes (`scheduleRebuild()` is called).
- Direct array access (`window.sphereModel[index]`) is used instead of
  QML's `model.property` syntax because QML's JS array model wrapper
  does not reliably expose element properties for non-selected items.

---

## Files changed

| File | Change |
|---|---|
| `hyprsphere.qml` | Add `iconMap`, `nameMap`, `resolveIcon()`, `resolveName()`, `showNonSelectedLabel()`, `iconReader` Process (with `Name=` extraction), `parseIcons()`, async wait in `finishOpenSwitcher()`, direct array access for card labels/icons, label visibility control |
| `hyprsphere.json` | Add `appCard.nonSelectedLayerLabels` config block |

---

## Exit criteria

1. **Running apps with matching desktop files** show the correct icon
   and display name
2. **Running apps without matching desktop files** fall back to raw appId
   and generic icon (silent, no crash)
3. **Layer 1 nodes** inherit the parent app's resolved icon and label
4. **Whitelist entries** keep their explicitly configured icon and label
5. **Search results (layer 2)** show resolved icons and names
6. **Non-selected card labels** can be toggled per layer via config
7. **No binding loops or rendering glitches** — label Rectangle hidden
   entirely (not just the Text inside it)
