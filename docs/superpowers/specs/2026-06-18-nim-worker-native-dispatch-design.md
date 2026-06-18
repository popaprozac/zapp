# Nim Worker → Native Service Dispatch — Design

**Status:** DESIGNED — 2026-06-18. Wire the Nim worker-service path to the real
service registry with two honest dispatch paths: a fast **sync** path that runs
inline on the worker pthread (foreign-thread GC, pure compute, no App), and an
**async** path that marshals to the main thread (full App access, like the
webview). Resolves #471 and adds the App-capable worker path.

## Problem

A zjs worker's `Services.invokeSync(method, args)` calls `service_invoke_native`
**synchronously on the worker pthread** (`zjs.c:508`). The Nim implementation
(`worker_service.nim`) is a benchmark stub — it dispatches a POD array to
`noop`/`echo` constants and never reaches the real `app.service.add` handlers, so
`invoke greet from worker` returns `{}`.

Wiring it to the real Nim registry (`service.nim`) is non-trivial:

1. **GC heaps are per-thread under `--mm:orc --threads:on`.** The registry is a
   Nim `seq` of records with Nim-string names and handlers returning Nim
   **strings**, all on the *main* thread's heap. Running it from the worker
   pthread touches main-heap GC objects (seq traversal, string compare,
   `gCurrentApp`), and the result string has no GC root on the worker → may be
   collected before `zjs.c` copies it. No worker-thread GC setup exists today.
2. **AppKit/Cocoa is main-thread-only.** Any service that touches the App / a
   window / the tray *must* run on the main thread — this is why the native layer
   is full of `dispatch_async(dispatch_get_main_queue(), …)`. A worker running an
   App-touching handler on its own thread is unsafe in **any** language (zc
   included; zc's inline worker calls into App services are latently
   AppKit-off-main unsafe). The Nim GC is a *second* reason the inline path can't
   touch the App.

## Key insight: the webview already does the safe thing

The webview "calls services with no issue" because its `Services.invoke` is an
**async Promise**: WebKit delivers the call to `zapp_handle_message_from_window`
**on the app's main thread** (`webview.m:357→378`), the handler runs on main (App
+ GC + AppKit valid), and the result returns asynchronously via `eval_js`. The
webview's JS thread never runs the handler. **Driving App tasks from a worker is
therefore a "get onto the main thread" problem — exactly what the webview does.**

## Decision: two dispatch paths; the caller picks

| call (worker JS) | dispatched | runs on | `app` | use for |
|---|---|---|---|---|
| `Services.invokeSync(m,a)` | inline | worker pthread (foreign-thread GC) | `nil` | hot, pure compute (the NimPerf fast path) |
| `await Services.invoke(m,a)` | marshaled to main | **main thread** (like the webview) | **real** | App / UI / stateful work |

Same handler `proc(app: App, args: JsonNode): string` on both. The path the caller
chooses determines App availability, which dissolves the "expose-all vs opt-in"
question: App-using calls run on main where the App is real; the sync path is, by
contract, the pure/fast one.

### Context matrix (the rule to document)

| context | `invoke` (async → main, App-capable) | `invokeSync` (inline, pure) |
|---|---|---|
| **webview** | ✅ the only path | ❌ throws "workers/backend only" |
| **worker** | ✅ (new: marshal to main) | ✅ (inline on worker pthread) |

`invoke` is universal and App-capable (always lands on main). `invokeSync` exists
only where a thread can run native code inline — the worker — and is pure-only.
The webview cannot do sync: WebKit's JS↔native bridge is inherently async
(one-way message + async eval back); page JS can't block and return a native value
inline. `runtime/services.ts:53` already throws there — kept as-is.

## Path 1 — `invokeSync` (worker thread, fast) — resolves #471

- **Worker-thread GC init:** call a Nim-exported `zapp_worker_thread_gc_init()`
  (wrapping `setupForeignThreadGc()`) once at zjs worker-thread start, before the
  message loop (`zjs.c:1627` preamble). Threads are detached; teardown GC on exit
  is best-effort (workers live for app lifetime).
- **POD registry snapshot:** built at startup (after `app.service.add`, before
  `zapp_start_headless_workers`) by walking the Nim registry into an
  `array[N, {name: cstring, fn: handler-ptr}]` — fn-ptrs are code addresses (safe
  cross-thread); cstring names are immutable char* (safe to read). No Nim-`seq`
  traversal on the worker.
