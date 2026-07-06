# PHASE_8 — Visual/UX cleanup and polish

**Deliverable:** Clean up visual elements, replace the satellite decoration
with a custom SVG, make icon sizes configurable per selection state, and
add a window-count badge.

---

## Tasks

### 1. Remove the stars background ✅

The `Repeater` that generates 50 random star dots in the overlay background
is removed.

### 2. Replace satellite decoration with custom SVG ✅

Satellite QML primitives (hull, solar panels, struts, antenna, thruster)
replaced with `assets/selected.svg`. The SVG is conditionally shown via
`satellite.selectedBackground` config.

### 3. Configurable icon sizes ✅

- **Selected icon size:** `satellite.iconSize` in config (default 40)
- **Non-selected icon size:** `appCard.nonSelectedIconSize` in config (default 55)

### 4. Window-count / index badge (redesigned)

Shows a small numeric badge **centered over the icon** with configurable
X/Y offset. On **app nodes** it shows the window count (e.g. `"3"`).
On **window nodes** (layer 1 drill-down, layer 2 search results) it shows
the window's **per-app opening-order index** (e.g. `"2"`).

#### Config

```json
{
  "appCard": {
    "windowCountBadge": {
      "satellite": true,
      "nonSelected": true,
      "offsetY": 0,
      "offsetX": -60,
      "fontSize": 18,
      "padding": 14,
      "color": "#ff4400",
      "bgColor": "#2b2b2b",
      "bgOpacity": 0.5,
      "windowColor": "#2b2b2b",
      "windowBgColor": "#ff4400",
      "windowBgOpacity": 0.5
    }
  }
}
```

| Field | Default | Description |
|---|---|---|
| `windowCountBadge.satellite` | `true` | Show badge on the selected satellite card |
| `windowCountBadge.nonSelected` | `true` | Show badge on non-selected sphere cards |
| `windowCountBadge.offsetY` | `0` | Vertical offset from icon center (negative = upward) |
| `windowCountBadge.offsetX` | `-60` | Horizontal offset from icon center (negative = left) |
| `windowCountBadge.fontSize` | `18` | Pixel size of the badge text |
| `windowCountBadge.padding` | `14` | Extra space added to text (symmetric, keeps badge circular) |
| `windowCountBadge.color` | `"#ff4400"` | Foreground text color of the badge |
| `windowCountBadge.bgColor` | `"#2b2b2b"` | Background pill color of the badge |
| `windowCountBadge.bgOpacity` | `0.5` | Opacity of the background pill (0-1) |
| `windowCountBadge.windowColor` | `"#2b2b2b"` | Foreground text color for window index badges |
| `windowCountBadge.windowBgColor` | `"#ff4400"` | Background pill color for window index badges |
| `windowCountBadge.windowBgOpacity` | `0.5` | Background pill opacity for window index badges (0-1) |

#### Behavior

- **What it shows:** App nodes show window count (e.g. `"3"`);
  window nodes show static 1-based opening-order index (e.g. `"2"`)
- **Where:** Centered over the app/window icon, with X/Y offset,
  for both the satellite card and non-selected cards
- **When:** App nodes where `windowCount` ≥ 1. Window nodes always show
  their index badge. Hidden for whitelisted placeholders and
  "No windows"/"No results" placeholders
- **Style:** Bold text on a rounded pill background. App badges use
  `bgColor`/`bgOpacity`. Window badges use `windowBgColor`/
  `windowBgOpacity`/`windowColor`. Positioned centered over the icon,
  with configurable X/Y offset.

#### Implementation

**Satellite card:** An `Item` (pill `Rectangle` + `Text`) anchored to the center of the
satellite icon `Image`, with configurable X/Y offset. Visible when:
- `cfg.appCard?.windowCountBadge?.satellite !== false`
- The selected node is not a placeholder/whitelisted placeholder
- If app node: `windowCount` ≥ 1; if window node: always

