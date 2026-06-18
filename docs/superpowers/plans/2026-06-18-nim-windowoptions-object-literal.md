# Nim WindowOptions Object-Literal Construction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `WindowOptions` construct via object literal (Nim field defaults) passed directly to `app.window.create(...)`, and remove `newWindowOptions`.

**Architecture:** Move every default from `newWindowOptions`'s body onto the `WindowOptions` type as Nim 2.0 field defaults (verified to apply to `ref object` partial construction in Nim 2.2.10), delete the constructor proc, and convert all live call sites to object literals. `create`'s signature is unchanged. Deliberate Nim-only divergence from zc's `WindowOptions::create` (logged in the spec).

**Tech Stack:** Nim 2.2 (object field defaults, UFCS), the existing C-ABI, `cli/src` (scaffold), bun:test for the CLI.

**Spec:** `docs/superpowers/specs/2026-06-18-nim-windowoptions-object-literal-design.md`

**Coupling note:** removing `newWindowOptions` breaks every caller at once, so the native-library change, its internal callers, the test, and the app-facing surfaces must land **together** to compile. Task 1 is therefore one atomic commit; Task 2 is docs + the full cross-gate + manual smoke.

---

### Task 1: Object-literal WindowOptions (native + app + test) — atomic

**Files:**
- Modify: `native/nim/window.nim` (type defaults + delete `newWindowOptions` + one doc-comment)
- Modify: `native/nim/router.nim:751`
- Modify: `native/nim/zapp.nim` (export comments)
- Modify: `native/nim/tests/windowmanager_test.nim`
- Modify: `kitchen-sink/zapp/app.nim`
- Modify: `cli/src/init.ts` (the `zapp init` Nim scaffold template)

- [ ] **Step 1: Rewrite the `WindowOptions` type with field defaults.** In `native/nim/window.nim`, replace the current `WindowOptions* = ref object` block (the field list, currently with no defaults) with this exact definition — field ORDER unchanged, defaults added only where the value is non-zero/non-empty:

```nim
  WindowOptions* = ref object
    # --- set by the skeleton ---
    title*: string
    url*: string
    width*: int32 = 1200
    height*: int32 = 800
    x*, y*: int32
    autoCenter*: bool
    visible*: bool = true
    resizable*: bool = true
    closable*: bool = true
    minimizable*: bool = true
    maximizable*: bool = true
    borderless*: bool
    transparent*: bool
    alwaysOnTop*: bool
    hidden*: bool
    fullscreen*: bool
    acceptFirstMouse*: bool = true
    backgroundColor*: string
    numericIdPrealloc*: int32 = -1
    inspectable*: TriState = TriState.Unset  # unset/off/on; window.m treats `> 0` as on
    frameAutosaveName*: string
    vibrancy*: string
    # --- title-bar style + traffic-light buttons ---
    # titleBarStyle MUST be explicit: Unset is ord 3 (appended last), NOT the
    # enum's zero value (Default=0). Without `= TitleBarStyle.Unset` an
    # unspecified titleBarStyle would default to Default and re-break the
    # split-window title-bar logic (window.m only applies the sidebar chrome
    # default for tbs==3/Unset).
    titleBarStyle*: TitleBarStyle = TitleBarStyle.Unset
    trafficLights*: TrafficLights = TrafficLights(
      close: ButtonState.Enabled, minimize: ButtonState.Enabled, zoom: ButtonState.Enabled)
    # --- sidebar (feature unused by the skeleton; "" url => never built) ---
    # Sidebar/inspector geometry defaults MUST stay non-zero: window.m sets
    # NSSplitViewItem.maximumThickness = wopts_sidebar_max_width(opts) literally,
    # so a 0 default clamps the pane to ZERO width (invisible sidebar — #460).
    sidebarUrl*: string
    sidebarMaterial*: string
    sidebarBackgroundColor*: string
    sidebarWidth*: int32 = 260
    sidebarMinWidth*: int32 = 180
    sidebarMaxWidth*: int32 = 400
    sidebarCollapsible*: bool = true
    sidebarCollapsed*: bool
    sidebarCanResize*: bool = true
    sidebarNumericId*: int32 = -1
    # --- inspector pane (feature unused; "" url => never built) ---
    inspectorUrl*: string
    inspectorMaterial*: string
    inspectorBackgroundColor*: string
    inspectorWidth*: int32 = 280
    inspectorMinWidth*: int32 = 180
    inspectorMaxWidth*: int32 = 400
    inspectorCollapsible*: bool = true
    inspectorCollapsed*: bool
    inspectorCanResize*: bool = true
    inspectorNumericId*: int32 = -1
    # --- toolbar (feature unused; "" json => never attached) ---
    toolbarJson*: string
    # --- runtime Window.create extras (JS-driven) ---
    asSheetOfId*: int32 = -1
    sheetPresentation*: int32
    sheetDetents*: int32
    sheetGrabber*: bool
```

