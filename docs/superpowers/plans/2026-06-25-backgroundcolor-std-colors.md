# backgroundColor via Nim std/colors — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `backgroundColor` (window + sidebar + inspector) accept CSS names, `#rgb`/`#rrggbb`/`#rrggbbaa`, `rgb()`, and `rgba()` — parsed in Nim via `std/colors` — instead of today's `#rrggbb`-only C parser, and let Nim `app.nim` authors pass `std/colors` constants (`backgroundColor: colBlue`) directly.

**Architecture:** A new `native/nim/color.nim` parses the color string (`std/colors` for names + a small custom parse for `rgb()`/`rgba()`/hex) and exports `zapp_color_parse(s, *r,*g,*b,*a) -> bool` via `{.exportc.}`. The macOS `window.m` calls it at its three `backgroundColor` sites (replacing the local hex parser) and applies the returned alpha. A `ZappColor` distinct type (with scoped converters from `string` and from `std/colors.Color`) replaces the three Nim `string` `backgroundColor` fields so both author paths work. The wire shape is unchanged — the raw string still flows TS/Nim → native, which now delegates parsing to Nim.

**Tech Stack:** Nim (`std/colors`, `std/options`, `std/strutils`), Objective-C (AppKit), TypeScript (runtime types/JSDoc only), `bun:test`, `nim c -r`.

## Global Constraints

- Branch `feat/nim-native`, kept **UNMERGED** (do NOT merge to main).
- Commit trailer (every commit): `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Staging discipline:** explicit per-file `git add` only. **NEVER** `git add -A` / `git add .` — the working tree has unrelated pre-existing WIP under `assets/`, `benchmarks/`, `vendor/`, `spikes/`, plus untracked files, that must NOT be swept into these commits.
- Always use **Bun**, never Node.
- Behavior is **macOS-only** and **create-time only** (no runtime mutation). But `color.nim` + the `window.nim` field changes are pure Nim and **must still cross-compile for the iOS simulator** (the bg is only painted on macOS).
- Accepted formats: CSS **names**; `#rgb` / `#rrggbb` / `#rrggbbaa`; `rgb()`; `rgba()`. **No** `hsl()`. `rgba()` alpha is a **float in `0..1`** (so `1` = opaque, `0.5` → 128); int 0–255 alpha only via `#rrggbbaa`.
- Alpha: honor on sidebar + inspector (flat pane path — alpha shows the window background behind the pane); clamp the opaque **window** to `1.0`.
- Invalid (non-empty, unparseable) color → log `[zapp] invalid backgroundColor: "…"` to stderr and ignore (skip the bg). Empty/unset → ignore silently.
- `std/colors` facts: `parseColor(name)` accepts CSS/X11 names + `#rrggbb`, raises `ValueError` on failure (case-insensitive lookup not guaranteed — pass a lowercased name); `Color` is RGB-only; named constants are `colBlue`, `colRebeccaPurple`, …; `$Color` → `"#rrggbb"`.

---

### Task 1: `color.nim` — parser + `ZappColor` + `zapp_color_parse` (TDD)

**Files:**
- Create: `native/nim/color.nim`
- Test: `native/nim/tests/color_test.nim`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces (used by Task 2):
  - `type ZappColor* = distinct string`
  - `converter toZappColor*(s: string): ZappColor`
  - `converter colorToZappColor*(c: Color): ZappColor` (from `std/colors`)
  - `proc parseCssColor*(s: string): Option[tuple[r, g, b, a: int]]` (channels 0–255)
  - `proc zapp_color_parse*(s: cstring; r, g, b, a: ptr cint): bool {.exportc, cdecl.}`

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/color_test.nim`:

```nim
import ../color
import std/options
import std/colors

# Helper: parse to an unnamed 4-tuple (avoids named/unnamed tuple == ambiguity).
proc rgba(s: string): (int, int, int, int) =
  let p = parseCssColor(s).get
  (p.r, p.g, p.b, p.a)

