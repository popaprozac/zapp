# Nim Breadth Batch 1 — Event Dispatch Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make window + app events reach the webview under the Nim build — port `events.zc`+`callbacks.zc`+`app_events.zc` to Nim with real `zapp_dispatch_event`/`zapp_app_dispatch`, plus the minimal `subscribe`/`unsubscribe` router wiring.

**Architecture:** The `.m` layer (untouched) calls `zapp_dispatch_event`/`zapp_app_dispatch` (Nim `{.exportc.}`). Nim owns the per-window registries + JS-subscription bitmask + dispatch logic, but **delegates the actual JS delivery to the untouched `.m`**: window events → `zapp_dispatch_event_to_js` (`importc`, in `window.m`); app events → `darwin_webview_eval_all` (`importc`, in `webview.m`). Worker fan-out is a deferred no-op (Batches 4/7).

**Tech Stack:** Nim 2.2.10 (ORC, main-thread — allocation is fine here, unlike the worker hot path). Spec: `docs/superpowers/specs/2026-06-15-nim-breadth-batch1-events-design.md`.

---

## Working rules (read first)

- Branch `feat/nim-native`. NEVER edit `native/platform/**` or `native/worker/engines/*.c`. Stage ONLY each task's files by explicit path. Never `git add -A`; never stage user-WIP (`kitchen-sink/`, `vendor/*`, `hello-world/src/*` (except where a task explicitly edits the demo), `spikes/`, `.zapp/`, `native/worker/engines/zjs-cross-eval-test.c`).
- Commit trailer EXACTLY (last line): `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Idiomatic Nim, no `{.emit.}`.** Event codes → `enum`; registries → Nim `array`; bitmask → `uint32`.
- These dispatchers run on the **Cocoa main thread**, NOT a worker pthread — normal ORC; allocation is fine.
- **Wire shapes stay identical** to the zc/`.m` version (delegated to `.m`, so automatically identical). No new concession.
- **Build success** = `[zapp] build complete:` last line.

## ABI reference (verbatim — from the source)

**Nim `{.exportc, cdecl.}` (called by the untouched `.m` layer):**
```
int  zapp_dispatch_event(int window_id, int event_id, int w, int h, int x, int y);  // window.m calls this
int  zapp_app_dispatch(int event_id, const char* data);                             // platform.m/notification.m call this
// registration surface (.m on_ready + the Nim router subscribe block call these):
void zapp_window_set_on_ready(int id, void* handle, void (*cb)(int, void*));
void zapp_window_trigger_on_ready(int id);
void zapp_window_set_event_cb(int id, int event_id, int (*cb)(void*));
void zapp_window_set_js_listener(int id, int event_id, int has_listener);
void zapp_window_set_close_guard(int id, int enabled);
void zapp_window_set_backend_listener(int id, int event_id, int has_listener);
void zapp_app_on(int event_id, void (*cb)(int, const char*));
```

**Nim `{.importc, cdecl.}` (provided by the untouched `.m` layer, already compiled in the skeleton):**
```
void zapp_dispatch_event_to_js(int window_id, int event_id, int w, int h, int x, int y);  // window.m — JS delivery
void darwin_webview_eval_all(const char* js);                                             // webview.m — app-event fan-out
```

**Event codes (exact — from events.zc):** window `READY=0,FOCUS=1,BLUR=2,RESIZE=3,MOVE=4,CLOSE=5,MINIMIZE=6,MAXIMIZE=7,RESTORE=8,FULLSCREEN=9,UNFULLSCREEN=10,MODAL_DISMISSED=11`; app `STARTED=100,SHUTDOWN=101,NOTIFICATION_CLICK=102,NOTIFICATION_ACTION=103,REOPEN=104,OPEN_URL=105,DID_BECOME_ACTIVE=106,DID_RESIGN_ACTIVE=107,THEME_CHANGED=108`. Limits: `ZAPP_MAX_WINDOW_CALLBACKS=64`, `ZAPP_MAX_WINDOW_EVENT_TYPES=12` (confirm against events.zc/callbacks.zc), `ZAPP_MAX_APP_EVENT_TYPES`/`ZAPP_MAX_APP_CALLBACKS` (confirm in app_events.zc).

**App-event JS name map (app_events.zc:Layer3, exact):** `104→"app:reopen"`, `105→"app:open-url"`, `106→"app:active"`, `107→"app:inactive"`, `108→"app:theme-changed"` (confirm the full set incl. any 109-116 in app_events.zc; STARTED/SHUTDOWN are NOT forwarded to webviews). App-event Layer-3 IIFE: `(function(){var b=globalThis[Symbol.for('zapp.bridge')];if(b&&b._onEvent)b._onEvent('<name>','<data>');})();`

**Subscribe wire (bootstrap/webview.ts):** `{t:4, m:"subscribe"|"unsubscribe", a:{event:"window:<name>"}}`. `event_name_to_id`: strip `"window:"` prefix, then `ready→0…unfullscreen→10` (exact table from router.zc:356-374).

---

## Task 1: `events.nim` + `callbacks.nim` (registries + `zapp_dispatch_event`)

**Files:**
- Create: `native/nim/events.nim`
- Create: `native/nim/callbacks.nim`
- Test: `native/nim/tests/callbacks_test.nim`

- [ ] **Step 1: `events.nim`** — the event-code enums (exact values):
```nim
## Window + app event codes. Values MUST match native/window/events.zc exactly
## (the .m layer passes these integers). Used by callbacks.nim + app_events.nim.
const
  ZAPP_MAX_WINDOW_CALLBACKS* = 64
  ZAPP_MAX_WINDOW_EVENT_TYPES* = 12   # confirm vs events.zc/callbacks.zc
