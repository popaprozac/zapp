# Window bounds and displays

Measure a window and its current display through the window handle:

```ts
import { currentWindow } from "@zappdev/runtime/window";

const window = currentWindow();
const bounds = await window.getBounds();
const display = await window.getDisplay();
if (display) {
  console.log(bounds, display.workArea, display.scaleFactor);
}
```

The same methods are available on related-window handles. `Bounds` and `Display`
are type exports from `@zappdev/runtime/window`:

```ts
interface Bounds {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

interface Display {
  readonly id: string;
  readonly bounds: Bounds;
  readonly workArea: Bounds;
  readonly scaleFactor: number;
  readonly isPrimary: boolean;
}
```

## Coordinates and meaning

- `getBounds()` measures the **outer window frame**, excluding shadows.
  `getSize()` instead measures the content area. Neither returns a pending resize target.
- All rectangles use logical desktop units (points on macOS), with the primary
  display's top-left as origin, x increasing right and y increasing down.
  Negative and fractional coordinates are valid.
- Display `bounds` covers the full display. `workArea` excludes system-reserved
  space such as the menu bar and Dock. Both use the same global coordinates.
- `scaleFactor` describes backing-pixel density. Do **not** multiply the rectangle
  coordinates by it when calling `setPosition()`.
- `id` is opaque; it is not a persistent identity across restarts or reconnects.

The macOS backend uses the screen containing most of the window. An offscreen
window with no owning display returns `null`, **not the primary display**.
`center()` separately retains its documented primary-display fallback.

## Snapshots and lifetime

These are read-only value snapshots, not live display handles. Frontend values
are copied and frozen, including nested rectangles. Moving a window, unplugging
a display, or closing the window does not change an earlier snapshot. Separate
queries are not an atomic desktop transaction; re-query when current values matter.

Queries reject with `WindowError` before native startup, after close, or when
native measurement is unavailable. A related document's expired handle rejects
with `RelatedWindowInvalidatedError`. Neither failure is represented as `null`.
The methods do not show, focus, restore, or otherwise change window presentation.

## Native Z

```zs
import { Window, Bounds, Display, WindowError } from "zapp/window";
import { thread } from "std/thread";

function measure(window: Window): Bounds throws WindowError on thread.main {
  return try window.getBounds();
}

function owningDisplay(window: Window): Option<Display> throws WindowError on thread.main {
  return try window.getDisplay();
}
```

Z uses readonly value structs with `f64` rectangle fields and scale factor,
`String` display ID, and `boolean` primary flag. These snapshots contain no
native references. `Option.none` means an otherwise valid window has no display.

## Placing a companion window

Z Notes creates its inspector hidden, mounts its component, measures both outer
frames and the owner's work area, then positions and shows it. It prefers the
right side, tries the left, and overlaps the owner if necessary to stay visible.
An inspector larger than the usable area is aligned so its top-left remains
accessible. Without an owner display, Notes explicitly chooses `center()`.

That is **application policy**, not automatic related-window behavior. Zapp does
not clamp all windows or continuously follow their owner. This tier does not
provide `setBounds()`, display enumeration, display-change events, or saved
geometry restoration.