# names (via std/colors)
doAssert rgba("blue") == (0, 0, 255, 255)
doAssert rgba("rebeccapurple") == (102, 51, 153, 255)
doAssert rgba("  BLUE  ") == (0, 0, 255, 255)          # whitespace + case tolerant

# hex: 3 / 6 / 8 digit
doAssert rgba("#00f") == (0, 0, 255, 255)
doAssert rgba("#0000ff") == (0, 0, 255, 255)
doAssert rgba("#0000FF80") == (0, 0, 255, 128)         # 8-digit alpha (case tolerant)

# rgb() / rgba()
doAssert rgba("rgb(1,2,3)") == (1, 2, 3, 255)
doAssert rgba("rgb( 10 , 20 , 30 )") == (10, 20, 30, 255)   # inner whitespace
doAssert rgba("rgba(0,0,0,0.5)") == (0, 0, 0, 128)
doAssert rgba("rgba(0,0,0,1)") == (0, 0, 0, 255)            # alpha 1 = opaque

# invalid → none
doAssert parseCssColor("").isNone                # empty
doAssert parseCssColor("#zz").isNone             # non-hex
doAssert parseCssColor("#1234567").isNone        # bad hex length (7)
doAssert parseCssColor("reddish").isNone         # unknown name
doAssert parseCssColor("rgb(1,2)").isNone        # wrong arity
doAssert parseCssColor("rgb(300,0,0)").isNone    # channel > 255
doAssert parseCssColor("rgba(0,0,0,2)").isNone   # alpha > 1
doAssert parseCssColor("rgba(0,0,0,128)").isNone # int alpha rejected (use #rrggbbaa)

# ZappColor converters
let zc: ZappColor = colBlue            # Color -> ZappColor ($Color is UPPERCASE hex)
doAssert string(zc) == "#0000FF"
let zs: ZappColor = "rebeccapurple"    # string -> ZappColor (identity wrap)
doAssert string(zs) == "rebeccapurple"

echo "color ok"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nim c -r --hints:off native/nim/tests/color_test.nim`
Expected: FAIL — `cannot open file: ../color` (the module does not exist yet).

- [ ] **Step 3: Write `color.nim`**

Create `native/nim/color.nim`:

```nim
## CSS-style color parsing for window/sidebar/inspector backgroundColor.
## Accepts: CSS names + #rgb/#rrggbb/#rrggbbaa + rgb()/rgba(). Names come from
## std/colors; rgb()/rgba() and hex are parsed here (std/colors is RGB-only and
## doesn't parse rgb()/rgba()). rgba() alpha is a float in 0..1.

import std/options
import std/colors
import std/strutils

type ZappColor* = distinct string
  ## A backgroundColor value. Accepts a CSS string OR a std/colors `Color`
  ## (e.g. `colBlue`) via the converters below. The raw string is carried to
  ## native unchanged; native delegates parsing to `zapp_color_parse`.

converter toZappColor*(s: string): ZappColor = ZappColor(s)
converter colorToZappColor*(c: Color): ZappColor = ZappColor($c)  # $Color -> "#rrggbb"

# stderr warn idiom (matches permissions.nim / worker.nim).
proc c_fprintf(stream: pointer, fmt: cstring) {.importc: "fprintf", varargs, header: "<stdio.h>", cdecl.}
var cstderr {.importc: "stderr", header: "<stdio.h>".}: pointer

proc parseHexPair(s: string): Option[int] =
  ## Parse exactly two hex digits (00..FF). None on any non-hex char.
  try: some(parseHexInt(s)) except ValueError: none(int)

proc parseHex(t: string): Option[tuple[r, g, b, a: int]] =
  ## t includes the leading '#'. Supports #rgb, #rrggbb, #rrggbbaa.
  let h = t[1 .. ^1]
  var rs, gs, bs, asx: string
  case h.len
  of 3:
    rs = $h[0] & $h[0]; gs = $h[1] & $h[1]; bs = $h[2] & $h[2]; asx = "ff"
  of 6:
    rs = h[0 .. 1]; gs = h[2 .. 3]; bs = h[4 .. 5]; asx = "ff"
  of 8:
    rs = h[0 .. 1]; gs = h[2 .. 3]; bs = h[4 .. 5]; asx = h[6 .. 7]
  else:
    return none(tuple[r, g, b, a: int])
  let r = parseHexPair(rs); let g = parseHexPair(gs)
  let b = parseHexPair(bs); let a = parseHexPair(asx)
  if r.isNone or g.isNone or b.isNone or a.isNone:
    return none(tuple[r, g, b, a: int])
  some((r.get, g.get, b.get, a.get))

