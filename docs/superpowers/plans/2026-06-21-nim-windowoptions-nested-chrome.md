# Nim `WindowOptions` Nested Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nest the Nim `WindowOptions` chrome fields (`sidebar`/`inspector`/`toolbar`) into sub-objects so the Nim authoring struct matches the already-nested TS `WindowOptions` and JSON wire.

**Architecture:** Pure Nim-side refactor. New `SidebarOptions`/`InspectorOptions`/`ToolbarOptions` (+ `ToolbarItemOpt`/`MenuItemOpt`) types replace the flat `sidebar*`/`inspector*`/`toolbarJson` fields on `WindowOptions`. The `wopts_*` C-ABI accessor **signatures are unchanged** (so `window.m` is untouched); only their bodies change their field path. The toolbar is authored as a `ToolbarOptions` object and serialized to the existing `{style,items:[…]}` wire JSON on demand via `wopts_toolbar_json` (into a derived `toolbarJsonCache` buffer so the returned `cstring` doesn't dangle). `windowOptsApplyJson` reads nested `sidebar`/`inspector` directly and parses an incoming `toolbarJson` string into `toolbar` via a new `parseToolbarJson`.

**Tech Stack:** Nim (`std/json`), the `wopts_*` C-ABI bridge to `native/platform/darwin/window.m`, the Nim unit-test convention (`nim c -r`).

**Branch:** `feat/nim-native` (unmerged). **Commit trailer:** `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Spec:** `docs/superpowers/specs/2026-06-21-nim-windowoptions-nested-chrome-design.md`.

---

## File Structure

- `native/nim/window.nim` — the refactor: new nested types (before `WindowOptions`), `WindowOptions` fields (flat → nested + `toolbarJsonCache`), `createWindow` numericId/url reads, all `wopts_*` accessor bodies, `windowOptsApplyJson`, and two new helpers `serializeToolbar`/`parseToolbarJson`.
- `native/nim/tests/windowmanager_test.nim` — add the two missing link stubs (`darwin_webview_eval_all`, `zjs_broadcast_eval_js`), convert flat-field assertions to nested, add toolbar serialize/parse round-trip + apply-json toolbar tests.
- `kitchen-sink/zapp/app.nim` — migrate the window construction to the nested shape (the Nim build root).

**Untouched:** `native/platform/darwin/window.m`, the `wopts_*` signatures, the TS `WindowOptions` API, and the JSON wire (`sidebar`/`inspector` stay nested objects; the toolbar stays a `toolbarJson` string).

## The toolbar wire schema (authoritative — match exactly)

`serializeToolbar` must emit, and `parseToolbarJson` must read, the schema that `native/platform/darwin/toolbar.m`'s `zapp_toolbar_parse_items` consumes and that TS `runtime/window.ts` `normalizeToolbar` produces:

```jsonc
{ "style": "unified",            // "unified" | "unifiedCompact" | "expanded"
  "items": [
    { "type": "toggleSidebar" },
    { "type": "toggleInspector" },
    { "type": "trackingSeparator", "pane": "sidebar" },   // pane: "sidebar" | "inspector"
    { "type": "space" },
    { "type": "flexibleSpace" },
    { "type": "button", "id": "compose", "label": "Compose", "icon": "sf:square.and.pencil",
      "enabled": true,
      "menu": [ { "id": "all", "label": "All", "icon": "", "checked": false } ],
      "indicator": true }   // chevron — ONLY emitted on menu items; native default YES
  ] }
```

Key facts pinned from the source:
- `toolbar.m:269` reads `def["type"]` (default `"button"`); `:284`/`:169` read `def["pane"]` (default `"sidebar"`); `:299` reads `def["id"]`; `:222`/`:197` read `def["label"]`; `:226`/`:201` read `def["icon"]`; `:246`/`:214` read `def["enabled"]`; `:193` reads `def["menu"]` (array); `:209` reads `def["indicator"]` (menu chevron, default YES when absent); `:339`/`:322` read root `def["style"]`/`def["items"]`.
- TS `normalizeToolbar` (`window.ts:628-639`) emits buttons as `{type:"button", id, label, icon}` plus `enabled`/`indicator` only when defined, plus `menu` when present; spacers/toggles as `{type}`; trackingSeparator as `{type, pane}`; root `{style, items}`.

**`indicator` default note (refines the spec):** the native menu-chevron default is YES, so `ToolbarItemOpt.indicator` defaults to `true` and is serialized **only on items that carry a menu**. Plain buttons never emit `indicator` (native ignores it for them). The spec's type block listed `indicator*: bool`; this plan pins it to `indicator*: bool = true`.

---

### Task 1: Failing test — nested fields + toolbar round-trip (RED)

**Files:**
- Modify: `native/nim/tests/windowmanager_test.nim`

This task only edits the test. It will FAIL TO COMPILE against the current flat `window.nim` (undefined `o.sidebar`, `serializeToolbar`, `parseToolbarJson`) — that is the RED state. Task 2 makes it GREEN.

- [ ] **Step 1: Add the two missing link stubs.** `window.nim` imports `dispatch`, which references `darwin_webview_eval_all` and `zjs_broadcast_eval_js`; the test currently omits them (pre-existing link gap — the test does not link standalone today). Add them next to the existing `darwin_window_*` stubs (after line 17, the `darwin_window_numeric_id_for_string` stub), mirroring `dispatch_test.nim:7,9`:

```nim
proc darwin_webview_eval_all(js: cstring) {.exportc, cdecl.} = discard
proc zjs_broadcast_eval_js(js: cstring) {.exportc, cdecl.} = discard
```

- [ ] **Step 2: Convert the existing flat-field assertions to nested.** Replace every flat chrome field reference in the existing blocks with its nested equivalent. The exact replacements (whole-file):

  - In the "sidebar slot" block (currently lines 27-33): `o.sidebarUrl = "#sidebar-pane"` → `o.sidebar.url = "#sidebar-pane"`; `o.sidebarNumericId` → `o.sidebar.numericId`.
  - In the "both" block (35-43): `o.sidebarUrl = "#sidebar-pane"` → `o.sidebar.url = "#sidebar-pane"`; `o.inspectorUrl = "#inspector-pane"` → `o.inspector.url = "#inspector-pane"`; `o.sidebarNumericId` → `o.sidebar.numericId`; `o.inspectorNumericId` → `o.inspector.numericId`.
  - In the "plain" block (45-48): `o.sidebarNumericId == -1 and o.inspectorNumericId == -1` → `o.sidebar.numericId == -1 and o.inspector.numericId == -1`.
  - In the big apply-json block (55-78): `o.sidebarUrl == "#sb" and o.sidebarWidth == 240'i32` → `o.sidebar.url == "#sb" and o.sidebar.width == 240'i32`; `o.inspectorUrl == "#insp" and o.inspectorCollapsed == true` → `o.inspector.url == "#insp" and o.inspector.collapsed == true`.
  - In the "pres" block (90-94): `o.sidebarPresentation == "overlay"` → `o.sidebar.presentation == "overlay"`.
  - In the "pres-default" block (96-100): `o.sidebarPresentation == ""` → `o.sidebar.presentation == ""`.
  - In the "partial defaults" block (102-116): `o.sidebarWidth == 260'i32 and o.sidebarMaxWidth == 400'i32` → `o.sidebar.width == 260'i32 and o.sidebar.maxWidth == 400'i32`; `o.inspectorWidth == 280'i32 and o.inspectorMaxWidth == 400'i32` → `o.inspector.width == 280'i32 and o.inspector.maxWidth == 400'i32`; `o.sidebarCollapsible == true and o.inspectorCollapsible == true` → `o.sidebar.collapsible == true and o.inspector.collapsible == true`.

- [ ] **Step 3: Add a toolbar serialize/parse round-trip block.** Append before the final `echo "windowmanager ok"`:

```nim
block:
  # serializeToolbar emits the native wire schema; parseToolbarJson is its inverse.
  let t = ToolbarOptions(style: "unified", items: @[
    ToolbarItemOpt(`type`: "toggleSidebar"),
    ToolbarItemOpt(`type`: "trackingSeparator", pane: "sidebar"),
    ToolbarItemOpt(`type`: "button", id: "compose", label: "Compose", icon: "sf:square.and.pencil"),
    ToolbarItemOpt(`type`: "flexibleSpace"),
    ToolbarItemOpt(`type`: "button", id: "filter", icon: "sf:line.3.horizontal.decrease",
                   menu: @[
                     MenuItemOpt(id: "all", label: "All", checked: true),
                     MenuItemOpt(id: "unread", label: "Unread")]),
  ])
  let s = serializeToolbar(t)
  doAssert "\"style\":\"unified\"" in s, "style must serialize"
  doAssert "\"type\":\"toggleSidebar\"" in s
  doAssert "\"pane\":\"sidebar\"" in s, "trackingSeparator must carry pane"
  doAssert "\"id\":\"compose\"" in s
  doAssert "\"checked\":true" in s, "menu checked must serialize"
  doAssert "\"indicator\":true" in s, "menu items emit the chevron indicator"
  doAssert parseToolbarJson(s) == t, "parse(serialize(t)) must round-trip"
```

- [ ] **Step 4: Add an apply-json toolbar block.** Append before the final `echo`:

```nim
block:
  # windowOptsApplyJson parses an incoming toolbarJson STRING into o.toolbar.
  let o = WindowOptions(title: "tb")
  windowOptsApplyJson(o, parseJson(
    """{"toolbarJson":"{\"style\":\"unified\",\"items\":[{\"type\":\"button\",\"id\":\"go\",\"label\":\"Go\",\"icon\":\"\"}]}"}"""))
  doAssert o.toolbar.items.len == 1, "toolbarJson string must parse into o.toolbar"
  doAssert o.toolbar.items[0].id == "go" and o.toolbar.items[0].label == "Go"
```

- [ ] **Step 5: Run the test to verify it FAILS (compile error).**

Run: `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --warnings:off --mm:orc --threads:on -o:/tmp/wm tests/windowmanager_test.nim 2>&1 | tail -8`
Expected: FAIL — Nim errors like `undeclared field: 'sidebar'`, `undeclared identifier: 'serializeToolbar'` / `'parseToolbarJson'` / `'ToolbarOptions'`. (Compile failure is the RED state.)

- [ ] **Step 6: Commit.**

```bash
git add native/nim/tests/windowmanager_test.nim
git commit -m "$(cat <<'EOF'
test(nim): nested WindowOptions chrome + toolbar round-trip (RED)

Convert windowmanager_test to the nested sidebar/inspector shape, add
serializeToolbar/parseToolbarJson round-trip + apply-json toolbar coverage,
and add the missing darwin_webview_eval_all/zjs_broadcast_eval_js link stubs
(window.nim imports dispatch). Fails to compile until window.nim is nested.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Implement the nested types + accessors + serialize/parse in window.nim (GREEN)

**Files:**
- Modify: `native/nim/window.nim`

- [ ] **Step 1: Add `std/options`? No — confirm imports.** No new imports are needed (`std/json` is already imported at `window.nim:16`; `std/strutils` is NOT required). Do not add imports.

- [ ] **Step 2: Add the nested types BEFORE `WindowOptions`.** Insert immediately before `WindowOptions* = ref object` (currently `window.nim:42`), inside the same `type` block:

```nim
  MenuItemOpt* = object              ## mirrors TS ZappMenuItem (toolbar pull-down item)
    id*, label*, icon*: string
    checked*: bool

  ToolbarItemOpt* = object           ## mirrors TS ToolbarItemDef — DATA fields only (no action closure)
    id*: string
    `type`*: string                  ## "" ⇒ native treats as "button"
    pane*: string                    ## trackingSeparator: "sidebar" | "inspector"
    label*, icon*: string
    enabled*: bool = true
    indicator*: bool = true          ## menu chevron; native default YES; emitted only on menu items
    menu*: seq[MenuItemOpt]

  ToolbarOptions* = object
    style*: string                   ## "" ⇒ "unified"
    items*: seq[ToolbarItemOpt]

  SidebarOptions* = object
    url*, material*, backgroundColor*, presentation*: string
    width*: int32 = 260
    minWidth*: int32 = 180
    maxWidth*: int32 = 400
    collapsible*: bool = true
    collapsed*: bool
    resizable*: bool = true
    numericId*: int32 = -1

  InspectorOptions* = object
    url*, material*, backgroundColor*: string
    width*: int32 = 280
    minWidth*: int32 = 180
    maxWidth*: int32 = 400
    collapsible*: bool = true
    collapsed*: bool
    resizable*: bool = true
    numericId*: int32 = -1
```

- [ ] **Step 3: Replace the flat chrome fields on `WindowOptions` with nested ones.** In `WindowOptions* = ref object`, delete the flat sidebar block (`window.nim:79-89`: `sidebarUrl` … `sidebarNumericId`), the flat inspector block (`91-100`: `inspectorUrl` … `inspectorNumericId`), and the `toolbarJson*: string` field (`105`). Replace with:

```nim
    # --- accessory chrome (nested; "" url / empty items ⇒ never built) -------
    sidebar*: SidebarOptions
    inspector*: InspectorOptions
    toolbar*: ToolbarOptions
    toolbarJsonCache*: string   ## derived: wopts_toolbar_json serializes `toolbar` here
                                ## so the returned cstring borrows a GC-pinned buffer (BOUNDARY RULE 1)
```

Keep the surrounding comments about the load-bearing non-zero geometry defaults (now satisfied by the `SidebarOptions`/`InspectorOptions` field defaults). Leave `nativeSurface*` and the sheet fields unchanged.

- [ ] **Step 4: Update `createWindow`'s sidebar/inspector reads.** In `createWindow*` (`window.nim:230-234`), change:

```nim
  if o.sidebar.url.len > 0:
    o.sidebar.numericId = gNextWindowId
    inc gNextWindowId
  if o.inspector.url.len > 0:
    o.inspector.numericId = gNextWindowId
    inc gNextWindowId
```

(Match the existing increment structure exactly — only the field paths change from `o.sidebarUrl`/`o.sidebarNumericId`/`o.inspectorUrl`/`o.inspectorNumericId`.)

- [ ] **Step 5: Update the sidebar accessor bodies** (`window.nim:162-172`) — signatures unchanged, only the field path:

```nim
proc wopts_sidebar_url(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebar.url.cstring
proc wopts_sidebar_material(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebar.material.cstring
proc wopts_sidebar_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebar.width
proc wopts_sidebar_min_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebar.minWidth
proc wopts_sidebar_max_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebar.maxWidth
proc wopts_sidebar_collapsible(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebar.collapsible
proc wopts_sidebar_collapsed(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebar.collapsed
proc wopts_sidebar_can_resize(p: pointer): bool {.exportc, cdecl.} = opt(p).sidebar.resizable
proc wopts_sidebar_background_color(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebar.backgroundColor.cstring
proc wopts_sidebar_presentation(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebar.presentation.cstring
proc wopts_sidebar_numeric_id(p: pointer): int32 {.exportc, cdecl.} = opt(p).sidebar.numericId
```

(Note the accessor name stays `wopts_sidebar_can_resize` though the field is now `resizable` — `window.m` calls that name.)

- [ ] **Step 6: Update the inspector accessor bodies** (`window.nim:175-184`):

```nim
proc wopts_inspector_url(p: pointer): cstring {.exportc, cdecl.} = opt(p).inspector.url.cstring
proc wopts_inspector_material(p: pointer): cstring {.exportc, cdecl.} = opt(p).inspector.material.cstring
proc wopts_inspector_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspector.width
proc wopts_inspector_min_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspector.minWidth
proc wopts_inspector_max_width(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspector.maxWidth
proc wopts_inspector_collapsible(p: pointer): bool {.exportc, cdecl.} = opt(p).inspector.collapsible
proc wopts_inspector_collapsed(p: pointer): bool {.exportc, cdecl.} = opt(p).inspector.collapsed
proc wopts_inspector_can_resize(p: pointer): bool {.exportc, cdecl.} = opt(p).inspector.resizable
proc wopts_inspector_background_color(p: pointer): cstring {.exportc, cdecl.} = opt(p).inspector.backgroundColor.cstring
proc wopts_inspector_numeric_id(p: pointer): int32 {.exportc, cdecl.} = opt(p).inspector.numericId
```

- [ ] **Step 7: Add `serializeToolbar` + `parseToolbarJson` and rewrite `wopts_toolbar_json`.** Replace the toolbar accessor (`window.nim:190-191`) with the two helpers + the cache-backed accessor. Place the two helpers just above the accessor:

```nim
# Serialize ToolbarOptions to the native toolbar wire JSON ({style, items:[...]})
# consumed by toolbar.m's zapp_toolbar_parse_items (matches TS normalizeToolbar).
proc serializeToolbar*(t: ToolbarOptions): string =
  var items = newJArray()
  for it in t.items:
    case it.`type`
    of "toggleSidebar", "toggleInspector", "space", "flexibleSpace":
      items.add(%*{"type": it.`type`})
    of "trackingSeparator":
      items.add(%*{"type": "trackingSeparator",
                   "pane": (if it.pane.len > 0: it.pane else: "sidebar")})
    else:  # button (default)
      var w = %*{"type": "button", "id": it.id, "label": it.label,
                 "icon": it.icon, "enabled": it.enabled}
      if it.menu.len > 0:
        var m = newJArray()
        for mi in it.menu:
          m.add(%*{"id": mi.id, "label": mi.label, "icon": mi.icon, "checked": mi.checked})
        w["menu"] = m
        w["indicator"] = %it.indicator   # chevron — only meaningful on menu items
      items.add(w)
  $(%*{"style": (if t.style.len > 0: t.style else: "unified"), "items": items})

# Inverse: parse a native toolbar wire string back into ToolbarOptions (used when
# a window arrives over the JSON wire carrying a pre-serialized toolbarJson string).
proc parseToolbarJson*(s: string): ToolbarOptions =
  result.style = "unified"
  if s.len == 0: return
  let root = try: parseJson(s) except CatchableError: return
  if root.kind != JObject: return
  if jHasStr(root, "style"): result.style = jStr(root, "style")
  let items = root{"items"}
  if items.isNil or items.kind != JArray: return
  for itn in items:
    if itn.kind != JObject: continue
    var item = ToolbarItemOpt(enabled: true, indicator: true)  # explicit: match field defaults
    item.`type` = (if jHasStr(itn, "type"): jStr(itn, "type") else: "button")
    if jHasStr(itn, "id"): item.id = jStr(itn, "id")
    if jHasStr(itn, "pane"): item.pane = jStr(itn, "pane")
    if jHasStr(itn, "label"): item.label = jStr(itn, "label")
    if jHasStr(itn, "icon"): item.icon = jStr(itn, "icon")
    if jHasBool(itn, "enabled"): item.enabled = jBool(itn, "enabled", true)
    if jHasBool(itn, "indicator"): item.indicator = jBool(itn, "indicator", true)
    let menu = itn{"menu"}
    if not menu.isNil and menu.kind == JArray:
      for mn in menu:
        if mn.kind != JObject: continue
        var m: MenuItemOpt
        if jHasStr(mn, "id"): m.id = jStr(mn, "id")
        if jHasStr(mn, "label"): m.label = jStr(mn, "label")
        if jHasStr(mn, "icon"): m.icon = jStr(mn, "icon")
        if jHasBool(mn, "checked"): m.checked = jBool(mn, "checked", false)
        item.menu.add(m)
    result.items.add(item)

# toolbar accessor — serializes `toolbar` into the ref's own toolbarJsonCache so
# the returned cstring borrows a GC-pinned buffer (BOUNDARY RULE 1). Empty items
# ⇒ "" ⇒ window.m skips darwin_toolbar_attach (same short-circuit as the old flat field).
proc wopts_toolbar_json(p: pointer): cstring {.exportc, cdecl.} =
  let o = opt(p)
  o.toolbarJsonCache = (if o.toolbar.items.len == 0: "" else: serializeToolbar(o.toolbar))
  o.toolbarJsonCache.cstring
```

Note: `serializeToolbar`/`parseToolbarJson` must be defined ABOVE `wopts_toolbar_json` (and the helpers use `jHasStr`/`jStr`/`jHasBool`/`jBool`, which are defined at `window.nim:294-311`). If the toolbar accessor currently sits ABOVE those `j*` helpers, move the two new helpers + the accessor to just AFTER the `j*` helper definitions (before `windowOptsApplyJson`) so the `j*` procs are in scope. The accessor's `{.exportc, cdecl.}` name/position relative to `window.m` does not matter (C resolves by symbol name, not order).

- [ ] **Step 8: Update `windowOptsApplyJson` sidebar/inspector + add toolbar.** In the sidebar block (`window.nim:357-366`) change each assignment target from `o.sidebarX` to `o.sidebar.x`:

```nim
  let sb = a{"sidebar"}
  if not sb.isNil and sb.kind == JObject:
    if jHasStr(sb, "url"): o.sidebar.url = jStr(sb, "url")
    if jHasStr(sb, "material"): o.sidebar.material = jStr(sb, "material")
    if jHasStr(sb, "backgroundColor"): o.sidebar.backgroundColor = jStr(sb, "backgroundColor")
    if jHasNum(sb, "width"): o.sidebar.width = jI32(sb, "width", o.sidebar.width)
    if jHasNum(sb, "minWidth"): o.sidebar.minWidth = jI32(sb, "minWidth", o.sidebar.minWidth)
    if jHasNum(sb, "maxWidth"): o.sidebar.maxWidth = jI32(sb, "maxWidth", o.sidebar.maxWidth)
    if jHasBool(sb, "collapsible"): o.sidebar.collapsible = jBool(sb, "collapsible", o.sidebar.collapsible)
    if jHasBool(sb, "collapsed"): o.sidebar.collapsed = jBool(sb, "collapsed", o.sidebar.collapsed)
    if jHasBool(sb, "resizable"): o.sidebar.resizable = jBool(sb, "resizable", o.sidebar.resizable)
    if jHasStr(sb, "presentation"): o.sidebar.presentation = jStr(sb, "presentation")
  let insp = a{"inspector"}
  if not insp.isNil and insp.kind == JObject:
    if jHasStr(insp, "url"): o.inspector.url = jStr(insp, "url")
    if jHasStr(insp, "material"): o.inspector.material = jStr(insp, "material")
    if jHasStr(insp, "backgroundColor"): o.inspector.backgroundColor = jStr(insp, "backgroundColor")
    if jHasNum(insp, "width"): o.inspector.width = jI32(insp, "width", o.inspector.width)
    if jHasNum(insp, "minWidth"): o.inspector.minWidth = jI32(insp, "minWidth", o.inspector.minWidth)
    if jHasNum(insp, "maxWidth"): o.inspector.maxWidth = jI32(insp, "maxWidth", o.inspector.maxWidth)
    if jHasBool(insp, "collapsible"): o.inspector.collapsible = jBool(insp, "collapsible", o.inspector.collapsible)
    if jHasBool(insp, "collapsed"): o.inspector.collapsed = jBool(insp, "collapsed", o.inspector.collapsed)
    if jHasBool(insp, "resizable"): o.inspector.resizable = jBool(insp, "resizable", o.inspector.resizable)
```

And replace the flat toolbar line (`window.nim:353`, `if jHasStr(a, "toolbarJson"): o.toolbarJson = jStr(a, "toolbarJson")`) with:

```nim
  if jHasStr(a, "toolbarJson"): o.toolbar = parseToolbarJson(jStr(a, "toolbarJson"))
```

- [ ] **Step 9: Sweep for any straggler flat-field references.**

Run: `cd /Users/zach/code/zapp && grep -rn "sidebarUrl\|sidebarWidth\|sidebarMaterial\|sidebarMinWidth\|sidebarMaxWidth\|sidebarCollapsible\|sidebarCollapsed\|sidebarCanResize\|sidebarBackgroundColor\|sidebarPresentation\|sidebarNumericId\|inspectorUrl\|inspectorMaterial\|inspectorWidth\|inspectorMinWidth\|inspectorMaxWidth\|inspectorCollapsible\|inspectorCollapsed\|inspectorCanResize\|inspectorBackgroundColor\|inspectorNumericId\|\.toolbarJson\b" native/nim/ kitchen-sink/`
Expected: only `toolbarJsonCache` (the new field) may match `\.toolbarJson`. No `sidebarX`/`inspectorX`/bare `.toolbarJson` references remain in `window.nim`. (kitchen-sink is fixed in Task 3.) If any other `.nim` file references a flat field, update it to nested the same way and note it in the commit.

- [ ] **Step 10: Run the unit test to verify GREEN.**

Run: `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --warnings:off --mm:orc --threads:on -o:/tmp/wm tests/windowmanager_test.nim 2>&1 | tail -5`
Expected: PASS — last line `windowmanager ok`.

- [ ] **Step 11: Commit.**

```bash
git add native/nim/window.nim
git commit -m "$(cat <<'EOF'
feat(nim): nested WindowOptions chrome (sidebar/inspector/toolbar)

Replace the flat sidebar*/inspector*/toolbarJson fields with nested
SidebarOptions/InspectorOptions/ToolbarOptions sub-objects, matching the
TS WindowOptions + JSON wire. wopts_* C-ABI signatures unchanged (window.m
untouched); toolbar authored as ToolbarOptions and serialized on demand via
wopts_toolbar_json into a derived toolbarJsonCache buffer. windowOptsApplyJson
reads nested sidebar/inspector and parses an incoming toolbarJson string into
o.toolbar via the new parseToolbarJson. Single source of truth.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Migrate kitchen-sink + full build gates

**Files:**
- Modify: `kitchen-sink/zapp/app.nim`

- [ ] **Step 1: Migrate the window construction to the nested shape.** In `kitchen-sink/zapp/app.nim`, replace the flat sidebar/inspector lines (currently lines 33-34) inside the `WindowOptions(...)` literal:

```nim
    sidebar: SidebarOptions(url: "#sidebar-pane", width: 240, presentation: "overlay"),
    inspector: InspectorOptions(url: "#inspector-pane", width: 300, collapsed: true),
```

(Leave `title`, `visible`, `width`, `height`, `inspectable` unchanged.)

- [ ] **Step 2: Build the kitchen-sink Nim app (macOS).** This compiles `kitchen-sink/zapp/app.nim` (the Nim build root) + `window.nim`.

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts build 2>&1 | tail -20`
Expected: the LAST line is `[zapp] build complete: …` (per the verify-native-build rule — Vite's `✓ built` is NOT success). If the build fails on a nested-field error, fix the offending reference and rebuild. Confirm a fresh binary mtime.

- [ ] **Step 3: iOS-sim build gate** (the `wopts_*` accessors compile into the iOS binary too).

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts build --platform ios 2>&1 | tail -20`
Expected: LAST line `[zapp] build complete: …` (iOS-sim target). No `wopts_*`/`window.nim` compile errors.

- [ ] **Step 4: TS suite (no CLI change, must stay green).**

Run: `cd /Users/zach/code/zapp && bun test cli/src 2>&1 | tail -5`
Expected: all pass (103/103 or current baseline), 0 failures.

- [ ] **Step 5: Commit.**

```bash
git add kitchen-sink/zapp/app.nim
git commit -m "$(cat <<'EOF'
refactor(kitchen-sink): nested WindowOptions chrome shape

Migrate the Nim app window construction to the nested sidebar:/inspector:
sub-objects (matches the new WindowOptions). No behavior change.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Human visual smoke (GATE — pause for the user)

**Files:** none (verification only).

- [ ] **Step 1: Run the kitchen-sink app in dev.**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts dev`

- [ ] **Step 2: Confirm chrome renders identically to before the refactor.** Ask the user to verify on the kitchen-sink window:
  - The **sidebar** appears (overlay presentation, ~240px) and its toggle works.
  - The **inspector** is present (starts collapsed, width ~300) and toggles open.
  - The **toolbar** shows the same items in the same positions (compose, filter menu with its moving checkmark, sidebar/inspector toggles), and clicks/menu still route.

This proves the nested authoring path produces byte-identical native chrome. **Pause here for the user's confirmation before finishing the branch.**

---

## Self-Review

**Spec coverage:** new nested types (Task 2 Step 2) ✓; sentinel unchanged — `sidebar.url == ""`/`inspector.url == ""`/`toolbar.items.len == 0` (Task 2 Steps 3-4,7) ✓; field-name alignment incl. `resizable` (Step 2) ✓; accessors unchanged-signature, nested bodies (Steps 5-6) ✓; `wopts_toolbar_json` serialize-into-`toolbarJsonCache` BOUNDARY RULE 1 (Step 7) ✓; `serializeToolbar`/`parseToolbarJson` matching the pinned wire schema (Step 7) ✓; `windowOptsApplyJson` nested + toolbar parse (Step 8) ✓; kitchen-sink + windowmanager_test migration (Tasks 1,3) ✓; verification = unit test + Nim macOS + iOS-sim + `bun test cli/src` + human smoke (Tasks 2-4) ✓; window.m / TS / wire untouched (no task touches them) ✓.

**Placeholder scan:** none — every code step shows complete code and exact commands.

**Type consistency:** `ToolbarItemOpt.`type``/`pane`/`menu`, `MenuItemOpt.checked`, `SidebarOptions.resizable`/`numericId`, `WindowOptions.sidebar`/`inspector`/`toolbar`/`toolbarJsonCache`, and the helper names `serializeToolbar`/`parseToolbarJson` are used identically across Tasks 1, 2, 3. The `indicator*: bool = true` default is pinned consistently (type def + parse defaults + serialize emit-on-menu).
