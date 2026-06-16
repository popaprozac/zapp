# Nim Breadth Batch 6e — screen Leaf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the webview Screen-query surface — `routeScreen` handling t:1 `__screen:list`/`__screen:cursor`/`__screen:forWindow` via `darwin_screen_*_json`, at parity with the zc's `screen_route`.

**Architecture:** `screen.zc` is **only** a routing function (`screen_route` — no native-first manager/namespace, unlike fs/dialog/notification), so it ports directly to a `routeScreen` proc in `router.nim` (mirroring how `__zapp:`/`__app:` routes live there — NO separate `screen.nim` module). `screen.m` is **already compiled** in the build root (zapp.nim:21); no new compile, framework, or stub. The SCREENS_CHANGED event already works (screen.m is linked + the event dispatchers — app_events.nim/callbacks.nim — are ported).

**Tech Stack:** Nim (`std/json` already imported), `importc` of `screen.m`'s `darwin_screen_*_json` (heap `char*`, freed after copy) + libc `free`, `bridge.nim` (`sendInvokeResponse`).

---

## Background

- **Branch:** `feat/nim-native`. macOS / Nim build only. Spec: `…batch6-leaf-services-design.md` (B6e).
- **Runtime contract** (`runtime/screen.ts` → the zc `screen_route`, screen.zc:6-71): `Screen.getAll()` → `__screen:list` → a JSON array of displays; `__screen:cursor` → cursor-position JSON; `__screen:forWindow` (arg `windowId` = `"win-<n>"` string) → the display JSON for that window. Replies are the darwin JSON pass-through.
- **Native targets (defined in `native/platform/darwin/screen.m`, ALREADY compiled in zapp.nim:21):** `char* darwin_screen_list_json(void)`, `char* darwin_screen_cursor_json(void)`, `char* darwin_screen_for_window_json(int32_t window_id)`. **All return heap `char*` the caller must `free`** (the zc frees after `dispatch_invoke_response`). `darwin_window_numeric_id_for_string(const char*): int32_t` resolves the `"win-<n>"` arg → already `importc`'d in router.nim (B5b `resolveWinId`).
- **Reply contract (mirror screen.zc):** `__screen:list` → the array JSON, or `"[]"` if NULL (success). `__screen:cursor` → the JSON, or `false`/`"null"` if NULL. `__screen:forWindow` → resolve `windowId` (arg) via `darwin_window_numeric_id_for_string` (default target `-1` if absent), then the JSON, or `false`/`"null"` if NULL. **Improvement over the zc:** an unknown `__screen:*` method → reply `false`/`"UNKNOWN_SCREEN"` (the zc's `screen_route` returns false and the caller drops it → the JS promise hangs; replying avoids the hang).
- **Permission gate:** `permission_id_for_invoke("__screen:*")` → `"screen"` (permissions.nim; confirmed by permissions_test). Gated by routeMessage's t:1 checkpoint.
- **No new `.m` compile / framework / stub** (screen.m already compiled; AppKit/Cocoa covered; no zapp.nim stub collides).
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only `native/nim/router.nim`. Never `hello-world/` etc. No `{.emit.}`. Build ends `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/router.nim` | `routeScreen` + the `darwin_screen_*_json` importc + `__screen:` dispatch | Modify |

*(No `screen.nim` module: `screen.zc` is purely the route function, like `__zapp:`/`__app:`. No pure-logic unit test — build + runtime + human-smoke gated.)*

---

## Task 1: routeScreen + __screen: dispatch → build → GATE

**Files:** Modify `native/nim/router.nim`.

- [ ] **Step 1: Add the screen importc decls + a libc free**

In `native/nim/router.nim`, after the B6a shell-path importc block (the `darwin_trash_item` decl), add:
```nim
# --- t:1 screen-query targets (screen.m, already compiled; B6e). Each returns
# a heap char* the caller frees. darwin_window_numeric_id_for_string is already
# importc'd above (B5b). ---
proc darwin_screen_list_json(): cstring {.importc, cdecl.}
proc darwin_screen_cursor_json(): cstring {.importc, cdecl.}
proc darwin_screen_for_window_json(windowId: int32): cstring {.importc, cdecl.}
proc c_free(p: cstring) {.importc: "free", cdecl.}
```

- [ ] **Step 2: Add the `routeScreen` proc**

In `native/nim/router.nim`, add `routeScreen` immediately AFTER `routeShortcuts` (before `proc routeWindowAction`):
```nim
proc routeScreen(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__screen:*` (mirror screen.zc:screen_route). darwin_screen_*_json
  ## return heap char* — copy ($) into the reply, then free. NULL → safe default.
  case meth
  of "__screen:list":
    let j = darwin_screen_list_json()
    if j.isNil: sendInvokeResponse(windowId, id, true, "[]")
    else:
      sendInvokeResponse(windowId, id, true, $j); c_free(j)
  of "__screen:cursor":
    let j = darwin_screen_cursor_json()
    if j.isNil: sendInvokeResponse(windowId, id, false, "null")
    else:
      sendInvokeResponse(windowId, id, true, $j); c_free(j)
  of "__screen:forWindow":
    let ws = a{"windowId"}.getStr("")
    let target = (if ws.len > 0: darwin_window_numeric_id_for_string(ws.cstring) else: -1'i32)
    let j = darwin_screen_for_window_json(target)
    if j.isNil: sendInvokeResponse(windowId, id, false, "null")
    else:
      sendInvokeResponse(windowId, id, true, $j); c_free(j)
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_SCREEN")
```
(`a{"windowId"}.getStr("")` is nil-safe; `-1'i32` matches the zc's default target. The zc's NULL-list → `"[]"` true / NULL-cursor+forWindow → `false`/`"null"` is preserved.)

- [ ] **Step 3: Dispatch `__screen:` in routeMessage**

In `routeMessage`'s t:1 chain, add the `__screen:` branch after the `__shortcuts:` branch and before `invokeService`:
```nim
  if f.m.startsWith("__shortcuts:"):
    routeShortcuts(f.m, f.a, windowId, f.id)
    return
  if f.m.startsWith("__screen:"):
    routeScreen(f.m, f.a, windowId, f.id)
    return
```

- [ ] **Step 4: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_screen_*_json` → unlikely, screen.m is already compiled; check the importc spelling.) Do NOT `git add` hello-world/.

- [ ] **Step 5: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): routeScreen t:1 __screen:* (Batch 6e)\n\nrouteScreen handles __screen:list/cursor/forWindow via screen.m'\''s\ndarwin_screen_*_json (heap char*, copied then freed); forWindow resolves the\n"win-<n>" arg via darwin_window_numeric_id_for_string. Unknown method replies\nUNKNOWN_SCREEN (the zc dropped it → promise hang). screen.m already compiled;\nSCREENS_CHANGED event already wired via the ported dispatchers.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 7: GATE — human smoke (controller continues; user smokes later)**

`ZAPP_NATIVE_LANG=nim bun run dev`: `Screen.getAll()` returns the display list; the cursor/forWindow queries return display JSON; moving a window between monitors fires SCREENS_CHANGED (if the demo subscribes).

---

## Self-Review

**1. Spec coverage:** `__screen:list`/`cursor`/`forWindow` → Step 2 (`routeScreen`) + Step 3 (dispatch); heap-free handling → Step 2; forWindow id-resolution → Step 2; no module/compile/framework (screen.zc is route-only, screen.m pre-compiled) → documented; SCREENS_CHANGED already wired → documented. ✓
**2. Placeholder scan:** No TBD/TODO; full proc + exact insertions. ✓
**3. Type consistency:** `darwin_screen_*_json(): cstring` / `darwin_screen_for_window_json(int32): cstring` match screen.m's `char*`/`int32_t`; `darwin_window_numeric_id_for_string(cstring): int32` reused from B5b; `c_free(cstring)` libc free; `$j` copies before `c_free`; `sendInvokeResponse(windowId, id, bool, string)` matches; `routeScreen(meth, a, windowId, id)` matches the routeMessage call site. ✓
