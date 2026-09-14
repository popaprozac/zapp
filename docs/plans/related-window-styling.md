# Related-window injection and styling

Status: **proposals for deliberation; no public API or styling default approved**,
2026-09-13. Captured from the side-chat handoff. This work does not replace the
current [close/lifetime integration sequence](related-windows.md).

## Current behavior

The intended related-window factory provides a minimal same-origin document,
its own native bridge, and a document handle for ordinary DOM rendering or a
framework portal. It does not load another frontend application entrypoint or
accept an arbitrary child URL. The public factory remains unexported.

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
