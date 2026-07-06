# PHASE_7 — Icon resolution via .desktop file scanning

**Deliverable:** Every sphere node shows the correct freedesktop icon for
its app, instead of the generic fallback. Uses a one-shot `Process` to scan
`.desktop` files at startup and build an `appId → iconName` mapping.

---

## Problem

Hyprland's `wayland.appId` is often a reverse-DNS string like
`"com.mitchellh.ghostty"` or `"org.mozilla.firefox"`, while the
freedesktop icon theme knows them as `"ghostty"` or `"firefox"`.

Currently, `buildLayer0()` sets `icon: appId` — the raw appId string is
passed to `image://icon/appId`. This works for apps where appId happens
to match the icon name (e.g., `"firefox"`), but fails for most others,
showing the generic `"application-x-executable"` fallback.

Whitelist entries specify their own `icon` in `hyprsphere.json`, so they
are not affected by this bug.

---

## Solution

Since `Quickshell.DesktopEntries` is not available in Quickshell 0.3.0,
we use a one-shot `Process` to scan `.desktop` files at startup — the
same approach used by the polysphere prototype.

A bash script iterates `/run/current-system/sw/share/applications/*.desktop`
and `~/.local/share/applications/*.desktop`, extracting:
- Desktop file ID (from filename, e.g. `"firefox"`)
- `Icon=` field (the freedesktop icon name)
- `StartupWMClass=` field (used as a secondary key matching `wayland.appId`)

The results are parsed into an `iconMap` object:
```js
{
  "firefox": "firefox",
  "com.mitchellh.ghostty": "com.mitchellh.ghostty",
  "blender": "blender",
  ...
}
```

### Resolution chain

```
resolveIcon(rawAppId):
    iconMap[appId]           (lookup in built map)
    ??
    "application-x-executable"   (generic fallback)
```

No reverse-DNS stripping, no heuristic matching — just a direct hash
lookup against the desktop-file index.

---

## Steps

### 1. Add `iconMap` property and `resolveIcon()` function

Add alongside the other utility properties:

```qml
// ── Phase 7: Icon resolution ──
property var iconMap: ({})

function resolveIcon(appId) {
    if (!appId) return "application-x-executable";
    return iconMap[appId] || "application-x-executable";
}
```

### 2. Add the `iconReader` Process

A one-shot bash script scans desktop files at startup:

```qml
Process {
    id: iconReader
    command: ["bash", "-c",
        "for f in /run/current-system/sw/share/applications/*.desktop " +
        "$HOME/.local/share/applications/*.desktop; do " +
        "[ -f \"$f\" ] || continue; " +
        "echo \"[ID]$(basename \"$f\" .desktop)\"; " +
        "grep -E '^(Icon=|StartupWMClass=)' \"$f\" 2>/dev/null; " +
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

### 3. Add `parseIcons()` function

Parses the collected output into the `iconMap`:

```qml
function parseIcons(text) {
    var map = {};
    var blocks = text.split('---');
    for (var b = 0; b < blocks.length; b++) {
        var lines = blocks[b].trim().split('\n');
        var id = null, icon = null, wmClass = null;
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (line.startsWith('[ID]')) {
                id = line.substring(4).trim();
            } else if (line.startsWith('Icon=')) {
                icon = line.substring(5).trim();
            } else if (line.startsWith('StartupWMClass=')) {
                wmClass = line.substring(15).trim();
            }
        }
        if (id && icon) {
            map[id] = icon;
            if (wmClass) map[wmClass] = icon;
        }
    }
    iconMap = map;
}
```

### 4. Start the reader at startup

In `Component.onCompleted`, add `iconReader.running = true;`.

### 5. Update `buildLayer0()` and `buildSearchDatabase()`

Replace `icon: appId` with `icon: window.resolveIcon(appId)` in both
functions.

---

## Notes

- The `[ -f "$f" ] || continue` guard ensures the script skips over
  glob patterns that don't match any files (e.g., when
  `~/.local/share/applications/*.desktop` is empty).
- Both the desktop file ID AND the `StartupWMClass` are added as keys
  in the `iconMap`. This ensures that apps like `com.mitchellh.ghostty`
  resolve even when their `.desktop` filename doesn't match the appId
  — as long as `StartupWMClass=com.mitchellh.ghostty` is set.
- The overlay automatically refreshes with correct icons if it's visible
  when the icon map finishes building (`scheduleRebuild()` is called).

---

## Files changed

| File | Change |
|---|---|
| `hyprsphere.qml` | Add `iconMap` property, `resolveIcon()`, `iconReader` Process, `parseIcons()`, update `buildLayer0()` and `buildSearchDatabase()`, trigger reader at startup |

---

## Exit criteria

1. **Running apps with matching desktop files** show the correct icon
   (checked visually on the sphere cards and satellite card)
2. **Running apps without matching desktop files** fall through to
   `"application-x-executable"` (silent fallback, no crash)
3. **Layer 1 nodes** inherit the parent app's resolved icon (no window-level
   icon override)
4. **Whitelist entries** keep their explicitly configured icon
5. **Search results (layer 2)** show resolved icons for both app and window
   nodes
6. **No performance regression** — icon lookup is a single hash access per
   node, called only when the model is rebuilt
