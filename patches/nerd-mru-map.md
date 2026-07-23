# PATCH — Nerd Font MRU proportional bracket icons in badges

## Goal

Replace the numeric badge text (opening-order index like "1", "2", "3") with
Nerd Font bracket icons that represent the *proportional* MRU position of a
window within its app's window list. The brackets visually show how many
windows of that app exist and where this window falls in the MRU order.

## Bracket icon mapping

Icon is selected by computing `x = badgeIndex / totalWindowsForApp` and
matching against 12 equal-width buckets. Uses the standard Nerd Font
Progress glyph set (U+EE00–U+EE0B), not the Cascadia Code private range:

| Proportional range | Icon | Unicode |
|---|---|---|
| `x ≤ 1/12` |  | U+EE00 |
| `1/12 < x ≤ 2/12` |  | U+EE01 |
| `2/12 < x ≤ 3/12` |  | U+EE02 |
| `3/12 < x ≤ 4/12` |  | U+EE03 |
| `4/12 < x ≤ 5/12` |  | U+EE04 |
| `5/12 < x ≤ 6/12` |  | U+EE05 |
| `6/12 < x ≤ 7/12` |  | U+EE06 |
| `7/12 < x ≤ 8/12` |  | U+EE07 |
| `8/12 < x ≤ 9/12` |  | U+EE08 |
| `9/12 < x ≤ 10/12` |  | U+EE09 |
| `10/12 < x ≤ 11/12` |  | U+EE0A |
| `11/12 < x ≤ 12/12` |  | U+EE0B |

## Colors

- **Foreground:** `#ff4400` (orange-red)
- **Background:** `"transparent"` (invisible)

## Changes required

### 1. `shell.qml` — Badge text replacement (both `badgeLabel` and `satBadgeLabel`)

Replace the numeric `text:` expression with a proportional bracket icon lookup
function (shared between both badge instances). The function:

- Takes `badgeIndex` and `totalWindows` for the app
- Computes `proportion = badgeIndex / Math.max(1, totalWindows)`
- Maps to the correct bracket icon character
- Returns the Nerd Font unicode string

### 2. `shell.qml` — Badge background

Change badge `Rectangle.color` to `"transparent"` unconditionally (currently
switches between `windowBgColor` and `bgColor` based on node type).

### 3. `shell.qml` — Badge foreground

Change badge `Text.color` to `"#ff4400"` unconditionally.

## Open questions (to be resolved during clarification)

- ~~Q1~~: **Resolved** — use `badgeIndex / windowsForApp(appId).length` (per-app MRU, already built and tracked).
- ~~Q2~~: **Resolved** — satellite badge only. Sphere card badges stay hidden (`nonSelected: false`).
- ~~Q3~~: **Resolved** — remove the entire `windowCountBadge` block from `hyprsphere.json`. All badge values (offsets, padding, fontSize, colors) are hardcoded in QML.
- ~~Q4~~: **Resolved** — install `nerd-fonts.jetbrains-mono` via `environment.systemPackages` in `modules/packages.nix` (alongside `freefont_ttf`). After rebuild, `"JetBrains Mono"` family will include Nerd Font glyphs — no QML font-family change needed.
- ~~Q5~~: **Resolved** — whitelist placeholder nodes never show badges. Only real window nodes get the bracket icon.
- ~~Q6~~: **Resolved** — hardcode `fontSize: 18`, `padding: 14`, `offsetX: 0`, `offsetY: 57`.
- ~~Q7~~: **Resolved** — single-window app → proportion 1.0 → full bracket 󱑉. Correct.
- ~~Q8~~: **Resolved** — search bar node count badge stays as plain number. No changes.
- ~~Q9~~: **Resolved** — whitelisted placeholders get no badge at all (superseded by Q5).
- ~~Q10~~: **Resolved** — pill sizes to glyph natural width. No explicit minimum size needed.
