# PHASE_10 — Gate overlay visibility on data readiness

**Deliverable:** On first open (and every open), the overlay only becomes
visible after `finishOpenSwitcher()` has populated the sphere with real
data. This eliminates the "different overlay on startup vs re-open"
problem — no stale `sphereModel` flash, no empty-to-populated transition,
no zoom/drift artifacts. The user sees either nothing or the fully-built
sphere, every time.

---

## Rationale

The root cause is a **timing gap** in `openSwitcher()`:

```
openSwitcher() →
    window.visible = true           ← overlay visible NOW with stale/empty data
    Qt.callLater → finishOpenSwitcher() → sphereModel populated LATER
```

On first launch after quickshell starts, `sphereModel` is `[]` (the
initial property value), so the overlay appears transparent/empty until
`finishOpenSwitcher()` retries through its icon-readiness and toplevel
checks and finally populates the model.

On re-open (after Escape), `sphereModel` still holds the **previous
session's data** — `cancelSwitch()` does not clear it. So the overlay
appears immediately with old apps/windows, then flashes to the new data
a frame or two later. `selectedAppIndex` and `sphereZoom` are also stale,
creating visible jumps in the satellite card and zoom level.

The fix moves `visible = true` (and the entrance animation trigger) from
`openSwitcher()` into `finishOpenSwitcher()`, after the sphere data is
ready. The overlay stays invisible during the async data-gathering phase,
then appears all at once with the correct content, correct selection,
and correct zoom.

---

## Implementation

### 1. Move visibility and animation out of `openSwitcher()`

**Before:**
```qml
function openSwitcher() {
    window.layer = 0;
    window.drilledAppId = "";
    window.searchQuery = "";
    window.savedLayer2Model = [];
    window.savedLayer2Query = "";

    window.focusable = true;
    window.overlayActive = true;
    window.visible = true;
    introPhaseAnim.restart();
    focusGrabber.forceActiveFocus();

    Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("hyprsphere"))']);

    Hyprland.refreshToplevels();
    Qt.callLater(function() { finishOpenSwitcher(); });
}
```

**After:**
```qml
function openSwitcher() {
    window.layer = 0;
    window.drilledAppId = "";
    window.searchQuery = "";
    window.savedLayer2Model = [];
    window.savedLayer2Query = "";

    window.focusable = true;
    window.overlayActive = true;

    Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.submap("hyprsphere"))']);

    Hyprland.refreshToplevels();
    Qt.callLater(function() { finishOpenSwitcher(); });
}
```

Removed three lines:
- `window.visible = true`
- `introPhaseAnim.restart()`
- `focusGrabber.forceActiveFocus()`

### 2. Add visibility and animation to `finishOpenSwitcher()`

**Before** (last lines of the function):
```qml
    projDirty = true;
    rebuildProjCache();

    // Initialize Fuse index for search
    initFuseIndex();

    // Refresh on next tick to catch pending appId resolutions.
    Qt.callLater(function() { scheduleRebuild(); });
```

**After:**
```qml
    projDirty = true;
    rebuildProjCache();

    // Initialize Fuse index for search
    initFuseIndex();

    // Now that sphere data is ready, make the overlay visible.
    // The entrance fade animation and keyboard focus are handled
    // by onVisibleChanged, which fires automatically.
    window.visible = true;

    // Refresh on next tick to catch pending appId resolutions.
    Qt.callLater(function() { scheduleRebuild(); });
```

The `onVisibleChanged` handler already takes care of the entrance
animation and focus grab:
```qml
Connections {
    target: window
    function onVisibleChanged() {
        if (window.visible) {
            window.sphereZoom   = 1.0;
            introPhaseAnim.restart();
            focusGrabber.forceActiveFocus();
        }
    }
}
```

So we get `introPhaseAnim.restart()` and `focusGrabber.forceActiveFocus()`
for free — no need to call them explicitly in `finishOpenSwitcher()`.

### 3. Edge case: Empty-state placeholder