(These defaults are exactly what today's `newWindowOptions` assigns. Fields with no `=` default to Nim's zero — empty string / 0 / false — which matches the old body. The grouped lines `width*, height*` / `sidebarWidth*, sidebarMinWidth*, sidebarMaxWidth*` / `sidebarCollapsible*, sidebarCollapsed*` / the inspector equivalents were SPLIT because their defaults differ.)

- [ ] **Step 2: Delete the `newWindowOptions` proc.** Remove the entire `proc newWindowOptions*(title: string): WindowOptions = WindowOptions(...)` definition (and its doc comment) from `native/nim/window.nim` — the type now carries the defaults.

- [ ] **Step 3: Fix the `windowOptsApplyJson` doc-comment.** In `native/nim/window.nim`, the `windowOptsApplyJson` doc comment says "leave the newWindowOptions defaults" — change that phrase to "leave the type's field defaults".

- [ ] **Step 4: Fix the internal router caller.** In `native/nim/router.nim` (~line 751), change `let o = newWindowOptions("Zapp")` to `let o = WindowOptions(title: "Zapp")`.

- [ ] **Step 5: Update the `zapp.nim` export comments.** In `native/nim/zapp.nim`, the two comments listing the exported surface mention `newWindowOptions` (e.g. `WindowOptions/newWindowOptions/createWindow`). Drop `newWindowOptions` from those comments (it no longer exists). Comment-only edit.

- [ ] **Step 6: Convert the unit test to literals + add the defaults-survive assertion.** In `native/nim/tests/windowmanager_test.nim`:
  - Replace every `newWindowOptions("X")` with `WindowOptions(title: "X")` (occurrences around lines 19, 20, 24, 28, 32, 38, 42, 52, 77).
  - Add a new assertion block (after the existing blocks) locking the load-bearing guarantee that partial object-literal construction fills the defaults:

```nim
block:
  # Partial object-literal construction must fill the field defaults — the
  # load-bearing guarantee (window.m clamps panes to wopts_sidebar_max_width
  # literally, so a 0 default = invisible sidebar, #460). Replaces the old
  # newWindowOptions defaults.
  let o = WindowOptions(title: "x")
  doAssert o.width == 1200'i32 and o.height == 800'i32
  doAssert o.visible == true and o.acceptFirstMouse == true and o.autoCenter == false
  doAssert o.sidebarWidth == 260'i32 and o.sidebarMaxWidth == 400'i32
  doAssert o.inspectorWidth == 280'i32 and o.inspectorMaxWidth == 400'i32
  doAssert o.sidebarCollapsible == true and o.inspectorCollapsible == true
  doAssert o.numericIdPrealloc == -1'i32 and o.asSheetOfId == -1'i32
  doAssert o.inspectable == TriState.Unset
  doAssert o.titleBarStyle == TitleBarStyle.Unset, "Unset (ord 3) must be the default, not Default"
  doAssert o.trafficLights.close == ButtonState.Enabled
```

- [ ] **Step 7: Run the unit test (verify the library compiles + defaults hold).**

