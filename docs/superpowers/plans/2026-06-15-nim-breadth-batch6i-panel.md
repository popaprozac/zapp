# Nim Breadth Batch 6i — panel Leaf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the embedded-webview ("panel") t:4 action surface — a `routePanel` in `routeWindowAction` handling the 11 `panel*` actions via `darwin_panel_*`, closing the B5b panel deferral. Last B6 leaf.

**Architecture:** `panel.zc`'s `panel_route` is a dedicated route function (like `screen_route` — no native-first manager), so it ports to a `routePanel(action, a, windowId): bool` proc in `router.nim` (returns true if it handled a `panel*` action; `routeWindowAction` calls `if routePanel(...): return`). All 11 actions are arg-based (parsed `a`) → `darwin_panel_*`. `panel.m` is **already compiled** (zapp.nim:22) and its callbacks already link; no new compile, framework, or stub. This commit also refreshes `routeWindowAction`'s now-stale doc comment.

**Tech Stack:** Nim (`std/json`), `importc` of `panel.m`'s `darwin_panel_*`.

---

## Background

- **Branch:** `feat/nim-native`. macOS / Nim build only. Spec: `…batch6-leaf-services-design.md` (B6i; the B5b-deferred panel ops).
- **The webview path** (`runtime/webview.ts` `<zapp-webview>` element → router.zc:732 `if panel_route(window_id, action, pre_args) { return; }`): all `panel*` actions are fire-and-forget t:4 (no reply).
- **Native targets** (defined in `native/platform/darwin/panel.m`, **ALREADY compiled** in zapp.nim:22), from panel.zc:20-185:
  - `darwin_panel_create(int32_t window_id, const char* panel_id, const char* url, bool bridge, const char* partition)`
  - `darwin_panel_set_bounds(const char* panel_id, int32_t x, int32_t y, int32_t w, int32_t h)`
  - `darwin_panel_load_url(const char* panel_id, const char* url)`
  - `darwin_panel_eval_js(const char* panel_id, const char* js)`
  - `darwin_panel_post_message(const char* panel_id, const char* data_json)`
  - `darwin_panel_show` / `darwin_panel_hide` / `darwin_panel_reload` / `darwin_panel_go_back` / `darwin_panel_go_forward` / `darwin_panel_destroy` — each `(const char* panel_id)`.
- **Action → target + args** (panel.zc; `panel_str(a,k)`=`a{k}.getStr("")`, `panel_int(a,k)`=`a{k}.getInt(0)`): `panelCreate`(panelId,url,partition,bridge:bool default false), `panelSetBounds`(panelId,x,y,w,h), `panelLoadUrl`(panelId,url), `panelExecJs`(panelId,code), `panelPostMessage`(panelId,data — JSON-encoded by the runtime), `panelShow`/`panelHide`/`panelReload`/`panelBack`(→go_back)/`panelForward`(→go_forward)/`panelDestroy`(panelId).
- **No new compile / framework / stub:** panel.m already compiled (zapp.nim:22) — its symbols (incl. any panel→host callbacks) already link. No `zapp_resolve_icon` use.
- **Permission gate:** `permission_id_for_action` maps all 11 `panel*` actions → `"embed"` (permissions.nim, B5a; confirmed by permissions_test `panelCreate`/`panelDestroy` → `"embed"`) — gated at routeWindowAction's head.
- **Doc-comment refresh:** `routeWindowAction`'s header comment still says only subscribe/unsubscribe/ready are ported + "window/app/panel/shell arms are Batch 5b; dock/sidebar/inspector/popover/toolbar are Batch 8" — stale after B5b/B6a/B6f/B6g/B6h/B6i. Update it to reflect reality (ported: subscribe/ready, window ops, app ops, openExternal, shell-path, menu, tray, dock, panel; remaining B8: sidebar/inspector/popover/toolbar).
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only `native/nim/router.nim`. Never `hello-world/` etc. No `{.emit.}`. Build ends `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/router.nim` | `routePanel` + `darwin_panel_*` importc + the `routeWindowAction` call + doc-comment refresh | Modify |

*(No `panel.nim` module — panel.zc is route-only, like screen.zc. panel.m already compiled. No pure-logic unit test — build + runtime + human-smoke gated.)*

---

## Task 1: routePanel + darwin_panel_* importc → build → GATE

**Files:** Modify `native/nim/router.nim`.

- [ ] **Step 1: Add the panel importc decls**

In `native/nim/router.nim`, after the B6h dock importc block (the `darwin_dock_set_icon` decl), add:
```nim
# --- t:4 panel (embedded-webview) targets (panel.m, already compiled; B6i).
# Arg-based; embed-gated at the head. ---
proc darwin_panel_create(windowId: int32, panelId, url: cstring, bridge: bool, partition: cstring) {.importc, cdecl.}
proc darwin_panel_set_bounds(panelId: cstring, x, y, w, h: int32) {.importc, cdecl.}
proc darwin_panel_load_url(panelId, url: cstring) {.importc, cdecl.}
proc darwin_panel_eval_js(panelId, js: cstring) {.importc, cdecl.}
proc darwin_panel_post_message(panelId, dataJson: cstring) {.importc, cdecl.}
proc darwin_panel_show(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_hide(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_reload(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_go_back(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_go_forward(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_destroy(panelId: cstring) {.importc, cdecl.}
```

- [ ] **Step 2: Add the `routePanel` proc**