proc parseRgbFunc(low: string): Option[tuple[r, g, b, a: int]] =
  ## low is the already-lowercased, already-trimmed string starting with
  ## "rgb(" or "rgba(". rgba alpha is a float 0..1.
  let isRgba = low.startsWith("rgba(")
  let openLen = if isRgba: 5 else: 4
  if not low.endsWith(")"):
    return none(tuple[r, g, b, a: int])
  let body = low[openLen .. ^2]              # drop "rgb("/"rgba(" and trailing ")"
  let parts = body.split(',')
  let wantArity = if isRgba: 4 else: 3
  if parts.len != wantArity:
    return none(tuple[r, g, b, a: int])
  var ch: array[3, int]
  for i in 0 .. 2:
    try:
      ch[i] = parseInt(parts[i].strip())
    except ValueError:
      return none(tuple[r, g, b, a: int])
    if ch[i] < 0 or ch[i] > 255:
      return none(tuple[r, g, b, a: int])
  var a = 255
  if isRgba:
    var f: float
    try:
      f = parseFloat(parts[3].strip())
    except ValueError:
      return none(tuple[r, g, b, a: int])
    if f < 0.0 or f > 1.0:
      return none(tuple[r, g, b, a: int])
    a = int(f * 255.0 + 0.5)                 # round to nearest
  some((ch[0], ch[1], ch[2], a))

proc parseCssColor*(s: string): Option[tuple[r, g, b, a: int]] =
  ## Parse a CSS color: name | #rgb/#rrggbb/#rrggbbaa | rgb()/rgba().
  ## Returns none on empty or unparseable input.
  let t = s.strip()
  if t.len == 0:
    return none(tuple[r, g, b, a: int])
  let low = t.toLowerAscii()
  if low.startsWith("rgb(") or low.startsWith("rgba("):
    return parseRgbFunc(low)
  if t.startsWith("#"):
    return parseHex(t)
  try:
    let (r, g, b) = extractRGB(parseColor(low))
    some((r, g, b, 255))
  except ValueError:
    none(tuple[r, g, b, a: int])

proc zapp_color_parse*(s: cstring; r, g, b, a: ptr cint): bool {.exportc, cdecl.} =
  ## C-ABI entry called from native. Fills *r,*g,*b,*a (0..255) and returns true
  ## on success. Empty/nil => false (silent). Non-empty unparseable => warn + false.
  if s == nil: return false
  let str = $s
  if str.len == 0: return false
  let parsed = parseCssColor(str)
  if parsed.isNone:
    c_fprintf(cstderr, cstring("[zapp] invalid backgroundColor: \"%s\" — ignoring\n"), s)
    return false
  let (rr, gg, bb, aa) = parsed.get
  r[] = rr.cint; g[] = gg.cint; b[] = bb.cint; a[] = aa.cint
  true
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nim c -r --hints:off native/nim/tests/color_test.nim`
Expected: PASS — prints `color ok`, exits 0. (If `extractRGB`/`parseColor` import errors appear, confirm `import std/colors` is present.)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/color.nim native/nim/tests/color_test.nim
git commit -m "$(cat <<'EOF'
feat(nim): color.nim — CSS color parsing via std/colors (#685 T1)

parseCssColor (names + #rgb/#rrggbb/#rrggbbaa + rgb()/rgba(), rgba alpha float
0..1), ZappColor distinct with scoped converters from string and std/colors
Color, exported zapp_color_parse with warn-on-invalid. TDD color_test.nim.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Wire `ZappColor` + `zapp_color_parse` into `window.nim` and `window.m` (atomic, cross-language)

This task is atomic: the Nim field-type change and the native parser swap must land together so the build stays green on both platforms.

**Files:**
- Modify: `native/nim/window.nim` (imports ~14–19; fields lines 120, 132, 161; getters lines 250, 273, 286; `windowOptsApplyJson` assignments lines 596, 603, 615)
- Modify: `native/platform/darwin/window.m` (extern block ~41–59; delete `zapp_parse_hex_color` def ~655; call sites ~816, ~912, ~977)
- Modify: `runtime/window.ts` (three `backgroundColor` JSDoc blocks: window ~108–113, sidebar ~270–273, inspector ~319–322)

**Interfaces:**
- Consumes (from Task 1): `ZappColor`, the two converters, `zapp_color_parse`.
- Produces: native `extern bool zapp_color_parse(const char*, int*, int*, int*, int*);` usage; no new public symbols.

- [ ] **Step 1: `window.nim` — import + re-export `color`**

In `native/nim/window.nim`, add to the import block (after the existing `import coretypes` / `import apptypes` / `import appconfig` lines, ~14–19):

```nim
import color
export color   # ZappColor + converters reach app.nim through the WindowOptions API
```

- [ ] **Step 2: `window.nim` — change the three `backgroundColor` fields to `ZappColor`**

Line 120 (`SidebarOptions`) currently:

```nim
    url*, backgroundColor*: string
