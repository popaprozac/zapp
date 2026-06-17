# Nim WindowManager Port (runtime windows) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make JS `Window.create(...)` and `Window.createPopover(...)` work on the Nim build (`ZAPP_NATIVE_LANG=nim`) by porting the runtime WindowManager (full create with sidebar/inspector slot pre-alloc + asSheetOf, slot allocator, opts-from-JSON) and wiring the router's `__window:create` + `__popover:create` t:1 routes.

**Architecture:** Idiomatic, main-thread Nim (window creation runs on the main thread via the router/boot — no gcsafe/POD constraints). The Nim WindowManager keeps **no handle map**: window lookups already go through the `.m` registry (`darwin_window_get_by_numeric_id`, used by B5b's window ops). The existing `createWindow*` in `native/nim/window.nim` is extended into the full create; a slot allocator + a JSON→opts mapper are added; the router gains the two t:1 routes.

**Tech Stack:** Nim (`std/json`), the untouched darwin `window.m`/`popover.m` (already compiled into the Nim build), `nim c -r` unit tests.

**Spec:** `docs/superpowers/specs/2026-06-16-nim-windowmanager-port-design.md`

---

## Build & Verify Reality

- A native build is successful **only** when its last line is `[zapp] build complete: <path>`. Vite's `✓ built in XXms` is NOT success.
- The Nim build is opt-in: `ZAPP_NATIVE_LANG=nim bun run build` / `... bun run dev`. The default (`bun run build`) is the zc build.
- Nim unit tests run via `nim c -r --hints:off <test>.nim` from `native/nim/tests/`.

## Standing Constraints (non-negotiable)

- **NEVER** `git add -A` / `git add .`. Stage only the explicit paths named in each commit step (here: `native/nim/window.nim`, `native/nim/router.nim`, `native/nim/zapp.nim`, `native/nim/tests/windowmanager_test.nim`).
- **Do NOT edit** anything under `native/platform/**` or `native/worker/**` (the `.m`/`.c`/`.zc` files). Read them; never modify. This is a port that consumes them by C-ABI.
- No `{.emit.}`.
- Always **Bun**, never Node.
- Commit message trailer's **last line must be EXACTLY**: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `native/nim/window.nim` | + runtime WindowOptions fields, extend `createWindow` (slot pre-alloc + asSheetOf), `allocSlot`, `windowOptsApplyJson` | 1 |
| `native/nim/tests/windowmanager_test.nim` | unit test: id/slot allocation + JSON→opts mapping | 1 |
| `native/nim/router.nim` | `__window:create` + `__popover:create` t:1 routes | 2 |
| `native/nim/zapp.nim` | (no change — boot already calls `createWindow`, which we extend in place) | — |

Source-of-truth references (read, do NOT edit): `native/window/window.zc:336-635` (`window_opts_apply_json`), `:837-898` (WindowManager `create`/`alloc_slot`); `native/app/router.zc:186-275` (`__window:create` + `__popover:create`).

---

## Task 1: window.nim — runtime fields + full create + allocSlot + windowOptsApplyJson (TDD)

**Files:**
- Modify: `native/nim/window.nim`
- Create: `native/nim/tests/windowmanager_test.nim`

- [ ] **Step 1: Add the runtime WindowOptions fields**

In `native/nim/window.nim`, in the `WindowOptions* = ref object` block, after the `toolbarJson*: string` field (currently the last field), add:
```nim
    # --- runtime Window.create extras (JS-driven; the skeleton boot never sets these) ---
    asSheetOfId*: int32          # -1 = not a sheet; else parent window numeric id
    sheetPresentation*: int32    # iOS sheet style 0=page/1=form/2=fullscreen/3=bottomSheet (macOS no-op)
    sheetDetents*: int32         # iOS bottomSheet detent bitmask (macOS no-op)
    sheetGrabber*: bool          # iOS sheet grabber (macOS no-op)
```
In `newWindowOptions`, before the closing `)` of the `WindowOptions(...)` constructor (after `toolbarJson: "",`), add:
```nim
    asSheetOfId: -1,
    sheetPresentation: 0, sheetDetents: 0, sheetGrabber: false,
```
(No `wopts_*` accessors are added: `window.m` does not read these — `asSheetOfId` is consumed by `createWindow` below, and the sheet fields are iOS-only, unused on the macOS build. They exist so `windowOptsApplyJson` can carry them without a crash.)

- [ ] **Step 2: Import std/json + the darwin lookup/attach symbols**

At the top of `native/nim/window.nim`, after the existing `import coretypes` / `export coretypes` lines, add:
```nim
import std/json
```
In the `# --- Window creation` importc block (where `darwin_window_create` + `darwin_window_register_numeric_id` are declared), add the two symbols `createWindow`'s asSheetOf attach needs (both defined in window.m, already linked):
```nim
proc darwin_window_get_by_numeric_id(numericId: int32): pointer {.importc, cdecl.}
proc darwin_window_attach_modal(parent, modal: pointer) {.importc, cdecl.}
```

- [ ] **Step 3: Extend `createWindow` into the full WindowManager create + add `allocSlot`**

Replace the existing `createWindow*` proc (the one that allocates `gNextWindowId`, sets `numericIdPrealloc`, GC-pins, `darwin_window_create`, `darwin_window_register_numeric_id`, returns `(id, h)`) with:
```nim
proc createWindow*(o: WindowOptions): tuple[id: int32, handle: pointer] =
  ## Full WindowManager.create (port of window.zc:837-889). Allocate the window's
  ## numeric id, then — only when those panes are requested — the sidebar/inspector
  ## transport slots, all from the SAME monotonic id-space (never a parallel
  ## allocator, so a slot can never collide with a future window's id). asSheetOf
  ## forces visible=false (no free-floating flash) and attaches to the parent after
  ## create. Window lookups use the .m registry (no Nim handle map).
  let id = gNextWindowId
  inc gNextWindowId
  o.numericIdPrealloc = id
  if o.sidebarUrl.len > 0:
    o.sidebarNumericId = gNextWindowId
    inc gNextWindowId
  if o.inspectorUrl.len > 0:
    o.inspectorNumericId = gNextWindowId
    inc gNextWindowId
  if o.asSheetOfId >= 0:
    o.visible = false
  # window.m reads `o` ONLY synchronously inside darwin_window_create via the
  # wopts_* accessors; pin across the call so ORC can't collect mid-read, then
  # unpin (the createWindow pin/unpin template).
  GC_ref(o)
  let h = darwin_window_create(cast[pointer](o))
  GC_unref(o)
  darwin_window_register_numeric_id(h, id)
  if o.asSheetOfId >= 0:
    let parent = darwin_window_get_by_numeric_id(o.asSheetOfId)
    if parent != nil:
      darwin_window_attach_modal(parent, h)
  (id, h)

proc allocSlot*(): int32 =
  ## Draw one dispatch slot from the same monotonic id-space windows + panes use
  ## (port of window.zc:894-898 alloc_slot). Used by the router's __popover:create.
  result = gNextWindowId
  inc gNextWindowId
```

- [ ] **Step 4: Add `windowOptsApplyJson`**

At the end of `native/nim/window.nim`, add the faithful port of `window_opts_apply_json` (window.zc:336-635) — JSON args → WindowOptions:
```nim
# --- JSON → WindowOptions (port of window.zc:window_opts_apply_json) -----------
# nil-safe readers. Numeric reads use getFloat so a fractional dim from the bridge
# (which stores all JSON numbers as doubles) isn't silently truncated to 0 by the
# std/json getInt-on-JFloat trap (the B5b lesson).
proc jStr(a: JsonNode, k: string): string =
  let v = a{k}
  if not v.isNil and v.kind == JString: v.getStr else: ""
proc jHasStr(a: JsonNode, k: string): bool =
  let v = a{k}; (not v.isNil and v.kind == JString)
proc jI32(a: JsonNode, k: string, dflt: int32): int32 =
  let v = a{k}
  if v.isNil: dflt
  elif v.kind == JInt: v.getInt.int32
  elif v.kind == JFloat: v.getFloat.int32
  else: dflt
proc jHasNum(a: JsonNode, k: string): bool =
  let v = a{k}; (not v.isNil and (v.kind == JInt or v.kind == JFloat))
proc jBool(a: JsonNode, k: string, dflt: bool): bool =
  let v = a{k}
  if not v.isNil and v.kind == JBool: v.getBool else: dflt
proc jHasBool(a: JsonNode, k: string): bool =
  let v = a{k}; (not v.isNil and v.kind == JBool)

proc buttonStateFromStr(s: string, dflt: ButtonState): ButtonState =
  case s
  of "hidden": ButtonState.Hidden
  of "disabled": ButtonState.Disabled
  of "enabled": ButtonState.Enabled
  else: dflt

proc windowOptsApplyJson*(o: WindowOptions, a: JsonNode) =
  ## Set each WindowOptions field from the JSON args when present. Missing keys
  ## leave the newWindowOptions defaults. Faithful to window_opts_apply_json
  ## (incl. closable/minimizable/maximizable=false disabling the matching
  ## traffic-light button, and asSheetOf accepting a number or a "win-<n>" string).
  if a.isNil or a.kind != JObject: return
  if jHasStr(a, "title"): o.title = jStr(a, "title")
  if jHasStr(a, "url"): o.url = jStr(a, "url")
  if jHasNum(a, "width"): o.width = jI32(a, "width", o.width)
  if jHasNum(a, "height"): o.height = jI32(a, "height", o.height)
  if jHasNum(a, "x"): o.x = jI32(a, "x", o.x)
  if jHasNum(a, "y"): o.y = jI32(a, "y", o.y)
  if jHasBool(a, "visible"): o.visible = jBool(a, "visible", o.visible)
  if jHasBool(a, "resizable"): o.resizable = jBool(a, "resizable", o.resizable)
  if jHasBool(a, "closable"):
    o.closable = jBool(a, "closable", o.closable)
    if not o.closable: o.trafficLights.close = ButtonState.Disabled
  if jHasBool(a, "minimizable"):
    o.minimizable = jBool(a, "minimizable", o.minimizable)
    if not o.minimizable: o.trafficLights.minimize = ButtonState.Disabled
  if jHasBool(a, "maximizable"):
    o.maximizable = jBool(a, "maximizable", o.maximizable)
    if not o.maximizable: o.trafficLights.zoom = ButtonState.Disabled
  if jHasBool(a, "fullscreen"): o.fullscreen = jBool(a, "fullscreen", o.fullscreen)
  if jHasBool(a, "borderless"): o.borderless = jBool(a, "borderless", o.borderless)
  if jHasBool(a, "transparent"): o.transparent = jBool(a, "transparent", o.transparent)
  if jHasBool(a, "hidden"): o.hidden = jBool(a, "hidden", o.hidden)
  if jHasBool(a, "alwaysOnTop"): o.alwaysOnTop = jBool(a, "alwaysOnTop", o.alwaysOnTop)
  if jHasBool(a, "acceptFirstMouse"): o.acceptFirstMouse = jBool(a, "acceptFirstMouse", o.acceptFirstMouse)
  if jHasBool(a, "autoCenter"): o.autoCenter = jBool(a, "autoCenter", o.autoCenter)
  if jHasStr(a, "vibrancy"): o.vibrancy = jStr(a, "vibrancy")
  if jHasStr(a, "backgroundColor"): o.backgroundColor = jStr(a, "backgroundColor")
  if jHasStr(a, "frameAutosaveName"): o.frameAutosaveName = jStr(a, "frameAutosaveName")
  if jHasStr(a, "toolbarJson"): o.toolbarJson = jStr(a, "toolbarJson")
  # sidebar object
  let sb = a{"sidebar"}
  if not sb.isNil and sb.kind == JObject:
    if jHasStr(sb, "url"): o.sidebarUrl = jStr(sb, "url")
    if jHasStr(sb, "material"): o.sidebarMaterial = jStr(sb, "material")
    if jHasNum(sb, "width"): o.sidebarWidth = jI32(sb, "width", o.sidebarWidth)
    if jHasNum(sb, "minWidth"): o.sidebarMinWidth = jI32(sb, "minWidth", o.sidebarMinWidth)
    if jHasNum(sb, "maxWidth"): o.sidebarMaxWidth = jI32(sb, "maxWidth", o.sidebarMaxWidth)
    if jHasBool(sb, "collapsible"): o.sidebarCollapsible = jBool(sb, "collapsible", o.sidebarCollapsible)
    if jHasBool(sb, "collapsed"): o.sidebarCollapsed = jBool(sb, "collapsed", o.sidebarCollapsed)
  # inspector object
  let insp = a{"inspector"}
  if not insp.isNil and insp.kind == JObject:
    if jHasStr(insp, "url"): o.inspectorUrl = jStr(insp, "url")
    if jHasStr(insp, "material"): o.inspectorMaterial = jStr(insp, "material")
    if jHasNum(insp, "width"): o.inspectorWidth = jI32(insp, "width", o.inspectorWidth)
    if jHasNum(insp, "minWidth"): o.inspectorMinWidth = jI32(insp, "minWidth", o.inspectorMinWidth)
    if jHasNum(insp, "maxWidth"): o.inspectorMaxWidth = jI32(insp, "maxWidth", o.inspectorMaxWidth)
    if jHasBool(insp, "collapsible"): o.inspectorCollapsible = jBool(insp, "collapsible", o.inspectorCollapsible)
    if jHasBool(insp, "collapsed"): o.inspectorCollapsed = jBool(insp, "collapsed", o.inspectorCollapsed)
  # asSheetOf: number (raw numeric id) or "win-<n>" string
  let aso = a{"asSheetOf"}
  if not aso.isNil:
    if aso.kind == JInt or aso.kind == JFloat:
      o.asSheetOfId = jI32(a, "asSheetOf", o.asSheetOfId)
    elif aso.kind == JString:
      let s = aso.getStr
      if s.len > 4 and s[0..3] == "win-":
        try: o.asSheetOfId = parseInt(s[4..^1]).int32 except ValueError: discard
  # sheet presentation / detents / grabber (iOS data flow; macOS no-op)
  let pres = jStr(a, "presentation")
  case pres
  of "page": o.sheetPresentation = 0
  of "form": o.sheetPresentation = 1
  of "fullscreen": o.sheetPresentation = 2
  of "bottomSheet": o.sheetPresentation = 3
  else: discard
  let detents = a{"detents"}
  if not detents.isNil and detents.kind == JArray:
    var bits: int32 = 0
    for d in detents:
      if d.kind == JString:
        case d.getStr
        of "medium": bits = bits or 1
        of "large": bits = bits or 2
        else: discard
    o.sheetDetents = bits
  if jHasBool(a, "grabber"): o.sheetGrabber = jBool(a, "grabber", o.sheetGrabber)
  # titleBarStyle string enum
  let tbs = jStr(a, "titleBarStyle")
  case tbs
  of "hidden": o.titleBarStyle = TitleBarStyle.Hidden
  of "hiddenInset": o.titleBarStyle = TitleBarStyle.HiddenInset
  of "default": o.titleBarStyle = TitleBarStyle.Default
  else: discard
  # trafficLights object {close,minimize,zoom: "enabled"|"disabled"|"hidden"}
  let tl = a{"trafficLights"}
  if not tl.isNil and tl.kind == JObject:
    o.trafficLights.close = buttonStateFromStr(jStr(tl, "close"), o.trafficLights.close)
    o.trafficLights.minimize = buttonStateFromStr(jStr(tl, "minimize"), o.trafficLights.minimize)
    o.trafficLights.zoom = buttonStateFromStr(jStr(tl, "zoom"), o.trafficLights.zoom)
```
(`parseInt` comes from `std/strutils`; add `import std/strutils` next to the `import std/json` from Step 2.)

- [ ] **Step 5: Write the unit test**

Create `native/nim/tests/windowmanager_test.nim`:
```nim
# Unit test for window.nim's WindowManager (id/slot allocation) + windowOptsApplyJson.
# Stubs the darwin window symbols window.nim importc's (no AppKit in the test).
import std/json
import ../window

# --- darwin stubs (window.nim references these by C name) --------------------
proc darwin_window_create(opts: pointer): pointer {.exportc, cdecl.} = cast[pointer](1)
proc darwin_window_register_numeric_id(handle: pointer, id: int32) {.exportc, cdecl.} = discard
proc darwin_window_get_by_numeric_id(numericId: int32): pointer {.exportc, cdecl.} = nil
proc darwin_window_attach_modal(parent, modal: pointer) {.exportc, cdecl.} = discard

# --- id + slot allocation ---------------------------------------------------
block:
  # plain window: one id consumed; the next window's id is +1.
  let a = createWindow(newWindowOptions("a"))
  let b = createWindow(newWindowOptions("b"))
  doAssert b.id == a.id + 1, "plain windows must consume exactly one id each"

block:
  # sidebar window: sidebar slot pre-allocated right after the window id; the
  # NEXT window's id is +2 (window id + sidebar slot).
  let o = newWindowOptions("sb")
  o.sidebarUrl = "#sidebar-pane"
  let w = createWindow(o)
  doAssert o.sidebarNumericId == w.id + 1, "sidebar slot must follow the window id"
  let after = createWindow(newWindowOptions("after"))
  doAssert after.id == w.id + 2, "sidebar must consume a second id from the same space"

block:
  # sidebar + inspector: both slots pre-allocated; next window id is +3.
  let o = newWindowOptions("both")
  o.sidebarUrl = "#sidebar-pane"
  o.inspectorUrl = "#inspector-pane"
  let w = createWindow(o)
  doAssert o.sidebarNumericId == w.id + 1
  doAssert o.inspectorNumericId == w.id + 2
  let after = createWindow(newWindowOptions("after2"))
  doAssert after.id == w.id + 3, "sidebar+inspector consume two extra ids"

block:
  # no chrome => slots stay at the -1 default.
  let o = newWindowOptions("plain")
  discard createWindow(o)
  doAssert o.sidebarNumericId == -1 and o.inspectorNumericId == -1

block:
  # allocSlot draws one monotonic id.
  let s1 = allocSlot()
  let s2 = allocSlot()
  doAssert s2 == s1 + 1, "allocSlot must be monotonic"

# --- windowOptsApplyJson ----------------------------------------------------
block:
  let o = newWindowOptions("base")
  o.width = 100; o.height = 100
  let a = parseJson("""{
    "title":"Hi","width":800.5,"height":600,"vibrancy":"sidebar",
    "titleBarStyle":"hiddenInset","closable":false,
    "sidebar":{"url":"#sb","width":240},
    "inspector":{"url":"#insp","collapsed":true},
    "asSheetOf":"win-7","presentation":"bottomSheet","detents":["medium","large"],
    "grabber":true
  }""")
  windowOptsApplyJson(o, a)
  doAssert o.title == "Hi"
  doAssert o.width == 800'i32, "fractional dims must use getFloat (not truncate to 0)"
  doAssert o.height == 600'i32
  doAssert o.vibrancy == "sidebar"
  doAssert o.titleBarStyle == TitleBarStyle.HiddenInset
  doAssert o.closable == false and o.trafficLights.close == ButtonState.Disabled
  doAssert o.sidebarUrl == "#sb" and o.sidebarWidth == 240'i32
  doAssert o.inspectorUrl == "#insp" and o.inspectorCollapsed == true
  doAssert o.asSheetOfId == 7'i32, "asSheetOf string win-7 must parse to 7"
  doAssert o.sheetPresentation == 3'i32
  doAssert o.sheetDetents == 3'i32, "medium|large => bits 1|2 = 3"
  doAssert o.sheetGrabber == true

block:
  # empty/missing args leave defaults intact.
  let o = newWindowOptions("def")
  windowOptsApplyJson(o, parseJson("{}"))
  doAssert o.title == "def" and o.asSheetOfId == -1'i32

echo "windowmanager ok"
```

- [ ] **Step 6: Run the unit test, verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off windowmanager_test.nim 2>&1 | tail -3`
Expected last line: `windowmanager ok`. (If a darwin symbol is undefined → a stub is missing in the test; if `parseInt`/`JString` unresolved → the `std/strutils`/`std/json` import is missing in window.nim.)

- [ ] **Step 7: Full Nim build (boot still uses createWindow — confirm the signature change didn't break it)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5`
Expected last line: `[zapp] build complete: <path>`. (`zapp.nim:243` calls `discard createWindow(opts)` — the return type is unchanged `(id, handle)`, so it still compiles.)

- [ ] **Step 8: Regression — the Nim unit suite stays green**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in registry_test worker_test permissions_test windowmanager_test; do [ -f $t.nim ] && (nim c -r --hints:off $t.nim 2>&1 | tail -1); done`
Expected: each prints its `… ok` line.

- [ ] **Step 9: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/window.nim native/nim/tests/windowmanager_test.nim
git commit -m "$(printf 'feat(nim): WindowManager core — full create (slot pre-alloc + asSheetOf) + allocSlot + windowOptsApplyJson\n\nExtend createWindow into the faithful WindowManager.create: pre-allocate the\nsidebar/inspector transport slots from the same monotonic id-space when those\nurls are set (this is what lets a JS-created window mount native chrome on Nim),\nvisible=false + attach for asSheetOf. Add allocSlot (popover dispatch slot) and\nwindowOptsApplyJson (JSON args -> WindowOptions, port of window_opts_apply_json).\nNo Nim handle map (the .m registry is the source of truth). Unit-tested.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: router — `__window:create` + `__popover:create` t:1 routes → build → GATE

**Files:**
- Modify: `native/nim/router.nim`

- [ ] **Step 1: Import window + the popover/id-resolution darwin symbols**

In `native/nim/router.nim`, ensure `window` is imported (so `createWindow`/`allocSlot`/`windowOptsApplyJson`/`newWindowOptions` resolve). At the top with the other `import` lines (e.g. `import worker, registry`), add `window` if absent:
```nim
import window
```
In the darwin importc cluster (near `darwin_window_attach_modal` at router.nim:50), add (skip any already present — `darwin_window_get_by_numeric_id` / `darwin_window_numeric_id_for_string` may already be declared from B5b/B8; do NOT double-declare):
```nim
proc darwin_window_numeric_id_for_string(wid: cstring): int32 {.importc, cdecl.}
proc darwin_popover_create(windowPtr: pointer, popoverId: cstring, url: cstring,
                           width, height: int32, behavior: cstring,
                           hostSlot, popoverSlot: int32) {.importc, cdecl.}
```
(Verify with `grep -n "darwin_window_numeric_id_for_string\|darwin_window_get_by_numeric_id" native/nim/router.nim` before adding — if a name is already importc'd, leave it. `darwin_popover_create` is defined in popover.m, compiled into the Nim build since B8a.)

- [ ] **Step 2: Add the two routes in `routeMessage`'s t:1 chain**

In `native/nim/router.nim`, in `routeMessage`, in the `__`-prefixed t:1 route chain (after the permission gate and alongside `__clipboard:`/`__zapp:`/`__app:`/`__dialog:`/`__notif:`/`__shortcuts:`/`__screen:` — i.e. before the `invokeService` fallthrough), add:
```nim
  if f.m == "__window:create":
    let o = newWindowOptions("Zapp")
    if not f.a.isNil: windowOptsApplyJson(o, f.a)
    let (newId, _) = createWindow(o)
    sendInvokeResponse(windowId, f.id, true, "{\"windowId\":\"win-" & $newId & "\"}")
    return

  if f.m == "__popover:create":
    var target = windowId.int32
    var url = ""
    var behavior = "transient"
    var pw: int32 = 320
    var ph: int32 = 400
    if not f.a.isNil and f.a.kind == JObject:
      let widv = f.a{"windowId"}
      if not widv.isNil and widv.kind == JString:
        let resolved = darwin_window_numeric_id_for_string(widv.getStr.cstring)
        if resolved >= 0: target = resolved
      let urlv = f.a{"url"}
      if not urlv.isNil and urlv.kind == JString: url = urlv.getStr
      let bv = f.a{"behavior"}
      if not bv.isNil and bv.kind == JString: behavior = bv.getStr
      let wv = f.a{"width"}
      if not wv.isNil and (wv.kind == JInt or wv.kind == JFloat): pw = wv.getFloat.int32
      let hv = f.a{"height"}
      if not hv.isNil and (hv.kind == JInt or hv.kind == JFloat): ph = hv.getFloat.int32
    if url.len > 0:
      let slot = allocSlot()
      let host = darwin_window_get_by_numeric_id(target)
      if host != nil:
        let pid = "pop-" & $slot
        darwin_popover_create(host, pid.cstring, url.cstring, pw, ph,
                              behavior.cstring, target, slot)
        sendInvokeResponse(windowId, f.id, true, "{\"popoverId\":\"" & pid & "\"}")
        return
    sendInvokeResponse(windowId, f.id, true, "{}")
    return
```
(`JObject`/`JInt`/`JFloat`/`JString` come from `std/json`, already imported in router.nim. `f.a` is the parsed args `JsonNode`. `sendInvokeResponse(windowId, id, ok, jsonStr)` is router.nim's existing responder. The empty-`{}` tail mirrors the zc's no-op branch when url is empty or the host can't be resolved.)

- [ ] **Step 3: Full Nim build**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5`
Expected last line: `[zapp] build complete: <path>`. (Undefined `createWindow`/`allocSlot`/`windowOptsApplyJson` → the `import window` is missing; undefined `darwin_popover_create` → the importc is missing or popover.m isn't compiled — it should be, from B8a; undefined `darwin_window_numeric_id_for_string` → importc missing.)

- [ ] **Step 4: Regression — Nim unit suite + zc build sanity**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in registry_test worker_test windowmanager_test router_subscribe_test; do [ -f $t.nim ] && (nim c -r --hints:off $t.nim 2>&1 | tail -1); done`
Expected: each prints its `… ok` line.
Then confirm the **zc build still builds** (the changes are Nim-only, but sanity-check the default path): `cd /Users/zach/code/zapp/kitchen-sink && bun run build 2>&1 | tail -3` → `[zapp] build complete:`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): route __window:create + __popover:create (t:1) to the WindowManager\n\nrouteMessage now handles JS Window.create (windowOptsApplyJson -> createWindow ->\n{windowId:win-N}) and Window.createPopover (allocSlot -> darwin_popover_create ->\n{popoverId:pop-N}). New windows/sheets/popovers now work on the Nim build; a\nJS-created window with sidebar/inspector opts mounts native chrome. Closes the\nB8 popover:create deferral.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 6: GATE — human smoke (Nim build)**

`cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run dev`, then in the kitchen-sink **Multi-window** section:
- **New window** → a new plain window opens (result logs `window → win-<n>`), no longer the "needs WindowManager" message.
- **Vibrancy / sheet variants** → open (sheets attach to the shell window).
- A window created with `sidebar`/`inspector` opts → opens **with native chrome** (this is the chrome-on-Nim payoff). If the kitchen-sink Multi-window section lacks a sidebar-window variant, add one ad-hoc in the dev session or note it for a kitchen-sink follow-up.
- The **Popover** section → `createPopover().show()` shows a native popover.
Also confirm the default **zc build** still opens windows/popovers (`bun run dev`) — sanity, no regression.

---

## Self-Review

**1. Spec coverage:**
- WindowOptions runtime fields (asSheetOfId + sheet*) → Task 1 Step 1. ✓
- `createWindow` full (numericId + sidebar/inspector slot pre-alloc + asSheetOf attach) → Task 1 Step 3. ✓
- `allocSlot` → Task 1 Step 3. ✓
- `windowOptsApplyJson` (faithful field set, getFloat dims, asSheetOf int/string, presentation/detents/grabber, titleBarStyle/trafficLights) → Task 1 Step 4. ✓
- Switch the boot → not needed: boot already calls `createWindow`, extended in place (Task 1 Step 7 confirms it still builds). ✓ (spec's "switch the boot to wmCreate" is satisfied by keeping the name `createWindow` and extending it — no zapp.nim edit; noted in File Structure.)
- router `__window:create` (response `{"windowId":"win-N"}`) → Task 2 Step 2. ✓ (matches router.zc:208)
- router `__popover:create` (allocSlot + darwin_popover_create + `{"popoverId":"pop-N"}`, empty-`{}` fallback) → Task 2 Step 2. ✓ (matches router.zc:215-275)
- No Nim handle map (uses `.m` registry) → createWindow + popover both use `darwin_window_get_by_numeric_id`. ✓
- Unit tests for allocation + JSON mapping → Task 1 Step 5. ✓
- Human GATE on Nim → Task 2 Step 6. ✓
- Risks resolved: response shape (`{"windowId":"win-%d"}` confirmed router.zc:208); opts field set (enumerated from window.zc:336-635); attach symbol (`darwin_window_attach_modal`, already in router.nim:50 + window.m:1186). ✓

**2. Placeholder scan:** No TBD/TODO. Every code step is complete. The "verify before adding" notes for the importc decls (Task 2 Step 1) are dedup guards (don't double-declare a symbol B5b/B8 already imported), with the exact grep — not hand-waves.

**3. Type consistency:** `createWindow(o: WindowOptions): tuple[id: int32, handle: pointer]` (unchanged signature, extended body) — boot call `discard createWindow(opts)` still valid; router uses `let (newId, _) = createWindow(o)`. `allocSlot(): int32`. `windowOptsApplyJson(o: WindowOptions, a: JsonNode)`. `WindowOptions` fields (`asSheetOfId`/`sheetPresentation`/`sheetDetents`/`sheetGrabber`, plus existing `sidebarUrl`/`sidebarNumericId`/`inspectorUrl`/`inspectorNumericId`/`trafficLights`/`titleBarStyle`) all consistent between window.nim + the test + router. `ButtonState.Disabled`/`.Hidden`/`.Enabled` and `TitleBarStyle.Hidden`/`.HiddenInset`/`.Default` match window.nim's enums. `darwin_popover_create` signature matches router.zc's extern (window_ptr, popover_id, url, width, height, behavior, host_slot, popover_slot). ✓
