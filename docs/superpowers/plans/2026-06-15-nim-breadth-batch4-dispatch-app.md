# Nim Breadth Batch 4 — Bridge/Dispatch + App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make window/app events reach the headless worker (close the B1 Layer-3 deferral) and replace the hardcoded app-config stubs with real `AppConfig` reads + the user-facing `Inspectable` enum.

**Architecture:** New leaf `dispatch.nim` (worker-broadcast helpers: real escaping `zapp_escape_dup`, `worker_broadcast_eval_js`→zjs, `dispatch_event_to_all`) wired into `callbacks.nim`/`app_events.nim` Layer-3/2. New leaf `appconfig.nim` (`Inspectable {.pure.}` enum + `AppConfig` + the `app_get_bootstrap_*` getters) wired into `app.nim`/`zapp.nim`. Both replace `zapp.nim` stubs.

**Tech Stack:** Nim (`--mm:orc`, `std/strutils`), libc via `importc`, Nim unit tests (`nim c -r --hints:off`).

---

## Background

- **Branch:** `feat/nim-native`. Additive to the Nim layer; `zc` path untouched.
- **The B1 deferral this closes:** `callbacks.nim` Layer-3 (`workerBroadcastEvalJs(cstring"")`, a `discard` stub) and `app_events.nim` Layer-2 (`workerBroadcastAppEvent(cstring"")` stub) never deliver events to workers. This batch makes them real via `zjs_broadcast_eval_js` (in zjs.c, in the build).
- **Exact IIFE shapes (from the zc — reproduce verbatim):**
  - `dispatch_event_to_all` (dispatch.zc:138): `(function(){var b=globalThis[Symbol.for('zapp.bridge')];if(b&&typeof b._onEvent==='function'){b._onEvent('<name>','<payload>');}})();` — **name + payload escaped**, to all webviews + all workers.
  - window→worker (callbacks.zc:131-136): `(function(){var b=globalThis[Symbol.for('zapp.bridge')];if(b&&typeof b._onEvent==='function'){b._onEvent('window:event','{"windowId":<N>,"event":<N>,"w":<N>,"h":<N>,"x":<N>,"y":<N>}');}})();` — **all integers, NO escaping**.
  - app→worker (app_events.zc:59-64): `(function(){var b=self.__zappBridge||globalThis.__zappBridge;if(b&&b._dispatchAppEvent)b._dispatchAppEvent(<eventId>,'<data>');})();` — worker-context bridge, `_dispatchAppEvent`, **unescaped passthrough** (data, or `""`), broadcast for ALL events (no STARTED/SHUTDOWN skip — that skip is webview-only).