```

Replace with:

```nim
    url*: string
    backgroundColor*: ZappColor
```

Line 132 (`InspectorOptions`) currently:

```nim
    url*, backgroundColor*: string
```

Replace with:

```nim
    url*: string
    backgroundColor*: ZappColor
```

Line 161 (window options type) currently:

```nim
    backgroundColor*: string
```

Replace with:

```nim
    backgroundColor*: ZappColor
```

- [ ] **Step 3: `window.nim` — getters return the underlying string**

Line 250:

```nim
proc wopts_background_color(p: pointer): cstring {.exportc, cdecl.} = string(opt(p).backgroundColor).cstring
```

Line 273:

```nim
proc wopts_sidebar_background_color(p: pointer): cstring {.exportc, cdecl.} = string(opt(p).sidebar.backgroundColor).cstring
```

Line 286:

```nim
proc wopts_inspector_background_color(p: pointer): cstring {.exportc, cdecl.} = string(opt(p).inspector.backgroundColor).cstring
```

(`string(distinct)` is a borrow of the struct-owned string — same `.cstring` lifetime as before, no dangling pointer.)

- [ ] **Step 4: `window.nim` — `windowOptsApplyJson` assignments (no edit needed; verify)**

Lines 596 / 603 / 615 currently assign a `string` to each `backgroundColor` field:

```nim
  if jHasStr(a, "backgroundColor"): o.backgroundColor = jStr(a, "backgroundColor")
  ...
    if jHasStr(sb, "backgroundColor"): o.sidebar.backgroundColor = jStr(sb, "backgroundColor")
  ...
    if jHasStr(insp, "backgroundColor"): o.inspector.backgroundColor = jStr(insp, "backgroundColor")
```

These now rely on the `toZappColor` converter (string → ZappColor) and compile unchanged. **Do not edit them**; the next build step verifies they compile.

- [ ] **Step 5: Verify the Nim side still compiles (and the test still passes)**

Run: `nim c -r --hints:off native/nim/tests/color_test.nim`
Expected: PASS (`color ok`) — confirms `color.nim` unchanged.
Run: `nim check --hints:off native/nim/window.nim`
Expected: no errors (the `ZappColor` fields, getters, and converter-backed JSON assignments all type-check). Pre-existing unrelated warnings are fine; there must be no new error.

- [ ] **Step 6: `window.m` — declare the extern, delete the old parser**

In `native/platform/darwin/window.m`, in the `extern` declaration block near the other `wopts_*` externs (around line 41–59), add:

```objc
// Nim-side color parser (native/nim/color.nim): names/#hex/rgb()/rgba() -> rgba 0..255.
extern bool zapp_color_parse(const char* s, int* r, int* g, int* b, int* a);
```

Delete the `zapp_parse_hex_color` definition (lines ~655–658):

```objc
static bool zapp_parse_hex_color(const char* hex, int* r, int* g, int* b) {
    if (!hex || hex[0] != '#' || strlen(hex) < 7) return false;
    return sscanf(hex + 1, "%2x%2x%2x", r, g, b) == 3;
}
```

- [ ] **Step 7: `window.m` — window site (~812–819): opaque, alpha clamped to 1.0**

Current:

```objc
        NSColor* bgColor = nil;
        {
            int cr, cg, cb;
            if (!wopts_transparent(opts) && !useVibrancy &&
                zapp_parse_hex_color(wopts_background_color(opts), &cr, &cg, &cb)) {
                bgColor = [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:1.0];
                [window setBackgroundColor:bgColor];
            }
        }