Run: `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --warnings:off --mm:orc --threads:on -o:/tmp/wmtest tests/windowmanager_test.nim`
Expected: prints `windowmanager ok` (the file's final echo). A failure here means a default is wrong or a literal conversion broke.

- [ ] **Step 8: Convert kitchen-sink app.nim to the inline literal.** In `kitchen-sink/zapp/app.nim`, replace the `var opts = newWindowOptions("Kitchen Sink")` + field-assignment block + `let win = app.window.create(opts)` with:

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

(Keep the surrounding `runApp` body otherwise unchanged — `newApp`, `app.service.add`, `app.run()` stay.)

- [ ] **Step 9: Convert the `zapp init` scaffold.** Read `cli/src/init.ts` and find the Nim scaffold app.nim template (around line 238, `var opts = newWindowOptions("${name}")`). Convert its window construction to an inline object literal passed to `app.window.create(...)` exactly as in Step 8, preserving whatever fields the scaffold currently sets (read them; don't invent). Also update the surface comment near line 222 that lists `newWindowOptions` → `WindowOptions`. Match the template's existing escaping (it's a JS template literal — `${name}` etc.).

- [ ] **Step 10: Build the nim kitchen-sink (full compile of window + router + zapp + app.nim).**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build`
Expected: LAST line `[zapp] build complete: ...`. (Vite's "✓ built" is NOT success.) A failure here surfaces any missed `newWindowOptions` caller.

- [ ] **Step 11: Commit (all Task-1 files together — atomic).**

```bash
cd /Users/zach/code/zapp
git add native/nim/window.nim native/nim/router.nim native/nim/zapp.nim \
        native/nim/tests/windowmanager_test.nim kitchen-sink/zapp/app.nim cli/src/init.ts
git commit -m "feat(nim): WindowOptions object-literal construction; remove newWindowOptions"
```
(Commit-message trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

---

### Task 2: Docs + full gate + manual smoke

**Files:**
- Modify: `docs/api-reference.md` (the "Authoring an app in Nim" Nim example, ~line 1549)

- [ ] **Step 1: Update the api-reference Nim example.** In `docs/api-reference.md`, find the "Authoring an app in Nim" code example that uses `var opts = newWindowOptions("My App")` + field sets. Replace it with the inline object-literal form passed to `app.window.create(...)`, e.g.:

```nim
let win = app.window.create(WindowOptions(
  title: "My App",
  width: 1100, height: 700,
  # sidebarUrl: "#sidebar", inspectorUrl: "#inspector", ...
))
win.onReady(onReady)
```

Also adjust any surrounding prose that names `newWindowOptions` (it no longer exists — construction is the `WindowOptions(...)` literal). If a nearby line mentions WindowOptions defaults, note they live on the type.

- [ ] **Step 2: Full cross-gate.** Run each (from the indicated dir); report the relevant line of each:

```bash
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build   # expect: [zapp] build complete:
cd /Users/zach/code/zapp/kitchen-sink && bun run build                         # expect: [zapp] build complete:  (zc path — unaffected)
cd /Users/zach/code/zapp && bun run check                                      # expect: tsc clean
cd /Users/zach/code/zapp/cli && bun test src                                   # expect: all pass
```

- [ ] **Step 3: Commit docs.**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "docs: Nim WindowOptions object-literal construction"
```
(Trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

- [ ] **Step 4: GATE — manual smoke.** `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run dev`. Confirm the window opens with the sidebar **visible** and the inspector still reveals — this proves the geometry defaults survived the move onto the type (the real risk in this change). PAUSE for human confirmation.

---

## Self-review notes

- **Spec coverage:** field defaults on the type (T1.1) ✓; remove `newWindowOptions` (T1.2) ✓; doc-comment fix (T1.3) ✓; internal caller router (T1.4) ✓; export comments (T1.5) ✓; test conversion + defaults-survive assertion (T1.6) ✓; app surfaces kitchen-sink + scaffold (T1.8–9) ✓; docs (T2.1) ✓; parity divergence is spec-only (no task) ✓; manual sidebar smoke (T2.4) ✓. The spec's "no `create` signature change / no zc change / no JS-path change" are honored by omission (no task touches them).
- **The titleBarStyle trap:** explicitly defaulting `titleBarStyle` to `TitleBarStyle.Unset` (ord 3) is called out in Step 1 because the enum's zero value is `Default`, not `Unset` — getting this wrong silently re-breaks the #478 fix. The test (Step 6) asserts it.
- **Type consistency:** every converted call site uses `WindowOptions(title: ...)` / the inline literal; `create(o: WindowOptions)`, `windowOptsApplyJson(o: WindowOptions, ...)`, and the `wopts_*` accessors are unchanged (they read field values; field defaults don't change the ABI or signatures).
- **Atomicity:** Task 1 commits all callers together because removing `newWindowOptions` breaks them simultaneously; its Step 10 full build is the real cross-file gate, Step 7's unit test is the fast inner check.
