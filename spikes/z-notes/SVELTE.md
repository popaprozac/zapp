# Svelte notes and related inspectors

Status: explicit child-stylesheet integration (2026-09-14).
General related-window stylesheet sharing is the agreed future workstream, not
a default introduced by this demo.

The first **private DOM stylesheet proof** now passes in packaged and Vite
WebKit. It is opt-in testing only; see the [styling checkpoint](../../docs/plans/related-window-styling.md#private-dom-stylesheet-checkpoint--2026-09-14).
Run it with `VITE_ZAPP_STYLE_SMOKE=1 bun cli/src/test-notes-launch-macos.ts`
from the repository root (or append `packaged` / `dev`).

The application uses Svelte 5.57.0 and its Vite plugin 7.3.0, pinned only in the
Notes workspace. The reusable Zapp runtime has no Svelte dependency. The notes
list/editor and metadata inspector share one owner-held Svelte store. Persistent
notes still belong to the Z/SQLite service. `app.js` retains the existing native
menus, clipboard, worker, navigation and lifecycle diagnostics.

`related-inspectors.ts` uses the existing public factory, `mount`, `unmount`, and
terminal invalidation subscription. It is application code, not a public adapter.
Mounting into a child document does not rebind `window`, `document`, or bridge
authority for owner callbacks. Inspector save still invokes the owner's generated
service; its close button uses the child's document-bound native handle.

## Styling ownership

The owner uses the Svelte plugin's normal CSS extraction. The inspector has no
component `<style>` block: its namespaced rules live in `note-inspector.css`.
Vite's [`?inline` CSS import](https://vite.dev/guide/features.html#disabling-css-injection-into-the-page)
returns processed text without registering a style element. The manager creates
one element in the child head before mounting, removes it on invalidation or
creation rollback, and creates a fresh element when reopening. No observer or
global style-node registry is added. Closing one inspector does not remove its
siblings' styles.

The normal inspector's grouped panel treatment uses translucent-looking CSS
surfaces within an opaque document. It does not turn on macOS vibrancy or native
window transparency. Its initial size is 440 × 600, with narrow-layout rules.

This is deliberately explicit application code. It does not inherit the owner's
CSS, theme, or injection profiles. Changes to the imported CSS follow the host's
normal Vite reload path; preserving live inspectors across CSS/theme HMR is not
promised in this tier. Svelte component HMR alone is not proof of that behavior.

## Verified

- Eight model regressions: selection and bigint IDs, multiple subscribers,
  unsaved edits during refresh/save, successful save, errors, duplicate in-flight
  mutations, deletion, and out-of-order refreshes.
- Svelte diagnostics: zero errors and warnings; repository TypeScript checks.
- The 33 existing related-window API/lifetime/transport and local Vite command
  regressions pass unchanged.
- Actual macOS WebKit, packaged and Vite dev launch: two related inspectors,
  child-to-child/owner and owner-to-child input events and reactivity, component
  CSS in the child, save through the generated native service, per-root DOM and
  store-subscription cleanup, surviving sibling updates, and restored seed data.
- The final explicit-style rerun verifies one independently owned style per
  inspector, none injected into the owner, no Svelte injected-CSS node in the
  child, removal after close, sibling-style preservation, and fresh ownership
  and removal after reopening. These assertions pass in packaged and dev modes.
- Existing launch checks still pass: second-instance forwarding, worker/service
  calls, navigation/permission boundaries, ordered shutdown, endpoint cleanup,
  and dev port 5173 release.

Run from the repository root:

```sh
bun run --cwd spikes/z-notes test
bun run --cwd spikes/z-notes check
VITE_ZAPP_SVELTE_SMOKE=1 bun cli/src/test-notes-launch-macos.ts packaged
VITE_ZAPP_SVELTE_SMOKE=1 bun cli/src/test-notes-launch-macos.ts dev
```

The smoke flag loads a test-only frontend module and adds a native DOM gate.
Its frontend probe has a 15-second deadline, the opt-in native watchdog 20
seconds, and each complete launch/build is bounded at 240 seconds. Ordinary
smoke runs keep their existing five-second native watchdog. Probes use unique
application identities and restore their seed title; interactive data is untouched.

## Why the injected-CSS experiment was replaced

With `emitCss: false`, Svelte places a component's CSS in the mounted node's
document. Its current development runtime also calls `register_style` from
`src/internal/client/dom/css.js`. `src/internal/client/dev/css.js` owns a strong
`Map<string, Set<HTMLStyleElement>>`; `cleanup_styles` clears a component hash
for hot replacement, not per component unmount. Closed inspectors' style nodes
therefore remain rooted by the owner's development runtime between hot updates.
Removing the DOM node alone does not remove that registry reference. This is a
source-inspected retention path, not an RSS/GC benchmark. The production branch
does not register these styles, and subscription cleanup passing does not prove
whole-document collection in development.

The agreed choice is ordinary owner CSS extraction plus an explicitly owned
inspector stylesheet for this slice. We are not patching Svelte or using its
private CSS registry. A general framework-neutral stylesheet-sharing layer is
the agreed follow-up, with the remaining choices recorded in the
[styling plan](../../docs/plans/related-window-styling.md).

No Svelte internals were patched or called. No production automatic CSS/theme synchronization,
`inject` option, framework adapter API, or change to factory readiness was added.
Live CSS HMR, font/paint readiness, and complete closed-document collection
remain separate validation work. The private proof now covers lazy DOM styling,
relative URLs, ordering, queued updates, and disposal but is not enabled in the
ordinary app. Removing this known registry path
and proving local cleanup is not a whole-process memory or constant-RSS claim.