**Non-selected cards:** Same `Item` pattern anchored to the center of the
card's icon `Image`. Visible when:
- `cfg.appCard?.windowCountBadge?.nonSelected !== false`
- The current node is not a placeholder/whitelisted placeholder
- If app node: `windowCount` ≥ 1; if window node: always

#### Per-app window indexing

Each app's windows get their own independent 1-based numbering in
opening order:

- **At startup:** `initWindowIndices()` scans `Hyprland.toplevels` and
  groups addresses by `appId` into `_appOpeningOrder[appId]` (retries
  on each tick until data is available).
- **On `openwindow`:** the window's address is appended to the end of
  its app's array in `_appOpeningOrder`.
- **On `closewindow`:** the window's address is removed from its app's
  array — all subsequent windows in that app shift down (indices
  compact).
- **New windows always get the next sequential index** for their app
  (e.g., after compacting 7 Firefox windows down to 6, the next new
  Firefox window gets index 7).

Index lookup in badge text:
```js
var appList = window._appOpeningOrder[n.appId];
if (!appList) return "";
var oi = appList.indexOf(address);
return String(oi >= 0 ? oi + 1 : "");
```

**Key structural changes from previous implementation:**
- Badge is no longer a child of `ColumnLayout` — it is pulled out and
  positioned relative to the icon `Image` itself
- The anchor point changed from `bottom-right` of card to `center` of
  the icon, with configurable X/Y offset
- App badges use `color`/`bgColor`/`bgOpacity`;
  window badges use `windowColor`/`windowBgColor`/`windowBgOpacity`
  (inverted color scheme: orange pill with dark text for windows)

---

## Config additions

### `satellite.selectedBackground`

| Field | Default | Description |
|---|---|---|
| `selectedBackground` | `true` | Show the SVG decoration behind the selected app icon |

### `appCard.windowCountBadge`

| Field | Default | Description |
|---|---|---|
| `windowCountBadge.satellite` | `true` | Show window count on the satellite card |
| `windowCountBadge.nonSelected` | `true` | Show window count on non-selected cards |
| `windowCountBadge.offsetY` | `0` | Vertical offset from icon center (negative = up) |
| `windowCountBadge.offsetX` | `-60` | Horizontal offset from icon center (negative = left) |
| `windowCountBadge.fontSize` | `18` | Pixel size of the badge text |
| `windowCountBadge.padding` | `14` | Extra space added to text (symmetric, keeps badge circular) |
| `windowCountBadge.color` | `"#ff4400"` | Foreground text color of the badge |
| `windowCountBadge.bgColor` | `"#2b2b2b"` | Background pill color of the badge |
| `windowCountBadge.bgOpacity` | `0.5` | Opacity of the background pill (0-1) |
| `windowCountBadge.windowColor` | `"#2b2b2b"` | Foreground text color for window index badges |
| `windowCountBadge.windowBgColor` | `"#ff4400"` | Background pill color for window index badges |
| `windowCountBadge.windowBgOpacity` | `0.5` | Background pill opacity for window index badges (0-1) |

---

## Exit criteria

1. ✅ No stars background
2. ✅ Satellite SVG decoration (toggleable via config)
3. ✅ Selected icon size configurable via `satellite.iconSize`
4. ✅ Non-selected icon size configurable via `appCard.nonSelectedIconSize`
5. **Window count / index badge** shows centered over the icon on both app and window nodes across all layers
6. **Badge toggles** independently for satellite and non-selected cards
7. **Badge position** configurable via `offsetY` and `offsetX` (vertical/horizontal offset from icon center)
8. **Badge style** configurable via `color` (foreground) and `fontSize`
9. **Badge background** configurable via `bgColor`/`bgOpacity` for apps,
   `windowBgColor`/`windowBgOpacity`/`windowColor` for windows
10. **Per-app indexing** — each app's windows are numbered independently
    starting at 1, in opening order
11. **Compact on close** — closing a window shifts all later indices down
12. **New windows get next sequential index** — never reused numbers from
    closed windows
