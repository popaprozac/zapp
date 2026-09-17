# Remembering window placement

Opt a native-created window into placement restoration with a stable key:

```zs
import { WindowOptions } from "zapp/window";

const window = try app.windows.create(WindowOptions({
  title: "Z Notes",
  width: 900,
  height: 640,
  minWidth: Option.some(u32(600)),
  minHeight: Option.some(u32(400)),
  stateKey: Option.some("notes.main"),
}));
```

Omit `stateKey` for a window that should always use its creation defaults.
The current implementation is available on macOS.

## What is remembered

Zapp remembers the ordinary **content size**, the outer frame's top-left
position, and whether the window was maximized. It applies that placement
**before showing** a new window with the same key. Minimized and fullscreen
states are not restored. Maximization is restored only when the current
`maximizable` and `resizable` policies allow it.

The current minimum/maximum content sizes still apply. If a display has been
removed or the saved rectangle is offscreen, Zapp recovers the placement into
a current display's work area. Oversized windows keep their top-left accessible;
display recovery does not override an application's minimum size. Coordinates
are logical desktop units, not physical pixels or persistent display IDs.

This does **not** reopen windows automatically. Application code still decides
which windows to create, what they display, and whether they are visible.
Document/session restoration is a separate application concern.

## Keys and authority

- Use stable names such as `notes.main` or `settings`, not a runtime window ID.
- Two live windows in one application cannot have the same key. Creation fails
  with `WindowError`; a closed window releases its key for reuse.
- Keys contain 1–256 UTF-8 bytes. They are data inside the state file, never paths.
- Only native Z `WindowOptions` accepts `stateKey`. Frontend `createWindow()`
  and `createRelatedWindow()` reject it, including at the native bridge boundary.

Once a native window is opted in, moves and resizes made through its frontend
handle are remembered too. The renderer does not gain access to the saved-state
catalog or filesystem.

Z Notes opts in its main window. Related note inspectors remain explicitly
positioned beside their owner and are not persisted.

## Storage and shutdown

Zapp owns `window-state.json` beneath `ApplicationContext.paths.data`, with a
versioned schema separate from `zapp.config.ts`. It uses adjacent
`window-state.lock` and `window-state.pending` files for serialized atomic
replacement. Do not use these filenames for application data.

State is loaded lazily on the first opted-in creation. Missing, corrupt, or
unsupported-version data falls back to the creation defaults. Read/write
failures are diagnostic messages, not startup failures.

Native callbacks update an in-memory queue. A background writer coalesces bursts
over 200 ms and does JSON encoding and disk I/O outside the UI thread. There is
no polling while idle. Accepted window closure does not wait for a save;
application shutdown joins the final writer after native windows have closed.

Saving is best-effort. Atomic replacement prevents readers seeing a partially
written file, but it is not a power-loss durability guarantee. A forced process
termination may lose the latest unsaved movement. This is a small placement
catalog (up to 1,024 keys), not a history of every window ever opened.

For explicit placement and measurement, see [window positioning](window-positioning.md)
and [bounds and displays](window-displays.md).
