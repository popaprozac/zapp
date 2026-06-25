# `backgroundColor` via Nim `std/colors` — Design

**Status:** approved (brainstorm), pending plan
**Branch:** `feat/nim-native` (UNMERGED)
**Task:** #685
**Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

## Goal

Let `backgroundColor` on a window, sidebar, and inspector accept CSS-style
color **names**, `#rgb`/`#rrggbb`/`#rrggbbaa` hex, `rgb()`, and `rgba()` —
parsed with Nim's `std/colors` — instead of today's `#rrggbb`-only C parser.
In the Nim `app.nim` authoring path, also accept the typed `std/colors`
constants directly (`backgroundColor: colBlue`).

## Background (current state, verified 2026-06-25)

- `backgroundColor?: string` exists on `WindowOptions` and on the `sidebar` /
  `inspector` option blocks (TS `runtime/window.ts`), mirrored as
  `backgroundColor*: string` in Nim `native/nim/window.nim` (window field +
  the two nested pane-option types).
- The string flows TS/Nim → native **raw**. The Nim getters
  `wopts_background_color` / `wopts_sidebar_background_color` /
  `wopts_inspector_background_color` (`{.exportc.}`) return the struct's string.
- Native `native/platform/darwin/window.m` parses it with
  `static bool zapp_parse_hex_color(const char* hex, int* r, int* g, int* b)` —
  requires a leading `#` and ≥7 chars, `sscanf "%2x%2x%2x"`. **No names, no
  `rgb()`, alpha hardcoded to 1.0.** Three call sites:
  - window (~816): opaque windows only, `colorWithSRGBRed:…alpha:1.0`.
  - sidebar (~912): `sideVC.view.layer.backgroundColor = …alpha:1.0`.
  - inspector (~979): `inspVC.view.layer.backgroundColor = …alpha:1.0`.
- No existing Nim color module (greenfield).
- `std/colors` facts that shape the design: `parseColor(name)` accepts CSS/X11
  **names** and `#rrggbb` and raises `ValueError` on failure; the `Color` type
  is **RGB-only (no alpha)**; named constants are `colBlue`, `colRebeccaPurple`,
  …; `$Color` → `"#rrggbb"`. So `rgb()`/`rgba()` and any alpha need a small
  custom parse on top of `std/colors`.

## Decisions (from brainstorm)

1. **Parse location — Approach A:** a Nim color module parses the string and is
   exported via `{.exportc.}` as `zapp_color_parse`; native calls it (outputs by
   pointer). Honors "use `std/colors` from Nim", keeps native thin, no
   cstring-return lifetime hazard, one tested source covering both author paths.
