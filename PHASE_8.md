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

### 4. Window-count badge

Shows the number of windows for an app node as a small numeric badge at the
bottom-right of the card. Only appears on **app nodes** (not window nodes or
placeholders) across all layers.

#### Config

```json
{
  "appCard": {
    "windowCountBadge": {
      "satellite": true,
      "nonSelected": true
    }
  }
}
```

| Field | Default | Description |
|---|---|---|
| `windowCountBadge.satellite` | `true` | Show badge on the selected satellite card |
| `windowCountBadge.nonSelected` | `true` | Show badge on non-selected sphere cards |

#### Behavior

- **What it shows:** The raw window count number (e.g. `"3"`)
- **Where:** Bottom-right corner of the card, positioned over the SVG or
  card background
- **When:** Only for app nodes where `windowCount` ≥ 1. Hidden for window
  nodes, whitelisted placeholders, and "No windows"/"No results"
  placeholders
- **Style:** Small, subtle text — same font as the card label, slightly
  smaller pixel size, with a contrasting background circle or pill shape

#### Implementation

**Satellite card:** Add a `Text` element anchored to the bottom-right of
the satellite `ColumnLayout`, visible when:
- `cfg.appCard?.windowCountBadge?.satellite !== false`
- The selected node is an app node (has `windowCount` ≥ 1)

**Non-selected cards:** Add a `Text` element anchored to the bottom-right
of the card `ColumnLayout`, visible when:
- `cfg.appCard?.windowCountBadge?.nonSelected !== false`
- The current node has `windowCount` ≥ 1

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

---

## Exit criteria

1. ✅ No stars background
2. ✅ Satellite SVG decoration (toggleable via config)
3. ✅ Selected icon size configurable via `satellite.iconSize`
4. ✅ Non-selected icon size configurable via `appCard.nonSelectedIconSize`
5. **Window count badge** shows on app nodes across all layers
6. **Badge toggles** independently for satellite and non-selected cards
