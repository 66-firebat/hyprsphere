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

### 4. Window-count badge (redesigned)

Shows the number of windows for an app node as a small numeric badge
**centered over the icon**, shifted slightly upward on the Y axis.
Only appears on **app nodes** (not window nodes or placeholders)
across all layers.

#### Config

```json
{
  "appCard": {
    "windowCountBadge": {
      "satellite": true,
      "nonSelected": true,
      "offsetY": 0,
      "offsetX": -30,
      "fontSize": 18,
      "padding": 14,
      "color": "#ff4400",
      "bgColor": "#2b2b2b"
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

#### Behavior

- **What it shows:** The raw window count number (e.g. `"3"`)
- **Where:** Centered over the app icon, shifted up by `offsetY` pixels,
  for both the satellite card and non-selected cards
- **When:** Only for app nodes where `windowCount` ≥ 1. Hidden for window
  nodes, whitelisted placeholders, and "No windows"/"No results"
  placeholders
- **Style:** Bold text on a rounded pill background (`bgColor` at `bgOpacity`). Positioned
  centered over the app icon, shifted up by `offsetY` pixels.

#### Implementation

**Satellite card:** Add a `Text` element anchored to the center of the
satellite icon `Image`, with a vertical offset of `windowCountBadge.offsetY`.
Visible when:
- `cfg.appCard?.windowCountBadge?.satellite !== false`
- The selected node is an app node (has `windowCount` ≥ 1)

**Non-selected cards:** Add a `Text` element anchored to the center of the
card's icon `Image`, with a vertical offset of `windowCountBadge.offsetY`.
Visible when:
- `cfg.appCard?.windowCountBadge?.nonSelected !== false`
- The current node has `windowCount` ≥ 1

**Key structural changes from previous implementation:**
- Badge is no longer a child of `ColumnLayout` — it is pulled out and
  positioned relative to the icon `Image` itself
- The background `Rectangle` (pill/circle shape) is removed entirely —
  badge is bare text with no background
- The anchor point changes from `bottom-right` of card to `center` of
  the icon, with a configurable Y offset

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

---

## Exit criteria

1. ✅ No stars background
2. ✅ Satellite SVG decoration (toggleable via config)
3. ✅ Selected icon size configurable via `satellite.iconSize`
4. ✅ Non-selected icon size configurable via `appCard.nonSelectedIconSize`
5. **Window count badge** shows centered over the icon on app nodes across all layers
6. **Badge toggles** independently for satellite and non-selected cards
7. **Badge position** configurable via `offsetY` and `offsetX` (vertical/horizontal offset from icon center)
8. **Badge style** configurable via `color` (foreground) and `fontSize`
9. **Badge background** configurable via `bgColor` and `bgOpacity` (pill shape behind text)
