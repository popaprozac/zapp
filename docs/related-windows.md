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
  visible: false,
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

inspector.show(); // Present after mounting; focus() also requests activation.
// inspector.close() requests ordinary native closure, including Z close vetoes.
```

## Creation and authority

The calling document is the owner. Both the application's permission ceiling
and that document's capability profile must permit `window:create`. The child
inherits the family's authority; it cannot select a stronger profile.

The supported options are `title`, `width`, `height`, `visible`, `titleBar`,
`styles`, and `theme`. Dimensions are positive integer logical units, defaulting to 900 × 640.
Native [titlebar appearance](window-titlebar.md) is child-local and independent
of shared application styles and title text visibility.
The child is a minimal same-origin shell: there is no `url`, second frontend
entrypoint, or injection-profile option. Unknown options fail before allocation.

The Promise resolves after the native window exists, the original document has
`head` and `body`, its direct bridge has been activated, and native publication
has succeeded. Initial style/theme synchronization is installed before publication.
This does **not** promise completed stylesheet loads, font readiness, or first paint.
Failed unpublished creations roll back natively; creation is bounded rather than
waiting indefinitely. Native errors use `WindowError`, while denied authority
uses `PermissionDeniedError` from `@zappdev/runtime`.

`visible` defaults to `true`. With `visible: false`, the native window stays hidden
through publication; mount your UI and call `show()` when you choose. Visibility
does not delay bridge activation or change the document's lifetime. `show()` does
not request keyboard focus or application activation; use `focus()` for that.

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

On macOS, accepted closure releases the related window's framework-owned runtime
graph after revoking routing; closed related windows are not held until application
shutdown. In-flight native callbacks keep their receivers alive through return.
AppKit/WebKit may finish native object release on subsequent run-loop turns, so
`INVALIDATED` is not a native deallocation barrier. Releasing your own DOM/handle
references remains important. This does not promise constant process RSS: WebKit,
JavaScript garbage collection, and native allocators have independent lifetimes.

## Shared state does not change where code runs

An owner-defined callback remains owner code when its element is placed in the
child. Calls made by that callback through imported service functions use the
owner's bridge. Child-defined code uses the child's own bridge. DOM placement
does not change permission provenance or move work onto another thread.

Related documents share trust and UI scheduling. They are not a security sandbox
or a replacement for workers. Use a worker for independent background work, and
native services for backend-owned state and OS resources. Independent frontends
remain useful when windows should initialize and manage their own UI state.

## Shared or independent styles

`styles: "shared"` is the default. Ordinary head-owned `<style>` elements and
stylesheet `<link>` elements synchronize from the owner, including additions,
removals, source order, text edits, and Vite CSS HMR. Keep using normal component
CSS imports and CSS Modules; no injection profile is required. Shared content is
not a shared DOM node: every document owns its sheets and evaluates media queries
against its own viewport. No owner JavaScript is copied or replayed.

```ts
// Ordinary application CSS applies; local CSS can add inspector-specific rules.
const inspector = await createRelatedWindow({ title: "Inspector" });

// A blank styling context for a deliberately separate design.
const palette = await createRelatedWindow({
  title: "Palette",
  styles: "independent",
});
```

Shared sheets precede child-local sheets. Standard specificity, cascade layers,
and `!important` still apply: later order does not guarantee every override wins.
Global owner `body`/`main` rules also apply; use scoped component rules or explicit
child layout overrides where the document structure differs. This is stylesheet
synchronization, not computed-style or ancestor-tree copying.

Relative inline CSS URLs are rebased to their source location; linked sheets keep
absolute URLs and normal browser loading. The first tier handles `url()`, string
`@import`, and image-set candidates. Alternate-sheet selection and URL-producing
`image()`/`src()` functions in inline styles fail explicitly at creation with
`WindowError`. An unsupported later edit reports an error in the owner console,
keeps the last good snapshot, and recovers after a supported edit. Use independent
styling for unsupported source forms. Browser CSP remains in force; nonce and
link integrity/cross-origin/referrer-policy metadata are preserved, not bypassed.

CSSOM-only edits (`insertRule`, programmatic sheet toggles), constructed sheets,
`adoptedStyleSheets`, shadow-root/body styles, replacement of the head, and
CSS-in-JS framework registries are not observed by this tier. These need separate
integration rather than a claim that copying style elements covers every library.

## Explicit theme synchronization

CSS rules travel with shared sheets. Root attributes, classes, and inline custom
properties do not travel unless selected:

```ts
const inspector = await createRelatedWindow({
  title: "Inspector",
  theme: {
    attributes: ["data-theme"],
    classes: ["dark"],
    variables: ["--accent"],
  },
});
```

Selections refer to each document's `<html>` element. Attribute names are limited
to `data-*`; event handlers, IDs, and arbitrary attributes cannot be copied.
Classes are individual tokens. Variables are selected **inline declarations**,
including their priority—not a dump of computed styles. Stylesheet-defined theme
variables already travel with their sheets. URLs in selected inline variables use
the owner's base URL, under the same rebasing limits as inline sheets. Selection lists are copied at
creation; mutating the options object later does not reconfigure the window.

Selected names remain owner-authoritative: updates/removals propagate and a
conflicting child edit is corrected. Unselected child state remains local.
Omitting `theme` installs no theme observer. `styles: "independent"` and `theme`
are orthogonal: an independently styled child can explicitly share selected
theme state. Neither feature selects or grants a capability profile.

Styles and theme bindings are released on rollback or terminal invalidation,
before application invalidation callbacks. Child-local style nodes are not
removed by framework cleanup. No frontend cleanup is awaited by native close.

Child `inject` profile selection remains a separate future extension. It would
complement shared CSS for child-specific setup, not replace ordinary CSS imports.

## Notes demo

From the repository root, run `bun run spike:z-notes:dev` (or
`bun run spike:z-notes`). Choose **Open related inspector** twice. Editing the
title in either inspector or Z Notes updates the shared frontend state; creating
a note uses the owner's generated service call. Closing one inspector leaves the
other and the main window usable.

The inspector uses an ordinary CSS import, creates a hidden related window,
mounts Svelte, then shows it. The translucent-looking surfaces are CSS within an
opaque document, not native macOS vibrancy or window transparency.

See the [implementation evidence and remaining gates](plans/related-windows.md)
and [styling proposals](plans/related-window-styling.md).