- **`zapp_escape_dup`:** the real one (dispatch.zc:30) escapes `\` `'` `\n` `\r` + `malloc(2n+1)`; zjs.c calls it + frees the result. The current `zapp.nim:257` stub only `strdup`s (no escaping) — a latent bug. This batch ports the real one (libc, POD → gcsafe + thread-safe).
- **AppConfig** (app.zc:302): `{name, applicationShouldTerminateAfterLastWindowClosed, webContentInspectable: ZappInspectable{Auto,On,Off}, maxWorkers}`. Getter resolves `Auto → zapp_build_dev_tools_default() > 0` (app.zc:52-56).
- **Convention** (2026-06-15-nim-type-modeling-convention-design.md): `{.pure.}` enums, module = namespace, C-ABI ordinal boundary. `Inspectable` lands here.
- **Nim test pattern:** standalone `.nim` in `native/nim/tests/`, `import ../<module>`, `proc test()` + `doAssert`, prints `"<name> ok"`, run `nim c -r --hints:off <file>.nim` from `native/nim/tests/` (`nim`=`/opt/homebrew/bin/nim`). A module that `importc`s a C symbol gets an `{.exportc.}` stub in the test (like `callbacks_test.nim` stubs `zapp_dispatch_event_to_js`). **`{.exportc.}` procs a test calls by Nim name also need `*`** (Batch 2 lesson).
- **STANDING CONSTRAINT — never `git add -A`.** Stage only the explicit paths per commit. Never `hello-world/`, `vendor/`, `kitchen-sink/`, user-WIP.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/dispatch.nim` | Worker-broadcast helpers (escape, broadcast, event-to-all) | **Create** |
| `native/nim/tests/dispatch_test.nim` | dispatch unit test | Create |
| `native/nim/callbacks.nim` | Window event Layer-3 worker fan-out | Modify |
| `native/nim/app_events.nim` | App event Layer-2 worker fan-out | Modify |
| `native/nim/appconfig.nim` | `Inspectable` enum + `AppConfig` + getters | **Create** |
| `native/nim/tests/appconfig_test.nim` | appconfig unit test | Create |
| `native/nim/app.nim` | Store AppConfig at `newApp` | Modify |
| `native/nim/zapp.nim` | Remove dispatch + app-config stubs; pass config | Modify |
| `native/nim/tests/callbacks_test.nim` | Add dispatch stubs + window:event assertion | Modify |

---

## Task 1: `dispatch.nim` — escape + broadcast + event-to-all (standalone)

**Files:** Create `native/nim/dispatch.nim`, `native/nim/tests/dispatch_test.nim`.

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/dispatch_test.nim`:
```nim
import ../dispatch
import std/strutils

# dispatch.nim importc's these C symbols (zjs.c / webview.m in the real build);
# stub them here to capture what would be eval'd.
var webviewJs = ""
proc darwin_webview_eval_all(js: cstring) {.exportc, cdecl.} = webviewJs = $js
var workerJs = ""
proc zjs_broadcast_eval_js(js: cstring) {.exportc, cdecl.} = workerJs = $js

proc test() =
  # escapeJs: backslash, quote, newline, CR
  doAssert escapeJs("a'b\nc\\d\re") == "a\\'b\\nc\\\\d\\re"
  # zapp_escape_dup (libc): same rules; nil -> ""
  doAssert $zapp_escape_dup(cstring"x'y") == "x\\'y"
  doAssert $zapp_escape_dup(nil) == ""
  # dispatch_event_to_all: escaped _onEvent IIFE to BOTH webviews + workers
  dispatch_event_to_all(cstring"app:theme-changed", cstring"{\"v\":\"a'b\"}")
  doAssert webviewJs.contains("b._onEvent('app:theme-changed','{\\\"v\\\":\\\"a\\'b\\\"}')")
  doAssert webviewJs.contains("Symbol.for('zapp.bridge')")
  doAssert workerJs == webviewJs        # same IIFE to both
  echo "dispatch ok"
test()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off dispatch_test.nim 2>&1 | tail -5`
Expected: FAIL — cannot open `../dispatch`.

- [ ] **Step 3: Write `native/nim/dispatch.nim`**

