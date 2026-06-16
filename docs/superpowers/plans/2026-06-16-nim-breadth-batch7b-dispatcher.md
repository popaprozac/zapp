# Nim Breadth Batch 7b — Worker Dispatcher + routeWorker (Approach B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Port `native/worker/worker.zc` (the engine-dispatcher) + `native/app/router.zc:router_handle_worker` + `native/app/app.zc:worker_dispatch_to_webview`/`worker_dispatch_to_window` to Nim, and route the `t:5` WORKER envelope — so `new Worker(url)` from the webview spawns + registers (→ `Workers.list()` shows it) + `postMessage`/`terminate` round-trip.

**Architecture:** `worker.nim` provides the engine dispatcher (`worker_create`/`worker_post_message`/`worker_terminate`/`worker_terminate_owner` + `zapp_resolve_engine`, zjs-only in this build) and the worker→webview delivery (`worker_dispatch_to_webview` → `worker_dispatch_to_window`, **gcsafe + libc** since zjs.c may call it on the worker thread). `routeWorker` (router.nim) ports `router_handle_worker` (create/post/terminate/disconnect) and is dispatched from `routeMessage`'s new `t==5` branch. `registry.nim` (B7a) gains gcsafe owner-access exports the delivery needs. Replaces the 2 remaining worker stubs in zapp.nim.

**Tech Stack:** Nim, `importc` of the compiled `zjs_worker_*` (zjs.c) + `darwin_window_*`, reusing `dispatch.nim`'s `zapp_escape_dup` (B4); source of truth `worker.zc` + `router.zc:1182-1340` + `app.zc:220-275`.

---

## Background

- **Branch:** `feat/nim-native`. macOS / Nim build (zjs-only — bare.c is NOT compiled). Decision: Approach B.
- **WORKER envelope = `t:5`** (`native/bridge/protocol.zc:26` `WORKER: 5`). `routeMessage` currently handles `t==4` (window action) + `t==1` (invoke); ADD `t==5` → `routeWorker`. The worker `action` is `f.m` (`"create"`/`"post"`/`"terminate"`/`"disconnect"`), args `f.a`.
- **`worker.zc` dispatcher** (the functions to port): `worker_create(app, scriptUrl, ownerId, workerId, engine)` → `zapp_resolve_engine` → `zapp_worker_registry_set_engine` → `zapp_dispatch_worker_create(eng,…)`; `worker_post_message(workerId, data)` → `get_engine` → `zapp_dispatch_worker_post`; `worker_terminate(workerId)` → `get_engine` → `zapp_dispatch_worker_terminate`; `worker_terminate_owner(ownerId)`. The dispatch switch: case 2-6 → `bare_worker_*` (NOT compiled — **OMIT/no-op in the Nim build, zjs-only**), case 7 → `zjs_worker_*` (compiled — importc). `zapp_resolve_engine`: only zjs (7) present → resolves to 7 (mirror the fallback + the downgrade `stderr` log when an explicit non-7 engine was requested).
- **`zjs_worker_*` C-ABI (compiled in zjs.c, importc):** `bool zjs_worker_create(const char* scriptUrl, const char* ownerId, const char* workerId)`; `void zjs_worker_post_message(const char* workerId, const char* dataJson)`; `void zjs_worker_terminate(const char* workerId)`; `void zjs_worker_terminate_owner(const char* ownerId)`; `void zjs_worker_eval_js(const char* workerId, const char* js)` (B7c).
- **`router_handle_worker`** (router.zc:1182-1340) — port to `routeWorker(action, a, windowId)`:
  - `create`: args `scriptUrl`,`workerId` (required), `shared`(bool), `engine`(string→id 2-7 / -1), `name`(string, default ""). `ownerId = darwin_window_id_string(windowId)`. Shared: `registryFindShared(scriptUrl)` → if found `registryAddOwner(existing, owner)` + reply the canonical id via `sendInvokeResponse(windowId, 0, true, existingId)` + return; else register (shared=1) + `worker_create`. Dedicated: `zapp_worker_registry_add_full_with_engine_and_name(workerId, owner, 0, scriptUrl, engine, name)` + `worker_create(...)`.
  - `post`: args `workerId`(required),`data`(default "") → `worker_post_message`.
  - `terminate`: `workerId`(required); if `zapp_worker_registry_is_shared` → no-op (use disconnect); else `worker_terminate` + `zapp_worker_registry_remove`.
  - `disconnect`: `workerId`(required); `ownerId = darwin_window_id_string(windowId)`; `remaining = zapp_worker_registry_remove_owner(workerId, owner)`; if `<= 0` → `worker_terminate` + `remove`.
