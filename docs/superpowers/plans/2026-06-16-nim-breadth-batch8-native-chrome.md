# Nim Breadth Batch 8 — Native-Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the native-chrome t:4 surface (sidebar / inspector / toolbar / popover) to the Nim build — compile the 4 chrome `.m`, delete the 8 zapp.nim stubs, add the accessory-pane sender resolution, and wire the chrome control routes — so windows with `sidebar`/`inspector`/`toolbar` opts construct + toggle/resize and `popover` show/hide/destroy work.

**Architecture:** `window.nim` already carries the chrome opts (`wopts_sidebar_*`/`wopts_inspector_*`/`wopts_toolbar_json`), so compiling the chrome `.m` makes window construction build the chrome. The control routes are t:4 arms in `routeWindowAction` (ungated, like window ops). The accessory-pane sender resolution (window/chrome ops from inside a pane → host window) is ported via `darwin_window_get_by_numeric_id` nil-check (the Nim build has no WindowManager). **`popover:create` is deferred** (needs a Nim window-slot allocator).

**Tech Stack:** Nim, `importc` of the chrome `.m` C-ABI, the design doc `docs/superpowers/specs/2026-06-16-nim-breadth-batch7-batch8-design.md`.

---

## Background

- **Branch:** `feat/nim-native`. macOS / Nim build only. Design + decision: `…2026-06-16-nim-breadth-batch7-batch8-design.md`.
- **The 4 chrome `.m`** (`native/platform/darwin/{sidebar,inspector,toolbar,popover}.m`) are NOT yet compiled. zapp.nim has 8 TEMP stubs for the symbols window.m calls into them. **Compiling the `.m` requires deleting the stubs** (duplicate symbol otherwise).
- **No new framework** (all Cocoa/WebKit, in passL). **No `zapp_resolve_icon` collision** (defined in menu.m B6f; toolbar.m `extern`s it). `zapp_pane_emit` defined in sidebar.m, `extern`'d by inspector.m (linker resolves; compile both).
- **Chrome construction** happens in window.m at window-create when the wopts are set (window.nim already exports them). Default opts (empty url / json) → no chrome built. So compiling the `.m` + deleting stubs is safe even before the runtime sets chrome opts.
- **Control routes** (all in `routeWindowAction`, ungated — `permission_id_for_action` returns `""` for sidebar/inspector/toolbar/popover, verified against B5a):
  - **sidebar** (router.zc:776-823): `sidebar:toggle`/`collapse`/`expand`/`setWidth` → `darwin_sidebar_toggle`/`collapse`/`expand`(int32 windowId) / `darwin_sidebar_set_width`(int32 windowId, int32 width). Target = `windowId` arg (`darwin_window_numeric_id_for_string`) else the (resolved) sender. `setWidth` reads `width` (int, default 0).
  - **inspector** (router.zc:825-872): identical shape → `darwin_inspector_*`.
  - **toolbar** (router.zc:916-963): `toolbar:setItems`/`updateItem`/`remove`. Target resolve (same as sidebar). `tb_wptr = darwin_window_get_by_numeric_id(target)`; if nil → no-op. `setItems` reads `toolbarJson` (required → return if absent) → `darwin_toolbar_set_items(tb_wptr, toolbarJson, target)`. `updateItem` reads `itemJson` (required) → `darwin_toolbar_update_item(tb_wptr, itemJson)`. `remove` → `darwin_toolbar_remove(tb_wptr)`.
  - **popover** (router.zc:876-914): `popover:show`/`hide`/`destroy`. Arg `popoverId` (required → return if absent). `show` → `darwin_popover_show(pid, argsJson, windowId)` where `argsJson = $a` (the args subtree the .m parses for anchor/edge). `hide` → `darwin_popover_hide(pid)`. `destroy` → `darwin_popover_destroy(pid)`.
