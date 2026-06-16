# Nim Breadth Batch 6c — notification Leaf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the webview Notification surface to the `ZAPP_NATIVE_LANG=nim` build — `routeNotification` handling t:1 `__notif:*` (requestPermission/getPermission/show/schedule/cancel/cancelAll/registerCategory/removeCategory/removeDelivered/removeAllDelivered/update), the async invoke-response callback (`notif_response_cb`), and the subscribe-time notification-bridge flush — at parity with the zc.

**Architecture:** A new `native/nim/notification.nim` owns the `darwin_notification_*` `importc` decls + the `notifResponseCb` cdecl callback (→ `sendInvokeResponse`) + thin Nim wrappers. `router.nim` gets `routeNotification` (dispatched from `routeMessage`'s t:1 chain) and a `__notif:` lazy-flush in the subscribe branch. `notification.m` is compiled in the build root (`zapp.nim`), and zapp.nim's TEMP `darwin_notification_setup_delegate` stub is **removed** (notification.m now provides the real one — keeping both = duplicate symbol).

**Tech Stack:** Nim (`std/json`), `importc` of `notification.m`'s C-ABI, `bridge.nim` (`sendInvokeResponse`).

---

## Background

- **Branch:** `feat/nim-native`. Additive; macOS / Nim build only. Spec: `docs/superpowers/specs/2026-06-15-nim-breadth-batch6-leaf-services-design.md` (B6c, third leaf).
- **The webview Notification path** (`runtime/notification.ts`): `Notification.requestPermission()`/`getPermissionStatus()` → `invoke("__notif:requestPermission"|"__notif:getPermission")` → `{status}`; `show(opts)`/`schedule(opts)` → `invoke("__notif:show"|"schedule")` → `{id}`; `registerCategory`/`removeCategory`/`cancel`/`cancelAll`/`removeDelivered`/`removeAllDelivered`/`update` → `invoke("__notif:…")`. The reply is the JSON object the native side returns, passed through (the runtime `JSON.parse`s it). (Worker-side `notifHost()` host-object path is separate — B7, not this batch.)
- **The native targets — split sync / async** (defined in `native/platform/darwin/notification.m`, compiled; signatures from `notification.h` + the router's inline `extern`s):
  - **Async** (resolve later via a callback `void(int32_t wid, int32_t rid, bool ok, const char* json)`): `darwin_notification_request_permission(int32_t wid, int32_t rid, cb)`, `darwin_notification_show(const char* opts, int32_t wid, int32_t rid, cb)`, `darwin_notification_schedule(const char* opts, int32_t wid, int32_t rid, cb)`. These do NOT reply inline — the callback does (later, on the main thread; notification.m marshals — untouched, works in the zc).
  - **Sync:** `const char* darwin_notification_get_permission(void)` (returns `{status}` JSON); `darwin_notification_cancel(const char* id)`; `darwin_notification_cancel_all(void)`; `darwin_notification_register_category(const char* cat_id, const char* actions_json)`; `darwin_notification_remove_category(const char* cat_id)`; `darwin_notification_remove_delivered_json(const char* json)`; `darwin_notification_remove_all_delivered(void)`; `darwin_notification_update_json(const char* json)`. (The `_json` variants + `register_category(2-arg)` are declared `extern` inline in router.zc — confirmed present in notification.m, NOT in notification.h.)
  - **Bridge flush:** `darwin_notification_set_bridge_ready(void)` — flush buffered notification responses once JS subscribes (notification.m:37).
  - **Delegate:** `darwin_notification_setup_delegate(void)` — notification.m installs the UN delegate; platform.m calls it on launch.
- **The zc reference:** `router.zc:1551-1690` (the `__notif:*` dispatch — async ones `return` after firing; sync ones reply `"{}"` or the result), `:1156-1168` (subscribe-time `__notif:` flush via `darwin_notification_set_bridge_ready`), `:1158` (`notif_response_cb` file-scope callback → `dispatch_invoke_response`).
- **Permission gate already in place:** `permission_id_for_invoke("__notif:*")` → `"notifications"` (permissions.nim; confirmed by permissions_test). So `__notif:` is permission-gated by `routeMessage`'s existing t:1 checkpoint before `routeNotification` runs.
- **B6a RULE:** a new leaf's `.m` is compiled in the **build root `zapp.nim`** (NOT self-compiled). `notification.m` is NOT yet in zapp.nim's block → this batch adds it AND removes zapp.nim's TEMP `darwin_notification_setup_delegate` stub (lines ~66-70) — notification.m provides the real symbol; keeping the stub = duplicate-symbol link error.
- **Scope (YAGNI):** port the **webview-routed surface** (the sync + async variants above) + the subscribe flush. **Defer** the native-first typed wrappers + `NotificationCategory`/`NotificationAction` structs (`notification.zc`'s `*_typed` / `NotificationManager`) — they involve struct-array marshaling, have no webview/Nim caller, and land when a native-first `App.notification` (Nim) does. Also out of scope: iOS, Windows, the worker `notif` host object (B7).
- **Bundle caveat (for the gate):** `UNUserNotificationCenter` aborts (SIGABRT) outside an `.app` bundle; notification.m funnels through `zapp_notification_center()` → nil → ObjC nil no-ops. The unbundled Nim dev binary therefore makes notification ops safe **no-ops** (getPermission returns a status, show/schedule don't visibly post). Visual confirmation needs a packaged `.app`; the gate verifies the round-trip + no-crash.
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only the files this task lists. Never `hello-world/`, `vendor/`, `kitchen-sink/`. Never edit `native/platform/**` or `native/worker/engines/*.c`. No `{.emit.}`. Build success ONLY when the last line is `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/notification.nim` | `darwin_notification_*` importc + `notifResponseCb` callback + thin wrappers | Create |
| `native/nim/router.nim` | `routeNotification` + t:1 `__notif:` dispatch + subscribe-branch `__notif:` flush | Modify |
| `native/nim/zapp.nim` | compile `notification.m`; remove the `darwin_notification_setup_delegate` TEMP stub | Modify |

*(No `.m`/pure-logic unit test: this leaf is thin importc wrappers + routing — build + runtime + human-smoke gated, like the router routes. The whole leaf is one cohesive commit because the wiring, the `notification.m` compile, and the stub removal are atomic — removing the stub without compiling notification.m fails to link; compiling it without removing the stub duplicates the symbol.)*

---

## Task 1: notification.nim + routeNotification + compile notification.m → build → GATE

**Files:** Create `native/nim/notification.nim`; modify `native/nim/router.nim`, `native/nim/zapp.nim`.

- [ ] **Step 1: Create `native/nim/notification.nim`**

Create `native/nim/notification.nim`:
```nim
## Notifications — webview Notification surface. Ports the JSON/async variants
## router.zc handles inline (native/notification/notification.zc is the separate
## native-first typed API, deferred). MAIN-THREAD (webview->native); idiomatic.
##
## NB: darwin_notification_* are defined in native/platform/darwin/notification.m,
## compiled by the build root (zapp.nim) — NOT self-compiled here (the B6a rule).
import std/json
import bridge          # sendInvokeResponse — the async callback bridges to it

# Async invoke-response callback signature: void(wid, rid, ok, json).
type NotifCallback = proc(wid, rid: int32, ok: bool, json: cstring) {.cdecl.}

# --- C-ABI: notification.m (notification.h + router.zc inline externs) -----
# Async (resolve later via the callback):
proc darwin_notification_request_permission(wid, rid: int32, cb: NotifCallback) {.importc, cdecl.}
proc darwin_notification_show(opts: cstring, wid, rid: int32, cb: NotifCallback) {.importc, cdecl.}
proc darwin_notification_schedule(opts: cstring, wid, rid: int32, cb: NotifCallback) {.importc, cdecl.}
# Sync:
proc darwin_notification_get_permission(): cstring {.importc, cdecl.}
proc darwin_notification_cancel(id: cstring) {.importc, cdecl.}
proc darwin_notification_cancel_all() {.importc, cdecl.}
proc darwin_notification_register_category(catId, actionsJson: cstring) {.importc, cdecl.}
proc darwin_notification_remove_category(catId: cstring) {.importc, cdecl.}
proc darwin_notification_remove_delivered_json(json: cstring) {.importc, cdecl.}
proc darwin_notification_remove_all_delivered() {.importc, cdecl.}
proc darwin_notification_update_json(json: cstring) {.importc, cdecl.}
proc darwin_notification_set_bridge_ready() {.importc, cdecl.}

# Async invoke-response callback (mirror router.zc's file-scope notif_response_cb):
# notification.m calls this (on the main thread — it marshals) once the prompt /
# post resolves; bridge it to the webview invoke reply. Plain cdecl proc (passed
# by address as the C function pointer); no exportc needed (no .m references it
# by name — the async fns receive it as a param).
proc notifResponseCb(wid, rid: int32, ok: bool, json: cstring) {.cdecl.} =
  sendInvokeResponse(wid.int, rid.int, ok, (if json.isNil: "" else: $json))

# --- Thin wrappers (used by router.nim's routeNotification) ----------------
proc notifRequestPermission*(windowId, id: int) =
  darwin_notification_request_permission(windowId.int32, id.int32, notifResponseCb)
proc notifShow*(optionsJson: string, windowId, id: int) =
  darwin_notification_show(optionsJson.cstring, windowId.int32, id.int32, notifResponseCb)
proc notifSchedule*(optionsJson: string, windowId, id: int) =
  darwin_notification_schedule(optionsJson.cstring, windowId.int32, id.int32, notifResponseCb)
proc notifGetPermission*(): string =
  let r = darwin_notification_get_permission()
  if r.isNil: "" else: $r
proc notifCancel*(id: string) = darwin_notification_cancel(id.cstring)
proc notifCancelAll*() = darwin_notification_cancel_all()
proc notifRegisterCategory*(catId, actionsJson: string) =
  darwin_notification_register_category(catId.cstring, actionsJson.cstring)
proc notifRemoveCategory*(catId: string) = darwin_notification_remove_category(catId.cstring)
proc notifRemoveDelivered*(json: string) = darwin_notification_remove_delivered_json(json.cstring)
proc notifRemoveAllDelivered*() = darwin_notification_remove_all_delivered()
proc notifUpdate*(json: string) = darwin_notification_update_json(json.cstring)
proc notifSetBridgeReady*() = darwin_notification_set_bridge_ready()
```

- [ ] **Step 2: Compile notification.m + remove the TEMP stub in zapp.nim**

In `native/nim/zapp.nim`, add to the `{.compile(...).}` block (after the `dialog.m` line from B6b):
```nim
{.compile("../platform/darwin/notification.m", "-fobjc-arc").}
```
Then DELETE the TEMP `darwin_notification_setup_delegate` stub (the comment block + proc, ~lines 66-70):
```nim
# darwin_notification_setup_delegate — defined in notification.m; platform.m
# calls it on launch to install the UN delegate. Not compiling notification.m
# yet. TEMP until the notification layer lands.
proc darwin_notification_setup_delegate() {.exportc, cdecl.} =
  discard
```
(notification.m now defines `darwin_notification_setup_delegate` — keeping the Nim stub would duplicate the symbol.)

- [ ] **Step 3: Add `import notification` + `routeNotification` in router.nim**

In `native/nim/router.nim`, add `notification` to the top `import` line (currently `…, permissions, fs, dialog`):
```nim
import bridge, service, clipboard, callbacks, events, permissions, fs, dialog, notification
```
Then add `routeNotification` immediately AFTER `routeDialog` (before `proc routeWindowAction`):
```nim
proc routeNotification(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__notif:*` (mirror router.zc:1551-1690). Async ops (requestPermission/
  ## show/schedule) reply LATER via notifResponseCb — this proc returns without
  ## replying for those. Sync ops reply inline ("{}" or the result). macOS only.
  let argsJson = (if a.isNil: "{}" else: $a)
  case meth
  of "__notif:requestPermission": notifRequestPermission(windowId, id)   # async
  of "__notif:show":              notifShow(argsJson, windowId, id)       # async
  of "__notif:schedule":          notifSchedule(argsJson, windowId, id)   # async
  of "__notif:getPermission":
    sendInvokeResponse(windowId, id, true, notifGetPermission())
  of "__notif:cancel":
    let nid = a{"id"}.getStr("")
    if nid.len > 0: notifCancel(nid)
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:cancelAll":
    notifCancelAll()
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:registerCategory":
    let cid = a{"id"}.getStr("")
    if cid.len > 0: notifRegisterCategory(cid, argsJson)
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:removeCategory":
    let cid = a{"id"}.getStr("")
    if cid.len > 0: notifRemoveCategory(cid)
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:removeDelivered":
    notifRemoveDelivered(argsJson)
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:removeAllDelivered":
    notifRemoveAllDelivered()
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:update":
    notifUpdate(argsJson)
    sendInvokeResponse(windowId, id, true, "{}")
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_NOTIFICATION")
```
(`a{"id"}.getStr("")` is nil-safe even when `a` is nil/non-object — the B5b/B6 idiom. Cleaner than the zc's `strstr("\"id\":\"")` walk.)

- [ ] **Step 4: Dispatch `__notif:` in routeMessage**

In `routeMessage`'s t:1 chain, add the `__notif:` branch AFTER the `__dialog:` branch and BEFORE the `invokeService` fallthrough:
```nim
  if f.m.startsWith("__dialog:"):
    routeDialog(f.m, f.a, windowId, f.id)
    return
  if f.m.startsWith("__notif:"):
    routeNotification(f.m, f.a, windowId, f.id)
    return
```

- [ ] **Step 5: Add the `__notif:` lazy-flush to the subscribe branch**

In `routeWindowAction`'s `subscribe`/`unsubscribe` branch, add the flush BEFORE the `eventNameToId` listener set (mirror router.zc:1156-1168 — on subscribe to a `__notif:` event, flush buffered notification responses). The branch currently reads:
```nim
  if action == "subscribe" or action == "unsubscribe":
    let evName = (if a.isNil: "" else: a{"event"}.getStr(""))
    let evId = eventNameToId(evName)
    if evId >= 0:
      zapp_window_set_js_listener(windowId.cint, evId.cint,
        (if action == "subscribe": 1.cint else: 0.cint))
    return
```
Insert the flush right after the `evName` line:
```nim
    let evName = (if a.isNil: "" else: a{"event"}.getStr(""))
    if action == "subscribe" and evName.startsWith("__notif:"):
      notifSetBridgeReady()        # flush buffered notification responses
    let evId = eventNameToId(evName)
```
(Notification click/response delivery is notification.m's job via its own webview eval — independent of the window-event bitmask; `eventNameToId("__notif:…")` returning -1 is fine, the flush is the load-bearing part.)

- [ ] **Step 6: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (A `duplicate symbol _darwin_notification_setup_delegate` → the Step-2 stub wasn't removed. An undefined `darwin_notification_*` → Step 2's compile line is missing/typo'd.) Do NOT `git add` hello-world/.

- [ ] **Step 7: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line.

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/notification.nim native/nim/router.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): notification.nim + routeNotification t:1 __notif:* (Batch 6c)\n\nnotification.nim wraps the darwin_notification_* webview variants (sync +\nasync) + notifResponseCb (the async invoke-response callback). routeNotification\ndispatches __notif:requestPermission/getPermission/show/schedule/cancel/cancelAll/\nregisterCategory/removeCategory/removeDelivered/removeAllDelivered/update; the\nsubscribe branch flushes buffered notification responses on __notif: subscribe.\nnotification.m compiled in the build root; the TEMP setup_delegate stub dropped\n(notification.m now provides it). Native-first typed wrappers deferred.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 9: GATE — human smoke (controller pauses here)**

Build + regression prove it links (incl. the real `setup_delegate`, no duplicate) + nothing regressed. Runtime confirmation (`ZAPP_NATIVE_LANG=nim bun run dev`), in hello-world:
1. `Notification.getPermissionStatus()` / `requestPermission()` → returns a status string (`granted`/`denied`/`not-determined`/`provisional`) with **no crash** (the bundle guard keeps an unbundled center nil-safe).
2. `Notification.show({title, body})` / `schedule(...)` → resolves with an `{id}` (the invoke round-trip completes via `notifResponseCb`).
3. **Caveat:** an unbundled dev binary won't *visually* post notifications (the `zapp_notification_center()` nil-guard makes posts no-ops). Visual confirmation needs a packaged `.app`; the round-trip + no-crash is the dev-mode gate.

Do not proceed to the final review until the human confirms (or accepts the build+regression gate).

---

## Self-Review

**1. Spec coverage** (B6 spec notification section):
- `notification.nim` idiomatic main-thread port of the webview `__notif:` surface → Task 1 Step 1. ✓
- t:1 `__notif:*` (all 11 methods) routed → Step 3 (`routeNotification`) + Step 4 (routeMessage branch). ✓
- Async invoke-response (`notif_response_cb` parity) → `notifResponseCb` + the async wrappers. ✓
- Subscribe-time `__notif:` flush → Step 5. ✓
- `notification.m` compiled per the B6a rule + the duplicate-`setup_delegate` stub removed → Step 2. ✓
- Native-first typed wrappers + structs deferred; iOS/Windows/worker-host-object out of scope → documented. ✓
- Build + runtime + human-smoke gated (no pure-logic unit test) → Steps 6-9. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step is complete (full module + exact insertions + the exact stub text to delete).

**3. Type consistency:** `notifRequestPermission`/`notifShow`/`notifSchedule(… windowId, id: int)`, `notifGetPermission(): string`, `notifCancel`/`notifRegisterCategory`/`notifRemoveCategory`/`notifRemoveDelivered`/`notifUpdate`/`notifCancelAll`/`notifRemoveAllDelivered`/`notifSetBridgeReady` — signatures used in `routeNotification`/the subscribe branch match their `notification.nim` definitions. The `darwin_notification_*` importc signatures match `notification.h` + the router inline externs (`const char*`↔`cstring`, `int32_t`↔`int32`, the `NotifCallback` cdecl matches `notif_callback_fn`). `notifResponseCb` matches `notif_callback_fn` exactly (void / int32 / int32 / bool / cstring). `sendInvokeResponse(windowId, id, bool, string)` matches bridge.nim usage in `routeClipboard`/`routeDialog`. `routeNotification(meth, a, windowId, id)` matches the `routeMessage` call site. ✓