```nim
## Bridge dispatch — native→JS broadcast helpers, ported from
## native/bridge/dispatch.zc. Leaf module (no back-imports) so callbacks.nim /
## app_events.nim use it without an import cycle.
##
## zapp_escape_dup is the worker-safe libc escaper (zjs.c calls it AND frees the
## result), replacing the perf-gate strdup stub. The Nim IIFE builders run on the
## Cocoa main thread (event dispatch), so escapeJs (Nim string) is fine there.

import std/strutils

proc c_malloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_strlen(s: cstring): csize_t {.importc: "strlen", header: "<string.h>".}

# Broadcast primitives from the compiled engine / platform layer.
proc zjs_broadcast_eval_js(js: cstring) {.importc, cdecl.}
proc darwin_webview_eval_all(js: cstring) {.importc, cdecl.}

# zapp_escape_dup — escape (\ ' \n \r) + malloc(2n+1); caller frees. zjs.c
# consumes + frees this for worker→webview payloads. POD/libc (no Nim heap) →
# gcsafe + thread-safe. Replaces the zapp.nim strdup-only stub (a latent bug:
# payloads with quotes/newlines broke the injected JS).
proc zapp_escape_dup*(src: cstring): cstring {.exportc, cdecl, gcsafe.} =
  let n = (if src.isNil: 0 else: c_strlen(src).int)
  let dst = cast[ptr UncheckedArray[char]](c_malloc(csize_t(n * 2 + 1)))
  if dst == nil: return nil
  var j = 0
  if not src.isNil:
    let s = cast[ptr UncheckedArray[char]](src)
    for i in 0 ..< n:
      let c = s[i]
      case c
      of '\\': dst[j] = '\\'; inc j; dst[j] = '\\'; inc j
      of '\'': dst[j] = '\\'; inc j; dst[j] = '\''; inc j
      of '\n': dst[j] = '\\'; inc j; dst[j] = 'n'; inc j
      of '\r': dst[j] = '\\'; inc j; dst[j] = 'r'; inc j
      else: dst[j] = c; inc j
  dst[j] = '\0'
  cast[cstring](dst)

# worker_broadcast_eval_js — fan a JS snippet to every worker. {.exportc.} so the
# B6/B8 native-emit .m sites (shortcuts/menu/tray/sync) link against it; the Nim
# dispatch path calls it now. zjs-only build → zjs_broadcast_eval_js.
proc worker_broadcast_eval_js*(js: cstring) {.exportc, cdecl.} =
  zjs_broadcast_eval_js(js)

# escapeJs — Nim main-thread escaper for the IIFE builders (same rules as
# zapp_escape_dup; used where the source is a Nim string).
proc escapeJs*(s: string): string =
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '\'': result.add "\\'"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    else: result.add c

# dispatch_event_to_all — global event broadcast (dispatch.zc:138): the _onEvent
# IIFE (name + payload escaped) to every webview + every worker.
proc dispatch_event_to_all*(eventName: cstring, payload: cstring)
    {.exportc, cdecl, gcsafe.} =
  let name = escapeJs(if eventName.isNil: "" else: $eventName)
  let pl = escapeJs(if payload.isNil: "" else: $payload)
  let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
           "if(b&&typeof b._onEvent==='function'){" &
           "b._onEvent('" & name & "','" & pl & "');}})();"
  darwin_webview_eval_all(js.cstring)
  worker_broadcast_eval_js(js.cstring)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off dispatch_test.nim 2>&1 | tail -5`
