# Nim Worker→Native Dispatch — Phase 0 + Phase 1 (sync path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Wire the worker's `invokeSync` to the *real* Nim service registry, running inline on the worker pthread via foreign-thread GC — so `invoke greet from worker` returns "Hello from Zapp!" (today `{}`). Resolves the core of #471.

**Architecture:** A Phase-0 spike first proves Nim foreign-thread GC works under `--mm:orc --threads:on` on a non-Nim pthread (the hard risk). Then the zjs worker thread calls `setupForeignThreadGc()` once at start; `service_invoke_native` dispatches through a POD registry snapshot (`{cstring name, handler-ptr}`, built at boot from the real registry — no cross-heap Nim-`seq` read), runs the handler with a `nil` app, and returns the result via a per-thread (`threadvar`) Nim string whose `cstring` survives `zjs.c`'s synchronous copy.

**Tech Stack:** Nim 2.2 (`setupForeignThreadGc`, `{.threadvar.}`, `--mm:orc --threads:on`), C (zjs.c worker thread), the existing C-ABI.

**Spec:** `docs/superpowers/specs/2026-06-18-nim-worker-native-dispatch-design.md` (this plan = Phase 0 + Phase 1; the Phase 2 async-to-main plan follows after this gate passes).

**Scope guard:** The async-to-main `invoke` path (Phase 2) is NOT in this plan. `invokeSync`-from-worker remains pure (nil app); App-using calls are Phase 2.

---

### Task 1 (RISK GATE): Phase 0 — foreign-thread GC spike

