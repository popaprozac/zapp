# Nim Type-Modeling Convention + Magic-Number Retro-Convert — Design

**Status:** Design (approved 2026-06-15). **Branch:** `feat/nim-native`.
**Part of:** the Nim migration (`docs/superpowers/specs/2026-06-15-nim-migration-design.md`),
realizing its stated "magic int codes → enum" idiom as an explicit, durable standard.

## Goal

Establish a Nim type-modeling convention — namespaced `{.pure.}` enums, a small shared
`coretypes.nim`, natural-cluster object grouping, with the C-ABI ordinal as the wire
boundary — and **retro-convert** the magic numbers already in the Nim layer. Adopt it as
the quality bar threaded through the remaining breadth batches (B4–B8).

## Why

The Nim port should leverage what Zen-C made painful: cross-module enums, real namespacing,
and distinct types without `_Generic`/codegen friction or `Enum__CASE`-style mangling.
Today the Nim layer still carries raw `int32` tags with `// -1/0/1` comments
(`window.nim` `inspectable`, `titleBarStyleTag`, the three `trafficLight*Tag`) — no type
safety, magic numbers a maintainer must decode. The shipped TS surface is already typed
(traffic-light / title-bar / inspectable unions); this brings the Nim internals to the same
standard and keeps the two in lockstep.

## The convention (the durable rules)

1. **Named `{.pure.}` enums replace magic numbers.** `{.pure.}` forces qualified use
   (`TitleBarStyle.Hidden`, `ButtonState.Hidden`) — no bare cases leaking to global scope,
   and it lets two enums share a case name (`TitleBarStyle.Hidden` *and* `ButtonState.Hidden`
   coexist — exactly our situation). The module is the namespace, so cross-module use reads
   `window.TitleBarStyle.Hidden`.
2. **Explicit ordinals match the C-ABI wire value.** Enum values are set to the integer the
   untouched `.m`/`.c` layer expects, so the accessor flattens with `.cint`:
   `wopts_title_bar_style_tag → opt(p).titleBarStyle.cint` yields `0/1/2`. The wire contract
   is unchanged; the enum is purely the ergonomic surface.
3. **Genuinely-shared atoms live in `coretypes.nim`.** The recurring shape is the `-1/0/1`
   **tri-state** (unset/off/on — the inspectable window tag and every webview pref). One
   `TriState` there, not N copies.
4. **Group only natural clusters into sub-objects.** The three traffic-light tags ARE one
   (mirroring the zc `TrafficLights` struct) → group as `trafficLights: TrafficLights`.
   Simple scalars stay flat — no nesting for its own sake.
5. **Three faces of one contract.** Nim enum ⟷ C-ABI ordinal (`wopts_*: cint`) ⟷ TS string
   union (`"auto" | "off" | "on"`). The TS surface already exists for the shipped API; as each
   user-facing config field is (re)exposed, its TS union and the Nim enum stay in lockstep,
   the CLI mapping string → ordinal.

### Layering note (the inspectable example, done right)

There are two distinct levels, and the enum differs per level:
- **User-facing config** (`zapp.config.ts` / the future app-config Nim port): the rich
  `Inspectable {.pure.} = enum Auto, On, Off` — your `Webview.Inspectable.Auto` vision. `Auto`
  means "dev-gated." This mirrors the existing TS `webContentInspectable` union and the zc
  `ZappInspectable` (`app.zc:296`). **It lands when app-config is ported** (a later batch), not
  here — `window.nim` has no app-config.
- **Internal window tag** (this retro-convert): by the time `Auto` reaches the window option
  it has already been *resolved* to on/off (`app.zc:55`: `Auto → dev_tools > 0`). The window
  tag is `-1/0/1` = unset/off/on → that is exactly the shared **`TriState`**. So the window
  field uses `TriState`, and the dev-gating happens at the assignment, not in the type.

## Scope

**In (retro-convert the existing Nim layer — behavior-preserving):**
- **`native/nim/coretypes.nim`** (new): `TriState* {.pure.} = enum Unset = -1, Off = 0, On = 1`;
  `EventResult* {.pure.} = enum Allow = 0, Cancel = 1`; a header comment stating the convention.
