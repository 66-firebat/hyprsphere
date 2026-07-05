# PLAN.md — hyprsphere (Quickshell.Hyprland alt-tab switcher, daemon-free)

Project name: **hyprsphere**. Starting from scratch. Frontend is the
existing 3D Fibonacci-sphere QML (sphere layout, drag-to-rotate, satellite
detail card, intro/exit animation) carried over from the app-launcher
prototype. Everything that assumed "launch a new app" is replaced with
"focus an existing window," and all data/IPC comes directly from
Quickshell's built-in Hyprland module — no Guile daemon, no Python
fetcher, no Unix socket of our own. Hyprland's role is a single bind in
`keymaps.lua` that opens the overlay and hands it keyboard focus;
everything after that (Tab cycling, `;` drill-down, Escape, and the
Alt-release commit) is handled client-side in QML — confirmed working
by direct test, not `keyd`, not a Hyprland submap.

Verified against Quickshell docs v0.3.0 (quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland)
and the Hyprland Lua config API (wiki.hypr.land/Configuring/Basics/Binds).

---

## Architecture summary

```
keymaps.lua — ONE bind: ALT + Tab → qs ipc call hyprsphere show
        │
        ▼
IpcHandler.show() (QML) → window.visible = true; forceActiveFocus()
        │
        ▼
Sphere overlay (PanelWindow, focused, handles all further input itself)
        │  Keys.onPressed:  Tab / SHIFT+Tab / ";"  → advance() / drillDown()
        │  Keys.onReleased: Alt                    → commitSelection()
        │  Keys.onReleased: Escape                 → cancelSwitch()
        │  layer 0: one node per APP (grouped, all workspaces)
        │  layer 1: one node per WINDOW of the drilled-into app
        │  reads live state from
        ▼
Quickshell.Hyprland singleton
   ├─ Hyprland.toplevels        (ObjectModel<HyprlandToplevel>, reactive)
   ├─ Hyprland.activeToplevel   (readonly, for MRU tracking)
   └─ Hyprland.dispatch(...)    (send dispatcher commands, e.g. focuswindow)
```

Confirmed by direct test (not just docs): Hyprland's `ALT + Tab` bind only
intercepts that specific bound combo — once the overlay has keyboard
focus, it receives every subsequent Alt/Tab press *and* release directly
via Qt's `Keys.onPressed`/`Keys.onReleased`, including Alt release after
a real press→cycle→release sequence. So Hyprland's role is reduced to a
single bind that opens the overlay and hands it focus; **no submap, no
`keyd`, no per-keystroke IPC round-trip.** Everything else — Tab cycling,
`;` drill-down, Escape, and the Alt-release commit — is handled
client-side in QML. See Phase 3 for the full reasoning and test
transcript that led here.

Two-layer model: opening the switcher always shows **apps** first
(one sphere node per distinct `appId`, aggregated across every
workspace/monitor). Pressing `;` while an app node is centered rebuilds
the same sphere in place with that app's individual **windows** as the
new nodes (layer 1). Committing (Alt release) at layer 0 focuses the
app's most-recently-used window directly; committing at layer 1 focuses
the specific window selected.

No polling, no JSON parsing of `hyprctl` output, no persistent background
process beyond Quickshell itself (which is already always-running).

---

## Phase 1 — Data source: app grouping (layer 0)

**Goal:** replace the launcher's `ListModel` + Python `Process` fetch
with a live **app-grouped** view, aggregated across every workspace and
monitor — this answers the "workspace scope" question from the last
round: **all workspaces, always, for layer 0.**

**Normalized node shape:** both layers must produce nodes with the same
property names so the `Repeater` delegate doesn't need layer-specific
branching:
```js
// Layer 0 node
{ label: "Firefox", icon: "firefox", appId: "firefox", windows: [...], windowCount: 3 }
// Layer 1 node
{ label: "hyprsphere — Editing PLAN.md", icon: "firefox", appId: "firefox", address: "0x..." }
```
The delegate always reads `model.label`/`model.icon`; layer 1 nodes
additionally carry `model.address` for the commit dispatch.

