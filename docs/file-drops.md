# Window file drops

On macOS, trusted native window creation can accept existing local files:

```zs
const window = try app.windows.create(WindowOptions({
  title: "Notes",
  fileDrop: true,
}));
```

`fileDrop` defaults to `false`. It is native application policy, not an option
that frontend `createWindow()` can turn on. Related windows currently reject
external file drops; their inheritance policy and hover events remain pending.

## Frontend

```ts
import { Application } from "@zappdev/runtime/application";
import { currentWindow, WindowEvent } from "@zappdev/runtime/window";

const files = Application.current().files;
const subscription = currentWindow().subscribe(
  WindowEvent.FILES_DROPPED,
  ({ paths, position }) => {
    void Promise.all(paths.map(path => files.readText(path)))
      .then(importTexts)
      .catch(showError);
  },
);

// When the component or feature is torn down:
subscription.unsubscribe();
```

`paths` is a detached, immutable snapshot of canonical paths. `position` contains
`x` and `y` relative to the top-left WebView viewport in CSS pixels, accounting
for page zoom. The event is observational: asynchronous JavaScript cannot veto
an OS drop that has already completed.

## Native cancellation and observation

Subscribe to `window.events.fileDropRequested` for a synchronous decision and
call `event.cancel()` to reject. The request carries the complete validated path
batch and viewport position. `window.events.filesDropped` reports acceptance;
both also appear in `window.events.all`. Keep the returned subscriptions alive.

The framework validates the entire batch before granting anything. A cancelled
request, invalid item, closed window, or document replacement during the request
callback leaves no partial grants. A replacement document cannot receive a
queued event from its predecessor.

## File authority is not operation permission

Accepted files receive exact, session-only application path grants, like
dialog-selected files. The grants do not include siblings or directory contents
and disappear on application teardown. They do not grant `fs:read`, `fs:write`,
or shell permissions: the existing application ceiling and caller capability
checks still apply to each operation. A grant names a canonical path; it does
not pin a file's contents or inode against later filesystem changes.

The first tier accepts multiple existing regular files. Directories, file
promises, remote file URLs, drag-out, and DOM drop zones are not supported.
Disabled or rejected external file drops do not navigate the WebView. Ordinary
text and internal HTML dragging remain delegated to WebKit.

## Try it

Run `bun run spike:z-notes` or `bun run spike:z-notes:dev`, then drop a small
UTF-8 `.txt` file from Finder onto the main Notes window. The filename becomes
the note title, and its text becomes the subtitle.

Framework acceptance is atomic for the path batch; the demo creates one note at
a time, so a later read or service failure can leave earlier imported notes.