2. **Alpha — honor it where applicable.** Parse alpha from `rgba()` /
   `#rrggbbaa`. Sidebar + inspector `backgroundColor` is the **flat,
   non-vibrant pane path** (`layer.backgroundColor`, used only when no
   `material` override is set — there is no `NSVisualEffectView` behind it);
   honoring alpha lets the **window background behind the pane** show through
   (real translucency; today it's forced opaque). The opaque window clamps to
   `1.0` (AppKit ignores alpha on opaque windows) — documented. `material`
   (glass) and `backgroundColor` remain mutually exclusive; `material` wins.
3. **Invalid input — warn + ignore (fall back).** Unparseable color → log
   `[zapp] invalid backgroundColor "…"` (warn) and skip the bg (surface keeps
   its default). Non-fatal; no longer silent.
4. **Nim authoring ergonomic — `ZappColor` distinct with scoped converters.**
   The three Nim `backgroundColor` fields become `ZappColor` (a
   `distinct string`) with converters `from string` and `from std/colors.Color`.
   Authors write `backgroundColor: colBlue`, `"#1e1e1e"`, or `"rgba(0,0,0,.5)"`
   interchangeably. Converters are scoped to `ZappColor` (no global
   `Color → string` footgun).
5. **Scope:** window + sidebar + inspector; macOS only; create-time only.
6. **Accepted formats:** names; `#rgb` / `#rrggbb` / `#rrggbbaa`; `rgb()`;
   `rgba()`. **No** `hsl()` (`std/colors` can't parse it; YAGNI).

## Architecture

Same wire shape as today: the color string flows TS/Nim → native unchanged;
native now delegates parsing to Nim instead of using a local C hex parser.

```
app.nim:   WindowOptions(backgroundColor: colBlue | "#1e1e1e" | "rgba(0,0,0,.5)")
                 │  (ZappColor converters: Color→$c, string→as-is)
TS:        Window.create({ backgroundColor: "rebeccapurple" })
                 │  wire JSON → windowOptsApplyJson → ZappColor(jsonStr)
                 ▼
native/nim/window.nim  wopts_*_background_color → string(field).cstring  (raw)
                 ▼
window.m   zapp_color_parse(str, &r,&g,&b,&a)  →  NSColor (alpha per surface)
                 ▲
native/nim/color.nim   parseCssColor (std/colors + custom rgb()/rgba()/hex8)
```

## Components

### `native/nim/color.nim` (new)

- `parseCssColor(s: string): Option[tuple[r, g, b, a: int]]` — channels 0–255.
  Dispatch on a trimmed, lower-cased copy:
  - starts with `rgba(` or `rgb(` → custom parse (see below).
  - starts with `#` → hex: 3-digit (`#rgb` → each nibble doubled), 6-digit
    (`#rrggbb`, a=255), 8-digit (`#rrggbbaa`). Any other length → `none`.
  - else → `std/colors.parseColor(s)`; on success `extractRGB` → (r,g,b,255);
    on `ValueError` → `none`.
- `rgb()` / `rgba()` custom parse: strip the `rgb(`/`rgba(` and `)`, split on
  `,`. `rgb` requires 3 ints 0–255 (a=255). `rgba` requires 3 ints + an alpha
  that is a **float in `0..1`** (CSS-canonical; → `round(f*255)`, so `1` = opaque,
  `0.5` → 128). Out-of-range (alpha >1 or <0, channel >255), wrong arity, or
  non-numeric → `none`. (Int 0–255 alpha is available via `#rrggbbaa`.)
- `ZappColor = distinct string` with:
  - `converter toZappColor(s: string): ZappColor` (identity wrap).
  - `converter colorToZappColor(c: Color): ZappColor = ZappColor($c)`
    (`std/colors` `$` → `"#rrggbb"`).
  - a readback (`proc str(z: ZappColor): string` or `string` borrow) for getters.
  - Default value is the empty string (unset), same as today.
- Exported C-ABI:
  `proc zapp_color_parse(s: cstring; r, g, b, a: ptr cint): bool {.exportc, cdecl.}`
  — empty/`nil` input → returns false silently (unset, not an error); a
  non-empty unparseable input → logs the `[zapp] invalid backgroundColor "…"`
  warning (via the existing Zapp Nim log primitive) and returns false; success
  fills the four channels and returns true.

**Unit tests (`native/nim/tests/color_test.nim`, TDD):** name (`"blue"`,
`"rebeccapurple"`); `#rgb` / `#rrggbb` / `#rrggbbaa` (8-digit alpha 0–255); `rgb(1,2,3)`;
`rgba(0,0,0,0.5)` (alpha 128) and `rgba(0,0,0,1)` (alpha 255, opaque);
whitespace/case tolerance; invalid (`"#zz"`, `"reddish"`, `"rgb(1,2)"`,
`"rgba(0,0,0,2)"`, `"rgba(0,0,0,128)"`) → `none`;
`colBlue` → `ZappColor` → `"#0000ff"` round-trip; empty → false (no warn).

### `native/nim/window.nim`

- `import color` (the new module).
- Change the three `backgroundColor` fields (window option type + the sidebar
  and inspector nested option types) from `string` to `ZappColor`.
- The three getters return `string(opt(p).backgroundColor).cstring` — same
  struct-owned lifetime as today (the underlying string lives in the struct;
  `string(distinct)` is a borrow, not a fresh allocation).
- `windowOptsApplyJson` constructs `ZappColor` from each JSON `backgroundColor`
  string (the `string` converter makes this transparent).
- Default-value parity: an unset field is the empty `ZappColor` → getter returns
  `""` → `zapp_color_parse` returns false silently → no bg applied (today's
  behavior).

### `native/platform/darwin/window.m`

- Declare `extern bool zapp_color_parse(const char*, int*, int*, int*, int*);`
- Delete `zapp_parse_hex_color` (these three sites are its only callers).
- Window (~816, opaque): `if (zapp_color_parse(str, &cr,&cg,&cb,&ca)) bg =
  colorWithSRGBRed:cr/255.0 …alpha:1.0;` — ignore `ca` (documented clamp).
- Sidebar (~912) & inspector (~979): `…alpha:ca/255.0` (honor alpha — flat pane path; alpha shows the window background behind the pane).

### `runtime/window.ts`

No parse change (raw passthrough — already a `string`). Update the three
`backgroundColor` JSDoc blocks: accepted formats (CSS name, `#rgb`/`#rrggbb`/
`#rrggbbaa`, `rgb()`, `rgba()`), and the note that window alpha is clamped to
opaque while sidebar/inspector honor it.

## Error handling

- Unparseable, non-empty color → `zapp_color_parse` warns once per surface and
  returns false → native skips the bg. Window/pane keeps its default.
- Empty/unset → false, no warning (normal "no color set").

## Kitchen-sink showcase

A Multi-window demo button opens a window with an **opaque named** window color
(e.g. `"teal"`) and a **flat `rgba()` sidebar** color whose alpha lets the teal
window background show through — one click proves names + alpha visually. (Keep
the main window clean as the smoke surface, consistent with prior cycles.)

## Docs

- `docs/api-reference.md`: `backgroundColor` accepted formats, the alpha
  semantics (window clamps, sidebar/inspector honor), and the Nim
  `colBlue`/`ZappColor` ergonomic.

## Testing & gates

- `color.nim` unit tests (above), run via `nim c -r`.
- `bun test runtime/…` (TS unaffected but run to confirm no regression) + `tsc`.
- Builds: macOS `[zapp] build complete:` + a fresh binary; **iOS-sim build must
  still compile** (the `ZappColor` field-type change + `color.nim` are pure Nim
  and must cross-compile, even though the bg is only painted on macOS).
- Human visual smoke: named color + `rgba()` sidebar render correctly; an
  intentionally bad color logs the warn + falls back (no crash).

## Plan shape (3 tasks)

1. **T1 — `color.nim`:** `parseCssColor` + `rgb()/rgba()/hex` + `ZappColor`
   converters + `zapp_color_parse` export, TDD with `color_test.nim`.
2. **T2 — wire (atomic, cross-language):** `window.nim` three fields → `ZappColor`
   + getters + `windowOptsApplyJson`; `window.m` three sites → `zapp_color_parse`
   with per-surface alpha; delete `zapp_parse_hex_color`; TS JSDoc. Build matrix.
3. **T3 — showcase + docs + final gates + human visual smoke.**

## Out of scope / non-goals

- `hsl()` and other CSS color functions (`std/colors` can't parse them).
- iOS painting of `backgroundColor` (the cross-compile gate only requires it to
  *compile*; rendering stays macOS).
- Runtime mutation of `backgroundColor` (create-time only, as today).
- Window translucency via alpha (window stays opaque; alpha is sidebar/inspector
  only).