If `finishOpenSwitcher()` builds a sphere with only the "No windows"
placeholder (e.g., no running apps at all), this is still **real data**
— the overlay appears with a meaningful state. No special handling
needed.

### 4. Edge case: Rapid Alt+Tab during data gathering

If the user presses Alt+Tab while `finishOpenSwitcher()` is still in its
retry loop (icons not ready, or toplevels empty):

- `IpcHandler.toggle()` checks `window.overlayActive`, which is `true`
  (set in `openSwitcher()`)
- It calls `window.advance(1)` instead of `openSwitcher()` again
- `selectedAppIndex` changes, but the overlay is still invisible
- When `finishOpenSwitcher()` eventually completes, it shows the correct
  state with the advanced index

This is benign — the advance is applied before the first render.

### 5. Edge case: Escape during data gathering

If the user presses Escape while `finishOpenSwitcher()` is still retrying:

- `Keys.onPressed` calls `window.cancelSwitch()`
- `cancelSwitch()` sets `overlayActive = false`, starts `closeSequence`
- `closeSequence` animates `introPhase` to 0.0 and sets `visible = false`
- Since the overlay was never made visible, the animation is invisible
  (but harmless)
- When `finishOpenSwitcher()` eventually runs, `overlayActive` is `false`,
  so `commitSelection()` guards prevent commits. But `finishOpenSwitcher()`
  will still set `visible = true` — this is a problem.

**Fix:** Add a guard at the top of `finishOpenSwitcher()` to abort if the
overlay is no longer active:

```qml
function finishOpenSwitcher() {
    // Guard: if the overlay was cancelled while we were gathering data, abort
    if (!window.overlayActive) {
        console.log("[hyprsphere] finishOpenSwitcher aborted — overlay no longer active");
        return;
    }
    // ... rest unchanged ...
}
```

This ensures that an Escape press during the async data-gathering phase
properly cancels the session without the overlay appearing unexpectedly
once the retry loop completes.

### 6. Edge case: `scheduleRebuild()` retry loop visibility

The `onRawEvent` closewindow handler also has a retry-like pattern that
toggles visibility:
```qml
if (window.visible) {
    window.visible = false;
    Qt.callLater(function() {
        window.visible = true;
    });
    scheduleRebuild();
}
```

This unmaps and remaps the surface to force the compositor to re-grant
keyboard focus. It only runs when the overlay is already visible, so it
doesn't interact with the Phase 10 changes.

### 7. Fullscreen on activate (configurable toggle)

**Objective:** When `fullscreenOnActivate` is set to `true` in
`hyprsphere.json`, any window committed via the overlay (Alt release,
double-click, or Ctrl+Enter spawn → Alt release) is automatically
maximized immediately after focus.

**Mode:** `"maximized"` — keeps the title bar and window decorations
visible while filling the workspace. This is the same mode used by the
`Alt + F` keybind in `keymaps.lua` (`hl.dsp.window.fullscreen({ mode =
"maximized" })`).

**Idempotency:** Uses `action = "set"` so that if the window is already
maximized, the dispatch is a no-op. This prevents accidental
un-maximizing when cycling back to an already-maximized window.

#### 7.1 Config

Add a single boolean toggle to `hyprsphere.json`:

```json
"fullscreenOnActivate": true
```

When `false` or absent, behavior is unchanged from the current
implementation (no fullscreen on commit).

#### 7.2 Path A — Normal window focus (address-based)

In `commitSelection()`, after the focus dispatch for existing windows
(layer 0 app groups and layer 1/2 window nodes):

```qml
// Focus the target window using Lua dispatch format.
var prefix = addr.indexOf("0x") === 0 ? "" : "0x";
Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.focus({window="address:' + prefix + addr + '"})']);

// Fullscreen on activate (if configured)
if (window.cfg.fullscreenOnActivate) {
    Quickshell.execDetached(["hyprctl", "dispatch",
        'hl.dsp.window.fullscreen({ mode = "maximized", action = "set", window = "address:' + prefix + addr + '" })']);
}
```