- Add `import Quickshell.Hyprland` to the overlay file.
- Delete `appFetcher` (`Process` running `app_fetcher.py`) and the
  `ListModel appModel` + chunked `appendChunk()` logic entirely.
- Group `Hyprland.toplevels` by `wayland.appId` (guard: `wayland` is null
  until the address is reported) into `layer0Apps`, a JS array rebuilt
  on open. All monitors, all normal workspaces — special (scratchpad)
  workspaces are excluded (see "Decisions locked" below):
  ```js
  function buildLayer0() {
      let groups = {};

      // 1. Build running-app groups from Hyprland.toplevels
      for (let i = 0; i < Hyprland.toplevels.count; i++) {
          let t = Hyprland.toplevels.get(i);
          let ws = t.workspace;
          let isSpecial = ws && (ws.id < 0 || String(ws.name ?? "").startsWith("special:"));
          if (isSpecial) continue; // skip scratchpad-style windows entirely
          let appId = t.wayland?.appId ?? "unknown";
          if (!groups[appId]) groups[appId] = { appId, label: appId, icon: appId, windows: [] };
          groups[appId].windows.push({ address: t.address, title: t.title });
          groups[appId].windowCount = groups[appId].windows.length;
      }

      // 2. Append whitelist entries, deduplicating by appId (see "Whitelist" below)
      let whitelist = cfg.whitelist || [];
      for (let entry of whitelist) {
          if (groups[entry.appId]) continue;  // already has windows, skip
          groups[entry.appId] = {
              appId: entry.appId,
              label: entry.label,
              icon: entry.icon,
              exec: entry.exec,
              windows: [],
              windowCount: 0,
              isWhitelistPlaceholder: true,   // commit will launch instead of focus
          };
      }

      return Object.values(groups);
  }
  ```
  
  **Whitelist `appId` note:** Hyprland's runtime `wayland.appId` is often
  reverse-DNS (`org.mozilla.firefox` not `firefox`). To find the correct
  value for a whitelist entry, run:
  ```
  hyprctl clients -j | jq '.[] | .class'
  ```
  and copy the exact string. If the whitelist `appId` doesn't match the
  runtime value, dedup silently fails and you get a duplicate ghost entry.
- Each layer-0 sphere node represents one app group, not one window —
  the card shows the app icon once regardless of how many windows that
  app has open (a small window-count badge is a nice touch, not
  required for v1).