In `native/nim/router.nim`, add `routePanel` immediately BEFORE `proc routeWindowAction` (alongside the other route helpers):
```nim
proc routePanel(action: string, a: JsonNode, windowId: int): bool =
  ## t:4 embedded-webview ("panel") actions (mirror panel.zc:panel_route).
  ## Returns true if `action` was a panel action (so routeWindowAction stops).
  ## Arg-based; embed-gated at routeWindowAction's head. panel.m owns the WKWebView.
  if not action.startsWith("panel"): return false
  let pid = a{"panelId"}.getStr("")
  case action
  of "panelCreate":
    let url = a{"url"}.getStr("")
    let partition = a{"partition"}.getStr("")
    darwin_panel_create(windowId.int32, pid.cstring, url.cstring,
                        a{"bridge"}.getBool(false), partition.cstring)
  of "panelSetBounds":
    darwin_panel_set_bounds(pid.cstring, a{"x"}.getInt(0).int32, a{"y"}.getInt(0).int32,
                            a{"w"}.getInt(0).int32, a{"h"}.getInt(0).int32)
  of "panelLoadUrl":
    let url = a{"url"}.getStr("")
    darwin_panel_load_url(pid.cstring, url.cstring)
  of "panelExecJs":
    let code = a{"code"}.getStr("")
    darwin_panel_eval_js(pid.cstring, code.cstring)
  of "panelPostMessage":
    let data = a{"data"}.getStr("")
    darwin_panel_post_message(pid.cstring, data.cstring)
  of "panelShow": darwin_panel_show(pid.cstring)
  of "panelHide": darwin_panel_hide(pid.cstring)
  of "panelReload": darwin_panel_reload(pid.cstring)
  of "panelBack": darwin_panel_go_back(pid.cstring)
  of "panelForward": darwin_panel_go_forward(pid.cstring)
  of "panelDestroy": darwin_panel_destroy(pid.cstring)
  else: return false      # "panel"-prefixed but not a real panel action
  return true
```
(Locals (`url`/`partition`/`code`/`data`) keep each Nim string alive across the synchronous darwin call; `a{…}` is nil-safe. The `startsWith("panel")` guard returns false fast for non-panel actions so `routeWindowAction` falls through.)

- [ ] **Step 3: Call `routePanel` in `routeWindowAction`**

In `routeWindowAction`, AFTER the B6h dock arm (`if action.startsWith("dock:"): … return`) and BEFORE the `# --- handle-based window ops …` comment, insert:
```nim
  # --- panel (embedded-webview) ops (panel.m; embed-gated at the head) ------
  if routePanel(action, a, windowId): return
```

- [ ] **Step 4: Refresh the stale `routeWindowAction` doc comment**

In `native/nim/router.nim`, REPLACE `routeWindowAction`'s header doc comment (currently describing only subscribe/unsubscribe/ready as ported and "ARMS are Batch 5b; dock/sidebar/inspector/popover/toolbar are Batch 8") with an accurate one:
```nim
  ## t:4 fire-and-forget window/app action dispatch. HEAD = the action permission
  ## gate (router.zc:376-385): ungated ("") falls through; a gated action not
  ## granted is dropped (fire-and-forget has no reply channel — permissions_check
  ## logs once). Ported arms: subscribe/unsubscribe/ready, id-based + handle-based
  ## window ops + attach/detachModal (B5b), app ops + openExternal (B5b),
  ## shell-path (B6a), menu (B6f), tray (B6g), dock (B6h), panel (B6i). Remaining:
  ## sidebar/inspector/popover/toolbar t:4 + accessory-pane sender resolution (B8).
```

- [ ] **Step 5: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_panel_*` → unlikely, panel.m is already compiled; check the importc spelling/signature.) Do NOT `git add` hello-world/.

- [ ] **Step 6: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): t:4 panel* (embedded webview) action arms (Batch 6i)\n\nrouteWindowAction now dispatches the 11 panel* actions (create/setBounds/loadUrl/\nexecJs/postMessage/show/hide/reload/back/forward/destroy) via routePanel ->\ndarwin_panel_* (panel.m, already compiled). Closes the B5b panel deferral.\nRefreshed routeWindowAction'\''s doc comment to list the now-ported arms (B5b/6a/\n6f/6g/6h/6i) vs the remaining B8 chrome.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 8: GATE — human smoke (controller continues; user smokes later)**

`ZAPP_NATIVE_LANG=nim bun run dev`: a `<zapp-webview>` element (panel) mounts (`panelCreate`), loads its URL, positions to its DOM rect (`panelSetBounds`); `loadUrl`/`reload`/`back`/`forward` navigate it; `execJs`/`postMessage` reach the embed; `show`/`hide`/`destroy` work.

---

## Self-Review

**1. Spec coverage:** all 11 `panel*` actions → Step 2 (`routePanel`) + Step 3 (call); panel.m already compiled (no new compile/framework/stub) → documented; embed-gated at head → documented; doc-comment refresh → Step 4 (closes the B6f reviewer nit). ✓
**2. Placeholder scan:** No TBD/TODO; full proc + exact insertions + the exact replacement comment. ✓
**3. Type consistency:** the 11 `darwin_panel_*` importc match panel.zc's extern decls (`int32_t`↔`int32`, `const char*`↔`cstring`, `bool`↔`bool`); `a{…}.getStr("")`/`getInt(0)`/`getBool(false)` mirror panel_str/panel_int/get_bool defaults; string locals keep cstrings alive across the synchronous calls; `routePanel(action, a, windowId): bool` is called as `if routePanel(...): return` (mirrors the zc `if panel_route(...) { return; }`); defined before `routeWindowAction` (Nim definition-before-use). ✓