```

Replace with (note the added `ca`, ignored — the window is opaque):

```objc
        NSColor* bgColor = nil;
        {
            int cr, cg, cb, ca;
            if (!wopts_transparent(opts) && !useVibrancy &&
                zapp_color_parse(wopts_background_color(opts), &cr, &cg, &cb, &ca)) {
                // Opaque window: AppKit ignores alpha on opaque windows; clamp to 1.0.
                bgColor = [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:1.0];
                [window setBackgroundColor:bgColor];
            }
        }
```

- [ ] **Step 8: `window.m` — sidebar site (~910–916): honor alpha**

Current:

```objc
                    int cr, cg, cb;
                    const char* sbg = wopts_sidebar_background_color(opts);
                    if (sbg && sbg[0] != '\0' && zapp_parse_hex_color(sbg, &cr, &cg, &cb)) {
                        sideVC.view.wantsLayer = YES;
                        sideVC.view.layer.backgroundColor =
                            [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:1.0].CGColor;
                    }
```

Replace with:

```objc
                    int cr, cg, cb, ca;
                    const char* sbg = wopts_sidebar_background_color(opts);
                    if (sbg && sbg[0] != '\0' && zapp_color_parse(sbg, &cr, &cg, &cb, &ca)) {
                        sideVC.view.wantsLayer = YES;
                        sideVC.view.layer.backgroundColor =
                            [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:ca/255.0].CGColor;
                    }
```

- [ ] **Step 9: `window.m` — inspector site (~975–981): honor alpha**

Current:

```objc
                    int cr, cg, cb;
                    const char* ibg = wopts_inspector_background_color(opts);
                    if (ibg && ibg[0] != '\0' && zapp_parse_hex_color(ibg, &cr, &cg, &cb)) {
                        inspVC.view.wantsLayer = YES;
                        inspVC.view.layer.backgroundColor =
                            [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:1.0].CGColor;
                    }
```

Replace with:

```objc
                    int cr, cg, cb, ca;
                    const char* ibg = wopts_inspector_background_color(opts);
                    if (ibg && ibg[0] != '\0' && zapp_color_parse(ibg, &cr, &cg, &cb, &ca)) {
                        inspVC.view.wantsLayer = YES;
                        inspVC.view.layer.backgroundColor =
                            [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:ca/255.0].CGColor;
                    }
```

- [ ] **Step 10: `runtime/window.ts` — update the three JSDoc blocks**

For the window `backgroundColor` (~line 113), the sidebar `backgroundColor` (~273), and the inspector `backgroundColor` (~322): the field stays `backgroundColor?: string;`. Update each block's prose to document the accepted formats and alpha behavior. Window block — replace its doc comment with:

```ts
  /** Window background color. Accepts a CSS name (`"teal"`), `#rgb`/`#rrggbb`/
   *  `#rrggbbaa`, `rgb()`, or `rgba()`. The window is opaque, so alpha is
   *  clamped to fully opaque. Opaque windows only (ignored when transparent or
   *  `vibrancy` is set). macOS; create-time. Invalid colors are ignored with a
   *  `[zapp] invalid backgroundColor` warning. */
  backgroundColor?: string;
