# Window positioning

Status: implemented for macOS, native Z, and ordinary/related frontend handles.

Developer guide: [window positioning](../window-positioning.md).

## Approved contract

- `getPosition()` returns the actual outer-window top-left, not WebView/content
  coordinates or the requested animation destination.
- `setPosition({ x, y })` accepts finite signed fractional logical coordinates.
  The desktop origin is the primary display's top-left; x grows right and y down.
  Displays above or to the left can have negative coordinates.
- No framework off-screen clamping. The operating system can constrain placement.
- `center()` geometrically centers the outer frame in the current display's
  usable area, falling back to the primary display. This is intentionally not
  AppKit's visually elevated `NSWindow.center()` placement.
- Neither operation shows, focuses, or restores the window. A non-resizable
  window can still be moved programmatically.
- During maximize/fullscreen, the latest positioning intent waits for ordinary
  presentation. Size and placement are composed into one target frame. Centering
  uses that resulting size and the display work area at application time.
- A close discards pending geometry. Promise resolution acknowledges native
  handling, not animation completion.
- Native Z methods use `WindowPosition { x: f64; y: f64; }`, require
  `thread.main`, and throw `WindowError` if native storage is unavailable.
- Related handles keep their child-document bridge and expiration rules.

## Evidence and remaining boundary

Native probes exercise primary-origin conversion, negative and fractional
coordinates, geometric centering, fixed-window movement, combined pending
size/position, native maximize/restore, synchronous delegate reentrancy, and
close cleanup. They pass through Stage 0 and the native compiler at `-O0` and
`-O2` with UBSan. Existing sizing and native presentation checks remain green.
Frontend proxy tests cover validation, acknowledgement, and child lifetime.
Real multi-display layouts and visible fullscreen transitions still need manual
validation; synthetic geometry tests are not a substitute for that evidence.

The position response uses Z's derived finite-`f64` encoder. Typed
`json.encode` consistently declares `throws JsonEncodeError`; transport catches
failures and returns a failed response with a fixed valid fallback, never
success with malformed JSON or a silently truncated coordinate. Fractional
bridge round-trips and serialization failure are native regression tests.
Z Notes exposes Center Notes, explicit movement, and measured-position controls.
Outer bounds and current-display snapshots now support explicit Notes inspector
placement. See [bounds and display snapshots](../window-displays.md). The pure
bridge tests cover nested finite-float JSON, no-display versus unavailable-window
results, detached values, and closed handles. AppKit tests cover frame versus
content size, visible/full display coordinates, backing scale, and a truly
offscreen window without a primary fallback. The Notes smoke checks placement
through the production bridge before exercising shared component state.

Contributor commands:

```sh
bun native/z/testing/window-focus.ts --positioning --native
bun native/z/testing/window-focus.ts --positioning
VITE_ZAPP_SVELTE_SMOKE=1 bun cli/src/test-notes-launch-macos.ts
```
