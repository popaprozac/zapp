# Svelte notes and related inspectors

Z Notes uses Svelte for the list/editor and for inspectors rendered into related
native windows. One owner-held store carries selection and unsaved edits across
all documents. Persistent notes remain owned by the Z/SQLite service.
The Zapp runtime has no Svelte dependency.

Run from the repository root:

```sh
bun run spike:z-notes:dev
```

Choose **Open related inspector** twice. Edit the title in either inspector or
the main window: all views update. Save invokes the generated native service;
closing one inspector leaves its siblings and the main window usable.

## Application integration

`related-inspectors.ts` imports `note-inspector.css` normally, creates a related
window with `visible: false`, mounts the Svelte component, then calls `show()`.
Shared styling is the factory default. No `?inline` import, handwritten stylesheet
cloning, injection catalog entry, or Svelte-private style registry is needed.

The manager subscribes to terminal invalidation to unmount each component and
release its store subscription and DOM references. Framework-owned shared sheets
are released independently by the window lifetime. Application callbacks retain
their owner's execution context and bridge provenance; mounting into a child
does not rebind global `window` or `document`.

The component uses namespaced `[data-note-inspector]` CSS. Its document changes
the owner's centered body layout to block layout with an explicit local style.
Shared CSS does not imply identical document structure or computed styles.
The grouped translucent-looking panels are CSS within an opaque document, not
native vibrancy. Initial dimensions are 440 × 600, with narrow-layout rules.

## Styling contract

See the [public related-window guide](../../docs/related-windows.md) for:

- Default shared head-owned DOM styles, ordinary imports, CSS Modules, lazy
  styles, and CSS HMR updates/removals.
- `styles: "independent"` for a separate styling context.
- Explicit `theme` selections for root `data-*` attributes, class tokens, and
  inline custom properties. The demo does not invent an implicit theme binding.
- Shared-before-local cascade ordering and lifecycle cleanup.
- Limits around CSSOM, constructed stylesheets, CSS-in-JS, fonts, and first paint.

`visible: false` controls presentation, not CSS/font loading. Mounting is not a
first-paint guarantee. A public stylesheet-readiness API and child `inject`
selection are separate follow-ups.

## Tests

```sh
bun run --cwd spikes/z-notes test
bun run --cwd spikes/z-notes check
VITE_ZAPP_STYLE_SMOKE=1 bun cli/src/test-notes-launch-macos.ts packaged
VITE_ZAPP_STYLE_SMOKE=1 bun cli/src/test-notes-launch-macos.ts dev
```

The style flag also enables the Svelte integration probe. The native smoke
verifies actual hidden publication and subsequent `show()`, while the frontend
checks ordinary imported CSS in multiple child documents, reactivity, save,
reopen, sibling preservation, and cleanup. Private probes exercise the public
factory's theme, ordering, URLs, external sheets, independent mode, and Vite's
real file-watcher-driven CSS update/pruning without reloading child input state.
Probe helpers are absent from normal builds.

The Notes test command covers eight model, six prototype URL, and six private
readiness regressions. Production styling/lifetime/transport tests live under
`runtime/related-window*.test.ts`.

The Svelte probe has a 15-second deadline, individual styling probes eight
seconds, the opt-in native watchdog 20 seconds, and each launch/build is bounded
at 240 seconds. Ordinary smokes retain their five-second watchdog. Per-run
identities and disposable HMR files isolate interactive data.

## Why the early injected-CSS approach was replaced

With `emitCss: false`, Svelte injects component CSS into the mounted node's
document. Its development style registry can retain those child style nodes
after ordinary component unmount. Removing a node does not remove that registry
reference. We avoided patching or depending on Svelte internals.

The explicit child-owned `?inline` stylesheet was a temporary application-level
solution. The current integration uses normal CSS extraction and the framework's
document-bound sharing lifetime. Earlier evidence remains in the
[styling plan](../../docs/plans/related-window-styling.md). Local cleanup tests do
not prove whole-document garbage collection or constant WebKit process RSS.