Proves `setupForeignThreadGc` + Nim alloc + `parseJson` + `cstring` return work on a raw (non-Nim) pthread under ORC, *before* any wiring. If this fails, STOP and report — the sync-path approach must be reconsidered (the design's fallback is marshal-to-main).

**Files:**
- Create: `native/nim/tests/foreign_gc_test.nim`

- [ ] **Step 1: Write the spike test.** Create `native/nim/tests/foreign_gc_test.nim`:

```nim
# Phase-0 risk gate for worker→native dispatch (#471): does Nim foreign-thread GC
# work on a RAW pthread (not a Nim-created thread) under --mm:orc --threads:on?
# Mirrors what zjs.c's worker pthread will do: setupForeignThreadGc, then alloc +
# parseJson + hand a cstring back (which must stay valid via a threadvar).
import std/[posix, json]

var tlResult {.threadvar.}: string   # per-thread root so the cstring stays alive

proc workerBody(arg: pointer): pointer {.cdecl.} =
  setupForeignThreadGc()
  # Allocating Nim work on a foreign thread — the real risk.
  let node = parseJson("""{"msg":"Hello from Zapp!","n":42}""")
  tlResult = node["msg"].getStr & ":" & $node["n"].getInt
  let c = tlResult.cstring                 # borrow the threadvar's buffer
  doAssert $c == "Hello from Zapp!:42"
  tearDownForeignThreadGc()
  result = nil

var tid: Pthread
doAssert pthread_create(addr tid, nil, workerBody, nil) == 0
doAssert pthread_join(tid, nil) == 0
echo "foreign-gc ok"
```

- [ ] **Step 2: Run it.**
Run: `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --mm:orc --threads:on -o:/tmp/fgc tests/foreign_gc_test.nim`
Expected: prints `foreign-gc ok`, exit 0, no crash/abort.
**If it crashes or aborts:** STOP. Report the exact failure (signal, message). Do NOT proceed to Task 2 — the approach needs revision (escalate to the controller).

- [ ] **Step 3: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/tests/foreign_gc_test.nim
git commit -m "test(nim): foreign-thread GC spike under ORC (worker dispatch gate)"
```
(Trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.)

---

### Task 2: Worker-thread GC init

**Files:**
- Modify: `native/nim/worker_service.nim` (add the GC-init export)
- Modify: `native/worker/engines/zjs.c` (call it once at worker-thread start)

- [ ] **Step 1: Add the Nim GC-init export.** In `native/nim/worker_service.nim`, add:
```nim
proc zapp_worker_thread_gc_init*() {.exportc, cdecl.} =
  ## Called by zjs.c ONCE on each worker pthread before its message loop, so the
  ## thread can run Nim GC code (service handlers alloc on this thread's heap).
  ## Idempotent-safe: zjs.c calls it once per thread start.
  setupForeignThreadGc()
```
(Add `import std/typedthreads`/nothing extra — `setupForeignThreadGc` is in `system`. Confirm it compiles.)

- [ ] **Step 2: Call it from the zjs worker thread.** In `native/worker/engines/zjs.c`, in `zjs_worker_thread` (~line 1627), AFTER the loop-init block and BEFORE the `while (1)` (around line 1644), add:
```c
    // Initialize Nim foreign-thread GC for this worker pthread so the Nim
    // service registry + handlers can run inline here (service_invoke_native).
    // Declared extern; no-op in the zc build (zc has no GC — provide a stub there).
    extern void zapp_worker_thread_gc_init(void);
    zapp_worker_thread_gc_init();
```

- [ ] **Step 3: zc-build stub.** The zc build also compiles zjs.c but has no Nim GC. Add a no-op `zapp_worker_thread_gc_init` to the zc side so the zc build links. In `native/service/service.zc` (or the zc worker glue), add:
```zc
fn zapp_worker_thread_gc_init() -> void { }
```
(Confirm the zc build links — find where zc defines the other `service_*` C-ABI fns and co-locate.)

- [ ] **Step 4: Build both.**
  - Nim: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`.
  - zc: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:` (proves the zc stub links).

- [ ] **Step 5: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/worker_service.nim native/worker/engines/zjs.c native/service/service.zc
git commit -m "feat(nim): worker pthread sets up foreign-thread GC at start"
```

---

### Task 3 (GATE): Phase 1 sync dispatch — real registry, greet works

**Files:**
- Modify: `native/nim/service.nim` (expose registry enumeration for the snapshot)
- Modify: `native/nim/worker_service.nim` (real snapshot + dispatch)
- Modify: `native/nim/app.nim` (build snapshot after services registered, before workers)

- [ ] **Step 1: Expose registry enumeration.** In `native/nim/service.nim`, add a accessor the worker snapshot can read (names + handler pointers) without exposing the seq:
```nim
iterator registeredServices*(): tuple[name: string, handler: AppServiceHandler] =
  for rec in gRegistry: yield (rec.name, rec.handler)
```

- [ ] **Step 2: Real POD snapshot + dispatch in worker_service.nim.** Replace the bench stub body. The snapshot stores the handler pointer + a C-owned copy of the name (so the cstring is independent of the main-heap Nim string). Dispatch runs the handler with `nil` app and (for now) a null `JsonNode` for args — greet ignores args; the real args walker is Task 4. Result is held in a `{.threadvar.}` string:
```nim
import std/json
import apptypes        # App, AppServiceHandler
import service         # registeredServices

type SnapEntry = object
  name: cstring              # C-owned (strdup) — independent of main-heap Nim strings
  handler: AppServiceHandler

var gSnap: seq[SnapEntry]    # built once on the MAIN thread at boot (read-only after)

proc buildWorkerServiceSnapshot*() =
  ## MAIN thread, after app.service.add calls, before workers spawn.
  gSnap = @[]
  for (name, handler) in registeredServices():
    gSnap.add SnapEntry(name: name.cstring, handler: handler)  # see note on cstring lifetime
  # NOTE: `name.cstring` borrows the registry's Nim-string buffer, which lives for
  # the app's lifetime (registry is append-only, never freed) and is only READ on
  # the worker — safe. If a strdup'd C copy is preferred for isolation, do it here.

var tlResult {.threadvar.}: string   # per-worker-thread root for the result cstring

proc service_invoke_native*(app: pointer, methodName: cstring, args: pointer): cstring
    {.exportc, cdecl.} =
  ## Worker pthread (foreign-thread GC already set up). Runs the real handler.
  ## args is a JsonValue* (opaque) — Task 4 bridges it; for now handlers that use
  ## args get JNull. Returns a cstring valid until the next call on this thread
  ## (zjs.c copies it synchronously).
  for e in gSnap:
    if e.name == methodName:                 # cstring strcmp, no alloc
      let node = newJNull()                  # TODO Task 4: bridge args JsonValue* -> JsonNode
      tlResult = e.handler(nil, node)        # nil app — pure-only contract (spec)
      return tlResult.cstring
  return cstring""
```
(Adjust imports/types to the real `AppServiceHandler` signature `proc(app: App, args: JsonNode): string`. Keep `registerWorkerServices`'s name if zjs.c/app.nim call it — or rename call sites to `buildWorkerServiceSnapshot`; check `app.nim`.)

- [ ] **Step 3: Build the snapshot at boot.** In `native/nim/app.nim`, where `registerWorkerServices()` is called today (before `zapp_start_headless_workers`), call `buildWorkerServiceSnapshot()` instead (after `app.service.add` + `runStartupAll`, before workers spawn). Confirm ordering: services registered → snapshot built → workers spawned.

- [ ] **Step 4: Build nim kitchen-sink.**
`cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`.

- [ ] **Step 5: GATE — human smoke.** `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run dev`. In the Workers section, "invoke greet from worker" must now return **"Hello from Zapp!"** (today it returns `{}`). PAUSE for human confirmation — this proves the foreign-GC + real-registry round-trip end to end.

- [ ] **Step 6: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/service.nim native/nim/worker_service.nim native/nim/app.nim
git commit -m "feat(nim): worker invokeSync runs the real service registry (foreign-thread GC)"
```

---

### Task 4: Args bridge — JsonValue* → JsonNode (worker heap)

**Files:**
- Modify: `native/nim/worker_service.nim`
- Test: `native/nim/tests/worker_service_test.nim`

- [ ] **Step 1: Map the JsonValue accessor API.** Read how the zc/bare paths read a `JsonValue*` (the provider accessors — e.g. type tag, string/number/bool getters, array length+index, object key iteration). The zc build and `bare.c`'s walker (#147) already consume `JsonValue*`; find the accessor functions (grep `JsonValue` in `native/bridge/`, `vendor/zjs/include`, and the generated provider) and `importc` the ones needed into Nim. Report the accessor set you found.

- [ ] **Step 2: Write the walker (TDD).** Add a `jsonValueToNode(p: pointer): JsonNode` that recursively builds a worker-heap `JsonNode` from the `JsonValue*` using those accessors (null/bool/int/float/string/array/object). Replace the `newJNull()` placeholder in `service_invoke_native` with `jsonValueToNode(args)` (guard `args == nil` → `newJNull()`). Add a unit test in `worker_service_test.nim` that builds a small JsonValue (or stubs the accessors) and asserts the JsonNode round-trips a representative object `{"name":"x","n":1,"ok":true,"xs":[1,2]}`.

- [ ] **Step 3: Run the unit test + build.**
  - `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --mm:orc --threads:on -o:/tmp/ws tests/worker_service_test.nim` → passes.
  - `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → `[zapp] build complete:`.

- [ ] **Step 4: Commit.**
```bash
cd /Users/zach/code/zapp
git add native/nim/worker_service.nim native/nim/tests/worker_service_test.nim
git commit -m "feat(nim): bridge worker invokeSync args (JsonValue* -> JsonNode)"
```

---

### Task 5: Docs (sync path + matrix) + final gate

**Files:**
- Modify: `docs/api-reference.md`

- [ ] **Step 1: Document.** In `docs/api-reference.md`, document worker `Services.invokeSync`: runs the handler inline on the worker thread (fast), pure compute only — the handler receives a **nil app**, so it must not touch `App`/windows (use `Services.invoke` async — Phase 2 — or Events for that). Include the context × path matrix from the spec (webview = async only / `invokeSync` throws there; worker = both), and note the foreign-thread-GC mechanism at a high level. Mark the async App-capable `invoke` path as "coming in Phase 2" if not yet shipped.

- [ ] **Step 2: Full gate.**
```bash
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build   # [zapp] build complete:
cd /Users/zach/code/zapp/kitchen-sink && bun run build                         # [zapp] build complete: (zc)
cd /Users/zach/code/zapp && bun run check                                      # tsc clean
cd /Users/zach/code/zapp/cli && bun test src                                   # all pass
cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --mm:orc --threads:on -o:/tmp/fg tests/foreign_gc_test.nim   # foreign-gc ok
cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --mm:orc --threads:on -o:/tmp/ws tests/worker_service_test.nim  # passes
```

- [ ] **Step 3: Commit + finish.** Commit docs; then this Phase-1 increment is complete. The Phase-2 (async-to-main App-capable `invoke`) plan is written next, on this proven foundation.
```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "docs: worker invokeSync (foreign-thread GC, pure-only) + invoke matrix"
```

---

## Self-review notes
- **Risk gate first:** Task 1 (foreign-GC spike) gates everything; a failure stops the plan and pivots the approach (marshal-to-main fallback). This is the single biggest unknown, isolated up front.
- **No cross-heap seq read on the worker:** the worker reads `gSnap` (a POD-ish `seq` of `{cstring, handler-ptr}`) — but note `gSnap` is itself a Nim seq; the worker iterates it read-only. STRICTLY POD-safe would be a fixed `array`/raw pointer; the implementer should confirm whether iterating a never-mutated `seq` from the worker (post-foreign-GC-setup) is safe, or convert `gSnap` to a fixed `array[N]` / `ptr UncheckedArray` to fully avoid GC-header reads. Flag for the code reviewer.
- **Result lifetime:** `tlResult` is a `{.threadvar.}` (per-worker-thread global) → its `cstring` stays valid until the next call on that thread; `zjs.c` copies synchronously before then. Matches the contract.
- **nil app contract:** Task 3 passes `nil` app — pure-only, per spec. App-using services are Phase 2 (async-to-main). Documented in Task 5.
- **zc unaffected:** the zc build gets a no-op `zapp_worker_thread_gc_init` stub (Task 2 Step 3); its `service_invoke_native` is untouched.
- **Type consistency:** `AppServiceHandler = proc(app: App, args: JsonNode): string`; snapshot stores that handler ptr; dispatch calls `handler(nil, node)`. `registeredServices` yields `(string, AppServiceHandler)`. Consistent across service.nim/worker_service.nim/app.nim.
