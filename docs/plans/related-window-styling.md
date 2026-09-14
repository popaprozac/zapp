# Related-window injection and styling

Status: **private DOM stylesheet proof passed; public API and styling defaults still require
deliberation**, updated 2026-09-14. Captured from the side-chat handoff. This work does not replace the
shipped [factory and close/lifetime contract](related-windows.md).

## Agreed sequence

The Svelte Notes slice uses an explicitly owned child stylesheet and ordinary
Svelte CSS extraction for the owner. This narrowly avoids the development
injected-CSS registry retention found in the integration proof; it is application
code, not the future framework styling model.

General, framework-neutral related-window stylesheet sharing is the agreed
workstream (option 3 from that discussion). The first private proof below is now
complete. Agree on the public defaults, independent
styling, ordering, readiness, theme and HMR behavior before shipping them.
This does not approve automatic JavaScript injection or a new `inject` option.

## Current behavior

The related-window factory provides a minimal same-origin document,
its own native bridge, and a document handle for ordinary DOM rendering or a
framework portal. It does not load another frontend application entrypoint or
accept an arbitrary child URL. The [public factory](../related-windows.md) is
exported from `@zappdev/runtime/window` on macOS.

`createMacOSRelatedWindowRuntime` currently passes an empty profile selection to
`installWebViewScripts`. The framework bridge and document/window identity
scripts still run. Application CSS/JS injection profiles are not automatically
inherited, and production application stylesheet synchronization is not built.

## Two distinct proposed features

### Explicit child-local injection

Reuse the existing `webview.inject` catalog rather than invent another catalog:

```ts
// Proposed only: not an approved or implemented factory option.
const inspector = await createRelatedWindow({
  title: "Inspector",
  inject: ["inspector"],
});
```

The proposal selects predeclared profiles explicitly, without replaying every
owner injection. Native validation must enforce the family's allowed policy;
merely finding a profile in the catalog must not grant authority. The exact
allowable-selection policy needs deliberation before implementation.

Injected scripts execute in the child's context. Portal components and callbacks
defined by the owner remain owner code. DOM placement never changes bridge
provenance. Injection is for child-specific CSS and trusted setup, not a
requirement to style ordinary application components.

### Natural application styling

Proposed target: style a component normally and have it look consistent when
rendered in a related document. Developers should retain ordinary CSS imports,
CSS Modules, and their existing frontend development workflow, without moving
application CSS into build configuration.

Explore a framework-neutral integration that makes already-loaded application
styles available to children and tracks lazy loading, HMR updates, and removals.
Preserve stylesheet ordering and resolve asset URLs correctly. Separate documents
retain separate layout: synchronize style content/references, not computed
geometry. Responsive rules must evaluate against the child's own viewport.

Independently styled children must remain possible, but no opt-out name, public
option, or default has been approved. Deliberate ordering between synchronized
application CSS and explicit child-local injection too.

## Boundaries to deliberate and test

- **Themes:** define which root classes, `data-theme` values, or dynamic CSS
  variables synchronize, and who owns subsequent updates. Do not blindly copy
  body attributes, IDs, or computed styles. Ancestor-dependent selectors may
  require compatible child structure.
- **Readiness:** keep bridge/DOM readiness distinct from stylesheet, font, and
  first-paint readiness. Decide whether initial presentation should wait, under
  what bound, and how failures behave; do not silently change factory resolution
  or wait indefinitely for assets/fonts.
- **Dynamic styles:** element copying alone is not a complete CSSOM, constructed
  stylesheet, or CSS-in-JS solution. Evaluate those separately. Emotion and
  styled-components are candidates for later adapter investigation, not promised
  compatibility.
- **Lifetime:** release observers, queued work, child references, and any copied
  style ownership on terminal invalidation. Never delay native close awaiting
  frontend cleanup, and never attach a stale update to a replacement document.
- **Cost:** measure initial style setup and update fan-out as children grow.
  Avoid assuming that shared application execution removes per-document style,
  font, layout, or rendering costs.

## Experiment sequence, after the current lifetime gates

1. Prove ordinary CSS and CSS Modules in Vite and packaged content, including
   relative asset URLs, ordering, and child-viewport responsive rules.
2. Exercise lazy stylesheet insertion, HMR replacement/removal, and a deliberately
   scoped theme model. Include an independently styled child.
3. Visually test cold/warm stylesheet and font readiness, flashes of unstyled
   content, and resize behavior. Ask for user visual feedback where useful.
4. Verify terminal cleanup, late queued updates, repeated child creation, and
   bounded memory/update costs.