**Why pass the address to fullscreen too?** Because the focus and
fullscreen are separate `hyprctl` calls (two `execDetached` invocations).
If we relied on "active window" state, the focus might not have taken
effect by the time the fullscreen call ran. Passing the address directly
makes the fullscreen target explicit and eliminates the race condition.

#### 7.3 Path B — Whitelist placeholder launch

In `commitSelection()`, after the focus dispatch for whitelisted apps
(not yet running):

**Before:**
```qml
var sh = node.exec + ' & sleep 0.3 && hyprctl dispatch '
    + "'hl.dsp.focus({window=\\\"class:" + node.appId + "\\\"})'" + ' &';
Quickshell.execDetached(["bash", "-c", sh]);
```

**After (with fullscreenOnActivate):**
```qml
if (cfg.fullscreenOnActivate) {
    // Launch via exec_cmd with a PID-tracked maximize rule that is
    // enforced by the compositor continuously. Unlike a one-shot
    // dispatch, the app's init cannot override this — the compositor
    // re-applies maximize on every state change the window requests.
    Quickshell.execDetached(["hyprctl", "dispatch",
        'hl.dsp.exec_cmd("' + node.exec + '", { maximize = true })']);
    // Focus by class after a small delay
    Quickshell.execDetached(["bash", "-c",
        'sleep 0.5 && hyprctl dispatch hl.dsp.focus({window="class:' + node.appId + '"}) &']);
} else {
    // Original shell chain: launch + focus (no maximize)
    var sh = node.exec + ' & sleep 0.3 && hyprctl dispatch '
        + "'hl.dsp.focus({window=\\\"class:" + node.appId + "\\\"})'" + ' &';
    Quickshell.execDetached(["bash", "-c", sh]);
}
```

For Path B, the window doesn't exist yet at commit time. When
`fullscreenOnActivate` is true, instead of a one-shot fullscreen dispatch
(which apps like Blender override during init), we use Hyprland's
`hl.dsp.exec_cmd()` dispatcher with a **PID-tracked window rule**.
This records the PID of the spawned process and applies the maximize
rule on every window state change — the compositor enforces it
continuously, not just once.

#### 7.3.1 How the PID-tracked rule works ("the Blender fix")

**The mechanism:** `hl.dsp.exec_cmd(cmd, rules?)` takes an optional
`rules` table (here `{ maximize = true }`). Internally, Hyprland:

1. Spawns the command and records the process PID
2. Tracks all child processes of that PID in a process tree
3. For every window whose process tree includes the tracked PID,
   applies the window rule effects on **every state change**

This means when Blender (or any app) calls `xdg_toplevel.unset_maximized()`
during its initialization, Hyprland's rule engine intercepts the request
and re-applies maximize before the window is rendered. The rule persists
for the lifetime of the spawned process and is automatically cleaned up
when the process exits. No flag cleanup, no event handling, no polling.

**Why every event-based approach failed (Blender investigation):**

Blender opens 4-5 windows on startup, and its GHOST toolkit repeatedly
requests `unset_maximized` during initialization. All attempted approaches
shared the same fundamental problem — they dispatched fullscreen **once**
(or a few times), but Blender continued overriding the state:

| Approach | What happened |
|---|---|
| `openwindow` event → dispatch | Blender overrides after dispatch |
| `scheduleRebuild` retry → dispatch | Window registered in toplevels before init finishes |
| `activewindow` event → dispatch | Focus change happens during init cycle |
| `onActiveToplevelChanged` signal → dispatch | Same timing as activewindow |
| `Qt.callLater` chain (2-3 ticks) | Init cycle spans many ticks, not just 2-3 |
| Duplicate openwindow tracking | Correct but insufficient — Blender overrides all dispatches |
| `action = "set"` (no-op if already fullscreen) | Correct but doesn't help — Blender makes it "not fullscreen" again |

