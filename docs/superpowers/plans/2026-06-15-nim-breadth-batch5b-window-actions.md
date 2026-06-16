# Nim Breadth Batch 5b — t:4 Window/App Action Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill `routeWindowAction`'s B5b seam in `native/nim/router.nim` with the t:4 window ops, app ops, and openExternal — so the demo's `Window.*` / `App.quit`/`activate` / open-URL controls work on the Nim build.

**Architecture:** All arms go into `routeWindowAction` (below the B5a permission gate + subscribe/unsubscribe/ready), as an `if action == …` chain mirroring `router.zc`. Handle-based window ops resolve the NSWindow via `darwin_window_get_by_numeric_id(windowId)`; id-based ops pass the numeric id; app/shell ops call platform.m directly. All `darwin_*` targets are `importc`'d at router.nim's top.

**Tech Stack:** Nim (`std/json` for arg extraction), `importc` of window.m/platform.m/webview.h symbols. No standalone router unit test (heavy import chain) — build + runtime-gated, consistent with B5a T2/T3.

---

## Background

- **Branch:** `feat/nim-native`. Additive; `zc` path untouched.
- **B5a left** `routeWindowAction(action: string, a: JsonNode, windowId: int)` with: the permission gate at the head, then `subscribe`/`unsubscribe` + `ready`, then a `# window / app / panel / shell action arms → Batch 5b` comment seam. **This batch replaces that seam with the arms.**
- **Targets (all compiled into the Nim build), confirmed signatures:**
  - window.h: `void* darwin_window_get_by_numeric_id(int32_t)`, `darwin_window_show/hide/minimize/maximize/focus/force_close(void* handle)`, `darwin_window_set_title(void*, const char*)`, `darwin_window_set_size(void*, int32_t, int32_t)`, `darwin_window_set_position(void*, int32_t, int32_t)`, `darwin_window_set_fullscreen(void*, bool)`, `darwin_window_set_always_on_top(void*, bool)`, `darwin_window_attach_modal(void* parent, void* modal)`, `darwin_window_detach_modal(void*, void*)`, `int32_t darwin_window_numeric_id_for_string(const char*)`, `darwin_window_load_url(int32_t, const char*)`.
  - webview.h: `darwin_open_external(const char*)`, `darwin_webview_set_drag_region(int32_t, bool)`.
  - platform.m: `darwin_app_quit(bool)`, `darwin_app_activate(void)`, `darwin_set_quit_guard(bool)`.
  - callbacks.nim (exportc, NOT `*`): `zapp_window_set_close_guard(int, int)` — `importc` it as a C symbol in router.nim.
- **Arg keys (confirmed from router.zc, dispatch only when present — mirror the zc `is_some()` guards):** `setTitle`→`title`; `setSize`→`width`,`height`; `setPosition`→`x`,`y`; `setFullscreen`/`setAlwaysOnTop`→`on`; `loadUrl`→`url`; `setDragRegion`→`drag`; `setCloseGuard`→`on`; `quit`→`force` (default false); `setQuitGuard`→`enabled` (default false); `openExternal`→`url`; `attachModal`/`detachModal`→`parentId`,`modalId` (int OR `"win-<n>"` string).
- **Accessory-pane sender resolution** (`router.zc:484-532`) is **B8** — the Nim build has no sidebar/inspector/popover panes, so the sending `windowId` IS the target host. Use `windowId` directly.
- **Deferred:** shell path ops (openPath/showItemInFolder/trashItem → B6, need fs.zc), panel ops (→ B6, need panel_route), dock/sidebar/inspector/popover/toolbar (→ B8).
- **STANDING CONSTRAINT — never `git add -A`.** Stage only `native/nim/router.nim`. Never `hello-world/`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/router.nim` | t:4 action arms in `routeWindowAction` + the `darwin_*` importc decls | Modify |

---

## Task 1: Window-op action arms (handle-based + id-based + modal)

**Files:** Modify `native/nim/router.nim`.

- [ ] **Step 1: Add the window-op importc decls**

In `native/nim/router.nim`, after the existing importc block (the B5a `darwin_set_login_item` etc.), add:
```nim
# --- t:4 window-op targets (window.m / webview.h, all compiled) -------------
proc darwin_window_get_by_numeric_id(numericId: int32): pointer {.importc, cdecl.}
proc darwin_window_numeric_id_for_string(wid: cstring): int32 {.importc, cdecl.}
proc darwin_window_show(handle: pointer) {.importc, cdecl.}
proc darwin_window_hide(handle: pointer) {.importc, cdecl.}
proc darwin_window_minimize(handle: pointer) {.importc, cdecl.}
proc darwin_window_maximize(handle: pointer) {.importc, cdecl.}
proc darwin_window_focus(handle: pointer) {.importc, cdecl.}
proc darwin_window_force_close(handle: pointer) {.importc, cdecl.}
proc darwin_window_set_title(handle: pointer, title: cstring) {.importc, cdecl.}
proc darwin_window_set_size(handle: pointer, w, h: int32) {.importc, cdecl.}
proc darwin_window_set_position(handle: pointer, x, y: int32) {.importc, cdecl.}
proc darwin_window_set_fullscreen(handle: pointer, on: bool) {.importc, cdecl.}
proc darwin_window_set_always_on_top(handle: pointer, on: bool) {.importc, cdecl.}
proc darwin_window_attach_modal(parent, modal: pointer) {.importc, cdecl.}
proc darwin_window_detach_modal(parent, modal: pointer) {.importc, cdecl.}
proc darwin_window_load_url(windowId: int32, url: cstring) {.importc, cdecl.}
proc darwin_webview_set_drag_region(windowId: int32, drag: bool) {.importc, cdecl.}
proc zapp_window_set_close_guard(id, enabled: cint) {.importc, cdecl.}  # def in callbacks.nim (exportc)

