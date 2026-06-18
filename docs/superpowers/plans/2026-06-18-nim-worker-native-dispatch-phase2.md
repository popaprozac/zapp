# Nim Worker→Native Dispatch — Phase 2 (async-to-main, App-capable) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make a worker's `await Services.invoke(method, args)` a TRUE async call that marshals to the **main thread**, runs the real handler there with the real `App` (GC + AppKit valid), and resolves a Promise back in the worker — so workers can drive App/UI/stateful services. (Phase 1 gave the fast `invokeSync` pure path; this is the App-capable companion.)

**Architecture:** JS-owned Promise (no zjs Promise C API). A new zjs host fn `host_invoke_service_async` (gated to the nim build) returns a request id, stringifies args, and `dispatch_async(dispatch_get_main_queue(), …)` a block that calls a Nim main-thread entry `zapp_worker_invoke_on_main(workerId, id, method, argsJson)`. That entry runs the real `invokeService(method, parseJson(argsJson))` (uses `gCurrentApp` — real app, on main) and delivers the result back via `zjs_worker_eval_js(workerId, iife)` calling `bridge._resolveInvoke(id, ok, payload)`. **This mirrors two proven precedents**: the worker `_syncPending`/`dispatchSyncResult` round-trip (Sync.wait) and the webview `_onInvokeResult` resolve handler.

**Tech Stack:** C (zjs.c + GCD `dispatch_async`), Nim (main-thread entry, real registry), TS (`bootstrap/worker.ts` promise map, `runtime/services.ts`).

**Spec:** `docs/superpowers/specs/2026-06-18-nim-worker-native-dispatch-design.md` (Phase 2). Phase 1 (sync path) is already merged on this branch.

**Scope:**
- zjs.c is shared with the zc build → gate the async host fn behind a nim-build compile define; the zc build's worker `invoke` stays the existing sync alias (documented; zc async-from-worker is a future parity item).
- Low risk: the round-trip shape is already proven by `_syncPending`/`dispatchSyncResult`. No separate spike.

---

### Task 1: Nim main-thread invoke entry + nim-build compile define

**Files:**
- Modify: `native/nim/worker_service.nim` (or a small new proc) — `zapp_worker_invoke_on_main`
- Modify: `native/nim/zapp.nim` (add the nim-build define to the zjs.c `{.compile.}` flags)

- [ ] **Step 1: Read the precedents.** Read `bootstrap/worker.ts:196-213` (`dispatchSyncResult` + `_syncPending`), `native/platform/darwin/sync.m:276-295` (how main builds the IIFE + calls `zjs_worker_eval_js`), `native/nim/bridge.nim` `sendInvokeResponse` (the webview resolve-IIFE + JSON escaping), and `native/nim/worker.nim:110` (`worker_eval_js*` wrapper). You'll mirror these.

- [ ] **Step 2: Add the Nim main-thread entry.** In `native/nim/worker_service.nim`, add (runs on the MAIN thread — called from the dispatch_async block; uses the real registry + `gCurrentApp`, so it needs `import service` (invokeService) + std/json + the escape helper used by bridge.nim):
```nim
import std/[json, options]
# worker_eval_js (main→worker JS injection) + a JSON-string escaper for embedding.
proc worker_eval_js(workerId, js: cstring) {.importc, cdecl.}   # defined in worker.nim
proc zappEscapeForJs(s: string): string                        # reuse bridge.nim's escaper (import it)

proc zapp_worker_invoke_on_main(workerId: cstring, reqId: cint,
                                methodName: cstring, argsJson: cstring) {.exportc, cdecl.} =
  ## MAIN thread. Runs the real service registry (gCurrentApp valid here) for an
  ## async worker invoke, then resolves the worker-side promise via eval.
  var ok = true
  var payload: string
  try:
    let args = if argsJson.isNil or argsJson[0] == '\0': newJNull() else: parseJson($argsJson)
    let r = invokeService($methodName, args)     # real registry, real app
    if r.isSome: payload = r.get
    else: (ok = false; payload = "NOT_FOUND")
  except CatchableError as e:
    ok = false; payload = e.msg
  # Mirror the webview/sync IIFE shape; _resolveInvoke is added in Task 3.
  let iife = "(function(){var b=self.__zappBridge;if(b&&b._resolveInvoke){b._resolveInvoke(" &
             $reqId.int & "," & (if ok: "true" else: "false") & ",'" &
             zappEscapeForJs(payload) & "');}})();"
  worker_eval_js(workerId, iife.cstring)
```
(Adapt: reuse the EXACT escaper bridge.nim uses for `_onInvokeResult` payloads — import it rather than re-implementing. Confirm `invokeService`/`worker_eval_js` signatures. The `payload` is already a JSON string from the handler; `_resolveInvoke` will `JSON.parse` it, matching `_onInvokeResult`.)

