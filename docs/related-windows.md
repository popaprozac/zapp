# Related windows

Use a related window when an inspector, detached editor, or palette should be
another document of the same frontend application—not another frontend startup.
The first implementation is available on macOS.

```ts
import { createRelatedWindow, RelatedWindowEvent } from "@zappdev/runtime/window";

const inspector = await createRelatedWindow({
  title: "Inspector",
  width: 440,
  height: 300,
});

const root = inspector.document.createElement("main");
inspector.document.body.append(root);

// Ordinary DOM code or a framework portal can render into this document.
// Its callbacks and objects can still belong to the frontend owner.
const button = inspector.document.createElement("button");
button.textContent = "Inspect selection";
button.onclick = () => console.log("Owner callback, child DOM");
root.append(button);

inspector.subscribe(RelatedWindowEvent.INVALIDATED, () => {
  button.onclick = null;
  root.remove(); // Unmount framework UI and release references here.
});

inspector.focus();
// inspector.close() requests ordinary native closure, including Z close vetoes.
```

## Creation and authority

The calling document is the owner. Both the application's permission ceiling
and that document's capability profile must permit `window:create`. The child
inherits the family's authority; it cannot select a stronger profile.

The supported options are `title`, `width`, and `height`. Dimensions are positive
integer logical units, defaulting to 900 × 640. The child is a minimal same-origin
shell: there is no `url`, second frontend entrypoint, or injection-profile option.

The Promise resolves after the native window exists, the original document has
`head` and `body`, its direct bridge has been activated, and native publication
has succeeded. This does **not** promise stylesheet/font readiness or first paint.
Failed unpublished creations roll back natively; creation is bounded rather than
waiting indefinitely. Native errors use `WindowError`, while denied authority
uses `PermissionDeniedError` from `@zappdev/runtime`.

## One document for the handle's lifetime

`RelatedWindowHandle` extends `WindowHandle`. Its `document` remains the original
document; it never follows a navigation to another page. Existing controls and
context menus use the child's direct native bridge, not a request relay through
the owner. The normal `WindowEvent` subscriptions remain available.

`RelatedWindowEvent.INVALIDATED` is terminal and observational. It is delivered
once per subscription, asynchronously, and remembered for late subscribers.
Unsubscribing stops that listener; it does not close the window. Native teardown
does not wait for JavaScript cleanup. A destroyed or blocked owner cannot be
promised timely callbacks, but native routing and resource retirement still run.

After invalidation, new handle operations fail with
`RelatedWindowInvalidatedError` (`code: "RELATED_WINDOW_INVALIDATED"`). Pending
child requests are rejected through the existing child transport. Keep the
invalidation subscription to unmount UI and release your document references.

Closing an owner closes its related subtree after native close preflight;
unrelated windows stay alive. A Z `closeRequested` listener may veto the closure.
Reloading/navigating a related child retires that original document rather than
retargeting the handle.

Current native-memory limitation: macOS keeps the closed, published window's
native runtime graph until application shutdown. Routing and callbacks are
retired, but repeatedly opening and closing inspectors still grows retained
native objects. Prompt reclamation is under review; do not treat this tier as
constant-memory window churn. Releasing your own DOM/handle references remains
important independently of that framework limitation.

## Shared state does not change where code runs

An owner-defined callback remains owner code when its element is placed in the
child. Calls made by that callback through imported service functions use the
owner's bridge. Child-defined code uses the child's own bridge. DOM placement
does not change permission provenance or move work onto another thread.

Related documents share trust and UI scheduling. They are not a security sandbox
or a replacement for workers. Use a worker for independent background work, and
native services for backend-owned state and OS resources. Independent frontends
remain useful when windows should initialize and manage their own UI state.

## Styling and demo

Documents have separate stylesheets. Automatic CSS synchronization, theme
propagation, CSS HMR, and explicit child `inject` selection are not implemented
by this tier. Style the child explicitly for now. The next styling experiment
will be deliberated separately; no JavaScript or application CSS profile is
silently replayed into children.

From the repository root, run `bun run spike:z-notes:dev` (or
`bun run spike:z-notes`). Choose **Open related inspector** twice. Editing the
title in either inspector or Z Notes updates the shared frontend state; creating
a note uses the owner's generated service call. Closing one inspector leaves the
other and the main window usable.

See the [implementation evidence and remaining gates](plans/related-windows.md)
and [styling proposals](plans/related-window-styling.md).