Expected: PASS — `dispatch ok`.
(If `{.gcsafe.}` on `dispatch_event_to_all` is rejected for the local Nim-string build, that means a stray *global* GC access — there is none here, so it should pass; if a genuine Nim wrinkle blocks it, drop the `gcsafe` pragma on `dispatch_event_to_all` only — the C ABI doesn't require it and dispatch is main-thread — and note it. `zapp_escape_dup`/`worker_broadcast_eval_js` MUST keep `gcsafe`/POD.)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/dispatch.nim native/nim/tests/dispatch_test.nim
git commit -m "$(printf 'feat(nim): dispatch.nim — escape + worker broadcast + event-to-all (Batch 4)\n\nReal escaping zapp_escape_dup (libc, replaces the strdup stub),\nworker_broadcast_eval_js->zjs_broadcast_eval_js, dispatch_event_to_all\n(escaped _onEvent IIFE to webviews + workers), escapeJs helper. Leaf module,\nstandalone unit-tested. Mirrors bridge/dispatch.zc.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: Wire worker fan-out (callbacks Layer-3 + app_events Layer-2) → build

**Files:** Modify `native/nim/callbacks.nim`, `native/nim/app_events.nim`, `native/nim/zapp.nim`, `native/nim/tests/callbacks_test.nim`.

- [ ] **Step 1: callbacks.nim — import dispatch + real window:event Layer-3**

In `native/nim/callbacks.nim`: add `dispatch` to the imports (`import events, coretypes` → `import events, coretypes, dispatch`). **Delete** the stub `proc workerBroadcastEvalJs(js: cstring) = discard` (line ~84). Replace the Layer-3 block (currently `if (gBackendListeners[windowId] and (1'u32 shl eventId.uint32)) != 0:` / `workerBroadcastEvalJs(cstring"")`):
```nim
  # Layer 3: backend worker fan-out — build the window:event IIFE (all-integer,
  # no escaping) and broadcast (callbacks.zc:131-136).
  if (gBackendListeners[windowId] and (1'u32 shl eventId.uint32)) != 0:
    let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
             "if(b&&typeof b._onEvent==='function'){" &
             "b._onEvent('window:event','{\"windowId\":" & $windowId &
             ",\"event\":" & $eventId & ",\"w\":" & $w & ",\"h\":" & $h &
             ",\"x\":" & $x & ",\"y\":" & $y & "}');}})();"
    worker_broadcast_eval_js(js.cstring)
```

- [ ] **Step 2: app_events.nim — import dispatch + real `_dispatchAppEvent` Layer-2**

In `native/nim/app_events.nim`: add `dispatch` to the imports. Replace the Layer-2 stub (`workerBroadcastAppEvent(cstring"")` and its stub proc if present) with the worker broadcast (app_events.zc:59-64 — `_dispatchAppEvent`, unescaped passthrough, ALL events):
```nim
  # Layer 2: broadcast to every worker via _dispatchAppEvent (app_events.zc:59-64).
  block:
    let safeData = (if data.isNil: "" else: $data)
    let wjs = "(function(){var b=self.__zappBridge||globalThis.__zappBridge;" &
              "if(b&&b._dispatchAppEvent)b._dispatchAppEvent(" & $eventId &
              ",'" & safeData & "');})();"
    worker_broadcast_eval_js(wjs.cstring)
```
(If a `proc workerBroadcastAppEvent(...) = discard` stub exists, delete it.)

- [ ] **Step 3: Remove the zapp.nim dispatch stubs**

In `native/nim/zapp.nim`, delete the two stubs now provided by `dispatch.nim`:
- `dispatch_event_to_all` (~line 218-221, the `# Fire-and-forget fan-out…` comment + `proc dispatch_event_to_all(...) = discard`).
- `zapp_escape_dup` (~line 255-258, the `proc c_strdup` + `zapp_escape_dup` strdup stub — **delete only `zapp_escape_dup`; if `c_strdup` is used elsewhere in zapp.nim keep it**, else delete it too). Verify with `rg -n "c_strdup|zapp_escape_dup" native/nim/zapp.nim` after.

`callbacks.nim`/`app_events.nim` now `import dispatch`, pulling it into the build graph so its `{.exportc.}` symbols replace the removed stubs.

- [ ] **Step 4: Update callbacks_test stubs + add the window:event assertion**

`callbacks.nim` now imports `dispatch`, which `importc`s `zjs_broadcast_eval_js` + `darwin_webview_eval_all` — so `callbacks_test.nim` must provide those stubs to link. In `native/nim/tests/callbacks_test.nim`, add near the top (alongside the existing `zapp_dispatch_event_to_js` stub):
```nim
var workerJs = ""
proc zjs_broadcast_eval_js(js: cstring) {.exportc, cdecl.} = workerJs = $js
proc darwin_webview_eval_all(js: cstring) {.exportc, cdecl.} = discard
```
Then add, inside `test()` (after the existing assertions), a backend-listener + window:event check:
```nim
  zapp_window_set_backend_listener(2, 3, 1)   # window 2 subscribes worker to event 3 (resize)
  workerJs = ""
  discard zapp_dispatch_event(2, 3, 100, 200, 0, 0)
  doAssert workerJs.contains("b._onEvent('window:event'")
  doAssert workerJs.contains("\"event\":3")
  doAssert workerJs.contains("\"w\":100")
```
(`zapp_window_set_backend_listener` is the existing exportc in callbacks.nim.)

- [ ] **Step 5: Run callbacks_test + dispatch_test**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in dispatch_test callbacks_test; do nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: `dispatch ok`, `callbacks ok`.

- [ ] **Step 6: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Duplicate `dispatch_event_to_all`/`zapp_escape_dup` → a zapp.nim stub wasn't removed; undefined `zjs_broadcast_eval_js` → check the dispatch.nim importc name.) Do NOT `git add` `hello-world/`.

- [ ] **Step 7: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/callbacks.nim native/nim/app_events.nim native/nim/zapp.nim native/nim/tests/callbacks_test.nim
git commit -m "$(printf 'feat(nim): wire worker fan-out (window + app events) via dispatch (Batch 4)\n\ncallbacks.nim Layer-3 broadcasts the window:event IIFE; app_events.nim Layer-2\nbroadcasts _dispatchAppEvent; both via dispatch.worker_broadcast_eval_js. Drop\nthe zapp.nim dispatch_event_to_all + zapp_escape_dup stubs (now in dispatch.nim).\nCloses the Batch 1 Layer-3 deferral — events reach the headless worker.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 3: `appconfig.nim` — `Inspectable` enum + AppConfig + getters (standalone)

**Files:** Create `native/nim/appconfig.nim`, `native/nim/tests/appconfig_test.nim`.

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/appconfig_test.nim`:
```nim
import ../appconfig

# appconfig.nim importc's the CLI-generated dev-tools flag; stub it (return 1 = dev).
proc zapp_build_dev_tools_default(): cint {.exportc, cdecl.} = 1.cint

proc test() =
  setAppConfig(AppConfig(name: "My App",
                         terminateAfterLastWindowClosed: true,
                         inspectable: Inspectable.Auto,
                         maxWorkers: 4))
  doAssert $app_get_bootstrap_name() == "My App"
  doAssert app_get_bootstrap_max_workers() == 4
  doAssert app_get_bootstrap_application_should_terminate_after_last_window_closed()
  # Auto + dev_tools=1 -> inspectable true
  doAssert app_get_bootstrap_web_content_inspectable()
  setAppConfig(AppConfig(name: "X", terminateAfterLastWindowClosed: false,
                         inspectable: Inspectable.Off, maxWorkers: 0))
  doAssert not app_get_bootstrap_web_content_inspectable()       # Off -> false
  doAssert not app_get_bootstrap_application_should_terminate_after_last_window_closed()
  setAppConfig(AppConfig(name: "Y", terminateAfterLastWindowClosed: true,
                         inspectable: Inspectable.On, maxWorkers: 0))
  doAssert app_get_bootstrap_web_content_inspectable()           # On -> true
  doAssert $app_get_allowed_navigation_json() == ""             # security.zc not ported
  echo "appconfig ok"
test()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off appconfig_test.nim 2>&1 | tail -5`
Expected: FAIL — cannot open `../appconfig`.

- [ ] **Step 3: Write `native/nim/appconfig.nim`**

```nim
## App config — the AppConfig value + the app_get_bootstrap_* getters webview.m
## reads at window creation. Ported from native/app/app.zc (AppConfig + the
## bootstrap accessors). Leaf module (only importc's the dev-tools flag) so it's
## unit-testable without booting the platform; app.nim sets the config at newApp.
##
## Inspectable {.pure.} is the user-facing config enum (the type-modeling
## convention's deferred item, mirroring app.zc:296 ZappInspectable) — distinct
## from the window-tag coretypes.TriState: this resolves to a bool at the getter.

type
  Inspectable* {.pure.} = enum
    Auto   ## dev-gated: on when dev-tools are enabled
    On
    Off

  AppConfig* = object
    name*: string
    terminateAfterLastWindowClosed*: bool
    inspectable*: Inspectable
    maxWorkers*: int32

# CLI-emitted dev-tools flag (1 in dev, 0 in prod) — resolves Inspectable.Auto.
proc zapp_build_dev_tools_default(): cint {.importc, cdecl.}

var gAppConfig = AppConfig(
  name: "Zapp", terminateAfterLastWindowClosed: true,
  inspectable: Inspectable.Auto, maxWorkers: 0)

proc setAppConfig*(c: AppConfig) =
  ## Called once at newApp (app.nim) before any window/worker exists.
  gAppConfig = c

# --- C-ABI getters (webview.m reads these at window creation) ----------------
var gName = "Zapp"   # module-let backing for the returned cstring (lifetime rule)

proc app_get_bootstrap_name*(): cstring {.exportc, cdecl.} =
  gName = gAppConfig.name
  gName.cstring

proc app_get_bootstrap_web_content_inspectable*(): bool {.exportc, cdecl.} =
  case gAppConfig.inspectable
  of Inspectable.On: true
  of Inspectable.Off: false
  of Inspectable.Auto: zapp_build_dev_tools_default() > 0

proc app_get_bootstrap_application_should_terminate_after_last_window_closed*(): bool
    {.exportc, cdecl.} =
  gAppConfig.terminateAfterLastWindowClosed

proc app_get_bootstrap_max_workers*(): cint {.exportc, cdecl.} =
  gAppConfig.maxWorkers.cint

proc app_get_allowed_navigation_json*(): cstring {.exportc, cdecl.} =
  ## security.zc (the nav allowlist) is not ported — "" = no extra allowlist.
  "".cstring
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off appconfig_test.nim 2>&1 | tail -5`
Expected: PASS — `appconfig ok`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/appconfig.nim native/nim/tests/appconfig_test.nim
git commit -m "$(printf 'feat(nim): appconfig.nim — Inspectable enum + AppConfig + getters (Batch 4)\n\nUser-facing Inspectable {.pure.} = Auto/On/Off (the convention deferral),\nAppConfig value, and the app_get_bootstrap_* getters resolving Auto via\nzapp_build_dev_tools_default. Leaf module, standalone unit-tested. Mirrors\napp.zc AppConfig + bootstrap accessors.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 4: Wire app config + remove zapp.nim stubs → GATE

**Files:** Modify `native/nim/app.nim`, `native/nim/zapp.nim`.

- [ ] **Step 1: app.nim — import appconfig + store config at newApp**

In `native/nim/app.nim`: add `appconfig` to the imports (e.g. `import router, service, permissions` → add `appconfig`). Change `newApp` to set the app config. The current `newApp(name, terminateAfterLastWindowClosed = true)` builds an `App`; add a `setAppConfig(...)` call inside it before returning:
```nim
proc newApp*(name: string, terminateAfterLastWindowClosed = true): App =
  ## Mirrors App::new — init the platform, store the app config, return the value.
  platformInit(name)
  setAppConfig(AppConfig(
    name: name,
    terminateAfterLastWindowClosed: terminateAfterLastWindowClosed,
    inspectable: Inspectable.Auto,
    maxWorkers: 0))
  App(name: name, terminateAfterLastWindowClosed: terminateAfterLastWindowClosed)
```
(Keep the existing `App` object type + `run` as-is. The window-tag `opts.inspectable` boot assignment in zapp.nim is unrelated and stays.)

- [ ] **Step 2: Remove the four app-config stubs from zapp.nim**

In `native/nim/zapp.nim`, delete the stub block (the `# app_get_bootstrap_* …` comment + the four procs `app_get_bootstrap_name`, `app_get_bootstrap_web_content_inspectable`, `app_get_bootstrap_application_should_terminate_after_last_window_closed`, `app_get_bootstrap_max_workers`) AND the `app_get_allowed_navigation_json` stub. `appconfig.nim` (now in the graph via `app.nim`) provides them. Also delete the now-unused `gBootstrapName` `let` if it backed only those stubs (verify with `rg -n "gBootstrapName" native/nim/zapp.nim`).

After: `rg -n "app_get_bootstrap|app_get_allowed_navigation" native/nim/zapp.nim` → no matches.

- [ ] **Step 3: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4`
Expected: last line `[zapp] build complete: <path>`. (Duplicate `app_get_bootstrap_*` → a zapp.nim stub remains; undefined → the appconfig getters aren't `*`/exportc or app.nim didn't import appconfig.) Do NOT `git add` `hello-world/`.

- [ ] **Step 4: Regression — all Nim unit tests + codegen test**

Run:
```bash
cd /Users/zach/code/zapp/native/nim/tests && \
for t in dispatch_test appconfig_test callbacks_test app_events_test router_subscribe_test permissions_test service_registry_test service_lifecycle_test service_manifest_test service_cabi_test worker_service_test; do \
  [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done
```
Expected: each existing test prints its `… ok` (skip any that don't exist, e.g. `app_events_test`).
Run: `cd /Users/zach/code/zapp/cli && bun test src/build-config-nim.test.ts 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/app.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): wire AppConfig at newApp; drop app_get_bootstrap stubs (Batch 4)\n\napp.nim newApp stores the AppConfig (appconfig.setAppConfig); remove the four\napp_get_bootstrap_* + app_get_allowed_navigation_json zapp.nim stubs (now real\nin appconfig.nim). The injected bootstrapConfig reflects real AppConfig +\ndev-gated Inspectable.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 6: GATE — human smoke (controller pauses here)**

The unit + build gates already prove the logic. Optional runtime confirmation on the Nim build (`ZAPP_NATIVE_LANG=nim bun run dev`):
1. **Worker fan-out:** with the Web Inspector now available, attach lldb (`lldb -p <pid>`, `b zjs_broadcast_eval_js`, `c`) and trigger a window resize/focus or a theme change → the breakpoint hits with the `_onEvent`/`_dispatchAppEvent` IIFE. (Or, if the user's worker registers a `bridge.on(...)`/`_onEvent` listener, it logs `[zapp/<worker>] …`.)
2. **App config:** the webview's injected `globalThis[Symbol.for('zapp.bootstrapConfig')]` shows the real `name` + `inspectable` resolved (dev → true).

Do not proceed to the final review until the human confirms (or accepts the unit+build gate).

---

## Self-Review

**1. Spec coverage:**
- `dispatch.nim`: real `zapp_escape_dup` + `worker_broadcast_eval_js` + `dispatch_event_to_all` + `escapeJs` → Task 1. ✓
- callbacks Layer-3 window:event + app_events Layer-2 `_dispatchAppEvent` worker fan-out → Task 2. ✓
- Remove zapp.nim `dispatch_event_to_all` + `zapp_escape_dup` stubs → Task 2 Step 3. ✓
- `appconfig.nim`: `Inspectable {.pure.}` + AppConfig + getters → Task 3. ✓
- Wire app.nim newApp + remove 4 app-config stubs → Task 4. ✓
- Deferred (worker_eval_js/registry → B7; cancellation → B5) → not implemented; documented in spec + plan background. ✓
- Gate (worker fan-out + app config real + build + units) → Task 4 Steps 3-6. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step is complete. The `std/options` note in Task 3 Step 3 explicitly says to remove the unused import — not a placeholder.

**3. Type consistency:** `AppConfig{name, terminateAfterLastWindowClosed, inspectable: Inspectable, maxWorkers: int32}` + `setAppConfig(c: AppConfig)` + `Inspectable{.pure.} = Auto/On/Off` used identically in Tasks 3 (def + test) and 4 (newApp). `dispatch_event_to_all(eventName, payload: cstring)`, `worker_broadcast_eval_js(js: cstring)`, `zapp_escape_dup(src: cstring): cstring`, `escapeJs(s: string): string` consistent across Task 1 (def + test) and Task 2 (callers). The window:event IIFE field names (`windowId`/`event`/`w`/`h`/`x`/`y`) match callbacks.zc. ✓