5. Deliberate public options/defaults using that evidence. Evaluate CSS-in-JS
   adapters and CSSOM/constructed-sheet coverage as a separate follow-up.

CSS synchronization stays separate from JavaScript injection throughout. This
document authorizes neither a new configuration key nor a production behavior.

## Private DOM stylesheet checkpoint — 2026-09-14

The opt-in `spikes/z-notes/frontend/style-experiment` proof imports no Svelte
internals and changes no runtime export, factory option, or default. Ordinary
Notes retains its explicitly owned inspector stylesheet. The inspector now has
grouped metadata and translucent-looking CSS surfaces, not native window
transparency or macOS vibrancy.

Run the isolated real-WebKit gates from the repository root:

```sh
VITE_ZAPP_STYLE_SMOKE=1 bun cli/src/test-notes-launch-macos.ts packaged
VITE_ZAPP_STYLE_SMOKE=1 bun cli/src/test-notes-launch-macos.ts dev
bun run --cwd spikes/z-notes test
```

The style flag enables the existing Svelte smoke gate as well. No watch timeouts
were widened. Both launch modes passed, including the restyled Svelte component,
native service calls, second-instance forwarding, shutdown and dev port release.
The fourteen Notes/model/URL regressions and 31 existing related-window
lifetime/transport and Vite-command regressions pass; repository TypeScript and
Svelte checks are clean. The ordinary production frontend build excludes the
private smoke modules and fixture assets. The normal inspector was visually
checked at 440 and 330 pixels, in light/dark and edited states, using a temporary
preview of the actual component; no preview page is shipped.

Verified in real related WebKit documents:

- Initial head `<style>` and regular stylesheet `<link>` sharing, compiled CSS
  Modules, and a real lazy CSS module import in packaged and Vite modes.
- Absolute link identity, link media changes, and a relative inline asset URL
  resolving to the original owner location rather than `/.zapp/`. The actual SVG
  asset decodes successfully; child base URLs are not changed.
- Source order, style-node replacement/removal, text-node updates, and fifty
  same-turn edits coalescing into one observer pass without recreating sheets.
- Distinct 330/800-pixel native viewports evaluate their own responsive rules.
  An unattached child receives no styles, and scripts are not copied.
- This experiment places mirrored sheets before child-local sheets, which keep
  their own cascade authority. That ordering is not yet a public contract.
- Disposal before a queued mutation, surviving sibling updates, twenty
  attach/detach cycles, and native invalidation cleanup. Each run created and
  removed 136 mirrored nodes; final tracked document/sheet counts were zero and
  the observer was disconnected. This is an ownership ledger, not proof of
  garbage collection, constant RSS, or absence of WebKit-internal retention.

The tiny fixture observed roughly 1 ms to attach two children and roughly 1 ms
for a fifty-edit burst including observer delivery in each mode. These are
single coarse-timer observations, not a benchmark or a large-application bound.
The prototype still rescans the head per mutation delivery; source parsing and
fan-out need profiling against realistic stylesheet sizes before promotion.

### Boundaries exposed, not solved

This is **DOM stylesheet synchronization**, not complete CSS synchronization.
The URL scanner covers `url()` and string `@import` with comments/escapes, with
six focused regressions. It explicitly rejects `image-set()` and alternative
stylesheet selection rather than misrepresenting their support. Production
promotion needs a reviewed CSS parsing strategy, CSP/nonce/stylesheet-selection
semantics, and coverage of additional URL-bearing constructs. Only head-owned
DOM styles are observed; CSSOM `insertRule`, `adoptedStyleSheets`, body styles,
shadow roots, head replacement, and CSS-in-JS are not implemented.

Real lazy Vite imports pass; **file-watcher-driven CSS HMR has not been proved**.
Replacement/removal tests exercise the DOM mechanisms, not the whole HMR path.
Theme attributes/variables are not synchronized. Copying all owner sheets also
copies global `body`/`main` rules: independent child structure and local resets
still matter; this is not computed-style isolation.

The implementation deliberately follows the browser's
[mutation-observer disposal model](https://developer.mozilla.org/en-US/docs/Web/API/MutationObserver/disconnect)
and tests [Vite's CSS/CSS Modules paths](https://vite.dev/guide/features.html#css),
without depending on private framework style registries.

Next: a real file-edit/HMR gate, scoped theme experiment, stylesheet/font/paint
readiness and visual checks, then decide default/opt-out and ordering with the
user. Keep CSS-in-JS/constructed-sheet adapters separate. Do not ship automatic
sharing or infer a new `inject` option from this checkpoint.