- [ ] **Step 3: Define the nim-build gate for zjs.c.** In `native/nim/zapp.nim`, the `{.compile("../worker/engines/zjs.c", "<flags>").}` line — add `-DZAPP_NIM_BUILD` to its per-file clang flags so the async host fn (Task 2) compiles only in the nim build. (Read the current compile line; append the define to the existing flag string.)

- [ ] **Step 4: Build nim kitchen-sink** (proves the new Nim entry compiles/links; the host fn isn't added yet so it's just the entry + define): `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`. (`zapp_worker_invoke_on_main` may be unused-but-exported — fine, it's `{.exportc.}`.)

- [ ] **Step 5: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/worker_service.nim native/nim/zapp.nim
git commit -m "feat(nim): main-thread async worker-invoke entry + nim-build zjs define"
```
(Trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

---

### Task 2: zjs.c async host fn (marshal to main)

**Files:**
- Modify: `native/worker/engines/zjs.c`

- [ ] **Step 1: Add the async host fn (gated).** In `native/worker/engines/zjs.c`, near `host_invoke_service` (~line 456), add (inside `#ifdef ZAPP_NIM_BUILD … #endif`):
```c
#ifdef ZAPP_NIM_BUILD
extern void zapp_worker_invoke_on_main(const char* worker_id, int req_id,
                                       const char* method, const char* args_json);
static _Atomic int g_async_req_id = 1;

// __zappBridge.invokeServiceAsync(method, args?) -> request id (int).
// JS bootstrap wraps the id in a Promise; main resolves it via _resolveInvoke.
static ZjsValue host_invoke_service_async(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    ZjsWorkerSlot* slot = zjs_slot_for_ctx(ctx);
    if (!slot) return zjs_undefined();
    char* method = /* argv[0] -> C string, same as host_invoke_service does */;
    char* args_json = /* JSON.stringify(argv[1]) via the slot's cached stringify -> C string,
                         or strdup("null") if absent */;
    int id = atomic_fetch_add(&g_async_req_id, 1);
    // Copy strings for the block (freed inside the block after the call).
    char* wid = strdup(slot->worker_id);
    dispatch_async(dispatch_get_main_queue(), ^{
        zapp_worker_invoke_on_main(wid, id, method, args_json);  // runs on MAIN
        free(method); free(args_json); free(wid);
    });
    return zjs_new_int(ctx, id);   // use the engine's int constructor (match existing usage)
}
#endif
```
READ `host_invoke_service` (456-527) for the EXACT idioms: how it extracts the method string from `argv[0]`, how it stringifies `argv[1]` (the cached `JSON.stringify` / `json_stringify_root` on the slot), and the int-return constructor name. Mirror them. Free ownership: the block frees the heap copies after `zapp_worker_invoke_on_main` returns (that fn does its work synchronously on main before returning).

- [ ] **Step 2: Register the host fn on the bridge (gated).** Where `host_invoke_service` is registered (~`zjs.c:882-894`, `zjs_set_property(ctx, bridge, "invokeService", …)`), add inside `#ifdef ZAPP_NIM_BUILD`:
```c
    ZjsValue invoke_async_fn = zjs_register_host_function(ctx, "__zapp_invoke_service_async",
                                                          host_invoke_service_async);
    zjs_set_property(ctx, bridge, "invokeServiceAsync", invoke_async_fn);
```

- [ ] **Step 3: Build BOTH.**
  - Nim: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:` (the gated fn compiles; `dispatch_async`/GCD available on Apple).
  - zc: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:` (the `#ifdef` keeps the async fn OUT of the zc build — proves the gate works + zc still links).

- [ ] **Step 4: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/worker/engines/zjs.c
git commit -m "feat(zjs): async worker invoke host fn — marshal to main (nim build)"
```

---

### Task 3: Worker bootstrap promise plumbing + runtime routing

**Files:**
- Modify: `bootstrap/worker.ts` (pending map + `invokeAsync` + `_resolveInvoke`)
- Modify: `runtime/services.ts` (worker `invoke` → async when available)

- [ ] **Step 1: Add the JS-owned promise machinery.** In `bootstrap/worker.ts`, mirror the `_syncPending`/`dispatchSyncResult` shape (read it first). Add to the bridge:
```ts
// Async invoke (App-capable): host returns a request id; main resolves via _resolveInvoke.
bridge._pendingInvokes = bridge._pendingInvokes || {};
bridge.invokeAsync = function (method: string, args?: unknown): Promise<unknown> {
  if (typeof bridge.invokeServiceAsync !== "function") {
    // No async host fn (e.g. zc build) — fall back to the sync path.
    return Promise.resolve(bridge.invokeService(method, args));
  }
  const id = bridge.invokeServiceAsync(method, args) as number;
  return new Promise((resolve, reject) => { bridge._pendingInvokes[id] = { resolve, reject }; });
};
bridge._resolveInvoke = function (id: number, ok: boolean, payload: string): void {
  const p = bridge._pendingInvokes[id];
  if (!p) return;
  delete bridge._pendingInvokes[id];
  if (ok) resolve_with_parse(p, payload); else p.reject(new Error(payload));
};
```
(Match the file's existing style + how `dispatchSyncResult` parses/resolves. `payload` is a JSON string → `JSON.parse` on success, mirroring webview `_onInvokeResult`.)

- [ ] **Step 2: Route worker `invoke` → async.** Today `bridge.invoke = bridge.invokeService` (alias, `worker.ts:72`). Change it so `invoke` prefers the async path when available:
```ts
bridge.invoke = function (method: string, args?: unknown) { return bridge.invokeAsync(method, args); };
```
(`invokeAsync` itself falls back to sync when `invokeServiceAsync` is absent — so the zc build still works.)

- [ ] **Step 3: runtime/services.ts.** Ensure the worker-context `Services.invoke` returns the real async Promise (drop the sync `.value` shim for the worker `invoke` path at `services.ts:40-42` — `invokeSync` stays as-is for the sync API). Read the current branch and adjust so `invoke` is genuinely async in workers; `invokeSync` unchanged.

- [ ] **Step 4: tsc + build.**
  - `cd /Users/zach/code/zapp && bun run check` → tsc clean.
  - `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:` (bootstrap is bundled into the build).

- [ ] **Step 5: Commit.**
```bash
cd /Users/zach/code/zapp
git add bootstrap/worker.ts runtime/services.ts
git commit -m "feat(runtime): worker Services.invoke is a true async (marshal-to-main) Promise"
```

---

### Task 4 (GATE): kitchen-sink App-from-worker demo + smoke

**Files:**
- Modify: `kitchen-sink/` Workers section (a worker that calls an App-using service via `await Services.invoke`)
- Possibly modify: `kitchen-sink/zapp/app.nim` (add an App-using service, e.g. one that opens a window)

- [ ] **Step 1: Add an App-using service + a worker call.** In `kitchen-sink/zapp/app.nim`, add a service that uses the App (e.g. `proc openInfoWindow(app: App, args: JsonNode): string = discard app.window.create(WindowOptions(title:"From Worker", width:360, height:200)); "opened"`). In the kitchen-sink Workers section, add a button whose worker does `const r = await Services.invoke("openInfoWindow", {})` and reports `r`.

- [ ] **Step 2: Build nim kitchen-sink.** `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`.

- [ ] **Step 3: GATE — human smoke.** `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run dev`. Click the new Workers button → the worker's `await Services.invoke("openInfoWindow")` must open a real window (proving it ran on the MAIN thread with the real App) and resolve with `"opened"`. PAUSE for human confirmation.

- [ ] **Step 4: Commit.**
```bash
cd /Users/zach/code/zapp
git add kitchen-sink/zapp/app.nim kitchen-sink/src   # adjust to the actual edited paths
git commit -m "demo(kitchen-sink): open a window from a worker via async Services.invoke"
```

---

### Task 5: Docs + final gate

**Files:**
- Modify: `docs/api-reference.md`

- [ ] **Step 1: Document the async App-capable path.** Update the Services section: worker `Services.invoke` (async) marshals to the main thread and runs with the real App — use it for App/UI/stateful work from a worker; `invokeSync` stays the inline pure path. Update the context×path matrix to mark worker async `invoke` as **shipped** (no longer "planned"). Note the zc build's worker `invoke` currently falls back to sync (async-from-worker is nim-build today).

- [ ] **Step 2: Full gate.**
```bash
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build   # [zapp] build complete:
cd /Users/zach/code/zapp/kitchen-sink && bun run build                         # [zapp] build complete: (zc, gate proves #ifdef)
cd /Users/zach/code/zapp && bun run check                                      # tsc clean
cd /Users/zach/code/zapp/cli && bun test src                                   # all pass
cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --mm:orc --threads:on -o:/tmp/ws tests/worker_service_test.nim   # still ok
```

- [ ] **Step 3: Commit + finish.** Commit docs. Phase 2 complete; #471 fully resolved (sync + async-to-main). Then superpowers:finishing-a-development-branch (or continue on feat/nim-native).
```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "docs: worker async Services.invoke (marshal-to-main, App-capable) shipped"
```

---

## Self-review notes
- **Low risk via precedent:** the worker→native→eval-back→resolve round-trip is already proven by `_syncPending`/`dispatchSyncResult` (Sync.wait) and the webview `_onInvokeResult`. Phase 2 mirrors both — no new mechanism, no spike.
- **No zjs Promise C API:** confirmed; the JS-owned-promise pattern (host fn returns id; JS wraps; main resolves via eval) is the only viable shape and matches the precedents.
- **Shared zjs.c:** the async host fn is `#ifdef ZAPP_NIM_BUILD` (define added to the nim build's zjs.c `{.compile.}` in zapp.nim); the zc build excludes it and its worker `invoke` falls back to the sync alias (documented future-parity item). zc build gate in Task 2 Step 3 proves the `#ifdef` keeps zc linking.
- **Real App on the async path:** `zapp_worker_invoke_on_main` runs `invokeService` on the MAIN thread, so `gCurrentApp` is valid and AppKit calls are legal — the whole point. The sync path (Phase 1) still passes nil app.
- **Type/symbol consistency:** `host_invoke_service_async` → `zapp_worker_invoke_on_main(workerId, id, method, argsJson)` → `worker_eval_js(workerId, iife)` calling `bridge._resolveInvoke(id, ok, payload)` wrapping `bridge._pendingInvokes[id]`. The id is an int throughout; payload is a JSON string (`_resolveInvoke` JSON.parses on ok), matching `_onInvokeResult`.
- **Ownership:** the dispatch_async block frees the strdup'd method/args_json/worker_id after `zapp_worker_invoke_on_main` returns (it runs synchronously on main).
- **Memory escaper:** reuse bridge.nim's existing JS-string escaper for the payload (the same one `_onInvokeResult` delivery uses) — do not hand-roll escaping.