```

Sidebar and inspector blocks — replace each `backgroundColor` doc comment with:

```ts
  /** Solid backdrop color behind the transparent pane webview (the flat,
   *  non-vibrant path — `material` takes precedence if both are set). Accepts a
   *  CSS name, `#rgb`/`#rrggbb`/`#rrggbbaa`, `rgb()`, or `rgba()`; an `rgba()`
   *  alpha lets the window background behind the pane show through. macOS;
   *  create-time. Invalid colors are ignored with a warning. */
  backgroundColor?: string;
```

- [ ] **Step 11: Build gate — macOS**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: ends with `[zapp] build complete: …/kitchen-sink (…KB)` and a freshly-built binary (no compile errors from `window.m` or the Nim layer).

- [ ] **Step 12: Build gate — iOS-sim cross-compile**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios`
Expected: ends with `[zapp] build complete: …/ios/kitchen-sink.app/kitchen-sink (…KB)`. This proves `color.nim` + the `ZappColor` field change cross-compile for iOS (the bg is only painted on macOS; iOS just links the unused exported symbol).

- [ ] **Step 13: TS gate**

Run: `cd /Users/zach/code/zapp && bun test runtime/ && bunx tsc --noEmit -p tsconfig.json`
Expected: bun tests pass (TS is a passthrough — no behavior change), `tsc` clean.

