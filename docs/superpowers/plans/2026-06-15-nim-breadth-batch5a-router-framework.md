# Nim Breadth Batch 5a — Router Framework + Available Routes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the router's dispatch framework + the routes whose targets are already compiled (`__zapp:*`, `__app:*`) + `permission_id_for_action` and the t:4 action permission gate — fixing the `Workers.list()` → NOT_FOUND the runtime hits.

**Architecture:** `permission_id_for_action` joins `permission_id_for_invoke` in `permissions.nim` (pure cstring mapping, leaf-testable). `router.nim` gains `__zapp:`/`__app:` t:1 routes and extracts t:4 handling into a `routeWindowAction` proc gated at its head by `permission_id_for_action`; the t:4 action arms (window/app/panel/shell) are B5b, leaf routes are B6/B8.

**Tech Stack:** Nim (`std/[options, json, strutils]`), libc `c_strncmp`/`c_strcmp` (already in permissions.nim), `importc` of platform.m symbols. Nim unit tests via `nim c -r --hints:off`.

---

## Background

- **Branch:** `feat/nim-native`. Additive; `zc` path untouched.
- **Why this exists:** `Workers.list()` → `__zapp:workers-list` invoke → the Nim router has no `__zapp:` route → falls through to the service registry → `NOT_FOUND`. B5a adds the route (returns the `[]` registry stub).
- **The router is split** (router.zc is 1891 LOC, ~half its targets are B6/B8). B5a = framework + available routes. The t:4 action arms (window/app/panel/shell) are **B5b**; leaf t:1 routes (`__dialog:`/`__notif:`/`__shortcuts:`/`__screen:`) are **B6**; dock/sidebar/inspector/popover/toolbar t:4 → **B8**; worker actions → **B7**. **Cancellation is NOT ported** (the `zapp_mark_cancelled` path is never called even in the zc — vestigial).
- **Current `router.nim`** (`routeMessage`): handles t:4 `subscribe`/`unsubscribe`/`ready` inline, then `if f.t != 1: return`, then the t:1 permission gate + `__clipboard:` + service invoke.
- **`permission_id_for_invoke`** (the sibling in `permissions.nim`) is the style to mirror — pure cstring logic, string-literal returns. It's `{.exportc, cdecl, gcsafe.}` because the worker engines call it; **`permission_id_for_action` has NO worker-engine caller (verified), so it's a plain exported Nim proc — no exportc.**
- **Targets (all in compiled `.m`):** `darwin_set_login_item(bool): bool`, `darwin_get_login_item(): bool` (platform.m:187,199); `zapp_workers_registry_list_json(): cstring` (the `zapp.nim` stub → static `"[]"`); `permissions_bootstrap_json(): cstring` (permissions.nim, B3).
- **Nim test pattern:** standalone `.nim` in `native/nim/tests/`. `permission_id_for_action` is unit-tested in `permissions_test.nim` (the router routes are integration-verified by the build + the runtime `Workers.list` gate — `router.nim`'s import chain is too heavy to unit-test standalone, consistent with prior batches).
- **STANDING CONSTRAINT — never `git add -A`.** Stage only the explicit paths per commit. Never `hello-world/`, `vendor/`, user-WIP.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/permissions.nim` | + `permission_id_for_action` mapping | Modify |
| `native/nim/tests/permissions_test.nim` | + `permission_id_for_action` assertions | Modify |
| `native/nim/router.nim` | + `__zapp:`/`__app:` routes; t:4 → `routeWindowAction` (gated) | Modify |

---

## Task 1: `permission_id_for_action` in permissions.nim

**Files:** Modify `native/nim/permissions.nim`, `native/nim/tests/permissions_test.nim`.

- [ ] **Step 1: Add the failing assertions**

In `native/nim/tests/permissions_test.nim`, inside `proc test()` (after the existing
`permission_id_for_invoke` asserts, before `echo "permissions ok"`), add:
```nim
  # permission_id_for_action mapping (router.zc:40-54)
  doAssert $permission_id_for_action(cstring"tray:create") == "tray"
  doAssert $permission_id_for_action(cstring"dock:setBadge") == "dock"
  doAssert $permission_id_for_action(cstring"panelCreate") == "embed"
  doAssert $permission_id_for_action(cstring"panelDestroy") == "embed"
  doAssert $permission_id_for_action(cstring"setMenu") == "menu"
  doAssert $permission_id_for_action(cstring"showContextMenu") == "menu"
  doAssert $permission_id_for_action(cstring"openExternal") == "shell:open"
  doAssert $permission_id_for_action(cstring"openPath") == "shell:open"
  doAssert $permission_id_for_action(cstring"showItemInFolder") == "shell:reveal"
  doAssert $permission_id_for_action(cstring"trashItem") == "shell:trash"
  doAssert $permission_id_for_action(cstring"setTitle") == ""        # window op — ungated
  doAssert $permission_id_for_action(cstring"subscribe") == ""       # plumbing — ungated
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off permissions_test.nim 2>&1 | tail -5`
Expected: FAIL — `undeclared identifier: 'permission_id_for_action'`.

- [ ] **Step 3: Add `permission_id_for_action` to permissions.nim**

In `native/nim/permissions.nim`, after `permission_id_for_invoke`, add (reuses the
existing `c_strncmp`/`c_strcmp` importc'd at the top of the module):
```nim
proc permission_id_for_action*(action: cstring): cstring =
  ## Map a t:4 fire-and-forget action to a permission id ("" = ungated: window
  ## ops, app lifecycle, plumbing). Pure cstring logic; mirrors router.zc:40-54.
  ## Router-internal (no worker-engine caller) → plain exported Nim proc, no
  ## exportc. String literals returned as cstring are static storage.
  if c_strncmp(action, cstring"tray:", 5) == 0: return cstring"tray"
  if c_strncmp(action, cstring"dock:", 5) == 0: return cstring"dock"
  if c_strcmp(action, cstring"panelCreate") == 0 or
     c_strcmp(action, cstring"panelSetBounds") == 0 or
     c_strcmp(action, cstring"panelLoadUrl") == 0 or
     c_strcmp(action, cstring"panelExecJs") == 0 or
     c_strcmp(action, cstring"panelPostMessage") == 0 or
     c_strcmp(action, cstring"panelShow") == 0 or
     c_strcmp(action, cstring"panelHide") == 0 or
     c_strcmp(action, cstring"panelReload") == 0 or
     c_strcmp(action, cstring"panelBack") == 0 or
     c_strcmp(action, cstring"panelForward") == 0 or
     c_strcmp(action, cstring"panelDestroy") == 0: return cstring"embed"
  if c_strcmp(action, cstring"setMenu") == 0: return cstring"menu"
  if c_strcmp(action, cstring"showContextMenu") == 0: return cstring"menu"
  if c_strcmp(action, cstring"openExternal") == 0: return cstring"shell:open"
  if c_strcmp(action, cstring"openPath") == 0: return cstring"shell:open"
  if c_strcmp(action, cstring"showItemInFolder") == 0: return cstring"shell:reveal"
  if c_strcmp(action, cstring"trashItem") == 0: return cstring"shell:trash"
  return cstring""
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off permissions_test.nim 2>&1 | tail -3`
Expected: PASS — `permissions ok`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/permissions.nim native/nim/tests/permissions_test.nim
git commit -m "$(printf 'feat(nim): permission_id_for_action mapping (Batch 5a)\n\nMaps t:4 actions to permission ids (tray/dock/embed/menu/shell), mirroring\nrouter.zc:40-54. Joins permission_id_for_invoke in permissions.nim; pure\ncstring logic, no exportc (no worker-engine caller). Unit-tested.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: `__zapp:` + `__app:` t:1 routes in router.nim → build (fixes Workers.list)

**Files:** Modify `native/nim/router.nim`.

- [ ] **Step 1: Add the route helpers + importc targets**

In `native/nim/router.nim`, after the existing `importc` block near the top (the
`darwin_window_id_string` / `darwin_window_set_bridge_ready` / `zapp_window_trigger_on_ready`
block), add:
```nim
# __zapp: route targets. zapp_workers_registry_list_json is the zapp.nim stub →
# a STATIC "[]" (NOT malloc'd) — do NOT free it (the zc frees a malloc'd registry
# string; B7's real registry will re-add the free here). permissions_bootstrap_json
# is in permissions.nim (B3).
proc zapp_workers_registry_list_json(): cstring {.importc, cdecl.}

# __app: route targets (platform.m — SMAppService login item, macOS).
proc darwin_set_login_item(enabled: bool): bool {.importc, cdecl.}
proc darwin_get_login_item(): bool {.importc, cdecl.}

proc routeZapp(meth: string, windowId, id: int) =
  ## __zapp:* routes (router.zc:1352-1375).
  if meth == "__zapp:workers-list":
    let json = zapp_workers_registry_list_json()
    sendInvokeResponse(windowId, id, true, (if json.isNil: "[]" else: $json))
    return
  if meth == "__zapp:permissions":
    sendInvokeResponse(windowId, id, true, $permissions_bootstrap_json())
    return
  sendInvokeResponse(windowId, id, false, "UNKNOWN_ZAPP_METHOD")

proc routeApp(meth: string, a: JsonNode, windowId, id: int) =
  ## __app:* routes (router.zc:1377-1415). Login item (macOS); reply the bool as
  ## a JSON literal the runtime JSON.parses.
  if meth == "__app:setLoginItem":
    let enabled = (if a.isNil: false else: a{"enabled"}.getBool(false))
    let ok = darwin_set_login_item(enabled)
    sendInvokeResponse(windowId, id, true, (if ok: "true" else: "false"))
    return
  if meth == "__app:getLoginItem":
    let ok = darwin_get_login_item()
    sendInvokeResponse(windowId, id, true, (if ok: "true" else: "false"))
    return
  sendInvokeResponse(windowId, id, false, "UNKNOWN")
```
NOTE: confirm the `setLoginItem` arg key against `native/app/router.zc:1377-1415` (read it) — the plan uses `"enabled"`; if the zc reads a different key, match it.

- [ ] **Step 2: Wire the routes into routeMessage**

In `routeMessage`, after the `__clipboard:` block (the `if f.m.startsWith("__clipboard:"): … return`),
and BEFORE the `let res = invokeService(...)` fallthrough, insert:
```nim
  if f.m.startsWith("__zapp:"):
    routeZapp(f.m, windowId, f.id)
    return
  if f.m.startsWith("__app:"):
    routeApp(f.m, f.a, windowId, f.id)
    return
```

- [ ] **Step 3: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Undefined `darwin_set_login_item`/`darwin_get_login_item` → wrong importc name vs platform.m; undefined `zapp_workers_registry_list_json` → it's a `zapp.nim` exportc stub, should resolve.) Do NOT `git add` `hello-world/`.

- [ ] **Step 4: Regression — Nim unit tests still pass**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in permissions_test router_subscribe_test callbacks_test dispatch_test service_cabi_test; do nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): router __zapp:* + __app:* t:1 routes (Batch 5a)\n\nrouteZapp (workers-list -> registry [] stub, no free; permissions -> bootstrap\nmanifest) + routeApp (setLoginItem/getLoginItem -> platform.m). Wired into\nrouteMessage before the service fallthrough. Fixes Workers.list() NOT_FOUND.\nMirrors router.zc:1352-1415.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 3: t:4 `routeWindowAction` refactor + action gate → GATE

**Files:** Modify `native/nim/router.nim`.

- [ ] **Step 1: Extract t:4 handling into a gated `routeWindowAction`**

In `native/nim/router.nim`, add a `routeWindowAction` proc ABOVE `routeMessage` (it uses
`permission_id_for_action`/`permissions_check` from the imported `permissions`, and the
`zapp_window_set_js_listener`/`darwin_window_*`/`zapp_window_trigger_on_ready` already in
scope):
```nim
proc routeWindowAction(action: string, a: JsonNode, windowId: int) =
  ## t:4 fire-and-forget window/app action dispatch. HEAD = the action permission
  ## gate (router.zc:380-385): ungated ("") falls through; a gated action not
  ## granted is dropped (fire-and-forget has no reply channel — permissions_check
  ## logs once). The window/app/panel/shell action ARMS are Batch 5b; dock/
  ## sidebar/inspector/popover/toolbar are Batch 8. Only the framework + the
  ## already-ported subscribe/unsubscribe/ready land here.
  let permId = permission_id_for_action(action.cstring)
  if not permId.isNil and permId[0] != '\0':
    if not permissions_check(permId, action.cstring):
      return

  # subscribe / unsubscribe: gate the per-window JS-subscription bitmask so
  # zapp_dispatch_event's Layer-2 JS delivery fires only for subscribed events.
  if action == "subscribe" or action == "unsubscribe":
    let evName = (if a.isNil: "" else: a{"event"}.getStr(""))
    let evId = eventNameToId(evName)
    if evId >= 0:
      zapp_window_set_js_listener(windowId.cint, evId.cint,
        (if action == "subscribe": 1.cint else: 0.cint))
    return

  # ready: the webview's bridge is up — signal bridge-ready (flushes window.m's
  # deferred first-focus event) + fire the native on_ready callback.
  if action == "ready":
    let wid = darwin_window_id_string(windowId.int32)
    if not wid.isNil: darwin_window_set_bridge_ready(wid)
    zapp_window_trigger_on_ready(windowId.int32)
    return

  # window / app / panel / shell action arms → Batch 5b (added below this point).
```

- [ ] **Step 2: Replace the inline t:4 blocks in routeMessage with the dispatch call**

In `routeMessage`, DELETE the two inline t:4 blocks (the `if f.t == 4 and (f.m == "subscribe" or f.m == "unsubscribe"): …` block AND the `if f.t == 4 and f.m == "ready": …` block) and replace them (in their place, before `if f.t != 1: return`) with:
```nim
  # t:4 fire-and-forget window/app action — dispatched (+ permission-gated) in
  # routeWindowAction.
  if f.t == 4:
    routeWindowAction(f.m, f.a, windowId)
    return
```
The `if f.t != 1: return` line stays after it (defensive; only INVOKE proceeds to the t:1 block).

- [ ] **Step 3: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. Do NOT `git add` `hello-world/`.

- [ ] **Step 4: Regression — all Nim unit tests + codegen test**

Run:
```bash
cd /Users/zach/code/zapp/native/nim/tests && \
for t in permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_registry_test service_lifecycle_test service_manifest_test service_cabi_test worker_service_test; do \
  [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done
```
Expected: each prints its `… ok`.
Run: `cd /Users/zach/code/zapp/cli && bun test src/build-config-nim.test.ts 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): t:4 routeWindowAction + action permission gate (Batch 5a)\n\nExtract the t:4 handling into routeWindowAction with permission_id_for_action +\npermissions_check at its head (the B3-deferred action gate); the existing\nsubscribe/unsubscribe/ready move under it unchanged. window/app/panel/shell\narms are Batch 5b. Mirrors router.zc:376-385.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 6: GATE — human smoke (controller pauses here)**

Unit + build gates prove the framework. Optional runtime confirmation on the Nim build
(`ZAPP_NATIVE_LANG=nim bun run dev`):
1. **`Workers.list()` now returns `[]`** (not `Error: NOT_FOUND`) — the issue the user hit.
2. **`App.getLoginItem()`** returns a bool; `App.setLoginItem(true)` toggles it (Login Items in System Settings).
3. **Window event subscriptions still work** (resize/focus listeners fire — the B1 bridge-ready focus fix preserved through the refactor).

Do not proceed to the final review until the human confirms (or accepts the unit+build gate).

---

## Self-Review

**1. Spec coverage:**
- `permission_id_for_action` in permissions.nim → Task 1. ✓
- `__zapp:*` route (workers-list → `[]` stub, no free; permissions → real) → Task 2. ✓
- `__app:*` route (login item → platform.m) → Task 2. ✓
- t:4 `routeWindowAction` + action permission gate (B3 deferral) → Task 3. ✓
- subscribe/unsubscribe/ready preserved (moved under the gate) → Task 3. ✓
- Workers.list NOT_FOUND fix → Task 2 + gate (Task 3 Step 6). ✓
- Deferred (t:4 arms→B5b; leaf t:1→B6; worker→B7; cancellation omitted) → not implemented; documented in plan background + spec. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step is complete. The one "confirm the arg key against router.zc" is a verification instruction (the implementer reads the source), not a placeholder — the plan supplies a concrete default (`"enabled"`).

**3. Type consistency:** `permission_id_for_action(action: cstring): cstring` used identically in Task 1 (def + test) and Task 3 (gate call, `action.cstring`). `routeZapp(meth, windowId, id)`, `routeApp(meth, a, windowId, id)`, `routeWindowAction(action, a, windowId)` signatures consistent between their defs (Task 2/3) and their `routeMessage` call sites. `sendInvokeResponse(windowId, id, ok, payload)` matches the existing bridge.nim signature used throughout. ✓
