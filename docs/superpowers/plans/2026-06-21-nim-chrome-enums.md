# Typed Nim Chrome Enums Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the bare-string Nim chrome fields (`material`, sidebar `presentation`, toolbar `style`, window `vibrancy`) into string-valued Nim enums, giving Nim app authors autocomplete + compile-time checking matching the already-typed TS API.

**Architecture:** Pure Nim-side change. Three `{.pure.}` string-valued enums (`Material`, `SidebarPresentation`, `ToolbarStyle`) in `window.nim`; the chrome fields change from `string` to those enums (defaults = a `Default`/`Unified` sentinel preserving today's `""`/`"unified"` behavior). The `wopts_*` C-ABI accessor **signatures are unchanged** (window.m untouched) — their bodies emit the enum's string value via a module-global lookup table (stable cstring, no alloc). `windowOptsApplyJson` parses string→enum via a generic `enumFromStr`. The JSON wire is unchanged.

**Tech Stack:** Nim (`std/json`), the `wopts_*` C-ABI bridge to `native/platform/darwin/window.m`, the Nim unit-test convention (`nim c -r`).

**Branch:** `feat/nim-native` (unmerged). **Commit trailer:** `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Spec:** `docs/superpowers/specs/2026-06-21-nim-chrome-enums-design.md`.

---

## File Structure

- `native/nim/window.nim` — 3 new enums, field type changes (sidebar/inspector `material`, sidebar `presentation`, toolbar `style`, window `vibrancy`), module-global enum→string tables + `enumFromStr`, accessor bodies, `windowOptsApplyJson`, `serializeToolbar`/`parseToolbarJson`.
- `native/nim/tests/windowmanager_test.nim` — enum assertions.
- `kitchen-sink/zapp/app.nim` — `presentation: "overlay"` → `SidebarPresentation.Overlay`.
- `docs/api-reference.md` — note the Nim chrome enums (one short subsection).

**Untouched:** `native/platform/darwin/window.m`, the `wopts_*` signatures, the TS API, the JSON wire.

## Enum value lists (pinned against `runtime/window.ts`)

`Material` (member name = TS const key, value = TS const value), with a leading empty `Default` sentinel:
`Default=""`, `Sidebar="sidebar"`, `HeaderView="headerView"`, `Titlebar="titlebar"`, `Menu="menu"`, `Popover="popover"`, `HudWindow="hudWindow"`, `FullScreenUI="fullScreenUI"`, `Sheet="sheet"`, `ContentBackground="contentBackground"`, `UnderWindowBackground="underWindowBackground"`, `UnderPageBackground="underPageBackground"`, `WindowBackground="windowBackground"`.

`SidebarPresentation`: `Default=""`, `Tile="tile"`, `Overlay="overlay"`.

`ToolbarStyle`: `Unified="unified"` (default, ord 0), `UnifiedCompact="unifiedCompact"`, `Expanded="expanded"`.

---

### Task 1: Failing test — enum chrome (RED)

**Files:**
- Modify: `native/nim/tests/windowmanager_test.nim`

Edits only the test; it will FAIL TO COMPILE against the current string-typed `window.nim` (enum types don't exist; `o.vibrancy == Material.Sidebar` etc. don't compile). That is RED. Task 2 makes it GREEN.

- [ ] **Step 1: Update the existing string assertions to enum.**
  - The big apply-json block (the one parsing `"vibrancy":"sidebar"`): change `doAssert o.vibrancy == "sidebar"` → `doAssert o.vibrancy == Material.Sidebar`.
  - The "pres" block: `doAssert o.sidebar.presentation == "overlay", …` → `doAssert o.sidebar.presentation == SidebarPresentation.Overlay, "sidebar.presentation must parse to the enum"`.
  - The "pres-default" block: `doAssert o.sidebar.presentation == "", …` → `doAssert o.sidebar.presentation == SidebarPresentation.Default, "absent sidebar.presentation must default to Default"`.
  - The toolbar round-trip block: change `ToolbarOptions(style: "unified", items: …)` → `ToolbarOptions(style: ToolbarStyle.Expanded, items: …)`, and change the style assertion `doAssert "\"style\":\"unified\"" in s, …` → `doAssert "\"style\":\"expanded\"" in s, "toolbar style enum must serialize to its value"`.

- [ ] **Step 2: Add an enum-value sanity block** (proves the enum string values match the wire). Append before the final `echo`:

```nim
block:
  # enum string values must equal the native/TS wire strings.
  doAssert $Material.Default == "", "Material.Default is the empty sentinel"
  doAssert $Material.Sidebar == "sidebar"
  doAssert $Material.HeaderView == "headerView"
  doAssert $Material.UnderWindowBackground == "underWindowBackground"
  doAssert $SidebarPresentation.Overlay == "overlay"
  doAssert $SidebarPresentation.Default == ""
  doAssert $ToolbarStyle.Unified == "unified"
  doAssert $ToolbarStyle.Expanded == "expanded"
```

- [ ] **Step 3: Add a chrome-enum apply-json block** (string→enum parse, incl. unknown→Default). Append before the final `echo`:

```nim
block:
  let o = WindowOptions(title: "chrome")
  windowOptsApplyJson(o, parseJson("""{
    "vibrancy":"sidebar",
    "sidebar":{"url":"#sb","material":"headerView","presentation":"tile"},
    "inspector":{"url":"#insp","material":"popover"}
  }"""))
  doAssert o.vibrancy == Material.Sidebar
  doAssert o.sidebar.material == Material.HeaderView
  doAssert o.sidebar.presentation == SidebarPresentation.Tile
  doAssert o.inspector.material == Material.Popover

block:
  # unknown / absent enum strings fall back to the Default sentinel.
  let o = WindowOptions(title: "chrome-bad")
  windowOptsApplyJson(o, parseJson("""{"sidebar":{"material":"bogus","presentation":"nope"}}"""))
  doAssert o.sidebar.material == Material.Default, "unknown material must fall back to Default"
  doAssert o.sidebar.presentation == SidebarPresentation.Default, "unknown presentation must fall back to Default"
```

- [ ] **Step 4: Extend the "partial defaults" block** with the enum defaults. Add these asserts inside the existing `block:` that checks `o.sidebar.width == 260'i32` etc.:

```nim
  doAssert o.sidebar.material == Material.Default and o.inspector.material == Material.Default
  doAssert o.sidebar.presentation == SidebarPresentation.Default
  doAssert o.toolbar.style == ToolbarStyle.Unified, "toolbar style defaults to Unified"
  doAssert o.vibrancy == Material.Default
```

- [ ] **Step 5: Run the test to verify it FAILS (compile error).**

Run: `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --warnings:off --mm:orc --threads:on -o:/tmp/wm tests/windowmanager_test.nim 2>&1 | tail -8`
Expected: FAIL — `undeclared identifier: 'Material'` / `type mismatch` (string vs enum). RED.

- [ ] **Step 6: Commit.**

```bash
git add native/nim/tests/windowmanager_test.nim
git commit -m "$(cat <<'EOF'
test(nim): typed chrome enums — Material/SidebarPresentation/ToolbarStyle (RED)

Assert chrome fields parse to enums (apply-json), enum string values match the
wire, unknown→Default fallback, and the toolbar style enum round-trips. Fails
to compile until window.nim defines the enums.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Implement the enums + boundary in window.nim (GREEN)

**Files:**
- Modify: `native/nim/window.nim`

- [ ] **Step 1: Add the three enums** in the `type` block, immediately after `TitleBarStyle` (and before `ButtonState`/`TrafficLights`/the chrome option objects — anywhere in the leading `type` block is fine, but they MUST be declared before the `SidebarOptions`/`InspectorOptions`/`ToolbarOptions`/`WindowOptions` that use them):

```nim
  Material* {.pure.} = enum   ## NSVisualEffectMaterial name (matches TS Material const)
    Default = ""              ## "" ⇒ native default
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

  SidebarPresentation* {.pure.} = enum   ## sidebar tiling vs overlay
    Default = ""              ## "" ⇒ per-platform default (macOS tiles)
    Tile = "tile"
    Overlay = "overlay"

  ToolbarStyle* {.pure.} = enum          ## NSWindow.toolbarStyle
    Unified = "unified"       ## default
    UnifiedCompact = "unifiedCompact"
    Expanded = "expanded"
```

- [ ] **Step 2: Change the chrome field types** in the option objects. In `SidebarOptions`: `material*: Material` and `presentation*: SidebarPresentation` (remove them from the `url*, material*, backgroundColor*, presentation*: string` line — keep `url`/`backgroundColor` as `string`). In `InspectorOptions`: `material*: Material` (keep `url`/`backgroundColor` string). In `ToolbarOptions`: `style*: ToolbarStyle` (was `string`). In `WindowOptions`: `vibrancy*: Material` (was `string`).

  Concretely, `SidebarOptions` becomes:
```nim
  SidebarOptions* = object
    url*, backgroundColor*: string
    material*: Material
    presentation*: SidebarPresentation
    width*: int32 = 260
    minWidth*: int32 = 180
    maxWidth*: int32 = 400
    collapsible*: bool = true
    collapsed*: bool
    resizable*: bool = true
    numericId*: int32 = -1
```
  `InspectorOptions` becomes (same, minus presentation):
```nim
  InspectorOptions* = object
    url*, backgroundColor*: string
    material*: Material
    width*: int32 = 280
    minWidth*: int32 = 180
    maxWidth*: int32 = 400
    collapsible*: bool = true
    collapsed*: bool
    resizable*: bool = true
    numericId*: int32 = -1
```
  `ToolbarOptions` becomes:
```nim
  ToolbarOptions* = object
    style*: ToolbarStyle
    items*: seq[ToolbarItemOpt]
```
  In `WindowOptions`, change `vibrancy*: string` → `vibrancy*: Material`.

- [ ] **Step 3: Add the enum→string tables + `enumFromStr`.** Place these AFTER the `type` block and BEFORE the `wopts_*` accessors (top-level; the `let` tables are filled once at module init and never reassigned, so the borrowed cstrings are stable — BOUNDARY RULE 1):

```nim
# Enum→value lookup tables, derived once from the enum's own $ values (single
# source of truth). Module-global + never reassigned ⇒ a borrowed cstring stays
# valid for window.m's synchronous read.
let materialStr = (block:
  var a: array[Material, string]
  for m in Material: a[m] = $m
  a)
let sidebarPresStr = (block:
  var a: array[SidebarPresentation, string]
  for p in SidebarPresentation: a[p] = $p
  a)

# Generic string→enum: returns the member whose $ equals `s`, else `dflt`.
proc enumFromStr[T: enum](s: string, dflt: T): T =
  for e in T:
    if $e == s: return e
  dflt
```

- [ ] **Step 4: Update the material/presentation/vibrancy accessors** (signatures unchanged):

```nim
proc wopts_sidebar_material(p: pointer): cstring {.exportc, cdecl.} = materialStr[opt(p).sidebar.material].cstring
proc wopts_sidebar_presentation(p: pointer): cstring {.exportc, cdecl.} = sidebarPresStr[opt(p).sidebar.presentation].cstring
proc wopts_inspector_material(p: pointer): cstring {.exportc, cdecl.} = materialStr[opt(p).inspector.material].cstring
proc wopts_vibrancy(p: pointer): cstring {.exportc, cdecl.} = materialStr[opt(p).vibrancy].cstring
```

(Leave every other `wopts_*` accessor exactly as-is — `url`, `width`, `collapsible`, etc.)

- [ ] **Step 5: Update `windowOptsApplyJson`** for the four enum fields. Replace the four string assignments:
  - `if jHasStr(a, "vibrancy"): o.vibrancy = jStr(a, "vibrancy")` → `if jHasStr(a, "vibrancy"): o.vibrancy = enumFromStr[Material](jStr(a, "vibrancy"), Material.Default)`
  - in the `sidebar` block: `if jHasStr(sb, "material"): o.sidebar.material = jStr(sb, "material")` → `… = enumFromStr[Material](jStr(sb, "material"), Material.Default)`
  - in the `sidebar` block: `if jHasStr(sb, "presentation"): o.sidebar.presentation = jStr(sb, "presentation")` → `… = enumFromStr[SidebarPresentation](jStr(sb, "presentation"), SidebarPresentation.Default)`
  - in the `inspector` block: `if jHasStr(insp, "material"): o.inspector.material = jStr(insp, "material")` → `… = enumFromStr[Material](jStr(insp, "material"), Material.Default)`

- [ ] **Step 6: Update `serializeToolbar` + `parseToolbarJson` for the style enum.**
  - In `serializeToolbar`, the root build currently is `$(%*{"style": (if t.style.len > 0: t.style else: "unified"), "items": items})`. `.len` is invalid on an enum — change to `$(%*{"style": $t.style, "items": items})` (the enum's value; `ToolbarStyle.Unified` → `"unified"`).
  - In `parseToolbarJson`, change `result.style = "unified"` → `result.style = ToolbarStyle.Unified`, and `if jHasStr(root, "style"): result.style = jStr(root, "style")` → `if jHasStr(root, "style"): result.style = enumFromStr[ToolbarStyle](jStr(root, "style"), ToolbarStyle.Unified)`.

- [ ] **Step 7: Sweep for stragglers.**

Run: `cd /Users/zach/code/zapp && grep -n "\.material = jStr\|\.presentation = jStr\|vibrancy = jStr\|style\.len\|vibrancy\*: string\|material\*: string\|presentation\*: string\|style\*: string" native/nim/window.nim`
Expected: no matches (all converted). If `material*`/`presentation*` still appear on a `string` line, they weren't fully split out — fix.

- [ ] **Step 8: Run the unit test → GREEN.**

Run: `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --warnings:off --mm:orc --threads:on -o:/tmp/wm tests/windowmanager_test.nim 2>&1 | tail -5`
Expected: PASS — last line `windowmanager ok`. (If `enumFromStr` or the `let … block` initializer is rejected by the compiler, report the exact error rather than guessing.)

- [ ] **Step 9: Commit.**

```bash
git add native/nim/window.nim
git commit -m "$(cat <<'EOF'
feat(nim): typed chrome enums (Material/SidebarPresentation/ToolbarStyle)

Replace the bare-string Nim chrome fields (sidebar/inspector material, sidebar
presentation, toolbar style, window vibrancy) with string-valued enums + a
Default/Unified sentinel. Accessors emit the value via module-global lookup
tables (stable cstring, no alloc); windowOptsApplyJson parses string→enum via a
generic enumFromStr; serializeToolbar/parseToolbarJson use the style enum.
window.m + the JSON wire are untouched.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: kitchen-sink migration + docs + full build gates

**Files:**
- Modify: `kitchen-sink/zapp/app.nim`
- Modify: `docs/api-reference.md`

- [ ] **Step 1: Migrate the kitchen-sink window.** In `kitchen-sink/zapp/app.nim`, change the sidebar line `sidebar: SidebarOptions(url: "#sidebar-pane", width: 240, presentation: "overlay"),` → `sidebar: SidebarOptions(url: "#sidebar-pane", width: 240, presentation: SidebarPresentation.Overlay),`. (The inspector line sets no material/presentation, so it's unchanged.)

- [ ] **Step 2: Document the Nim chrome enums.** In `docs/api-reference.md`, find the section covering the Nim authoring `WindowOptions`/sidebar/inspector/toolbar (where `material`/`presentation`/`style` are described). Add a short note listing the enums and that they replace bare strings on the Nim side:

```markdown
> **Nim authoring:** chrome style fields are typed enums — `material: Material`
> (`Material.Sidebar`, `Material.HeaderView`, …), `presentation:
> SidebarPresentation` (`.Tile`/`.Overlay`), and toolbar `style: ToolbarStyle`
> (`.Unified`/`.UnifiedCompact`/`.Expanded`); `vibrancy: Material`. Leave a field
> at its `Default` (or `ToolbarStyle.Unified`) to get the native default. (The
> TS API uses the equivalent `Material` const + string-literal unions.)
```

(If `docs/api-reference.md` has no Nim-authoring chrome section, add this note under the existing sidebar/inspector/toolbar reference where the string values were previously listed. Keep it to the one block above.)

- [ ] **Step 3: Nim macOS build gate.**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts build 2>&1 | tail -20`
Expected: LAST line `[zapp] build complete: …` (NOT Vite's `✓ built`). Fresh binary mtime.

- [ ] **Step 4: iOS-sim build gate.**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts build --platform ios 2>&1 | tail -20`
Expected: LAST line `[zapp] build complete: …`.

- [ ] **Step 5: TS suite.**

Run: `cd /Users/zach/code/zapp && bun test cli/src 2>&1 | tail -5`
Expected: 0 failures.

- [ ] **Step 6: Commit.**

```bash
git add kitchen-sink/zapp/app.nim docs/api-reference.md
git commit -m "$(cat <<'EOF'
refactor(kitchen-sink)+docs: adopt typed Nim chrome enums

kitchen-sink uses SidebarPresentation.Overlay; api-reference notes the Nim
chrome enums (Material/SidebarPresentation/ToolbarStyle). No behavior change.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Human visual smoke (GATE — pause for the user)

**Files:** none.

- [ ] **Step 1: Run kitchen-sink in dev.** `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts dev`

- [ ] **Step 2:** Ask the user to confirm the chrome renders unchanged (sidebar overlay ~240px, inspector, toolbar) — proving the enum→string boundary emits identical native strings. **Pause for confirmation before finishing the branch.**

---

## Self-Review

**Spec coverage:** enums (T2 S1) ✓; field type changes incl. defaults (T2 S2) ✓; module-global string tables + `enumFromStr` boundary (T2 S3-S5) ✓; toolbar style enum in serialize/parse (T2 S6) ✓; accessor signatures unchanged (T2 S4) ✓; kitchen-sink migration (T3 S1) ✓; docs (T3 S2) ✓; tests — apply-json parse, unknown→Default, enum-value-match, defaults, round-trip (T1) ✓; build gates + human smoke (T3-T4) ✓; window.m/TS/wire untouched (no task touches them) ✓.

**Placeholder scan:** none — every step has exact code/commands. The docs step gives the exact block + a fallback location instruction.

**Type consistency:** enum names `Material`/`SidebarPresentation`/`ToolbarStyle` and members (`.Sidebar`/`.Overlay`/`.Unified`/`.Expanded`/`.Default`), `enumFromStr[T]`, `materialStr`/`sidebarPresStr`, and the field paths (`o.sidebar.material`/`.presentation`, `o.inspector.material`, `o.toolbar.style`, `o.vibrancy`) are used identically across Tasks 1-3 and match the spec.