- **Rebuild on `appId` resolution:** `wayland.appId` can read `null`
  immediately after a toplevel first appears and resolve to a real value
  shortly after (the Wayland handshake hasn't completed yet). Without
  handling this, a window that opens right as you Alt+Tab could get
  permanently stuck grouped under `"unknown"`. Connect to the relevant
  toplevel property-change signal and re-run `buildLayer0()` when a
  previously-`"unknown"` appId resolves, with a rebuild guard so rapid
  successive resolutions during a big app launch don't cause visible
  flicker.
- Call `Hyprland.refreshToplevels()` once in `Component.onCompleted` as a
  safety net — most state arrives reactively via events, but some actions
  don't emit events per the docs.

### Whitelist — persistent app dock in the sphere

A list in `hyprsphere.json` of apps that always appear on the sphere
regardless of whether they're currently running. They're appended after
all running apps (sorted by MRU), deduplicated by `appId` — if a
whitelisted app already has windows open, it appears only in its normal
MRU-sorted position and is skipped in the whitelist tail.

Committing a whitelisted app that IS running focuses its most-recent
window (same as any layer-0 commit). Committing one that is NOT running
launches it via the `exec` field.

#### Schema (in `hyprsphere.json`)

```json
{
  "whitelist": [
    {
      "appId": "firefox",
      "label": "Firefox",
      "icon": "firefox",
      "exec": "firefox"
    },
    {
      "appId": "code",
      "label": "VS Code",
      "icon": "code",
      "exec": "code"
    }
  ]
}
```

- **`appId`** — compared against `t.wayland?.appId` for dedup with
  running windows.
- **`label`** — displayed as the card's text label.
- **`icon`** — freedesktop icon name, fed to `image://icon/...` (same
  icon resolution as the current launcher uses). No filesystem scanning
  at runtime.
- **`exec`** — shell command passed to `Hyprland.dispatch("exec " + exec)`
  when launching.

**Exit criteria:** opening the overlay populates the sphere with one node
per distinct running app (not per window), correct across all
workspaces/monitors, positions computed exactly as before (existing
`rebuildProjCache`/Fibonacci math is untouched — it doesn't care what a
node represents). The whitelist `appId` reverse-DNS matching note above
applies to the whitelist feature specifically.

---

## Phase 2 — MRU tracking, two levels (in-memory, no daemon)

**Goal:** track most-recently-used order at **both** the app level
(layer 0 ordering/pre-selection) and the window level (layer 1 ordering
within a drilled-into app) so cycling has classic alt-tab semantics at
either layer.

- `property var appMru: []` — array of `appId` strings, most-recent-first.
- `property var appWindowMru: ({})` — **per-app** map of `appId` →
  most-recent-first array of window addresses, e.g.
  `{ "firefox": ["0xaaa", "0xbbb"], "emacs": ["0xccc"] }`. This is a
  cleaner structure than a single global window-MRU list: layer 1
  sorting for a drilled-into app is a direct lookup
  (`appWindowMru[appId]`) instead of filtering a flat list by app on
  every drill-down.
- Both live in the QML root, survive across overlay open/close since
  Quickshell itself is long-running:
  ```js
  Connections {
      target: Hyprland
      function onActiveToplevelChanged() {
          let t = Hyprland.activeToplevel;
          if (!t) return;
          let appId = t.wayland?.appId ?? "unknown";
          let addr = t.address;
          window.appMru = [appId, ...window.appMru.filter(a => a !== appId)];
          let winList = window.appWindowMru[appId] || [];
          window.appWindowMru[appId] = [addr, ...winList.filter(a => a !== addr)];
      }
  }
  ```
- Layer 0 build order: sort `layer0Apps` by position in `appMru`
  (unknown/new apps sort last), pre-select index `1` (the previous app) —
  or index `0` if fewer than 2 apps exist yet (fresh Quickshell restart,
  MRU still empty).
- Layer 1 build order (on drill-down): sort the selected app's `windows`
  by position in `appWindowMru[appId]`, pre-select index `0` (that app's
  most recent window — if the app is currently active, this is the
  window you drilled down from; that's fine, it just means Tab is needed
  once to move off it).
- **Wrap-around** is configurable: `cfg.cycling?.wrapAround ?? true`.
  Default `true` — Tab past the last item wraps to index 0. `false`
  makes Tab a no-op past the last item instead.
- **Pruning on window close:** subscribe to `Hyprland.rawEvent` and
  match Hyprland's socket2 `closewindow>>` event to know exactly which
  address closed (rather than diffing the whole toplevels list every
  time):
  ```js
  Connections {
      target: Hyprland
      function onRawEvent(event) {
          if (!event.startsWith("closewindow>>")) return;
          let addr = event.substring("closewindow>>".length);
          for (let appId in window.appWindowMru) {
              let list = window.appWindowMru[appId];
              let idx = list.indexOf(addr);
              if (idx !== -1) {
                  list.splice(idx, 1);
                  if (list.length === 0) {
                      delete window.appWindowMru[appId];
                      window.appMru = window.appMru.filter(a => a !== appId);
                  }
                  break;
              }
          }
      }
  }
  ```
  This runs even while the overlay is closed, so MRU stays accurate
  continuously rather than needing a catch-up pass on next open.

**Exit criteria:** Alt+Tab (single tap, immediate release) always swaps
to the previously used **app**'s most recent window. Drilling into an
app and cycling always starts from that app's most recently focused
window. An app whose last window closes disappears from layer 0 on the
very next open, not just after a stale-address cleanup pass.

---

## Phase 3 — Trigger wiring (one Hyprland bind + client-side key handling)

**Goal:** get the overlay open and focused with a single Hyprland bind;
handle everything else — Tab cycling, `;` drill-down, Escape, and the
Alt-release commit — directly in QML via Qt's `Keys.onPressed`/
`Keys.onReleased` on the now-focused overlay window.

**How we got here:** the original plan for this phase went through
several iterations that turned out to be solving the wrong problem:

1. A submap-scoped release-bind (`{ release = true }` inside
   `hl.define_submap`) — confirmed broken by direct test: the release
   notification never fired, matching
   [issue #3058](https://github.com/hyprwm/Hyprland/issues/3058) and
   [issue #5292](https://github.com/hyprwm/Hyprland/issues/5292). A
   `submap_universal = true` variant was also tried as a mitigation; it
   was abandoned in favor of the `keyd` approach next, though no
   separately-saved test transcript confirms exactly how it failed —
   worth treating as "also didn't pan out" rather than "confirmed broken
   in the same documented way" as the plain submap-scoped case.
2. `keyd`'s `overload(alt, f24)`, intended to synthesize a release event
   below the compositor — also confirmed broken by direct test, for a
   different reason: `overload()`'s tap-action only fires if the key
   was *not* chorded with another key during the hold, and Alt+Tab is
   inherently a chord, so the F24 event never fired in real usage (only
   in the artificial bare-Alt-tap case).
3. **What actually works, confirmed by direct test:** Hyprland's
   `ALT + Tab` bind only intercepts that specific bound combo — it does
   not grab the raw keyboard stream. Once the overlay window has
   keyboard focus, it receives Alt press, repeated Tab press/release,
   and Alt release directly via Qt's own key event handlers, through
   the *actual* press→cycle→release sequence, not just a bare tap. No
   submap, no external tool, no per-keystroke IPC round-trip needed.

### `keymaps.lua` — the only Hyprland-side change needed

```lua
hl.bind("ALT + Tab", hl.dsp.exec_cmd("qs ipc call hyprsphere show"))
```

That's the entire Hyprland-side footprint. No submap, no release-bind,
no `keyd`/Nix changes.

### QML — `IpcHandler` shrinks to one function

```qml
import Quickshell.Io

IpcHandler {
    target: "hyprsphere"
    function show(): void { window.openSwitcher() }
}
```

### QML — everything else via `Keys.onPressed`/`Keys.onReleased`

`openSwitcher()` (Phase 4) sets `window.visible = true` and calls
`forceActiveFocus()` on a focus-holding `Item` covering the overlay.
Once focused, that item's key handlers drive the rest of the
interaction directly — no IPC involved after the initial `show`:

```qml
Item {
    id: focusGrabber
    anchors.fill: parent
    focus: true
    Keys.priority: Keys.BeforeItem  // must see Tab/Escape before any
                                     // child MouseArea (sphere delegates,
                                     // satellite Loader) could consume them

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Tab) {
            if (event.modifiers & Qt.ShiftModifier) window.advance(-1);
            else window.advance(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Semicolon) {
            window.drillDown();
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            window.cancelSwitch();
            event.accepted = true;
        }
    }
    Keys.onReleased: (event) => {
        if (event.key === Qt.Key_Alt) {
            window.commitSelection();
            event.accepted = true;
        }
    }
}
```

Qt's native key-repeat handles "hold Tab to auto-advance" the same way
it always has in this codebase (the launcher's `TextField` relied on
the same underlying repeat behavior for arrow-key navigation) — no
`{ repeating = true }` flag needed since that was a Hyprland-bind-level
concept that no longer applies here.

**Exit criteria:** confirmed already, by direct test, through the real
interaction — Alt press → three Tab presses (each correctly reporting
Alt as an active modifier) → Alt release all reached the client and
fired in order. Remaining work for this phase is purely wiring `advance`/
`drillDown`/`commitSelection`/`cancelSwitch` (Phase 4) into these
handlers instead of into `IpcHandler` functions — the functions
themselves don't change, only what calls them.

---

## Phase 4 — Selection & commit logic (two-layer state machine)

**Goal:** add a layer-aware state machine (`layer`, `drilledAppId`) with
`drillDown()` and `commitSelection()`, plus click-to-select / double-click-
to-commit on sphere nodes. Window titles shown at layer 1. See
`PHASE_4.md` for the full implementation plan and `PHASE_4_TESTS.md` for
the test suite.

**Summary of deliverables:**
- `property int layer: 0` / `property string drilledAppId: ""`
- `drillDown()` — toggles between app groups (layer 0) and per-app window
  list (layer 1), enriched node shape (icon+label carried from parent app).
  Always allowed — even single-window apps drill in (shows window title).
- `commitSelection()` — `closeSequence.running` guard, layer-aware address
  resolution (with existence check against `node.windows` rather than
  blindly trusting MRU order), whitelist exec launch, `overlayActive` reset,
  `Hyprland.dispatch("focuswindow address:...")`
- `cancelSwitch()` resets layer + drilledAppId
- `openSwitcher()` initialises layer = 0, calls `forceActiveFocus()`
- `scheduleRebuild()` is layer-aware (rebuilds window list at layer 1,
  falls back to layer 0 if drilled app is gone)
- `advance()` no-op on "No windows" placeholder
- Satellite + normal card text shows `title` at layer 1, `label` at layer 0
- `onClicked` selects node + `centerOnApp`; `onDoubleClicked` commits
- `closewindow` pruning triggers `scheduleRebuild()` for stale nodes

**Exit criteria:** full press→hold→cycle→(optional `;` drill)→cycle→
release→focus loop works at both layers; mouse click/double-click works;
window titles are visible at layer 1; Escape+Alt release race is guarded.

---

## Phase 5 — Ctrl+C close windows

**Goal:** add a `Ctrl+C` keybind to close the selected window (or all
windows of an app at layer 0) via `Hyprland.dispatch("closewindow address:...")`.

- `Keys.onPressed` handler for `Qt.Key_C` with `Qt.ControlModifier` in
  `focusGrabber`.
- At **layer 0**: close **all windows** of the selected app group. The
  app disappears from the sphere if all its windows close.
- At **layer 1**: close only the **specific selected window**.
- Handle edge cases:
  - Last window of an app closes → app removed from `appMru` and `sphereModel`
  - If that was the only app left → fall through to "No windows" placeholder
  - If closing a window at layer 1 leaves only 1 window → return to layer 0
- `closeSequence.running` guard: if already closing, no-op.
- Test that the overlay remains usable after a close (window removed from
  sphere, correct node selected next).

**Exit criteria:** Ctrl+C at layer 0 closes all windows of the selected
app; Ctrl+C at layer 1 closes only the selected window; overlay state
remains consistent after close (no stale nodes, correct layer fallback).

---

## Phase 6 — Search bar with fuzzy filtering (layer 2) ✅ IN PROGRESS

**Status:** Implemented and needs testing. Adds a search bar at bottom-center
of the overlay. Typing any letter/digit enters **layer 2** — the sphere
rebuilds with fuzzy-filtered results from Fuse.js, ordered: matching running
apps → matching whitelisted apps → matching windows.

**Key design:**
- Search bar is a readOnly TextField (text set programmatically) — no
  keyboard focus conflict with Tab cycling
- Fuse.js v7.0.0 (from polysphere/lib/) — proven working, QML-compatible
- Backspace when empty returns to layer 0; Escape always closes overlay
- `;` on an app node at layer 2 drills into that app's windows (layer 1);
  `;` again restores the search results
- Commit at layer 2: MRU-most for apps, direct address for window nodes
- All search/Fuse options configurable in hyprsphere.json under `search` block

See `PHASE_6.md` for full implementation details.

**Next:** Testing — ensure no regressions on layers 0/1, verify drill-down
round-trip from layer 2, verify Fuse results are correctly ordered, verify
search bar appearance/behavior.

---

## Phase 7 — Icon resolution (no daemon, one-shot)

Windows don't carry an icon path, so `appId` needs mapping to an icon
name. Since layer 0 is grouped by app, this is now naturally a
**per-appId** lookup — resolved once per group, reused for every window
under that group at layer 1.

- On `Component.onCompleted`, run a single `Process` that scans
  `/usr/share/applications/*.desktop` (and `~/.local/share/applications`)
  once, building `{ appId: iconName }` in a JS object (`window.iconMap`).
  This is a one-shot script, not a persistent process — no daemon needed.
- Fallback chain per node: `iconMap[appId] ?? appId ?? "application-x-executable"`,
  fed into the same `image://icon/...` provider the launcher already uses.
- `Quickshell.DesktopEntries` (built-in, `import Quickshell`) may cover
  this lookup natively — check it before hand-rolling the `.desktop` scan;
  it already indexes desktop entries for the shell.

**Exit criteria:** every layer-0 sphere node shows the correct app icon,
not the generic fallback, for all normally-installed GUI apps; layer-1
nodes for that app's windows show the same icon (window-level icon
variance isn't a thing worth chasing for v1).

---

## Phase 8 — Visual/UX carryover and cleanup

- Sphere projection math (`rebuildProjCache`, `project3D`, Fibonacci
  lattice), drag-to-rotate, auto-rotate timer, intro/exit animation,
  satellite detail card: all reusable **unchanged**. This is the payoff of
  keeping the same frontend — only the data layer and commit action
  changed, and it's rebuilt wholesale on layer transitions rather than
  patched in place.
- Satellite card's "screen" content depends on layer: at layer 0 it shows
  app icon + app name (+ optional window-count badge, e.g. "3 windows",
  as a hint that `;` does something); at layer 1 it shows the specific
  window's icon + title.
- Card label text: app name at layer 0, window title at layer 1 — titles
  are longer and more dynamic, so re-check `elide`/`wrapMode` behavior at
  layer 1 once real titles are flowing in (a Chrome window titled with a
  full page title is a good stress test).
- Consider a subtle transition (brief scale/fade) on layer change so the
  sphere rebuild doesn't feel like a jump-cut — reuse the existing
  `introPhase` fade machinery rather than building a new one.
- Remove now-dead config keys from `hyprsphere.json` that were
  launcher-specific (`appFetchChunkSize`, anything referencing `exec`).

---

## Decisions locked (previously open questions)

1. **Multi-monitor scope: all monitors, no filtering.** Layer 0 already
   spans all workspaces (decided last round) — filtering by monitor while
   not filtering by workspace would be an inconsistent rule to explain
   later. One sphere, everything running, full stop.
2. **Special-workspace windows: excluded from layer 0 by default.**
   Hyprland has no true minimize, but special (scratchpad-style)
   workspaces exist and are normally summoned via their own dedicated
   keybind — they shouldn't also surface on every Alt+Tab. If an app's
   *only* window lives on a special workspace, the whole app is dropped
   from layer 0 rather than appearing with no visible windows. See the
   `buildLayer0()` filter in Phase 1.

Both of these are one-line flips if they turn out wrong in practice —
worth a `hyprsphere.json` config key (`includeSpecialWorkspaces`,
`monitorScope`) in a later pass rather than hardcoding forever, but
hardcoded is the right starting point for v1.

---

## Explicitly out of scope for v1

- Guile daemon / Unix socket IPC — not used in this build.
- Text search / fuzzy filtering while switching.
- More than two layers (e.g. grouping by workspace *and* app) — the
  app→window two-layer model is the full scope for v1.
- **Late-appId resolution rebuild** (`scheduleRebuild()`). When a window
  first opens, its `wayland.appId` can be `null` for a brief window
  (Wayland handshake not yet complete). If the overlay is opened during
  that window, the toplevel appears as `"unknown"` until the next
  `openSwitcher()` call. The current code has a debounced
  `scheduleRebuild()` function but no trigger wired to fire it — the
  detection mechanism (connecting to per-toplevel `wayland` property
  changes or parsing `rawEvent` for `openwindow>>`) is underspecified.
  In practice this is a near-zero-occurrence race (windows resolve
  their `appId` within milliseconds of appearing), but if it does bite
  during Phases 3–8, revisit by wiring `Hyprland.rawEvent` or toplevel
  property-change signals to call `scheduleRebuild()`.