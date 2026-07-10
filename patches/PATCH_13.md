# PATCH 13 — Fix IPC Toggle Advance Runtime Error

## Bug
The IPC handler's `toggle()` function calls `window.advance(1)` but `advance`
is not a method on the window object. It's a standalone function in `binds.js`
that takes `(window, dir)` as arguments.

The result is a `TypeError` every time the user presses Alt+Tab while the
overlay is already open (which is the normal way to cycle through windows):

```
TypeError: Property 'advance' of object ... is not a function
```

This means Tab-to-advance only works on the first press — subsequent presses
error silently and the overlay doesn't advance.

## Fix
Replace `window.advance(1)` with `Binds.advance(window, 1)`.

`Binds` is already imported at line 12 of `shell.qml`:
```qml
import "binds.js" as Binds
```

## Files Modified
| File | Line | Change |
|------|------|--------|
| `shell.qml` | 803 | `window.advance(1)` → `Binds.advance(window, 1)` |
