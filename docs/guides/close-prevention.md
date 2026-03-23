# Close Prevention

Zapp supports cancellable close events for "unsaved changes?" dialogs and similar patterns. Close prevention works at two layers: native Zen-C callbacks and JavaScript handlers.

## JavaScript (TypeScript)

Register a `CLOSE` event listener on a window. This automatically enables a native close guard — the window won't close until your handler decides.

```ts
import { Window, WindowEvent, Dialog } from "@zapp/runtime";

const win = Window.current();

win.on(WindowEvent.CLOSE, async () => {
    const result = await Dialog.message({
        title: "Unsaved Changes",
        message: "You have unsaved changes. Close anyway?",
        kind: "warning",
        buttons: ["Close", "Cancel"],
    });

    if (result.button === 0) {
        win.destroy(); // force-close, bypasses all guards
    }
    // Otherwise: do nothing, window stays open
});
```

### `close()` vs `destroy()`

| Method | Behavior |
|---|---|
| `win.close()` | Normal close — triggers close guards. If a CLOSE handler is registered, it fires and the window stays open until `destroy()` is called. |
| `win.destroy()` | Force-close — bypasses all guards (native and JS). Use this inside CLOSE handlers to actually close the window. |

**Important:** Always use `destroy()` inside CLOSE handlers. Using `close()` would re-trigger the guard, creating an infinite loop.

## Native (Zen-C)

Native callbacks return an `int` — `0` (ALLOW) or `1` (CANCEL):

```zc
fn on_close(data: WindowEventData*) -> int {
    if has_unsaved_changes() {
        return 1; // EventResult.CANCEL — blocks close
    }
    return 0; // EventResult.ALLOW
}

win.on(WindowEvent.CLOSE, on_close);
```

## Priority chain

When a user clicks the close button:

1. **Native Zen-C callback** runs first (synchronous). If it returns `CANCEL` (1), the window stays open. JS never sees the event.
2. **JS close guard** — if a JS `CLOSE` listener is registered, native blocks the close and fires the event to JS. JS decides: call `destroy()` to close, or do nothing to keep open.
3. **No guards** — if neither a native callback nor a JS listener is registered, the window closes normally.

## Platform implementation

| | macOS | Windows |
|---|---|---|
| Native hook | `windowShouldClose:` returns `YES`/`NO` | `WM_CLOSE` handler skips `DestroyWindow` if cancelled |
| Force close | `forceClose` flag bypasses `windowShouldClose:` | `forceClose` flag bypasses guard in `WM_CLOSE` |
| JS guard | `closeGuarded` property on window delegate | `closeGuarded` field on `ZappWindowEntry` |