- **`native/nim/window.nim`** — convert the magic-number fields, mirroring the zc exactly:
  - `inspectable: int32` → `inspectable: TriState` (Unset/Off/On).
  - `titleBarStyleTag: int32` → `titleBarStyle: TitleBarStyle` (`{.pure.} = enum Default = 0,
    Hidden = 1, HiddenInset = 2`).
  - `trafficLightCloseTag/MinimizeTag/ZoomTag: int32` → `trafficLights: TrafficLights`, a
    grouped `object` of three `ButtonState` (`{.pure.} = enum Enabled = 0, Disabled = 1,
    Hidden = 2`).
  - The `wopts_*` accessors flatten via `.cint` (wire contract unchanged); `newWindowOptions`
    seeds the enum defaults (`TriState.Unset`, `TitleBarStyle.Default`, all `ButtonState.Enabled`).
  - `TitleBarStyle`, `ButtonState`, `TrafficLights` are window-domain → exported from `window.nim`.
- **`native/nim/zapp.nim`** — the boot assignment becomes, preserving the just-shipped
  dev-gated behavior (window.m treats `> 0` as on, so `Unset = -1` is OFF — must set `On`/`Off`
  explicitly):
  ```nim
  opts.inspectable = (if zapp_build_dev_tools_default() > 0: TriState.On else: TriState.Off)
  ```
- **`native/nim/callbacks.nim`** — replace the `EVENT_ALLOW = 0` / `EVENT_CANCEL = 1` consts
  with `EventResult` from `coretypes` (the `zapp_dispatch_event` return). Keep the C-ABI return
  `cint` (`.cint` at the boundary). Update the close-guard / cancel comparisons accordingly.

**Out (deferred / forward-looking):**
- The **user-facing `Inspectable {.pure.} = enum Auto, On, Off`** + the app-config port — lands
  with app-config (a later batch); noted in the layering section above.
- The **webview-pref build-config getters** (`zapp_build_webview_*`, tri-state) — codegen
  literals, not a consumed Nim surface yet; adopt `TriState` when wired from real config.
- **Pure-ifying the already-typed `WindowEvent` / `AppEvent` prefix-enums** (`weReady`,
  `aeStarted`) — already namespaced-by-prefix and type-safe (not magic numbers). Optional
  consistency polish, deferred to avoid churn-for-churn. New/ported enums use `{.pure.}`.
- **TS-side changes** — the shipped TS API is already typed for these fields; nothing to change.

## C-ABI boundary (the critical correctness point)

window.m reads these tags through the `wopts_*` accessors and is **untouched**. The retro-
convert MUST keep the returned integers identical:
- `wopts_inspectable → opt(p).inspectable.cint` → `-1/0/1` (window.m: `> 0` = on).
- `wopts_title_bar_style_tag → opt(p).titleBarStyle.cint` → `0/1/2`.
- `wopts_traffic_light_{close,minimize,zoom}_tag → opt(p).trafficLights.<field>.cint` → `0/1/2`.

`enum.cint` = `ord` = the explicit value, so the ordinals above reproduce the exact wire tags.
A pure refactor — no behavior change.

## Gate

- Full hello-world Nim build ends `[zapp] build complete:`; the binary still launches.
- All Nim unit tests pass (`callbacks_test` exercises the `EventResult`/dispatch path; window
  has no unit test, so the build + the inspectable smoke is its gate).
- **Behavior preserved:** the webview is still inspectable in the dev build (the just-shipped
  fix), and no window-creation regression — the ordinals are mechanically identical.
- No `{.emit.}`; `.m`/`.c`/worker layers untouched.

## Going forward (the standard for B4–B8)

Each breadth batch enumifies its own magic numbers as it lands (pane roles, power source,
material, menu/tray tags, the user-facing `Inspectable`/app-config enums, etc.), using
`coretypes.nim` for shared atoms and `{.pure.}` module-local enums otherwise, plus a short
consolidating sweep at the end. Recorded in the migration memo so every future module follows it.

## References

- `native/window/window.zc:11-15` (TitleBarStyle), `:19-25,297-310` (ButtonState/TrafficLights),
  `:696-698` (tag mappings); `native/app/app.zc:296,327-329,55` (ZappInspectable + Auto resolution).
- `native/nim/window.nim:35,39-42,72,75-76,114,117-120` (fields + accessors + defaults to
  convert), `native/nim/callbacks.nim` (EVENT_ALLOW/CANCEL), `native/nim/zapp.nim` (the boot
  `opts.inspectable` assignment).
- `native/platform/darwin/window.m:698` (`wopts_inspectable() > 0`) — the untouched consumer.
