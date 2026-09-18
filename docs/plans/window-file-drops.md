# Incoming window file drops

Status: whole-window API direction approved; implementation is not yet available.

## Application surface

Trusted native window creation opts in with `WindowOptions({ fileDrop: true })`.
The default is false. Renderer-authored create options must not enable native
path delivery on their own.

Native consumers subscribe through `window.events.filesDropped`. Frontend
consumers use the existing handle subscription pattern:

```ts
import { currentWindow, WindowEvent } from "@zappdev/runtime/window";

const subscription = currentWindow().subscribe(
  WindowEvent.FILES_DROPPED,
  ({ paths, position }) => {
    void importNotes(paths).catch(showError);
  },
);

subscription.unsubscribe();
```

Position is relative to the top-left WebView viewport in CSS coordinates, not
desktop coordinates or physical pixels. Related windows must identify their
actual target document, not route the drop as if it occurred in the owner.

## Acceptance and authority

- A native synchronous `fileDropRequested` event can reject with `event.cancel()`.
  The final `filesDropped` event is observational; JavaScript cannot asynchronously
  veto an OS drop that has already completed.
- Enter, move, and leave notifications support highlighting without exposing
  absolute paths or creating grants before a drop. Hover delivery is coalesced;
  it does not repeatedly serialize paths or read file contents.
- Accepted existing local files receive exact, session-only application path
  grants, consistent with dialog grants. Dropping a path grants no operation
  permission: `fs:read`, `fs:write`, trash, and other operations remain subject
  to their existing checks.
- Validate the complete batch before publishing grants. Cancellation, invalid
  items, document replacement, and close must not leave partially granted input.
- Bind native acceptance and renderer delivery to the current document identity.
  Recheck after synchronous user callbacks, and guard asynchronous delivery
  against a replacement document.
- Disabled or unsupported external file drops must not navigate the WebView.
  Ordinary text dragging and internal HTML drag-and-drop stay native.

The first tier allows multiple existing local files. Directories, file promises,
drag-out, and DOM drop zones are deferred. Z Notes will demonstrate dropping a
text file to create a note, with visual drag feedback.

## Native integration boundary

AppKit exposes drag-destination callbacks as optional protocol requirements
inherited by NSView, not concrete declarations on WKWebView. Z needs their
signatures for checked overrides and protocol-qualified sender values. It must
not turn an optional requirement into a promised superclass implementation.

Before wiring the drop receiver, establish safe superclass delegation for the
ordinary WebKit drag path. Do not bypass the compiler with an Objective-C shim,
silently return a generic default for all drag kinds, or disable ordinary HTML
dragging to get file drops working.
