# Window positioning

Use the same handle for measuring, moving, and centering a window:

```ts
import { currentWindow } from "@zappdev/runtime/window";

const window = currentWindow();
const position = await window.getPosition();
await window.setPosition({ x: position.x + 40, y: position.y + 20 });
await window.center();
```

Positions describe the **outer frame's top-left**, in logical desktop units
(points on macOS), not physical pixels or the WebView's content coordinates.
The origin is the primary display's top-left; x grows right and y down.
Displays left of or above the primary display can have negative coordinates.
Signed fractional coordinates are supported. NaN and infinities are rejected.

`center()` geometrically centers the outer frame in the current display's
usable area, excluding reserved system areas. If the window has no current
display, the primary display is used. This differs from AppKit's visually
elevated `NSWindow.center()` placement.

## State and timing

- Moving and centering do not show, focus, or unminimize a window.
- A non-resizable window can still be positioned programmatically.
- During maximize/fullscreen or a system transition, the latest placement
  request waits for ordinary presentation; it never forces an exit.
- Deferred size and placement compose into one target frame. A deferred center
  uses the resulting size and display work area when it is applied.
- Closing the window discards pending geometry.

Promises acknowledge native handling, **not animation completion**.
`getPosition()` returns the actual current frame, which can be intermediate
during an animation. There is no framework off-screen clamping; the operating
system may still constrain placement.

Related-window handles use their own document's bridge and expire with that
document. Positioning adds no authority to the family. Invalid frontend
arguments reject with `TypeError`; unavailable native windows reject with
`WindowError`.

## Native Z

```zs
import { Window, WindowPosition, WindowError } from "zapp/window";
import { thread } from "std/thread";

function moveEditor(window: Window): WindowPosition throws WindowError on thread.main {
  try window.setPosition(WindowPosition({ x: 120.5, y: 100 }));
  return try window.getPosition();
}

function centerEditor(window: Window): void throws WindowError on thread.main {
  try window.center();
}
```

Native operations require `thread.main` and throw when the native window is
unavailable, including before startup or after close. Initial position options,
outer-bounds queries, explicit display selection, and geometry persistence
remain separate future APIs. Content dimensions use [window sizing](window-sizing.md).
