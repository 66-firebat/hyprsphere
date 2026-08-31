# PATCH — Peek window fade-out on commit

> On Alt-release commit, fade **only the peek snapshot** out over a
> configurable duration instead of hiding it instantly, so the window switch
> isn't exposed as a "flash" of the previously focused window.

---

## Locked decisions

| # | Decision |
|---|---|
| 1 | **Fade-out only** — no linger/pause before the fade |
| 2 | Config: **top-level `"peekFadeOutMs"`** in `hyprsphere.json`, default **300** ms |
| 3 | **Only the peek snapshot fades**; sphere cards + search bar disappear instantly |
| 4 | Focus dispatch is **immediate** (concurrent with the fade) |
| 5 | **Cancel (Escape) unchanged** — keeps its full-overlay fade via `closeSequence` |
| 6 | **Input disabled immediately** on commit (`focusable = false`) |
| 7 | **No reopen guard** — the 300 ms edge case is accepted |
| 8 | **Open behavior unchanged** — peek fades in with the overlay |

---

## Problem

When you release Alt to commit:

1. The overlay hides **instantly** (`window.visible = false`).
2. The peek snapshot is cleared **immediately** (`onOverlayActiveChanged` →
   `peekView.captureSource = null`).
3. `dispatchCommit(addr)` runs **asynchronously** (spawns `hyprctl`/`bash`).

Because the overlay is gone before the focus completes, Hyprland's active
toplevel is still the **previous** window for a few frames → a visible flash of
the old window, then the new window snaps in.

The peek overlay sits on `WlrLayer.Overlay`, i.e. **above** the focused window at
all times. So fading the peek while dispatching focus immediately means the new
window is already focused *behind* the fading snapshot — the snapshot dissolves
into the real window with no flash.

## Root cause (three facts)

| # | Fact | Where |
|---|---|---|
| 1 | Commit hides instantly (no fade) | `binds.js` `commitSelection()`: `overlayActive = false; visible = false` |
| 2 | Peek cleared on `overlayActive = false` | `shell.qml` `onOverlayActiveChanged` |
| 3 | Focus dispatch is async | `shell.qml` `dispatchCommit()` → `execDetached(["bash", "-c", …])` |

---

## Implementation

### 1. Config

```json
{
  "peekFadeOutMs": 300,
  "...": "..."
}
```

### 2. Decouple the peek's opacity from `introPhase`

Currently `peekView`, `scene3D` (sphere), and `searchContainer` all bind
`opacity: window.introPhase`. To fade *only* the peek while the sphere/searchbar
hide instantly, the peek needs its own opacity:

```qml
// shell.qml
property real peekOpacity: 1.0
```

```qml
ScreencopyView {
    id: peekView
    ...
    opacity: window.peekOpacity      // was: window.introPhase
}
```

On open, drive `peekOpacity` up to `1.0` in step with the existing
`introPhaseAnim` (entrance), preserving the current fade-in behavior (decision 8).

### 3. Rework `commitSelection()` (binds.js)

Replace the instant hide with: sentinel → disable input → dispatch focus →
hide sphere/searchbar instantly → fade the peek → then fully close.

```javascript
    var addr = resolveTargetAddress(window, node);
    window.stopPerpetual();

    // Sentinel first — only this address may update MRU.
    if (addr) {
        window._mruCommitAddr = addr.indexOf("0x") === 0 ? addr : "0x" + addr;
    }

    // Disable input immediately (decision 6).
    window.focusable = false;

    // Dispatch focus immediately (async) — completes during the fade.
    window.dispatchCommit(addr);

    // Hide sphere + searchbar instantly (decision 3).
    scene3D.visible = false;
    searchContainer.visible = false;

    // Fade the peek snapshot out, then close the overlay.
    window.startPeekFadeOut();
```

`startPeekFadeOut()` (shell.qml) fades `peekOpacity` `1.0 → 0.0` over
`cfg.peekFadeOutMs ?? 300`, and on completion hides the window and clears the
snapshot:

```qml
    function startPeekFadeOut() {
        commitFadeAnim.duration = cfg.peekFadeOutMs ?? 300;
        commitFadeAnim.start();
    }

    NumberAnimation {
        id: commitFadeAnim
        target: window; property: "peekOpacity"; to: 0.0
        easing.type: Easing.OutCubic
        onStopped: { /* only when it finished naturally, not .stop() */ }
    }
    // or a SequentialAnimation: NumberAnimation → ScriptAction {
    //     window.overlayActive = false;
    //     window.visible = false;
    //     peekView.captureSource = null;
    // }
```

A `SequentialAnimation` is cleaner than `NumberAnimation` + `onStopped`:

```qml
    SequentialAnimation {
        id: commitFade
        NumberAnimation {
            target: window; property: "peekOpacity"; to: 0.0
            duration: cfg.peekFadeOutMs ?? 300
            easing.type: Easing.OutCubic
        }
        ScriptAction {
            script: {
                window.overlayActive = false;
                window.visible = false;
                peekView.captureSource = null;
            }
        }
    }
```

`commitSelection` then calls `commitFade.start()` instead of `startPeekFadeOut()`.

### 4. Guard against double-fire

Reuse a `.running` check (`commitFade.running`) at the top of `commitSelection`,
mirroring the existing `closeSequence.running` guard.

### 5. Restore state on the next open

`openSwitcher()` / `finishOpenSwitcher()` must reset:
- `peekOpacity = 1.0` (and re-run the entrance fade-in per decision 8)
- `scene3D.visible = true`
- `searchContainer.visible = true`
- `window.focusable = true`

(These are already set in the open path; verify they're complete.)

---

## Edge cases

| Scenario | Behavior |
|---|---|
| Rapid double-commit | `commitFade.running` guard blocks re-entry |
| Reopen during the 300 ms fade | Accepted (decision 7) — `toggle()` may `advance()`; harmless |
| Commit to whitelist placeholder | Unchanged (uses `closeSequence` full fade) |
| `fullscreenOnActivate` | Fullscreen dispatch is async; the 300 ms fade must outlast it (verify on slow fullscreen apps) |
| Focus dispatch fails | Sentinel never matches; overlay still fades + closes (same as today) |

## Files modified

| File | Change |
|---|---|
| `hyprsphere.json` | Add top-level `"peekFadeOutMs": 300` |
| `shell.qml` | Add `peekOpacity`; `peekView.opacity` → `peekOpacity`; add `commitFade` SequentialAnimation; add `startPeekFadeOut()`/reset in open path; add `visible` handling for `scene3D`/`searchContainer` |
| `binds.js` | Rework `commitSelection()`: sentinel → `focusable=false` → dispatch → hide sphere/searchbar → `commitFade.start()` |

## Verification

- Manual: Alt+Tab to another app, release Alt — the sphere vanishes instantly,
  the peek snapshot fades over ~300 ms, and the new window appears with **no
  flash** of the old window.
- Manual: Escape cancel — unchanged (full-overlay fade).
- Manual: rapid Alt release x2 — no double-fire.
- Manual: type immediately after releasing Alt — keys are ignored (input disabled).
- Grep: `commitSelection` no longer contains `window.visible = false` on the main
  path; it calls `commitFade.start()`.