proc resolveWinId(a: JsonNode, key: string): int32 =
  ## parentId/modalId may be an int OR a "win-<n>" pointer-string; -1 if absent
  ## (router.zc:666-700). Mirrors the int-then-string resolution.
  if a.isNil: return -1
  let v = a{key}
  if v.isNil: return -1
  if v.kind == JInt: return v.getInt(-1).int32
  if v.kind == JString: return darwin_window_numeric_id_for_string(v.getStr("").cstring)
  -1
```

- [ ] **Step 2: Add the window-op arms in routeWindowAction**

In `routeWindowAction`, REPLACE the `# window / app / panel / shell action arms → Batch 5b …` comment seam with the window-op arms (the app/openExternal arms come in Task 2 — leave a seam for them). Insert:
```nim
  # --- id-based window ops (take the numeric id; self-guard in the .m) -------
  if action == "loadUrl":
    let url = (if a.isNil: "" else: a{"url"}.getStr(""))
    if url.len > 0: darwin_window_load_url(windowId.int32, url.cstring)
    return
  if action == "setDragRegion":
    if not a.isNil and a.hasKey("drag"):
      darwin_webview_set_drag_region(windowId.int32, a{"drag"}.getBool(false))
    return
  if action == "setCloseGuard":
    if not a.isNil and a.hasKey("on"):
      zapp_window_set_close_guard(windowId.cint, (if a{"on"}.getBool(false): 1.cint else: 0.cint))
    return

  # --- attach/detach modal (resolve BOTH windows' handles) ------------------
  if action == "attachModal" or action == "detachModal":
    let pNum = resolveWinId(a, "parentId")
    let mNum = resolveWinId(a, "modalId")
    if pNum < 0 or mNum < 0: return
    let pH = darwin_window_get_by_numeric_id(pNum)
    let mH = darwin_window_get_by_numeric_id(mNum)
    if pH.isNil or mH.isNil: return
    if action == "attachModal": darwin_window_attach_modal(pH, mH)
    else: darwin_window_detach_modal(pH, mH)
    return

  # --- app ops + openExternal → Batch 5b Task 2 (seam) ----------------------

  # --- handle-based window ops (resolve the NSWindow from the numeric id) ---
  let h = darwin_window_get_by_numeric_id(windowId.int32)
  if h.isNil: return                       # window gone — nothing to act on
  case action
  of "show": darwin_window_show(h)
  of "hide": darwin_window_hide(h)
  of "minimize": darwin_window_minimize(h)
  of "maximize": darwin_window_maximize(h)
  of "setFocus": darwin_window_focus(h)
  of "close": darwin_window_force_close(h)
  of "setTitle":
    if not a.isNil and a.hasKey("title"): darwin_window_set_title(h, a{"title"}.getStr("").cstring)
  of "setSize":
    if not a.isNil and a.hasKey("width") and a.hasKey("height"):
      darwin_window_set_size(h, a{"width"}.getInt(0).int32, a{"height"}.getInt(0).int32)
  of "setPosition":
    if not a.isNil and a.hasKey("x") and a.hasKey("y"):
      darwin_window_set_position(h, a{"x"}.getInt(0).int32, a{"y"}.getInt(0).int32)
  of "setFullscreen":
    if not a.isNil and a.hasKey("on"): darwin_window_set_fullscreen(h, a{"on"}.getBool(false))
  of "setAlwaysOnTop":
    if not a.isNil and a.hasKey("on"): darwin_window_set_always_on_top(h, a{"on"}.getBool(false))
  else: discard
```
(`std/json` is already imported by router.nim, giving `hasKey`/`getStr`/`getInt`/`getBool`/`{}`/`kind`/`JInt`/`JString`.)

