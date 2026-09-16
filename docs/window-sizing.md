# Window sizing

Use `getSize()` and `setSize()` on a window handle. Sizes describe the native
content area in logical units (points on macOS), not physical display pixels or
the outer frame. WebView page zoom does not change this unit.

```ts
import { currentWindow, WindowEvent } from "@zappdev/runtime/window";

const window = currentWindow();
await window.setSize({ width: 900, height: 640 });
const actual = await window.getSize();

const subscription = window.subscribe(WindowEvent.RESIZE, ({ size }) => {
  console.log(size.width, size.height);
});
// Dispose when this UI scope ends.
subscription.unsubscribe();
```

`setSize()` resolves when native code handles the request, **not** when an
animation finishes. `getSize()` measures the current native content area; during
an animation it can return an intermediate size. Resize events report observed
sizes, never a fabricated requested size.

If a window is maximized or fullscreen, its latest requested size is remembered
until it returns to ordinary presentation. Sizing never forces that transition.
Closing the window discards the pending request. Requests during the native
fullscreen transition are also deferred.

## Creation limits

The same independent optional limits apply to ordinary and related windows:

```ts
import { createWindow } from "@zappdev/runtime/window";

const editor = await createWindow({
  title: "Editor",
  width: 900,
  height: 640,
  minWidth: 600,
  minHeight: 400,
  maxWidth: 1600,
});
```

Dimensions and limits must be positive integers representable by `u32`. A
minimum cannot exceed its corresponding maximum. Omitted limits add no
application constraint. Invalid values fail before creating or resizing the
native window; otherwise creation and size requests clamp to the declared
limits. The platform can impose additional geometry constraints, so use
`getSize()` for the actual result. On macOS, sizing preserves the outer
top-left corner where native screen constraints permit.

`resizable: false` disables interactive edge resizing, not application calls to
`setSize()`. Maximization and fullscreen policy remain separate creation options.

Related-window handles use their own document-bound bridge and lose access when
that document is invalidated. Sizing does not add capabilities or change the
window family's authority.

## Native Z

```zs
import { Window, WindowSize, WindowOptions, WindowError } from "zapp/window";
import { thread } from "std/thread";

function resizeEditor(window: Window): WindowSize throws WindowError on thread.main {
  try window.setSize(WindowSize({ width: 900, height: 640 }));
  return try window.getSize();
}

// Supply these options to app.windows.create(...).
function editorOptions(): WindowOptions {
  return WindowOptions({
    width: 900,
    height: 640,
    minWidth: Option.some(u32(600)),
    minHeight: Option.some(u32(400)),
  });
}
```

Native get/set operations require `thread.main` and throw `WindowError` when
the native window is unavailable, including before application startup or
after close. Creation options, rather than `setSize()`, configure initial size.
Frontend invalid arguments reject with `TypeError`; native window failures
reject with `WindowError`.

Positioning, display selection, dynamic limit updates, and geometry persistence
are not part of this API yet.