The `exec_cmd` approach succeeds because it's not a one-shot dispatch —
it's a **persistent rule** that the compositor applies on every state
change. Even if Blender requests `unset_maximized` 100 times, the rule
engine overrides it 100 times, and the window stays maximized.

#### 7.4 Edge case: Already fullscreen

The `action = "set"` parameter in the dispatcher means:
- If the window is NOT already maximized → set it maximized
- If the window IS already maximized → no-op

This is important because `fullscreen()` and `fullscreenstate()` without
`action = "set"` act as toggles — they would un-maximize an already
maximized window when you cycle back to it in the switcher. The `set`
action ensures idempotent behavior: commit always leaves the window
maximized, never toggles it off.

#### 7.5 Edge case: Config absent or false

When `fullscreenOnActivate` is not present in the config JSON (or is
set to `false`), the conditional guards evaluate to falsy and the
fullscreen dispatches are skipped. Zero behavioral change for existing
users.

#### 7.6 Interaction with gated visibility (Phase 10 main fix)

Both focus dispatches happen inside `commitSelection()`, which is only
reachable via Alt release, double-click, or the IPC `commit` handler.
The overlay is already visible at that point, so the Phase 10 changes
(visibility gating in `finishOpenSwitcher()`) don't interact with this
feature at all.

---

## Config

### New field: `fullscreenOnActivate`

| Field | Type | Default | Description |
|---|---|---|---|
| `fullscreenOnActivate` | boolean | `false` | When `true`, any window
  committed via the overlay is automatically maximized immediately after
  focus. Uses `mode = "maximized"` with `action = "set"` — if the window
  is already maximized, the dispatch is a no-op. |

Placed at the top level of `hyprsphere.json`:
```json
{
  "fullscreenOnActivate": true,
  ...existing config...
}
```

---

## Exit criteria

1. **First Alt+Tab** after quickshell starts — overlay appears only once
   sphere data is ready (no stale/empty flash)
2. **Re-open after Escape** — overlay appears identically to first open
   (no stale `sphereModel` flash from previous session)
3. **No visual difference** between first open and subsequent opens
4. **Entrance fade animation** still plays correctly on every open
5. **Keyboard focus** is grabbed when overlay appears
6. **Escape during data gathering** properly cancels the session (overlay
   never appears)
7. **Rapid Alt+Tab** during data gathering doesn't cause double-open or
   corruption
8. **`onVisibleChanged` handler** (`sphereZoom = 1.0`, `forceActiveFocus`,
   `introPhaseAnim.restart()`) fires correctly when visibility is set in
   `finishOpenSwitcher()`
9. **All existing features** continue to work: Tab cycling, `;` drill-down,
   search, Ctrl+C close, Ctrl+Enter spawn, Alt release commit, mouse
   interaction
10. **`fullscreenOnActivate: true`** — committing a window (Alt release)
    maximises it immediately after focus, at all layers (0, 1, 2)
11. **`fullscreenOnActivate: true`** — double-click commit also maximises
12. **`fullscreenOnActivate: true`** — Ctrl+Enter spawn then Alt release
    also maximises the spawned window
13. **`fullscreenOnActivate: true`** — whitelisted app launch on commit
    maximises the launched window (Firefox, KiCad, Sioyek, etc.)
14. **Multi-window app (Blender)** — whitelisted launch maximises ALL
    startup windows immediately, despite Blender internally requesting
    `unset_maximized` multiple times during its init cycle. Achieved via
    `hl.dsp.exec_cmd()` with a PID-tracked maximize rule rather than a
    one-shot fullscreen dispatch.
15. **Window already maximised** — committing it again does NOT un-maximise
    it (idempotent due to `action = "set"`)
16. **`fullscreenOnActivate: false`** (or absent) — no fullscreen dispatch
    occurs, existing behavior is preserved
17. **Race condition** — the fullscreen dispatch targets the committed
    window by address (not "active window"), so it works correctly even
    if a different window gains focus between the two `hyprctl` calls