- **Dispatch:** `service_invoke_native` (drops `{.gcsafe.}` — it now intentionally
  uses the worker's GC) scans the snapshot; bridges `args` (`JsonValue*`) to a
  **worker-heap** `JsonNode` (a `JsonValue→JsonNode` walker, or serialize+`parseJson`
  — whichever the zjson provider supports cleanly); calls `handler(nil, args)`;
  stashes the result in a `{.threadvar.}` Nim string so its `cstring` survives
  until `zjs.c`'s synchronous copy; returns that `cstring`.
- **Contract:** pure compute only; a handler that touches `app` (nil here)
  crashes — use `invoke` for App work. Documented.

## Path 2 — `invoke` (async → main, App-capable) — new

- Today the worker's `invoke` is an alias to the sync call and even hangs a sync
  `.value` on the promise (`services.ts:40-42`). We make worker `invoke` a **true
  Promise**: genuinely asynchronous, no immediate `.value`. `invokeSync` stays the
  inline one.
- **Worker side (zjs.c host fn):** assign a request id, `dispatch_async(
  dispatch_get_main_queue(), …)` a `{id, method, argsJson}` payload, return the
  pending promise to JS.
- **Main thread:** run the real `invokeService(method, parseJson(argsJson))` with
  the real `gCurrentApp` + GC + AppKit valid — *identical to the webview bridge*.
- **Return:** deliver `{id, result}` back into the worker via the existing
  `worker_eval_js` channel → a pending-promise map in the worker bootstrap
  resolves/rejects (mirrors the webview's request/response machinery in
  `bootstrap/webview.ts`).
- No worker blocking → no deadlock.

## Components

- **Phase 0 (spike):** standalone Nim program — `setupForeignThreadGc` on a raw
  pthread, allocate a Nim string + `parseJson`, return its `cstring`, assert
  correctness + no crash under `--mm:orc --threads:on`. De-risks Path 1.
- `native/nim/worker_service.nim` — real dispatch (POD snapshot scan + args bridge
  + threadvar result); `registerWorkerServices` builds the snapshot from the real
  registry instead of bench constants.
- `native/nim/service.nim` (or a small sibling) — expose a way to enumerate the
  registry (name + handler-ptr) for the snapshot; the snapshot build runs at boot.
- `native/worker/engines/zjs.c` — worker-thread GC-init call at thread start; a new
  async-invoke host fn + main-queue marshal + response-to-worker via `worker_eval_js`.
- `bootstrap/worker.ts` — `invoke` becomes a real async (pending-promise map +
  `_resolveInvoke(id, result)`), no longer an alias to `invokeService`.
- `runtime/services.ts` — keep `invokeSync` throwing in the webview; ensure worker
  `invoke` returns a genuine Promise (drop the sync `.value` shim).
- **Docs (first-class):** `docs/api-reference.md` — the context × path matrix, the
  threading "why", the App-access rule, and the pure-only contract on `invokeSync`.

## Phasing (build both; each gated)

- **Phase 0** — foreign-GC spike. Gate: spike runs clean.
- **Phase 1** — sync path real dispatch. Gate: kitchen-sink `invoke greet from
  worker` returns "Hello from Zapp!" (today `{}`), via `invokeSync`.
- **Phase 2** — async-to-main path. Gate: a kitchen-sink App-using service (e.g.
  open a window) invoked from a worker via `await Services.invoke(...)` runs on
  main and succeeds.

## Testing

- Phase 0: the spike binary (assertion-based).
- Phase 1: `worker_service` unit test (real dispatch + args bridge, with a stub
  registry) + kitchen-sink `greet`-from-worker smoke.
- Phase 2: worker async `invoke` round-trip (request id → main → resolve) + a
  kitchen-sink "open window from worker" smoke.
- Gates throughout: nim + zc kitchen-sink builds, `bun run check`, `cd cli && bun
  test src`, the nim unit tests.

## Parity note (logged per the Nim-vs-zc parity rule)

zc runs all worker service calls inline on the worker thread and has no
async-to-main path — so zc's worker calls into App/UI services are latently
AppKit-off-main unsafe. Nim diverges deliberately and more-correctly: the sync
path is pure (foreign-thread GC), plus a **new async-to-main path** for safe App
access from workers. Surfaced here.

## Out of scope

- No change to the webview bridge (already async-to-main; `invokeSync` already
  throws there).
- No change to zc's worker dispatch.
- Cross-thread App *mutation* from the sync path (intentionally unsupported — use
  `invoke`).
- Marshaling args as a `JsonValue*` across `service_invoke_native`'s C-ABI is
  unchanged for the sync path (the bridge happens Nim-side); the async path passes
  args as a JSON string (it's built fresh for the main-thread `parseJson`).