- **`worker_dispatch_to_webview`/`worker_dispatch_to_window`** (app.zc:220-275) — worker→owner delivery, **REPLACES the zapp.nim `worker_dispatch_to_webview` stub**. zjs.c calls `worker_dispatch_to_webview(workerId, dataJson)` (zjs.c:645) — possibly on the worker thread → **gcsafe + libc** (NO Nim string/GC). Logic: if `is_shared` → iterate the worker's owners, deliver to each; else → the single owner. Deliver = `worker_dispatch_to_window(workerId, dataJson, ownerId)`: resolve `ownerId` ("win-<n>") → numeric via `darwin_window_numeric_id_for_string`, build the JS `(self.__zappBridge||globalThis.__zappBridge)._onWorkerMessage('<workerId>','<escaped dataJson>')` (escape via `zapp_escape_dup` from dispatch.nim — libc, gcsafe), `darwin_window_eval_js(numericId, js)` (thread-safe in the .m), free the escaped/built buffers. **Confirm the exact IIFE shape + escaping against app.zc:220-243's `worker_dispatch_to_window`.** Needs registry owner-access (below).
- **`worker_post_message`** (worker→worker) REPLACES the other zapp.nim stub — `worker.nim`'s `worker_post_message` (the dispatcher) IS this symbol.
- **registry.nim owner-access (B7a gap):** `worker_dispatch_to_webview` needs the worker's owner(s) — B7a kept `owner`/`get` private. Add gcsafe exports to `registry.nim`: `registryFirstOwner*(workerId: cstring): cstring` (the dedicated single owner, "" if none) + `registryOwnerCount*(workerId: cstring): cint` + `registryOwnerAt*(workerId: cstring, idx: cint): cstring` (shared broadcast). POD/gcsafe, return cstrings into the static registry (stable).
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only the listed files. Never `hello-world/` etc. No `{.emit.}`. Do NOT edit `native/worker/**`/`native/platform/**`/`.c`/`.m`/`.zc`. Build ends `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/registry.nim` | + gcsafe owner-access exports (firstOwner/ownerCount/ownerAt) | Modify |
| `native/nim/worker.nim` | engine dispatcher + worker→webview delivery (gcsafe) | Create |
| `native/nim/router.nim` | `routeWorker` + `t:5` WORKER envelope branch | Modify |
| `native/nim/zapp.nim` | `import worker` + delete the 2 worker stubs | Modify |
| `native/nim/tests/worker_test.nim` | unit test (resolve_engine zjs-only + the escaping/IIFE shape if factored pure) | Create (best-effort) |

---

## Task 1: registry owner-access + worker.nim dispatcher + delivery + stub removal

**Files:** Modify `native/nim/registry.nim`, `native/nim/zapp.nim`; create `native/nim/worker.nim` (+ optional `worker_test.nim`).

- [ ] **Step 1: Add gcsafe owner-access exports to registry.nim**

