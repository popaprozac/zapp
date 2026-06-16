# Nim Breadth Batch 6g — tray Leaf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the webview Tray surface — the eight t:4 `tray:*` action arms in `routeWindowAction`, each passing the bridge payload to `darwin_tray_*_from_payload` (tray.m does the NSStatusItem work + click delivery).

**Architecture:** Like menu (B6f), every `tray:*` action is a payload-passthrough — tray.m extracts `"a"` itself and owns the status item, icon, menu, and click→JS/worker eval. The Nim side is an 8-way dispatch reusing the `payload` already threaded into `routeWindowAction` (B6f). `tray.m` is compiled in the build root; no framework or stub change, and **no `zapp_resolve_icon` collision** (tray.m doesn't reference it — verified).

**Tech Stack:** Nim, `importc` of `tray.m`'s `darwin_tray_*_from_payload`.

---

## Background

- **Branch:** `feat/nim-native`. macOS / Nim build only. Spec: `…batch6-leaf-services-design.md` (B6g).
- **The webview path** (`runtime/tray.ts` → router.zc:966-1058): all `tray:*` actions are fire-and-forget t:4 (no reply).
- **Native targets** (defined in `native/platform/darwin/tray.m`, NOT yet compiled), all `void f(const char* payload_json)`: `darwin_tray_create_from_payload`, `darwin_tray_set_icon_from_payload`, `darwin_tray_set_title_from_payload`, `darwin_tray_set_tooltip_from_payload`, `darwin_tray_set_menu_from_payload`, `darwin_tray_destroy_from_payload`, `darwin_tray_attach_window_from_payload`, `darwin_tray_detach_window_from_payload`. **Each extracts `"a"` from the FULL bridge envelope** (router.zc:965 "the .m side extracts 'a' itself") — pass the threaded `payload`, exactly like menu.
- **tray.m's callbacks already resolve** (verified): `darwin_webview_eval_all` (webview.m, compiled) + `worker_broadcast_eval_js` (dispatch.nim, B4) — so the tray-CLICK event (TRAY_CLICKED → JS/workers) works once tray.m links. No new wiring.
- **No `zapp_resolve_icon` collision:** tray.m does NOT reference `zapp_resolve_icon` (grep-verified) — it owns its icon handling. menu.m (B6f) remains the sole definer. No duplicate symbol.
- **Framework:** AppKit (Cocoa, in passL). None to add. No zapp.nim stub collides.
- **Permission gate:** `permission_id_for_action("tray:*")` → `"tray"` (permissions.nim, the `tray:` prefix rule; confirmed by permissions_test) — gated at routeWindowAction's head.
- **`payload` already threaded** into `routeWindowAction` (B6f) — reuse it.
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only `native/nim/router.nim`, `native/nim/zapp.nim`. Never `hello-world/` etc. No `{.emit.}`. Build ends `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/router.nim` | the 8 `tray:*` arms + `darwin_tray_*_from_payload` importc | Modify |
| `native/nim/zapp.nim` | compile `tray.m` | Modify |

*(No `tray.nim` module: payload-passthrough only, like menu. No pure-logic unit test — build + runtime + human-smoke gated.)*

---

## Task 1: tray:* arms + compile tray.m → build → GATE

**Files:** Modify `native/nim/router.nim`, `native/nim/zapp.nim`.

- [ ] **Step 1: Add the tray importc decls**

In `native/nim/router.nim`, after the B6f menu importc block (the `darwin_menu_show_context_from_payload` decl), add:
```nim
# --- t:4 tray targets (tray.m; payload = the FULL bridge envelope, tray.m
# extracts "a"). tray.m owns the NSStatusItem + icon + menu + click delivery. ---
proc darwin_tray_create_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_set_icon_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_set_title_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_set_tooltip_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_set_menu_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_destroy_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_attach_window_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_detach_window_from_payload(payloadJson: cstring) {.importc, cdecl.}
```

- [ ] **Step 2: Add the tray dispatch arm**

In `routeWindowAction`, AFTER the B6f menu arms (the `showContextMenu` block) and BEFORE the `# --- handle-based window ops …` comment, insert:
```nim
  # --- tray ops (tray.m parses the full payload; gated "tray" at the head) ---
  if action.startsWith("tray:"):
    case action
    of "tray:create": darwin_tray_create_from_payload(payload.cstring)
    of "tray:setIcon": darwin_tray_set_icon_from_payload(payload.cstring)
    of "tray:setTitle": darwin_tray_set_title_from_payload(payload.cstring)
    of "tray:setTooltip": darwin_tray_set_tooltip_from_payload(payload.cstring)
    of "tray:setMenu": darwin_tray_set_menu_from_payload(payload.cstring)
    of "tray:destroy": darwin_tray_destroy_from_payload(payload.cstring)
    of "tray:attachWindow": darwin_tray_attach_window_from_payload(payload.cstring)
    of "tray:detachWindow": darwin_tray_detach_window_from_payload(payload.cstring)
    else: discard      # unknown tray:* — no-op (matches the zc fallthrough)
    return
```
(`startsWith` from `std/strutils`, already imported by router.nim.)

- [ ] **Step 3: Compile tray.m in zapp.nim**

In `native/nim/zapp.nim`, add to the `{.compile(...).}` block (after the `menu.m` line):
```nim
{.compile("../platform/darwin/tray.m", "-fobjc-arc").}
```

- [ ] **Step 4: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_tray_*` → the compile line is missing. A `duplicate symbol zapp_resolve_icon` would mean tray.m unexpectedly defines it — STOP + report; per analysis it does not.) Do NOT `git add` hello-world/.

- [ ] **Step 5: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): t:4 tray:* + compile tray.m (Batch 6g)\n\nrouteWindowAction dispatches the 8 tray:* actions (create/setIcon/setTitle/\nsetTooltip/setMenu/destroy/attachWindow/detachWindow) to tray.m'\''s\ndarwin_tray_*_from_payload (reusing the B6f-threaded payload). tray.m owns the\nNSStatusItem + icon + menu + click delivery (callbacks already compiled). tray.m\ncompiled in the build root; no zapp_resolve_icon collision (tray.m doesn'\''t use\nit).\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 7: GATE — human smoke (controller continues; user smokes later)**

`ZAPP_NATIVE_LANG=nim bun run dev`: `Tray.create(...)` shows a status-bar item (icon/title/tooltip); `Tray.setMenu(...)` attaches a menu; clicking the item / a menu entry fires the callback into JS; `Tray.destroy()` removes it.

---

## Self-Review

**1. Spec coverage:** all 8 `tray:*` actions → Step 2 dispatch; payload reuse (tray.m needs the full envelope) → uses the B6f-threaded `payload`; `tray.m` compiled → Step 3; click delivery = tray.m's job, callbacks already compiled → documented; no collision/framework/stub → documented. ✓
**2. Placeholder scan:** No TBD/TODO; full arm + exact insertions. ✓
**3. Type consistency:** the 8 `darwin_tray_*_from_payload(cstring)` importc match tray.m's `void f(const char*)`; `payload.cstring` valid for the synchronous calls; the `case` dispatch is exhaustive over the 8 actions with `else: discard` (the `action.startsWith("tray:")` guard + `return` ensures only tray actions enter + they never fall into the handle-based case). Reuses `routeWindowAction`'s `payload` param (B6f). ✓
