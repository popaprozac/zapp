# Typed Nim Chrome Enums — Design

**Date:** 2026-06-21
**Branch:** `feat/nim-native` (unmerged)
**Status:** Approved (design); spec under review

## Goal

Give Nim app authors the same type-safety + IDE autocomplete the TS API already
has for the "stringly-typed" window-chrome fields — `material`, sidebar
`presentation`, and toolbar `style` (plus window `vibrancy`) — by turning the
bare Nim `string` fields into proper Nim enums, matching the existing
`TitleBarStyle`/`Inspectable` precedent.

## Background

The TS `WindowOptions` API already provides this (`runtime/window.ts`):
`material?: Material` / `vibrancy?: Material` (a const + `export type Material =
(typeof Material)[keyof typeof Material]`), `presentation?: "tile" | "overlay"`,
`style?: "unified" | "unifiedCompact" | "expanded"`, `titleBarStyle?: "default"
| "hidden" | "hiddenInset"` — all give autocomplete + compile-time checking
today (plain string literals still type-check, by design).

The gap is the **Nim authoring side**: in `native/nim/window.nim` these chrome
fields are plain `string` (a Nim app writes `material: "sidebar"`,
`presentation: "overlay"`, toolbar `style: "unified"`), even though Nim already
uses real enums for the sibling fields (`TitleBarStyle`, `Inspectable`). This
design closes that gap.

## Scope

**In scope (Nim-side only):**
- `native/nim/window.nim` — three new enums, the field type changes, the
  accessor bodies, `windowOptsApplyJson`, and `serializeToolbar`/`parseToolbarJson`.
- `native/nim/tests/windowmanager_test.nim` — enum assertions.
- `kitchen-sink/zapp/app.nim` — `presentation: "overlay"` → `SidebarPresentation.Overlay`.
- Docs — note the Nim chrome enums.

**Out of scope (untouched):**
- `native/platform/darwin/window.m` and the `wopts_*` C-ABI **signatures** —
  unchanged; native receives byte-identical strings.
- The TS `WindowOptions` API — already typed.
- The JSON wire — unchanged (`material`/`presentation`/`style` stay strings on
  the wire; only the Nim in-memory field type changes).

## The enums

Defined in `window.nim` alongside `TitleBarStyle`, `{.pure.}`, string-valued,
exported. Member names match the TS `Material` const keys for cross-language
consistency. The first member of `Material`/`SidebarPresentation` is the empty
`Default` sentinel (ord 0) — mirrors `TitleBarStyle.Unset` so an unset field
keeps today's `"" ⇒ native default` behavior.

```nim
type
  Material* {.pure.} = enum
    Default = ""                       # "" ⇒ native default
    Sidebar = "sidebar"
    HeaderView = "headerView"
    Titlebar = "titlebar"
    Menu = "menu"
    Popover = "popover"
    HudWindow = "hudWindow"
    FullScreenUI = "fullScreenUI"
    Sheet = "sheet"
    ContentBackground = "contentBackground"
    UnderWindowBackground = "underWindowBackground"
    UnderPageBackground = "underPageBackground"
    WindowBackground = "windowBackground"
  SidebarPresentation* {.pure.} = enum
    Default = ""                       # "" ⇒ per-platform default (macOS tiles)
    Tile = "tile"
    Overlay = "overlay"
  ToolbarStyle* {.pure.} = enum
    Unified = "unified"                # default (ord 0; no empty sentinel needed)
    UnifiedCompact = "unifiedCompact"
    Expanded = "expanded"
```

(Member-name/value lists are pinned against `runtime/window.ts`'s `Material`
const + the `presentation`/`style` unions — keep in lockstep.)

## Field changes (`window.nim`)

Defaults preserve today's behavior exactly:

| Field | Was | Now (default) |
|---|---|---|
| `SidebarOptions.material` | `string` | `Material` (`Default`) |
| `SidebarOptions.presentation` | `string` | `SidebarPresentation` (`Default`) |
| `InspectorOptions.material` | `string` | `Material` (`Default`) |
| `ToolbarOptions.style` | `string` | `ToolbarStyle` (`Unified`) |
| `WindowOptions.vibrancy` | `string` | `Material` (`Default`) |

`url`, `backgroundColor`, and the `ToolbarItemOpt`/`MenuItemOpt` string fields
stay free-form `string`.

## Boundary mechanism (window.m + wire unchanged)

The native side still reads/sends strings; only the Nim representation is an
enum, so two thin conversions sit at the boundary — both DRY (derived from the
enum's own string values, no value duplication):

- **enum → string (accessors):** module-global string tables filled once at
  module init from the enum's `$` value, e.g.
  `var materialStr: array[Material, string]; (for m in Material: materialStr[m] = $m)`.
  `wopts_sidebar_material`/`wopts_inspector_material`/`wopts_vibrancy` return
  `materialStr[<field>].cstring`; `wopts_sidebar_presentation` returns
  `sidebarPresStr[<field>].cstring`. These globals are filled once and never
  reassigned, so the borrowed `cstring` is stable for window.m's synchronous
  read (same BOUNDARY RULE 1 contract as the existing string accessors). No
  per-call allocation, no per-field cache.
- **string → enum (`windowOptsApplyJson`):** a generic
  `proc enumFromStr[T: enum](s: string, dflt: T): T` that scans `T` and returns
  the member whose `$` equals `s`, else `dflt`. Each chrome field parses with
  its `Default`/`Unified` fallback. (Replaces the current
  `o.sidebar.material = jStr(...)` etc.)
- **toolbar:** `serializeToolbar` emits `$t.style` (the enum's value) into the
  wire JSON (already cached in `toolbarJsonCache`, so no stability concern);
  `parseToolbarJson` sets `result.style = enumFromStr[ToolbarStyle](..., ToolbarStyle.Unified)`.

## Authoring after

```nim
app.window.create(WindowOptions(
  vibrancy: Material.Sidebar,
  sidebar: SidebarOptions(url: "#side", material: Material.Sidebar,
                          presentation: SidebarPresentation.Overlay),
  toolbar: ToolbarOptions(style: ToolbarStyle.UnifiedCompact, items: @[...]),
))
# a typo no longer compiles:  material: Material.Sidbar  → Error: undeclared field
```

## Testing

- **Unit (`windowmanager_test.nim`):**
  - `windowOptsApplyJson` with nested `sidebar.material`/`presentation` +
    `inspector.material` strings → asserts the parsed ENUM values
    (`o.sidebar.material == Material.Sidebar`, `o.sidebar.presentation ==
    SidebarPresentation.Overlay`).
  - Absent/unknown material/presentation → `Default`.
  - Accessor output: a constructed `WindowOptions` with enum chrome → the
    `wopts_*` accessors return the expected value strings (`$` of the enum).
  - Toolbar round-trip with an explicit `style: ToolbarStyle.Expanded` survives
    `parseToolbarJson(serializeToolbar(t)) == t`.
  - Update the existing `presentation`/`material` assertions from string to enum.
- **Build gates:** Nim macOS build (`[zapp] build complete:` last line + fresh
  binary mtime); iOS-sim build; `bun test cli/src`.
- **Human smoke:** kitchen-sink chrome renders unchanged (sidebar overlay,
  inspector, toolbar) — proves the enum→string boundary emits identical native
  strings.

## Risks / notes

- The `Default = ""` sentinel is the load-bearing parity point — it keeps "field
  unset" producing the same `""` the native side reads as "use default" today.
- enum↔string conversions are derived from the enum's `$` values (single source
  of truth); the enum value lists must stay in lockstep with the TS `Material`
  const + `presentation`/`style` unions (noted inline).
- Breaking change for Nim app authors, but kitchen-sink is the only consumer and
  the branch is unmerged.
