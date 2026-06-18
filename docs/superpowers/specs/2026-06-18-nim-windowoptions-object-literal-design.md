# Nim WindowOptions Object-Literal Construction — Design

**Status:** DESIGNED — 2026-06-18. Move `WindowOptions` defaults into the type as
Nim field defaults; construct via object literal passed directly to
`app.window.create(...)`; remove `newWindowOptions`. A deliberate, surfaced
Nim-only divergence from zc's `WindowOptions::create` + field-set pattern.

## Problem

Authoring a window in Nim today reads as build-a-blank-then-mutate:

```nim
var opts = newWindowOptions("Kitchen Sink")
opts.visible = false
opts.width = 1100
opts.sidebarUrl = "#sidebar-pane"
opts.inspectorCollapsed = true
let win = app.window.create(opts)
```

This is a faithful mirror of zc's `WindowOptions::create("X")` + field assignment,
but it's unidiomatic for the audience (JS devs expect to pass an object literal;
Go devs expect a struct literal) and it's **internally inconsistent within the Nim
API**: `AppConfig` is already constructed as an object literal
(`newApp(AppConfig(name: ..., inspectable: ...))`), and the JS surface already
passes an object (`Window.create({ ... })`). Only `WindowOptions` uses the
constructor-then-mutate shape.

## Decision

1. **Move every default from `newWindowOptions`'s body into the `WindowOptions`
   type as Nim 2.0 field defaults.** Verified (Nim 2.2.10) that field defaults
   apply to `ref object` partial construction — including non-zero numeric
   defaults and nested object defaults — so `WindowOptions(title: "X")` fills the
   omitted fields with their declared defaults.
2. **Remove `newWindowOptions`.** Object-literal construction is the single
   construction path. The trivial case is already terse: `WindowOptions(title: "X")`.
3. **Pass the literal directly into `create`** as the canonical pattern (no
   intermediate mutable `opts`). `create` already takes the options as its
   argument (`proc create*(wm: WindowManager, o: WindowOptions): Window`) — **no
   signature change**.

Canonical app code after this change:

```nim
let win = app.window.create(WindowOptions(
  title: "Kitchen Sink",
  visible: false,            # deferred show — revealed by onReady
  width: 1100, height: 700,
  sidebarUrl: "#sidebar-pane", sidebarWidth: 240,
  inspectorUrl: "#inspector-pane", inspectorWidth: 300, inspectorCollapsed: true,
  inspectable: inspectableAuto(),
))
win.onReady(onReady)
```

The `let opts = WindowOptions(...); opts.x = cond; create(opts)` form remains valid
for conditional construction; it is just no longer the documented default shape.

## Load-bearing detail: defaults must survive partial construction

`window.m` sets `NSSplitViewItem.maximumThickness` to `wopts_sidebar_max_width`
*literally* — a `0` default clamps the pane to zero width (the invisible-sidebar
/ #460 bug). The sidebar/inspector geometry and a few flags therefore MUST keep
their current non-zero / true defaults when moved onto the type:

| field | default | field | default |
|---|---|---|---|
| `width` | 1200 | `height` | 800 |
| `visible` | true | `acceptFirstMouse` | true |
| `autoCenter` | false | `inspectable` | `TriState.Unset` |
| `sidebarWidth` | 260 | `sidebarMinWidth` | 180 |
| `sidebarMaxWidth` | 400 | `sidebarCollapsible` | true |
| `sidebarCanResize` | true | `inspectorWidth` | 280 |
| `inspectorMinWidth` | 180 | `inspectorMaxWidth` | 400 |
| `inspectorCollapsible` | true | `inspectorCanResize` | true |
| `numericIdPrealloc` | -1 | `asSheetOfId` | -1 |
| `sidebarNumericId` | -1 | `inspectorNumericId` | -1 |
| `trafficLights` | all `Enabled` | (others) | "" / false / 0 |

(The full set is exactly today's `newWindowOptions` body — moved verbatim.) The
"why non-zero" comment migrates onto the type so the lesson isn't lost. Blank
`WindowOptions()` — used internally by the router before `windowOptsApplyJson` —
yields all defaults.

## Call-site sweep (live code only)

- `native/nim/window.nim` — add field defaults to the `WindowOptions` type;
  delete the `newWindowOptions` proc; fix the one `windowOptsApplyJson` doc-comment
  that says "leave the newWindowOptions defaults" → "leave the type's field defaults".
- `native/nim/router.nim:751` — `newWindowOptions("Zapp")` → `WindowOptions(title: "Zapp")`.
- `native/nim/zapp.nim` — export comments drop `newWindowOptions`.
- `native/nim/tests/windowmanager_test.nim` — all `newWindowOptions("x")` →
  `WindowOptions(title: "x")`; add the defaults-survive assertion (below).
- `cli/src/init.ts` — the `zapp init` app.nim scaffold template → inline object
  literal passed to `create`; drop `newWindowOptions` from the surface comment.
- `kitchen-sink/zapp/app.nim` — → inline object literal passed to `create`.
- `docs/api-reference.md` (~line 1549, "Authoring an app in Nim") — example → the
  canonical inline form.

**Untouched (historical records):** `docs/superpowers/**` plan/spec archive and
`kitchen-sink/SMOKE.md`'s past-bug note — they document past work accurately.

## Parity note (logged per the Nim-vs-zc parity rule)

This is a **deliberate Nim-only divergence**. zc keeps `WindowOptions::create("X")`
+ field assignment because zc struct literals can't supply partial fields with
defaults (which is *why* zc has the `create` constructor). Nim moves to object
literals because Nim 2.0 field defaults make it free. Net effect: the Nim window
API stops reading 1:1 with `app.zc` here, but becomes consistent with the Nim
`AppConfig` literal and the JS `Window.create({...})` object surface. Accepted
intentionally; recorded here so the divergence is not silent.

## Testing

- `native/nim/tests/windowmanager_test.nim`: convert constructions to literals,
  and **add an assertion locking the load-bearing guarantee** — e.g.
  ```nim
  let o = WindowOptions(title: "x")            # partial literal
  doAssert o.sidebarMaxWidth == 400'i32        # non-zero geometry default survives
  doAssert o.inspectorMaxWidth == 400'i32
  doAssert o.acceptFirstMouse == true
  doAssert o.visible == true
  doAssert o.trafficLights.close == ButtonState.Enabled
  ```
- Gate: nim kitchen-sink build (`[zapp] build complete:`), zc kitchen-sink build
  (unaffected — zc path unchanged), `bun run check` (tsc), `cd cli && bun test src`.
- Manual smoke: launch the nim kitchen-sink; the sidebar is still visible and the
  inspector still reveals (proves the geometry defaults survived the move to the
  type — the actual risk in this change).

## Out of scope

- No change to zc (`WindowOptions::create` stays — it's the zc-side constructor).
- No change to `create`'s signature, `windowOptsApplyJson`, or the `wopts_*`
  C-ABI accessors (they read whatever the constructed object holds; field
  defaults only affect how omitted fields are initialized).
- No change to the JS `Window.create({...})` runtime path.