- **Accessory-pane sender resolution** (router.zc:484-512): a t:4 window/chrome op from inside a sidebar/inspector/popover pane carries the pane's transport slot as `windowId`, which is NOT a real NSWindow. Remap to the host: if `darwin_window_get_by_numeric_id(windowId)` is nil, `darwin_window_id_string(windowId)` → `darwin_window_numeric_id_for_string` → host id. `subscribe`/`unsubscribe`/`ready` keep the sender's own slot (per-slot event delivery); window + chrome ops use the resolved host. (`darwin_window_id_string`, `darwin_window_numeric_id_for_string`, `darwin_window_get_by_numeric_id` are all already importc'd in router.nim from B5a/B5b.)
- **DEFERRED:** `popover:create` (router.zc:230-265) — needs `app.window.alloc_slot()` (the zc WindowManager slot allocator the Nim build lacks). Without it, popover show/hide/destroy have nothing to act on, but the routes still link + are correct. Follow-up: "Nim window-slot allocator / WindowManager port."
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only the listed files. Never `hello-world/` etc. No `{.emit.}`. Do NOT edit `native/platform/**` or `*.c`. Build ends `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/zapp.nim` | compile the 4 chrome `.m`; delete the 8 TEMP stubs | Modify |
| `native/nim/router.nim` | accessory-pane sender resolution + chrome `darwin_*` importc + chrome routes | Modify |

*(No `<chrome>.nim` modules — the chrome `.m` do all the work; router just dispatches. No pure-logic unit test — build + runtime + human-smoke gated.)*

---

## Task 1: Compile chrome .m + delete stubs + accessory-pane sender resolution

**Files:** Modify `native/nim/zapp.nim`, `native/nim/router.nim`.

- [ ] **Step 1: Compile the 4 chrome .m + delete the 8 stubs (zapp.nim)**

In `native/nim/zapp.nim`'s `{.compile(...).}` block (after the `dock.m` line from B6h), add:
```nim
{.compile("../platform/darwin/sidebar.m", "-fobjc-arc").}
{.compile("../platform/darwin/inspector.m", "-fobjc-arc").}
{.compile("../platform/darwin/toolbar.m", "-fobjc-arc").}
{.compile("../platform/darwin/popover.m", "-fobjc-arc").}
```
Then DELETE the 8 TEMP stub procs (and their comment block) — `zapp_sidebar_register`, `zapp_sidebar_unregister`, `zapp_inspector_register`, `zapp_inspector_unregister`, `darwin_toolbar_attach`, `zapp_toolbar_unregister`, `zapp_toolbar_inject_metrics`, `zapp_popover_unregister_window` (the real ones are now provided by the compiled `.m`).

- [ ] **Step 2: Add the accessory-pane resolution helper (router.nim)**

In `native/nim/router.nim`, add `resolveAccessoryHost` immediately BEFORE `proc routeWindowAction` (the `darwin_window_get_by_numeric_id` / `darwin_window_id_string` / `darwin_window_numeric_id_for_string` it uses are already importc'd from B5a/B5b):
```nim
proc resolveAccessoryHost(windowId: int): int =
  ## A t:4 window/chrome op from inside a sidebar/inspector/popover pane carries
  ## the pane's transport slot as windowId, which is NOT a real NSWindow. Remap to
  ## the host via the id-string round-trip (router.zc:484-512). Real windows pass
  ## through unchanged.
  if not darwin_window_get_by_numeric_id(windowId.int32).isNil: return windowId
  let hostStr = darwin_window_id_string(windowId.int32)
  if hostStr.isNil: return windowId
  let hostId = darwin_window_numeric_id_for_string(hostStr)
  if hostId >= 0: hostId else: windowId
```

- [ ] **Step 3: Thread the resolution into routeWindowAction**

Rename `routeWindowAction`'s window-id param from `windowId` to `rawWindowId`:
```nim
proc routeWindowAction(action: string, a: JsonNode, rawWindowId: int, payload: string) =
```
In the `subscribe`/`unsubscribe` arm and the `ready` arm (the only arms ABOVE the window/chrome ops), change their `windowId` references to `rawWindowId` (these keep the sender's own slot — per-slot event delivery): in `subscribe`/`unsubscribe` that's `zapp_window_set_js_listener(rawWindowId.cint, …)`; in `ready` that's `darwin_window_id_string(rawWindowId.int32)` and `zapp_window_trigger_on_ready(rawWindowId.int32)`.
Then, immediately AFTER the `ready` arm and BEFORE the id-based window ops, add:
```nim
  # Accessory-pane sender resolution: window + chrome ops from inside a pane
  # target the host window (router.zc:484-512). subscribe/ready above keep the
  # sender's own slot.
  let windowId = resolveAccessoryHost(rawWindowId)
```
All existing window-op arms below (loadUrl/setDragRegion/setCloseGuard/attach-detachModal/the handle-based `case`/shell-path/menu/tray/dock/panel) already reference `windowId` — they now transparently use the resolved host. (The `routeMessage` call site `routeWindowAction(f.m, f.a, windowId, msg)` is unchanged — it passes the sender id, which becomes `rawWindowId`.)

- [ ] **Step 4: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5`
Expected: last line `[zapp] build complete: <path>`. (A `duplicate symbol _zapp_sidebar_register` etc. → a stub wasn't deleted. A `duplicate symbol _zapp_resolve_icon` → should NOT happen, toolbar.m externs it. Undefined `zapp_pane_emit` → sidebar.m didn't compile.) Do NOT `git add` hello-world/.

- [ ] **Step 5: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line (router_subscribe especially — the subscribe arm changed).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/zapp.nim native/nim/router.nim
git commit -m "$(printf 'feat(nim): compile chrome .m + delete stubs + accessory-pane resolution (Batch 8a)\n\nCompile sidebar/inspector/toolbar/popover.m in the build root + delete the 8 TEMP\nzapp.nim stubs (the real .m provide them). Window construction now builds the\nchrome when sidebar/inspector/toolbar opts are set. Added resolveAccessoryHost:\nwindow/chrome t:4 ops from inside a pane remap to the host window via the\nid-string round-trip (router.zc:484-512); subscribe/ready keep the sender slot.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: Chrome control routes (sidebar / inspector / toolbar / popover)

**Files:** Modify `native/nim/router.nim`.

- [ ] **Step 1: Add the chrome importc decls**

In `native/nim/router.nim`, after the B6i panel importc block, add:
```nim
# --- t:4 native-chrome targets (sidebar/inspector/toolbar/popover .m, B8) ----
proc darwin_sidebar_toggle(windowId: int32) {.importc, cdecl.}
proc darwin_sidebar_collapse(windowId: int32) {.importc, cdecl.}
proc darwin_sidebar_expand(windowId: int32) {.importc, cdecl.}
proc darwin_sidebar_set_width(windowId: int32, width: int32) {.importc, cdecl.}
proc darwin_inspector_toggle(windowId: int32) {.importc, cdecl.}
proc darwin_inspector_collapse(windowId: int32) {.importc, cdecl.}
proc darwin_inspector_expand(windowId: int32) {.importc, cdecl.}
proc darwin_inspector_set_width(windowId: int32, width: int32) {.importc, cdecl.}
proc darwin_toolbar_set_items(windowPtr: pointer, toolbarJson: cstring, hostSlot: int32) {.importc, cdecl.}
proc darwin_toolbar_update_item(windowPtr: pointer, itemJson: cstring) {.importc, cdecl.}
proc darwin_toolbar_remove(windowPtr: pointer) {.importc, cdecl.}
proc darwin_popover_show(popoverId: cstring, argsJson: cstring, senderSlot: int32) {.importc, cdecl.}
proc darwin_popover_hide(popoverId: cstring) {.importc, cdecl.}
proc darwin_popover_destroy(popoverId: cstring) {.importc, cdecl.}
```

- [ ] **Step 2: Add a target-resolve helper + the chrome arms**

In `routeWindowAction`, AFTER the B6i `routePanel` call and BEFORE the `# --- handle-based window ops …` comment, insert:
```nim
  # --- native-chrome ops (sidebar/inspector/toolbar/popover; ungated like window ops) ---
  if action.startsWith("sidebar:") or action.startsWith("inspector:"):
    # target = "windowId" arg (a real window) else the resolved sender host
    let widArg = a{"windowId"}.getStr("")
    let target = (if widArg.len > 0: darwin_window_numeric_id_for_string(widArg.cstring) else: windowId.int32)
    let width = a{"width"}.getInt(0).int32
    case action
    of "sidebar:toggle": darwin_sidebar_toggle(target)
    of "sidebar:collapse": darwin_sidebar_collapse(target)
    of "sidebar:expand": darwin_sidebar_expand(target)
    of "sidebar:setWidth": darwin_sidebar_set_width(target, width)
    of "inspector:toggle": darwin_inspector_toggle(target)
    of "inspector:collapse": darwin_inspector_collapse(target)
    of "inspector:expand": darwin_inspector_expand(target)
    of "inspector:setWidth": darwin_inspector_set_width(target, width)
    else: discard
    return
  if action.startsWith("toolbar:"):
    let widArg = a{"windowId"}.getStr("")
    let target = (if widArg.len > 0: darwin_window_numeric_id_for_string(widArg.cstring) else: windowId.int32)
    let h = darwin_window_get_by_numeric_id(target)
    if h.isNil: return
    case action
    of "toolbar:setItems":
      let tj = a{"toolbarJson"}.getStr("")
      if tj.len > 0: darwin_toolbar_set_items(h, tj.cstring, target)
    of "toolbar:updateItem":
      let ij = a{"itemJson"}.getStr("")
      if ij.len > 0: darwin_toolbar_update_item(h, ij.cstring)
    of "toolbar:remove": darwin_toolbar_remove(h)
    else: discard
    return
  if action.startsWith("popover:"):
    let pid = a{"popoverId"}.getStr("")
    if pid.len == 0: return
    case action
    of "popover:show": darwin_popover_show(pid.cstring, ($a).cstring, windowId.int32)
    of "popover:hide": darwin_popover_hide(pid.cstring)
    of "popover:destroy": darwin_popover_destroy(pid.cstring)
    else: discard      # popover:create deferred (needs a Nim window-slot allocator)
    return
```
(All `a{…}` are nil-safe. `windowId` is the accessory-resolved host from Task 1. `($a).cstring` is the args subtree popover.m parses for anchor/edge — local-bound implicitly within the call statement; if Nim flags a temporary lifetime, bind `let argsJson = $a` first.)

- [ ] **Step 3: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_sidebar_*`/`darwin_inspector_*`/`darwin_toolbar_*`/`darwin_popover_*` → Task 1 didn't compile the `.m`, or the importc spelling is off.) Do NOT `git add` hello-world/.

- [ ] **Step 4: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): t:4 chrome control routes — sidebar/inspector/toolbar/popover (Batch 8b)\n\nrouteWindowAction now dispatches sidebar:/inspector: toggle/collapse/expand/\nsetWidth, toolbar:setItems/updateItem/remove, and popover:show/hide/destroy to\nthe chrome .m (compiled in 8a). Targets self-resolve via the windowId arg or the\naccessory-resolved sender host. popover:create deferred (needs a window-slot\nallocator).\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 6: GATE — human smoke (controller continues; user smokes later)**

`ZAPP_NATIVE_LANG=nim bun run dev` with a window created with `sidebar`/`inspector`/`toolbar` opts: the sidebar/inspector panes render; `sidebar:toggle`/`collapse`/`expand`/`setWidth` (and inspector) act; the toolbar renders + `setItems`/`updateItem`/`remove` update it; toolbar clicks fire `window:toolbar-clicked`. (popover needs `create` → deferred.)

---

## Self-Review

**1. Spec coverage:** compile 4 `.m` + delete 8 stubs → T1 S1; accessory resolution → T1 S2-3; sidebar/inspector/toolbar/popover-show-hide-destroy routes → T2; popover:create deferred + documented. ✓
**2. Placeholder scan:** No TBD/TODO; full code + exact insertions. The "confirm arg keys against router.zc" for toolbar is satisfied inline (toolbarJson/itemJson confirmed from router.zc:916-963). ✓
**3. Type consistency:** chrome importc match the `.m`/router.zc externs (`int32_t`↔`int32`, `void*`↔`pointer`, `const char*`↔`cstring`); `resolveAccessoryHost(int): int` uses the B5a/B5b-importc'd darwin helpers; the param rename `windowId`→`rawWindowId` + the `let windowId = resolveAccessoryHost(rawWindowId)` keeps every downstream arm valid; `$a` is the args subtree popover.m parses; chrome arms `startsWith` + `return` keep them out of the handle-based case. ✓
