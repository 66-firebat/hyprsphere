# PHASE_8 — Visual/UX cleanup and polish

**Deliverable:** Clean up visual elements, replace the satellite decoration
with a custom SVG, and make icon sizes configurable per selection state.

---

## Tasks

### 1. Remove the stars background

The `Repeater` that generates 50 random star dots in the overlay background
is removed. Stars were a carryover from the app-launcher prototype and don't
serve a functional purpose in the Alt+Tab switcher.

**Files changed:** `hyprsphere.qml`

**Changes:**
- Delete the `Item { opacity: window.introPhase }` block that contains the
  star `Repeater` and its delegate `Rectangle`.

---

### 2. Replace satellite decoration with custom SVG

The satellite card is currently built from ~100 lines of QML primitives:
- Central hull (Rectangle with rounded corners)
- Two solar panels with grid patterns
- Two struts connecting panels to hull
- Antenna with ball on top
- Thruster at bottom
- Screen area (overlay on hull) containing app icon + label

This entire container decoration is replaced by loading
`assets/selected.svg` as the satellite background image. The SVG is a
467KB detailed illustration that acts as the chassis behind the screen
content.

**Design:**
- The SVG is loaded as an Image filling the satellite container
- The app icon + label still render on top of the SVG (in the "screen"
  area, matching the current layout)
- The `assets/` directory is shipped with the repository

**Files changed:** `hyprsphere.qml`

**Changes:**
- Add a new `Image` loading `file:///path/to/assets/selected.svg`
  behind the existing `notifScreen` Rectangle
- Remove the QML code for: `lPanel`, `lStrut`, `hull` (antenna, screen,
  thruster), `rStrut`, `rPanel`

---

### 3. Configurable non-selected icon size

Currently both selected and non-selected card icons use different size
sources:
- **Selected (satellite) icon:** `cfg.satellite?.iconSize ?? 40` — already
  configurable via `satellite.iconSize` in `hyprsphere.json`
- **Non-selected card icon:** Hardcoded to `window._s55` (55px scaled)

A new config field `appCard.nonSelectedIconSize` is added, defaulting to
`55`. The non-selected card's `Image` uses this instead of `_s55`.

**Files changed:** `hyprsphere.qml`, `hyprsphere.json`

**Changes:**
- Add `"nonSelectedIconSize": 55` to the `appCard` block in config
- Replace `Layout.preferredWidth: window._s55` with
  `window.s(cfg.appCard?.nonSelectedIconSize ?? 55)` in the non-selected
  card delegate

---

## Config additions

### `appCard.nonSelectedIconSize`

| Field | Default | Description |
|---|---|---|
| `nonSelectedIconSize` | `55` | Icon size in pixels for non-selected sphere cards |

The selected (satellite) icon size was already configurable via
`satellite.iconSize`.

---

## Exit criteria

1. **No stars background** appears behind the sphere overlay
2. **Satellite card** shows the custom `selected.svg` decoration behind
   the app icon and label
3. **Non-selected icon size** can be changed via `hyprsphere.json` and
   updates on restart
4. **Selected icon size** still configurable via `satellite.iconSize`
   (unchanged)