In `native/nim/registry.nim`, add (gcsafe, returning cstrings into the static `gReg`, "" when absent — mirror the zc's static `owner`/`get`):
```nim
proc registryFirstOwner*(workerId: cstring): cstring {.gcsafe.} =
  ## First owner of a worker (dedicated workers have exactly one), "" if none.
  let i = registryIndex(workerId)
  if i < 0 or gReg[i].ownerCount <= 0: return cstring""
  cast[cstring](addr gReg[i].owners[0][0])
proc registryOwnerCount*(workerId: cstring): cint {.gcsafe.} =
  let i = registryIndex(workerId)
  if i < 0: return 0
  gReg[i].ownerCount
proc registryOwnerAt*(workerId: cstring, idx: cint): cstring {.gcsafe.} =
  let i = registryIndex(workerId)
  if i < 0 or idx < 0 or idx >= gReg[i].ownerCount: return cstring""
  cast[cstring](addr gReg[i].owners[idx][0])
```
(`registryIndex` is the existing private lookup. If its name differs, use the actual one.)

- [ ] **Step 2: Create `native/nim/worker.nim`**

Port `worker.zc`'s dispatcher (zjs-only) + the worker→webview delivery, gcsafe. Read `worker.zc:11-235` + `app.zc:220-275` as source of truth. Shape:
```nim
## Worker engine dispatcher + worker→webview delivery. Port of worker.zc + the
## worker_dispatch_to_* path in app.zc. zjs-only (bare.c not compiled in this
## build). gcsafe + libc on the delivery path (zjs.c may call worker_dispatch_to_
## webview on a worker pthread). NO Nim string/GC.
import registry          # registryFirstOwner/OwnerCount/OwnerAt/is_shared (gcsafe)

proc zjs_worker_create(scriptUrl, ownerId, workerId: cstring): bool {.importc, cdecl.}
proc zjs_worker_post_message(workerId, dataJson: cstring) {.importc, cdecl.}
proc zjs_worker_terminate(workerId: cstring) {.importc, cdecl.}
proc zjs_worker_terminate_owner(ownerId: cstring) {.importc, cdecl.}
proc zapp_worker_registry_set_engine(workerId: cstring, engine: cint) {.importc, cdecl.}
proc zapp_worker_registry_get_engine(workerId: cstring): cint {.importc, cdecl.}
proc zapp_worker_registry_is_shared(workerId: cstring): cint {.importc, cdecl.}
proc zapp_escape_dup(s: cstring): cstring {.importc, cdecl.}      # dispatch.nim (B4); libc malloc
proc darwin_window_numeric_id_for_string(wid: cstring): int32 {.importc, cdecl.}
proc darwin_window_eval_js(numericId: int32, js: cstring) {.importc, cdecl.}
proc c_free(p: cstring) {.importc: "free", cdecl.}
# … libc snprintf/malloc/strlen for the IIFE build …

proc zappResolveEngine(requested: cint, workerId: cstring): cint {.gcsafe.} =
  ## zjs-only build → always 7; warn (stderr) on an explicit non-7 request
  ## (mirror worker.zc:zapp_resolve_engine fallback + downgrade log).
  if requested == 7: return 7
  # (log downgrade if requested >= 0 and != 7) …
  7

proc worker_create*(app: pointer, scriptUrl, ownerId, workerId: cstring, engine: cint): bool {.exportc, cdecl, gcsafe.} =
  let eng = zappResolveEngine(engine, workerId)
  zapp_worker_registry_set_engine(workerId, eng)
  if eng == 7: return zjs_worker_create(scriptUrl, ownerId, workerId)
  false   # bare not compiled

proc worker_post_message*(workerId, dataJson: cstring) {.exportc, cdecl, gcsafe.} =
  ## REPLACES the zapp.nim stub. Dispatch to the worker's engine.
  if zapp_worker_registry_get_engine(workerId) == 7: zjs_worker_post_message(workerId, dataJson)

proc worker_terminate*(workerId: cstring) {.exportc, cdecl, gcsafe.} =
  if zapp_worker_registry_get_engine(workerId) == 7: zjs_worker_terminate(workerId)

proc worker_terminate_owner*(ownerId: cstring) {.exportc, cdecl, gcsafe.} =
  zjs_worker_terminate_owner(ownerId)

proc dispatchToWindow(workerId, dataJson, ownerId: cstring) {.gcsafe.} =
  ## Deliver one worker message to one owner window (port app.zc:worker_dispatch_to_window).
  ## Resolve "win-<n>" → numeric, build the _onWorkerMessage IIFE (escape dataJson +
  ## workerId via zapp_escape_dup), darwin_window_eval_js, free. Confirm the EXACT JS
  ## shape + which args are escaped against app.zc:220-243.
  …

proc worker_dispatch_to_webview*(workerId, dataJson: cstring) {.exportc, cdecl, gcsafe.} =
  ## REPLACES the zapp.nim stub. Shared → broadcast to all owners; dedicated → the one.
  if zapp_worker_registry_is_shared(workerId) != 0:
    let n = registryOwnerCount(workerId)
    for i in 0 ..< n: dispatchToWindow(workerId, dataJson, registryOwnerAt(workerId, i.cint))
  else:
    let owner = registryFirstOwner(workerId)
    if owner[0] != '\0': dispatchToWindow(workerId, dataJson, owner)
```
(Everything gcsafe + libc — the delivery path is worker-thread-reachable. NO Nim `string`/`seq`. Confirm the IIFE + escaping against `app.zc:worker_dispatch_to_window` — match it byte-faithfully.)

- [ ] **Step 3: Wire worker.nim into the build + delete the 2 stubs (zapp.nim)**

In `native/nim/zapp.nim`: add `import worker` to the `{.push warning[UnusedImport]: off.}` group (imported for its `{.exportc.}` side-effects). DELETE the 2 stubs: `worker_post_message` and `worker_dispatch_to_webview` (worker.nim now provides the real ones). (`worker_create`/`worker_terminate`/`worker_terminate_owner` were NOT stubbed — they're new exports referenced by routeWorker in Task 2.)

- [ ] **Step 4: (Best-effort) unit test the pure bits**

If `zappResolveEngine` (and any pure escaping/IIFE-build helper you factor) can be tested without the worker engine, add `native/nim/tests/worker_test.nim` stubbing the importc'd C symbols (the `permissions_test`/`registry_test` pattern) and asserting `zappResolveEngine(7,…)==7`, `zappResolveEngine(-1,…)==7`, `zappResolveEngine(3,…)==7`. If the module is too importc-entangled to unit-test cleanly, SKIP (build + runtime-gated, like the router routes) and note it.

- [ ] **Step 5: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5`
Expected: last line `[zapp] build complete: <path>`. (A `duplicate symbol _worker_post_message`/`_worker_dispatch_to_webview` → a stub wasn't deleted. Undefined `zjs_worker_*` → importc name mismatch vs zjs.c. Undefined `zapp_escape_dup` → it's in dispatch.nim, should resolve.) Do NOT `git add` hello-world/.

- [ ] **Step 6: Regression + commit**

Run the unit tests (`registry_test` + the rest + `worker_test` if created) — each `… ok`. Then:
```bash
cd /Users/zach/code/zapp
git add native/nim/registry.nim native/nim/worker.nim native/nim/zapp.nim native/nim/tests/worker_test.nim
git commit -m "$(printf 'feat(nim): worker.nim — engine dispatcher + worker→webview delivery (Batch 7b.1)\n\nPort of worker.zc dispatcher (worker_create/post/terminate/terminate_owner +\nzapp_resolve_engine, zjs-only) + worker_dispatch_to_webview/window (app.zc) —\nall gcsafe + libc (worker-thread-reachable; reuses dispatch.nim zapp_escape_dup +\ndarwin_window_eval_js). registry.nim gains gcsafe owner-access (firstOwner/\nownerCount/ownerAt). Replaces the worker_post_message + worker_dispatch_to_webview\nzapp.nim stubs. Approach B.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```
(Omit `worker_test.nim` from the `git add` if not created.)

---

## Task 2: routeWorker + t:5 WORKER envelope

**Files:** Modify `native/nim/router.nim`.

- [ ] **Step 1: import worker + add routeWorker**

In `native/nim/router.nim`, add `worker` to the top `import` line. Add `routeWorker(action: string, a: JsonNode, windowId: int)` (a t:1-style route helper, near `routeClipboard`) porting `router_handle_worker` (router.zc:1182-1340) — the create/post/terminate/disconnect arms exactly as specified in Background. Use the registry exportc procs (importc them in router.nim if not already: `zapp_worker_registry_add_full_with_engine_and_name`, `registryFindShared`, `registryAddOwner`, `zapp_worker_registry_is_shared`, `zapp_worker_registry_remove`, `zapp_worker_registry_remove_owner`) + `worker.nim`'s `worker_create`/`worker_post_message`/`worker_terminate` + `darwin_window_id_string` (already importc'd, B5a). `darwin_window_id_string(windowId)` gives the owner "win-<n>".

- [ ] **Step 2: Dispatch t:5 in routeMessage**

In `routeMessage`, after the `t==4` branch (or alongside it), add:
```nim
  if f.t == 5:        # WORKER envelope (protocol.zc:26)
    routeWorker(f.m, f.a, windowId)
    return
```

- [ ] **Step 3: Full build + regression + commit**

Build (`[zapp] build complete:`), regression tests (`… ok`), then:
```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim
git commit -m "$(printf 'feat(nim): routeWorker + t:5 WORKER envelope (Batch 7b.2)\n\nrouteMessage now routes the t:5 WORKER envelope to routeWorker (port of\nrouter_handle_worker): create (register + worker_create, shared dedup),\npost, terminate (shared-guard + registry remove), disconnect (remove_owner →\nterminate at refcount 0). new Worker(url) from the webview now spawns +\nregisters (Workers.list shows it) + postMessage/terminate round-trip.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 4: GATE — human smoke**

`ZAPP_NATIVE_LANG=nim bun run dev`: `new Worker(url)` spawns; the worker appears in `Workers.list()`; `worker.postMessage(x)` reaches the worker + a reply reaches `onmessage` (worker→webview delivery); `worker.terminate()` removes it. (hello-world's worker demo / ping.)

---

## Self-Review

**1. Spec coverage:** dispatcher (create/post/terminate/terminate_owner + resolve) → Task 1; worker→webview delivery (replace stub) → Task 1; registry owner-access → Task 1; routeWorker (create/post/terminate/disconnect) + t:5 envelope → Task 2; 2 stubs replaced → Task 1 S3. ✓
**2. Placeholder scan:** the `…` in worker.nim's `dispatchToWindow`/libc decls + `zappResolveEngine` downgrade-log are "confirm against app.zc/worker.zc" source-of-truth fill-ins (faithful port, like B7a's registry directive), with the gcsafe/libc discipline + the exact function surface + the IIFE shape reference pinned. Not hand-waves — the implementer matches the zc.
**3. Type consistency:** `worker_create(pointer, cstring×3, cint): bool`, `worker_post_message(cstring,cstring)`, etc. match the zc + zjs.c externs; registry owner-access returns cstrings into `gReg` (stable, gcsafe); `routeWorker(action, a, windowId)` matches the routeMessage `t==5` call; all delivery-path procs `{.gcsafe.}` (worker-thread-reachable) + libc (no Nim GC). ✓
