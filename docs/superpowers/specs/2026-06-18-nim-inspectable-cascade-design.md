# Nim `Inspectable` — Unified Enum + Cascade — Design

**Status:** DESIGNED — 2026-06-18. Replace `WindowOptions.inspectable: TriState` +
the free `inspectableAuto()` proc with the `Inspectable` enum (member access:
`Inspectable.Auto`), unified with `AppConfig.inspectable`, and resolve it as a
cascade: per-window setting → AppConfig global → dev-vs-prod default.

## Problem

Web-inspector enablement is modeled two inconsistent ways in the Nim API:

- `AppConfig.inspectable` uses `Inspectable` (`appconfig.nim`): `Auto / On / Off`,
  written `Inspectable.Auto`, resolved natively at `app_get_bootstrap_web_content_inspectable()`.
- `WindowOptions.inspectable` uses `TriState` (`coretypes.nim`): `Unset(-1) / Off / On`,
  and the only way to express "auto" is the free proc `inspectableAuto()`, which
  resolves dev/prod at *construction time*.

A free function for what is conceptually an enum value is hard to discover and
unidiomatic for a TS/Go audience (who expect `Inspectable.Auto`). The two enums
also can't express a relationship between the app-wide setting and a per-window
override.

## Decision — one enum, resolved as a cascade

### The enum (single, shared)

`Inspectable` becomes the single enum, living in the shared `coretypes` module
(per the "genuinely-shared atom" convention — it's now used by both `appconfig`
and `window`), gaining an `Inherit` member:

```nim
Inspectable* {.pure.} = enum
  Inherit   ## defer to the level above (window → AppConfig)
  Auto      ## decide by build: dev → on, prod → off
  On        ## force on
  Off       ## force off
```

Written `Inspectable.Auto` / `.On` / `.Off` / `.Inherit`. `TriState` is **removed**
(its only user was `WindowOptions.inspectable`), and the free `inspectableAuto()`
proc is **removed**.

### Defaults encode the cascade

| level | field | default | meaning of default |
|---|---|---|---|
| Window | `WindowOptions.inspectable` | `Inherit` | use the app's setting |
| App | `AppConfig.inspectable` | `Auto` | dev → on, prod → off |

Both fields are typed `Inspectable`. A window may also set `Auto`/`On`/`Off`
explicitly to override the app for that window.

### Resolution — most-specific wins

`wopts_inspectable(opts)` (the per-window accessor `window.m` already calls and
thresholds with `> 0`) resolves the window value:

- `On` → on, `Off` → off, `Auto` → `zapp_build_dev_tools_default() > 0`,
  `Inherit` → **the app-level resolution**.
- App-level resolution (`app_get_bootstrap_web_content_inspectable()`):
  `On` → on, `Off` → off, `Auto` → dev flag, `Inherit` → dev flag (treated as Auto;
  nothing sits above the app).

So precedence is **window-explicit > AppConfig global > dev-vs-prod default**. The
three canonical cases:

1. App default + window default → window `Inherit` → app `Auto` → dev on / prod off.
2. `AppConfig(inspectable: Inspectable.Off)` → all windows (which `Inherit`) off everywhere.
3. That window sets `inspectable: Inspectable.On` → on regardless, overriding app + build.

`window.m` is untouched: it still does `wopts_inspectable(opts) > 0`; the cascade
is resolved inside the accessor before it returns.

### JS-config-flag consistency

Today `webview.m` (darwin `:900`, iOS twin `~:749`) feeds the **app-level**
`app_get_bootstrap_web_content_inspectable()` into the bootstrap JS config flag,
while the native `setInspectable:` gate uses the **per-window** resolved value. In
the override case (app `Off`, window `On`) the JS flag would disagree with the
native inspector. Fix: route the **resolved per-window** value (the `inspectable`
param `darwin_webview_create_ext` already receives) into that JS flag on both
platforms, so the JS-visible flag matches the actual inspector state.

## Components

- `native/nim/coretypes.nim` — host `Inspectable` (the 4-value enum incl. `Inherit`);
  **remove `TriState`** (now unused).
- `native/nim/appconfig.nim` — `import coretypes` for `Inspectable` (was locally
  defined); `AppConfig.inspectable` default stays `Auto`; the getter's `case` adds
  an `Inherit` arm (→ dev flag, same as `Auto`).
- `native/nim/window.nim` — `WindowOptions.inspectable: Inspectable = Inspectable.Inherit`;
  `import appconfig` (leaf — no cycle) to reach the app resolver; rewrite
  `wopts_inspectable` to resolve the cascade; **delete `inspectableAuto()`**; drop
  the `TriState`/`inspectableAuto` references in the `export coretypes` comment.
- `native/platform/darwin/webview.m` + `native/platform/ios/webview.m` — feed the
  per-window resolved `inspectable` param (not the app getter) into the bootstrap
  JS config flag.
- `kitchen-sink/zapp/app.nim` — `inspectable: Inspectable.Auto` (was `inspectableAuto()`).
- `cli/src/init.ts` — scaffold template: `inspectable: Inspectable.Auto`.
- `docs/api-reference.md` — document the enum + cascade (window default `Inherit`,
  app default `Auto`, precedence), drop `inspectableAuto()` mentions.

## Testing

- `native/nim/tests/appconfig_test.nim` — add an `Inherit` case (resolves like `Auto`).
- `native/nim/tests/windowmanager_test.nim` (or a focused test) — exercise the cascade
  by stubbing `zapp_build_dev_tools_default` and using `setAppConfig` to control the
  app value, asserting `wopts_inspectable` for:
  - window `On` → on, `Off` → off, `Auto` → tracks the stubbed dev flag (both states);
  - window `Inherit` + app `On`/`Off`/`Auto` → tracks the app resolution;
  - window-explicit beats app (app `Off`, window `On` → on).
- Gate: nim + zc kitchen-sink builds, `bun run check` (tsc), `cd cli && bun test src`,
  the nim unit tests; manual smoke that dev devtools still open on the kitchen-sink.

## Parity note (logged per the Nim-vs-zc parity rule)

zc models this as `webContentInspectable: int` on the window (`-1` inherit / `0` off
/ `1` on — no per-window `Auto`) plus the app-level `ZappInspectable {Auto,On,Off}`.
This Nim design is **richer**: a single `Inspectable` enum used at both levels, and a
window may select `Auto` (its own dev/prod) — a state zc's window int lacks. The app
enum also gains `Inherit` (an alias for `Auto` at the root). Deliberate, surfaced
Nim-only divergence; the cascade semantics (window > app > build) match zc's intent.

## Out of scope

- No change to zc (`webContentInspectable` int + `ZappInspectable` stay).
- No change to `window.m`'s `wopts_inspectable(opts) > 0` consumption or the
  `create`/`windowOptsApplyJson` signatures.
- No real per-window→app *event* propagation (the cascade is resolved at window
  creation, matching how `wopts_inspectable` is consumed today).