type
  WindowEvent* = enum
    weReady = 0, weFocus = 1, weBlur = 2, weResize = 3, weMove = 4, weClose = 5,
    weMinimize = 6, weMaximize = 7, weRestore = 8, weFullscreen = 9,
    weUnfullscreen = 10, weModalDismissed = 11
  AppEvent* = enum
    aeStarted = 100, aeShutdown = 101, aeNotificationClick = 102,
    aeNotificationAction = 103, aeReopen = 104, aeOpenUrl = 105,
    aeDidBecomeActive = 106, aeDidResignActive = 107, aeThemeChanged = 108
const EVENT_ALLOW* = 0
const EVENT_CANCEL* = 1
```

- [ ] **Step 2: Failing test for `callbacks.nim`'s pure bitmask + gating logic.**

`native/nim/tests/callbacks_test.nim`:
```nim
import ../callbacks
# The subscribe bitmask: set then dispatch should report the JS-delivery decision.
# willDeliverToJs is a pure helper exposed for testing (no .m call).
proc test() =
  zapp_window_set_js_listener(2, 3, 1)            # window 2 subscribes to RESIZE(3)
  doAssert willDeliverToJs(2, 3) == true
  doAssert willDeliverToJs(2, 4) == false         # MOVE not subscribed
  zapp_window_set_js_listener(2, 3, 0)            # unsubscribe
  doAssert willDeliverToJs(2, 3) == false
  doAssert willDeliverToJs(-1, 3) == false        # bounds
  doAssert willDeliverToJs(2, 99) == false        # bounds
  echo "callbacks ok"
test()
```

- [ ] **Step 3: Run, verify FAIL.** Run: `cd /Users/zach/code/zapp/native/nim && nim c --mm:orc --threads:on -r tests/callbacks_test.nim 2>&1 | tail -8` — FAIL (callbacks/`willDeliverToJs`/`zapp_window_set_js_listener` undefined).

- [ ] **Step 4: Implement `callbacks.nim`.** Registries + bitmask + the dispatcher (delegating JS delivery to the importc'd `.m` fn; worker fan-out = local deferred stub):
```nim
import events

type
  WindowEventCb = proc(data: pointer): cint {.cdecl.}      # returns 0=ALLOW/1=CANCEL
  ReadyCb = proc(id: cint, handle: pointer) {.cdecl.}

var
  gEventCbs: array[ZAPP_MAX_WINDOW_CALLBACKS, array[ZAPP_MAX_WINDOW_EVENT_TYPES, WindowEventCb]]
  gReadyCbs: array[ZAPP_MAX_WINDOW_CALLBACKS, ReadyCb]
  gReadyHandles: array[ZAPP_MAX_WINDOW_CALLBACKS, pointer]
  gJsListeners: array[ZAPP_MAX_WINDOW_CALLBACKS, uint32]
  gBackendListeners: array[ZAPP_MAX_WINDOW_CALLBACKS, uint32]
  gCloseGuard: array[ZAPP_MAX_WINDOW_CALLBACKS, uint32]