- [ ] **Step 14: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/window.nim native/platform/darwin/window.m runtime/window.ts
git commit -m "$(cat <<'EOF'
feat(macos): backgroundColor via std/colors — names/rgb()/rgba()/hex (#685 T2)

window.nim: 3 backgroundColor fields string->ZappColor (scoped converters),
getters return string(field). window.m: replace zapp_parse_hex_color with the
Nim zapp_color_parse; sidebar/inspector honor alpha, opaque window clamps to
1.0; delete the old hex parser. window.ts JSDoc documents formats + alpha.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Kitchen-sink showcase + docs + final gates + human visual smoke

**Files:**
- Modify: `kitchen-sink/src/sections/multiwindow.ts` (add one demo card + button + handler)
- Modify: `docs/api-reference.md` (the `backgroundColor` references near lines 739, 757–761, 1088)

**Interfaces:**
- Consumes: the shipped `backgroundColor` parsing (Tasks 1–2). No new code interfaces.

- [ ] **Step 1: Add a "Color (std/colors)" demo to the Multi-window section**

In `kitchen-sink/src/sections/multiwindow.ts`, after the existing "Background extension" card block (the one with `bg-mirror` / `bg-extend`), add a new card + handler. Insert this card append after that block:

```ts
    // ── Color (std/colors) showcase ──────────────────────────────────────────
    host.appendChild(card({
      title: "Color (std/colors)",
      intro: "backgroundColor now accepts CSS names, #rgb/#rrggbb/#rrggbbaa, rgb() and rgba(). This window uses a named window color (opaque) and a translucent rgba() sidebar whose alpha lets the window color show through.",
      buttons: [
        { act: "color-demo", label: "Open color window" },
      ],
    }));
    onAct(host, "color-demo", () => open(host, "color window", () =>
      Window.create({
        title: "Color — names + rgba",
        url: "#sidebar-pane",
        width: 720, height: 480,
        backgroundColor: "teal",                       // CSS name → opaque window
        titleBarStyle: "hiddenInset",
        sidebar: {
          url: "#sidebar-pane",
          width: 240,
          backgroundColor: "rgba(170, 59, 255, 0.4)",  // flat translucent → teal shows through
        },
      })));
```

(`open`, `card`, `onAct`, and `Window` are already imported at the top of the file.)

- [ ] **Step 2: Build + verify the showcase compiles**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
Expected: `[zapp] build complete: …`.

- [ ] **Step 3: Update `docs/api-reference.md`**

Find the `backgroundColor` table row / prose (around lines 757–761) and the sidebar example (~739) and inspector mention (~1088). Update the prose so it documents the full format set and alpha behavior. Replace the explanatory paragraph near line 760 (currently begins "`backgroundColor` (e.g. `"#1e1e1e"`) paints a solid, opaque backdrop…") with:

```markdown
`backgroundColor` accepts a CSS color **name** (`"teal"`, `"rebeccapurple"`),
`#rgb` / `#rrggbb` / `#rrggbbaa` hex, `rgb()`, or `rgba()` (parsed via Nim's
`std/colors`). It paints a solid backdrop behind the transparent pane webview
(the flat, non-vibrant path; `material` wins if both are set). For sidebar and
inspector panes an `rgba()` alpha is honored — the window background behind the
pane shows through. The **window** `backgroundColor` is always opaque (AppKit
ignores alpha on opaque windows). Invalid colors are ignored with a
`[zapp] invalid backgroundColor` warning. In Nim `app.nim` you may pass a
`std/colors` constant directly, e.g. `backgroundColor: colBlue`. macOS;
create-time.
```

(Adjust the surrounding sentence boundaries to fit; keep the table row `| `backgroundColor` | `string` | — (material) |` intact.)

- [ ] **Step 4: Full gate matrix**

Run each and confirm:
- `cd /Users/zach/code/zapp && nim c -r --hints:off native/nim/tests/color_test.nim` → `color ok`
- `cd /Users/zach/code/zapp && bun test runtime/` → pass
- `cd /Users/zach/code/zapp && bunx tsc --noEmit -p tsconfig.json` → clean
- `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:`
- `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios` → `[zapp] build complete:` (ios)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/sections/multiwindow.ts docs/api-reference.md
git commit -m "$(cat <<'EOF'
demo+docs(color): kitchen-sink color window + api-reference formats (#685 T3)

Multi-window "Color (std/colors)" demo: named opaque window color + translucent
rgba() sidebar. api-reference documents names/hex/rgb()/rgba(), alpha behavior,
and the Nim colBlue ergonomic.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: HUMAN VISUAL GATE (pause for the user)**

Stop and ask the user to run `cd /Users/zach/code/zapp/kitchen-sink && bun run dev`, go to **Multi-window → Color (std/colors) → Open color window**, and confirm:
1. The window background is **teal** (CSS name parsed).
2. The sidebar is a **translucent purple** with the teal showing through (rgba alpha honored, not forced opaque).
3. (Optional) Temporarily set a bad color (e.g. `backgroundColor: "notacolor"`) and confirm the `[zapp] invalid backgroundColor: "notacolor"` warning prints and the app still runs (no crash, pane keeps default).

Do not proceed to the final whole-branch review until the user confirms.

---

## Self-Review

**1. Spec coverage:**
- Parser in Nim via `std/colors` (Approach A) → T1 `color.nim`. ✓
- Names / `#rgb`/`#rrggbb`/`#rrggbbaa` / `rgb()` / `rgba()`; rgba alpha float `0..1` → T1 `parseCssColor` + tests. ✓
- Honor alpha (sidebar/inspector flat path), clamp window → T2 Steps 7–9. ✓
- Warn + ignore invalid → T1 `zapp_color_parse` stderr warn; T3 Step 6 confirms. ✓
- `ZappColor` distinct + scoped converters (`colBlue` works) → T1; exported into app.nim via `export color` in T2 Step 1; unit-tested in T1. ✓
- Surfaces window+sidebar+inspector, macOS-only, create-time → T2. ✓
- iOS cross-compile gate → T2 Step 12, T3 Step 4. ✓
- Showcase + docs → T3. ✓
- Human visual gate → T3 Step 6. ✓

**2. Placeholder scan:** none — every code step contains complete code; every command has an expected result.

**3. Type consistency:** `ZappColor`, `toZappColor`, `colorToZappColor`, `parseCssColor`, `zapp_color_parse(s, *r,*g,*b,*a)->bool` are named identically in T1 (definition), T2 (consumption: `string(field)` getters, `extern` decl, three call sites all pass `&ca`), and the tests. The native extern signature (`const char*, int*, int*, int*, int*`) matches the Nim `cstring, ptr cint ×4`. ✓