- [ ] **Step 3: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_window_*`/`darwin_webview_set_drag_region` → check the importc name/signature vs window.h/webview.h; undefined `zapp_window_set_close_guard` → it's a callbacks.nim exportc, should resolve.) Do NOT `git add` hello-world/.

- [ ] **Step 4: Regression — Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in router_subscribe_test permissions_test callbacks_test dispatch_test service_cabi_test; do nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): t:4 window-op action arms (Batch 5b)\n\nrouteWindowAction now dispatches the Window.* ops: handle-based (show/hide/\nminimize/maximize/setFocus/close/setTitle/setSize/setPosition/setFullscreen/\nsetAlwaysOnTop via darwin_window_get_by_numeric_id) + id-based (loadUrl/\nsetDragRegion/setCloseGuard) + attach/detachModal. Mirrors router.zc window\narms; arg keys + is_some guards preserved.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: App ops + openExternal → build → GATE

**Files:** Modify `native/nim/router.nim`.

- [ ] **Step 1: Add the app/shell importc decls**

In `native/nim/router.nim`, after the window-op importc block from Task 1, add:
```nim
# --- t:4 app-op + shell targets (platform.m / webview.h) -------------------
proc darwin_app_quit(force: bool) {.importc, cdecl.}
proc darwin_app_activate() {.importc, cdecl.}
proc darwin_set_quit_guard(enabled: bool) {.importc, cdecl.}
proc darwin_open_external(url: cstring) {.importc, cdecl.}
```

- [ ] **Step 2: Add the app/openExternal arms**

In `routeWindowAction`, REPLACE the `# --- app ops + openExternal → Batch 5b Task 2 (seam) ---` line (from Task 1) with:
```nim
  # --- app ops (platform.m; ungated) ----------------------------------------
  if action == "quit":
    darwin_app_quit(if a.isNil: false else: a{"force"}.getBool(false))
    return
  if action == "activate":
    darwin_app_activate()
    return
  if action == "setQuitGuard":
    darwin_set_quit_guard(if a.isNil: false else: a{"enabled"}.getBool(false))
    return

  # --- openExternal (shell:open — gated at the head) ------------------------
  if action == "openExternal":
    let url = (if a.isNil: "" else: a{"url"}.getStr(""))
    if url.len > 0: darwin_open_external(url.cstring)
    return
```

- [ ] **Step 3: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. Do NOT `git add` hello-world/.

- [ ] **Step 4: Regression — all Nim unit tests + codegen test**

Run:
```bash
cd /Users/zach/code/zapp/native/nim/tests && \
for t in router_subscribe_test permissions_test callbacks_test dispatch_test appconfig_test service_registry_test service_lifecycle_test service_manifest_test service_cabi_test worker_service_test; do \
  [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done
```
Expected: each prints its `… ok` line.
Run: `cd /Users/zach/code/zapp/cli && bun test src/build-config-nim.test.ts 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): t:4 app ops + openExternal action arms (Batch 5b)\n\nrouteWindowAction now dispatches quit/activate/setQuitGuard (platform.m) +\nopenExternal (webview.h, shell:open-gated). Completes the B5b available t:4\naction surface; shell-path + panel arms remain deferred to B6.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 6: GATE — human smoke (controller pauses here)**

Build + regression gates prove it links + nothing regressed. Optional runtime confirmation on the Nim build (`ZAPP_NATIVE_LANG=nim bun run dev`), driving the demo's window controls:
1. `Window.setTitle("X")` → titlebar changes; `Window.setSize(w,h)` / `setPosition(x,y)` → window resizes/moves; `Window.minimize()` / `maximize()` / `hide()` then `show()` / `setFullscreen(true)`/`(false)` / `setAlwaysOnTop(true)` → act on the window; `Window.close()` closes it.
2. `App.activate()` brings the app forward; `App.quit()` quits.
3. An "open external URL" control opens the system browser.

Do not proceed to the final review until the human confirms (or accepts the build+regression gate).

---

## Self-Review

**1. Spec coverage:**
- Window ops handle-based (show/hide/minimize/maximize/setFocus/close/setTitle/setSize/setPosition/setFullscreen/setAlwaysOnTop) → Task 1. ✓
- Window ops id-based (loadUrl/setDragRegion/setCloseGuard) → Task 1. ✓
- attachModal/detachModal (spec said plan-decides; window.m has `darwin_window_attach_modal`/`detach_modal` → INCLUDED) → Task 1. ✓
- App ops (quit/activate/setQuitGuard) → Task 2. ✓
- openExternal (shell:open-gated) → Task 2. ✓
- Deferred (shell-path → B6, panel → B6, dock/sidebar/inspector/popover/toolbar → B8, accessory-pane resolution → B8) → not implemented; documented in plan background + spec. ✓
- Gate (demo window/app controls work) → Task 2 Step 6. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step is complete. The "→ Batch 5b Task 2 (seam)" marker in Task 1 is a real placeholder line that Task 2 Step 2 explicitly replaces (not a hand-wave).

**3. Type consistency:** `routeWindowAction(action: string, a: JsonNode, windowId: int)` is the existing B5a signature — both tasks add arms inside it, no signature change. `darwin_window_get_by_numeric_id(int32): pointer` result feeds the handle-based `darwin_window_*(handle: pointer)` calls consistently. `resolveWinId(a, key): int32` feeds `darwin_window_get_by_numeric_id`. Arg-extraction (`a{"key"}.getStr/getInt/getBool`, `a.hasKey`) matches the `std/json` API already used in `routeClipboard`. `.int32`/`.cint` conversions at the C-ABI boundary are explicit. ✓