template inBounds(id, ev: cint): bool =
  id >= 0 and id < ZAPP_MAX_WINDOW_CALLBACKS and ev >= 0 and ev < ZAPP_MAX_WINDOW_EVENT_TYPES

# --- registration surface (.m + router call these) ---
proc zapp_window_set_js_listener(id, eventId, hasListener: cint) {.exportc, cdecl.} =
  if not inBounds(id, eventId): return
  if hasListener != 0: gJsListeners[id] = gJsListeners[id] or (1'u32 shl eventId.uint32)
  else: gJsListeners[id] = gJsListeners[id] and not (1'u32 shl eventId.uint32)
proc zapp_window_set_backend_listener(id, eventId, hasListener: cint) {.exportc, cdecl.} =
  if not inBounds(id, eventId): return
  if hasListener != 0: gBackendListeners[id] = gBackendListeners[id] or (1'u32 shl eventId.uint32)
  else: gBackendListeners[id] = gBackendListeners[id] and not (1'u32 shl eventId.uint32)
proc zapp_window_set_close_guard(id, enabled: cint) {.exportc, cdecl.} =
  if id >= 0 and id < ZAPP_MAX_WINDOW_CALLBACKS: gCloseGuard[id] = (if enabled != 0: 1'u32 else: 0'u32)
proc zapp_window_set_event_cb(id, eventId: cint, cb: WindowEventCb) {.exportc, cdecl.} =
  if inBounds(id, eventId): gEventCbs[id][eventId] = cb
proc zapp_window_set_on_ready(id: cint, handle: pointer, cb: ReadyCb) {.exportc, cdecl.} =
  if id >= 0 and id < ZAPP_MAX_WINDOW_CALLBACKS: (gReadyCbs[id] = cb; gReadyHandles[id] = handle)
proc zapp_window_trigger_on_ready(id: cint) {.exportc, cdecl.} =
  if id >= 0 and id < ZAPP_MAX_WINDOW_CALLBACKS and gReadyCbs[id] != nil:
    gReadyCbs[id](id, gReadyHandles[id])

# pure test seam
proc willDeliverToJs*(id, eventId: cint): bool =
  inBounds(id, eventId) and (gJsListeners[id] and (1'u32 shl eventId.uint32)) != 0

# --- delivery delegated to the untouched .m layer ---
proc zapp_dispatch_event_to_js(windowId, eventId, w, h, x, y: cint) {.importc, cdecl.}
# worker fan-out — DEFERRED (Batch 4/7). Local no-op so Layer 3 links; backend
# bitmask is never set in Batch 1 (worker subscribe isn't wired), so it's unreached.
proc workerBroadcastEvalJs(js: cstring) = discard   # TEMP

# --- the dispatcher the .m window delegate calls ---
proc zapp_dispatch_event(windowId, eventId, w, h, x, y: cint): cint {.exportc, cdecl.} =
  if not inBounds(windowId, eventId): return EVENT_ALLOW
  # Layer 1: native callback (cancelable)
  let cb = gEventCbs[windowId][eventId]
  if cb != nil:
    # WindowEventData layout is opaque to Batch 1's native cbs (none registered yet);
    # pass nil — real native-cb data struct lands when the native callback API ports.
    let r = cb(nil)
    if r != 0: return r
  # Layer 1.5: JS close-guard
  if eventId == weClose.cint and gCloseGuard[windowId] != 0:
    zapp_dispatch_event_to_js(windowId, eventId, 0, 0, 0, 0)
    return EVENT_CANCEL
  # Layer 2: JS bridge (gated on subscription)
  if (gJsListeners[windowId] and (1'u32 shl eventId.uint32)) != 0:
    zapp_dispatch_event_to_js(windowId, eventId, w, h, x, y)
  # Layer 3: worker fan-out — DEFERRED (gated on backend bitmask, never set in Batch 1)
  if (gBackendListeners[windowId] and (1'u32 shl eventId.uint32)) != 0:
    workerBroadcastEvalJs(cstring"")   # TEMP no-op
  return EVENT_ALLOW
```
> Confirm `WindowEventData` handling against `callbacks.zc` — Batch 1 has NO native event callbacks registered (the user-facing `Window.on(event)` native path is later), so passing `nil` is safe; if `callbacks.zc` builds a real struct, note it but keep the nil path (unreached) for Batch 1. Confirm `ZAPP_MAX_WINDOW_EVENT_TYPES`.

- [ ] **Step 5: Run, verify PASS.** Run: `cd native/nim && nim c --mm:orc --threads:on -r tests/callbacks_test.nim 2>&1 | tail -5` → `callbacks ok`.

- [ ] **Step 6: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/events.nim native/nim/callbacks.nim native/nim/tests/callbacks_test.nim
git commit -m "$(printf 'feat(nim): events.nim + callbacks.nim — window event dispatch\n\nPort events.zc enums + callbacks.zc registries/bitmask + zapp_dispatch_event.\nJS delivery delegates to the untouched window.m zapp_dispatch_event_to_js\n(importc, gated on the JS-subscription bitmask); worker fan-out is a deferred\nno-op (Batch 4/7). Nim-tested bitmask gating.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: `app_events.nim` (`zapp_app_dispatch`)

**Files:**
- Create: `native/nim/app_events.nim`

- [ ] **Step 1: Implement `app_events.nim`** (native app callbacks + webview fan-out via `darwin_webview_eval_all`; worker broadcast deferred):
```nim
import std/strutils

const
  ZAPP_APP_EVENT_BASE = 100
  ZAPP_MAX_APP_EVENT_TYPES = 17     # confirm vs app_events.zc (covers 100..116)
  ZAPP_MAX_APP_CALLBACKS = 8        # confirm vs app_events.zc

type AppEventCb = proc(eventId: cint, data: cstring) {.cdecl.}
var gAppCbs: array[ZAPP_MAX_APP_EVENT_TYPES, array[ZAPP_MAX_APP_CALLBACKS, AppEventCb]]

proc zapp_app_on(eventId: cint, cb: AppEventCb) {.exportc, cdecl.} =
  let idx = eventId - ZAPP_APP_EVENT_BASE
  if idx < 0 or idx >= ZAPP_MAX_APP_EVENT_TYPES: return
  for i in 0 ..< ZAPP_MAX_APP_CALLBACKS:
    if gAppCbs[idx][i] == nil: (gAppCbs[idx][i] = cb; return)

proc darwin_webview_eval_all(js: cstring) {.importc, cdecl.}
proc workerBroadcastAppEvent(js: cstring) = discard   # TEMP deferred (Batch 4/7)

# event_id -> webview JS name (exact map from app_events.zc Layer 3)
proc appEventJsName(eventId: cint): string =
  case eventId
  of 104: "app:reopen"
  of 105: "app:open-url"
  of 106: "app:active"
  of 107: "app:inactive"
  of 108: "app:theme-changed"
  else: ""   # extend with any 109..116 cases present in app_events.zc

proc zapp_app_dispatch(eventId: cint, data: cstring): cint {.exportc, cdecl.} =
  let idx = eventId - ZAPP_APP_EVENT_BASE
  if idx < 0 or idx >= ZAPP_MAX_APP_EVENT_TYPES: return 0
  # Layer 1: native callbacks
  var fired: cint = 0
  for i in 0 ..< ZAPP_MAX_APP_CALLBACKS:
    if gAppCbs[idx][i] != nil:
      gAppCbs[idx][i](eventId, data); inc fired
  # Layer 2: worker broadcast — DEFERRED
  workerBroadcastAppEvent(cstring"")
  # Layer 3: webview fan-out (skip STARTED/SHUTDOWN)
  if eventId != 100 and eventId != 101:
    let name = appEventJsName(eventId)
    if name.len > 0:
      let safe = (if data.isNil: "{}" else: $data)
      let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
               "if(b&&b._onEvent)b._onEvent('" & name & "','" & safe & "');})();"
      darwin_webview_eval_all(js.cstring)
  return fired
```
> Confirm `ZAPP_MAX_APP_EVENT_TYPES`/`ZAPP_MAX_APP_CALLBACKS` + the FULL `appEventJsName` case set against `native/app/app_events.zc` (there may be 109..116 power/sleep/screen events). Match exactly. (`$data` of the cstring data is fine — main thread, ORC ok; if `data` is already JSON it's passed through, matching the zc `'%s'` formatting. Escaping parity: the zc path does NOT escape `data` either, so this matches.)

- [ ] **Step 2: Compile-check** (no standalone test — it delegates to `.m`; the gate is the integration smoke in Task 4):
Run: `cd native/nim && nim c --mm:orc --threads:on -c app_events.nim 2>&1 | tail -8` — Expected: compiles (the `importc`/`exportc` resolve at final link, not here; `-c` should still type-check; if it complains about the undefined `darwin_webview_eval_all` at link, that's fine — it's satisfied in the full build).

- [ ] **Step 3: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/app_events.nim
git commit -m "$(printf 'feat(nim): app_events.nim — zapp_app_dispatch\n\nPort app_events.zc: native app-callback registry + webview fan-out via the\nuntouched webview.m darwin_webview_eval_all (_onEvent IIFE, exact name map).\nWorker broadcast deferred (Batch 4/7). STARTED/SHUTDOWN not forwarded to\nwebviews, matching zc.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 3: Router `subscribe`/`unsubscribe` block + `event_name_to_id`

**Files:**
- Modify: `native/nim/router.nim`
- Test: `native/nim/tests/router_subscribe_test.nim`

- [ ] **Step 1: Failing test for `eventNameToId`** (pure):
```nim
import ../router
proc test() =
  doAssert eventNameToId("window:ready") == 0
  doAssert eventNameToId("window:resize") == 3
  doAssert eventNameToId("window:close") == 5
  doAssert eventNameToId("window:unfullscreen") == 10
  doAssert eventNameToId("resize") == 3        # prefix optional
  doAssert eventNameToId("window:bogus") == -1
  echo "router subscribe ok"
test()
```
> NB: `eventNameToId` must be exported (`*`) for the test. The test imports `../router`, which imports clipboard/bridge/etc.; if that pulls platform `importc`s that don't resolve in a `-r` run, instead put `eventNameToId` in a tiny importable helper OR run the test with the needed `{.passL.}`/stubs. Simplest: keep `eventNameToId` a pure proc with no platform deps and ensure the test only triggers that path. If `router`'s imports block a standalone `-r`, move `eventNameToId` into `events.nim` (pure) and test it there.

- [ ] **Step 2: Run, verify FAIL.** `cd native/nim && nim c --mm:orc --threads:on -r tests/router_subscribe_test.nim 2>&1 | tail -8` — FAIL (`eventNameToId` undefined).

- [ ] **Step 3: Add `eventNameToId` + the subscribe block to `router.nim`.** Add the pure mapper (exact table from router.zc:356-374) and, in `routeMessage`, a `t==4` `subscribe`/`unsubscribe` branch BEFORE the `if f.t != 1: return` (which currently drops t:4):
```nim
import callbacks   # zapp_window_set_js_listener

proc eventNameToId*(name: string): int =
  var n = name
  if n.startsWith("window:"): n = n[7 .. ^1]
  case n
  of "ready": 0
  of "focus": 1
  of "blur": 2
  of "resize": 3
  of "move": 4
  of "close": 5
  of "minimize": 6
  of "maximize": 7
  of "restore": 8
  of "fullscreen": 9
  of "unfullscreen": 10
  else: -1
```
In `routeMessage` (replace the bare `if f.t != 1: return` guard with the subscribe handling first):
```nim
  # t:4 window-action — Batch 1 handles only subscribe/unsubscribe (the rest is Batch 5).
  if f.t == 4 and (f.m == "subscribe" or f.m == "unsubscribe"):
    let evName = f.a{"event"}.getStr("")
    let evId = eventNameToId(evName)
    if evId >= 0:
      zapp_window_set_js_listener(windowId.cint, evId.cint, (if f.m == "subscribe": 1.cint else: 0.cint))
    return
  if f.t != 1: return
```
> `zapp_window_set_js_listener` is the `{.exportc.}` from callbacks.nim — import `callbacks` so the Nim name resolves. Confirm `routeMessage`'s frame field names (`f.t`,`f.m`,`f.a`) match bridge.nim's `BridgeMsg`. `__notif:` subscribe (the notification bridge-ready flush) is deferred — only `window:*` matters for Batch 1.

- [ ] **Step 4: Run, verify PASS.** `cd native/nim && nim c --mm:orc --threads:on -r tests/router_subscribe_test.nim 2>&1 | tail -5` → `router subscribe ok`. (If router's imports block the standalone `-r`, apply the Step-1 NB fallback: move `eventNameToId` to `events.nim` + test there.)

- [ ] **Step 5: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim native/nim/tests/router_subscribe_test.nim
git commit -m "$(printf 'feat(nim): router subscribe/unsubscribe block + eventNameToId\n\nThe webview posts {t:4,m:subscribe,a:{event:window:...}} when a JS listener\nis added; route it to callbacks.zapp_window_set_js_listener so event\ndelivery is gated correctly. eventNameToId mirrors router.zc:356-374. Only\nwindow:* subscribe in Batch 1 (rest of t:4 = Batch 5).\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 4: Wire into the build + GATE (window+app events reach JS)

**Files:**
- Modify: `native/nim/zapp.nim` (remove the two stubs; import the new modules)
- Modify: `native/nim/app.nim` if needed (no change expected)

- [ ] **Step 1: Remove the stubs + import the new modules in `zapp.nim`.** Delete the `zapp_dispatch_event` and `zapp_app_dispatch` `{.exportc.}` stub procs (now real in callbacks.nim/app_events.nim — duplicate symbol otherwise). Add imports (UnusedImport-suppressed, like the other exportc-only modules) so their `{.exportc.}` symbols are compiled in:
```nim
{.push warning[UnusedImport]: off.}
import callbacks, app_events
{.pop.}
```
KEEP the worker-delivery stubs (`dispatch_event_to_all`, `worker_post_message`, `worker_broadcast_eval_js` if present, etc.) — still deferred. Also confirm whether `zapp_window_set_on_ready`/`set_event_cb`/etc. were previously stubbed or referenced anywhere (grep `native/nim/`); if `window.nim` referenced a stub for any, it's now provided by callbacks.nim — remove the dup.

- [ ] **Step 2: Build hello-world on the Nim build.**
Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -6`
Expected: `[zapp] build complete:`. Resolve any duplicate-symbol (a leftover stub) or undefined-symbol (a missing `set_*` export the `.m`/router needs — add it to callbacks.nim).

- [ ] **Step 3: GATE — verify window + app events reach JS.** The hello-world demo registers window event listeners (`Window.on('resize'|'focus'|...)`) and may show/log them. Launch the app and exercise events:
```bash
BIN=/Users/zach/code/zapp/hello-world/bin/hello-world
"$BIN" >/tmp/events.log 2>&1 & PID=$!; sleep 2
# (resize/focus the window manually if interactive; or use AppleScript to resize)
osascript -e 'tell application "System Events" to tell (first process whose frontmost is true) to set size of front window to {700, 500}' 2>/dev/null || true
sleep 2; kill -INT $PID 2>/dev/null; wait $PID 2>/dev/null
```
**GATE passes when:** the demo's JS event listeners fire (visible in the UI or logged) — i.e. resizing/focusing the window reaches `window:resize`/`window:focus`, and a theme change reaches `app:theme-changed`. If you can't drive events headlessly, set an lldb breakpoint on `zapp_dispatch_event_to_js` and confirm it's called for the right `event_id` after the webview subscribes (i.e. the bitmask gate opened). Record the evidence. **This is a human-smoke milestone** — the controller will confirm with the user.

- [ ] **Step 4: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/zapp.nim native/nim/app.nim
git commit -m "$(printf 'feat(nim): wire event dispatch into the build (Batch 1 gate)\n\nRemove the zapp_dispatch_event/zapp_app_dispatch stubs (now real in\ncallbacks.nim/app_events.nim); import the modules for their exportc symbols.\nhello-world window + app events now reach the webview JS on the Nim build.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Self-review notes (for the executor)

- **The delegation insight is what keeps this small:** Nim owns the registries/bitmask/dispatch *decisions*; the actual JS eval lives in the untouched `.m` (`zapp_dispatch_event_to_js`, `darwin_webview_eval_all`), so the wire shape is automatically identical to zc — no IIFE re-synthesis for window events.
- **Worker fan-out is deferred** (local no-op stubs) — backend/worker bitmask is never set in Batch 1, so Layer 3 (window) is unreached; app Layer 2 is a no-op. Real worker delivery = Batch 4/7. Do NOT call `zjs_broadcast_eval_js` (hello-world doesn't link zjs).
- **Confirm the constants** (`ZAPP_MAX_WINDOW_EVENT_TYPES`, app limits, the full app-event JS-name map) against the `.zc` source — don't trust the plan's guesses (17/8); read app_events.zc.
- **Reconcile the `set_*` exportc surface** against existing skeleton stubs (grep `native/nim/`) to avoid duplicate symbols.
- **The gate is a human smoke** (window/app events visibly reach JS) — pause for the user, like the skeleton's sub-gate A / gate B.
- Scope: ONLY these 3 modules + the subscribe block. NOT the rest of the t:4 router surface, NOT worker delivery, NOT the native `Window.on()` callback data struct.
