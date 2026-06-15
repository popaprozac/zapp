# Nim Migration — Worker Host-Object Perf Gate (Phase 2, Step 1) — Design

**Status:** Design (approved 2026-06-15). **Branch:** `feat/nim-native`.
**Part of:** the Nim migration (`docs/superpowers/specs/2026-06-15-nim-migration-design.md`,
"Performance parity" section) — this is the **non-negotiable perf gate** that
must pass *before* breadth-porting the remaining ~35 modules.

## Goal

Prove the zero-overhead **worker→native** path (the Zapp differentiator) survives
in a Nim-driven build: a worker's `Services.invokeSync` round-trip through a
**Nim** `service_invoke_native` must match the Zen-C (`zc`) baseline within noise.
If it doesn't, root-cause the regression now — not after 35 modules are built on
the pattern.

## Success criteria (the gate)

- **PASS:** Nim-zjs `invokeService` **median µs/op ≤ 1.15 × the zc-zjs baseline**
  for the `invokeService.small` case (pure FFI + dispatch — the parity-critical
  one), measured with the same harness on the same machine, back-to-back, a few
  runs to average jitter. `invokeService.medium` recorded too (informational).
- **FAIL (>15%):** stop and root-cause (unexpected alloc, ORC on the hot path,
  indirection) before any breadth work.
- **Deliverable:** a short perf report (both builds' numbers + verdict) — the gate
  artifact, recorded alongside the skeleton assessment.

## Scope

zjs engine only; the two existing bench cases (`small` `{i:1}`, `medium` 50-item
array); reuse the existing harness verbatim. **NOT** in scope: retry/restart,
multi-worker, registry lifecycle, other host objects (postMessage / events / sync
/ dispatchEventToAll), bare engines — all breadth. Through the gate verdict only.

## Architecture — the path under test

```
worker JS  Services.invokeSync(name, args)
  → host_invoke_service (native/worker/engines/zjs.c:456)      [C, stays C, compiled in]
  → zjsvalue_to_jsonvalue (zjs.c:363, zero-JSON tree-walk)     [C, stays C]
  → service_invoke_native(app, method, JsonValue*) -> cstring  [BECOMES Nim {.exportc, cdecl.}]
  → echo/noop handler (Nim, reads JsonValue via importc)       [Nim, allocation-free]
  → result cstring → engine builds JS return value inline      [C copies synchronously]
```
The engine side is unchanged C. The **only** thing that becomes Nim is the
service dispatch seam + handlers — exactly the surface breadth will reuse.

## Components (minimal slice, on `feat/nim-native`)

1. **zjs in the Nim build.** `buildNativeNim` (`cli/src/native.ts`), when the app
   config selects the zjs engine, adds: `{.compile.}` of `native/worker/engines/
   zjs.c` with the zjs + libuv `-I` includes, and `{.passL.}` `-L<vendor/zjs/build>
   -lzjs.dylib -lz`. Auto-build `vendor/zjs` if the dylib is missing (reuse the
   `make -C vendor/zjs` path the zc build uses; see `build-config.ts:1235-1313`).
2. **`native/nim/worker_service.nim`** — exports
   `proc service_invoke_native(app: pointer, methodName: cstring, args: JsonValue):
   cstring {.exportc, cdecl, gcsafe.}` + a minimal worker-path registry with the
   bench `echo` / `noop` handlers. Handlers read `JsonValue` via `importc`'d
   accessors (`get_int`, etc. — the symbols `native/bridge/json_safe.zc` already
   uses) and return **constant / thread-local-buffer cstrings — zero Nim heap
   allocation**.
3. **Generated `.zapp/zapp_headless.nim`** — the Nim equivalent of
   `generateHeadlessWorkers`, zjs-only: `proc zapp_start_headless_workers()
   {.exportc, cdecl.}` calling `importc`'d `zjs_worker_create(scriptUrl, ownerId,
   workerId)` per zjs headless entry from `zapp.config.ts`. `app.nim`'s `run()`
   calls `zapp_start_headless_workers()`.
4. **Stub the rest of zjs.c's callback surface.** Grep `zjs.c` for the orchestration
   `extern`s it calls back into (postMessage / events / worker-registry / log) and
   provide Nim `{.exportc, cdecl.}` no-ops (the skeleton's "grep externs, stub
   unused" recipe). The bench worker only exercises `invokeService`.

## The load-bearing rule — allocation-free worker-thread entry

`service_invoke_native` runs on the **zjs worker pthread**, not Nim's main thread.
The Nim handlers MUST be allocation-free:
- Read `JsonValue` fields via `importc`'d accessors (no Nim alloc).
- Return a constant cstring (`"{}"` for `noop`) or a **thread-local static buffer**
  (`{.threadvar.}`) formatted in place for `echo` (valid until the next call on
  that thread — matches the engine-copies-immediately contract, same shape as the
  zc static-slot pattern).

This simultaneously (a) satisfies the migration spec's "zero-alloc hot path" perf
rule and (b) means **ORC is never invoked on the worker thread**, sidestepping
Nim's foreign-thread-GC requirement entirely (no `setupForeignThreadGc`). The Nim
procs are marked `{.gcsafe.}`; the Nim build adds `--threads:on` so the runtime
tolerates the foreign C pthread. If breadth ever needs worker-thread allocation,
*that* is when `setupForeignThreadGc` enters — flagged future, not now.

## Benchmark method

- **App:** `benchmarks/apps/zapp-host-bridge`, reused verbatim — its `bench-zjs`
  headless worker, `src/bench-worker.ts` timing loop (200-iter warmup + N timed
  iters; reports `usPerOp = totalMs*1000/iters`), and `Noop`/`Echo` services.
- **Baseline:** build the app with the `zc` build, run, record zjs
  `invokeService.small` + `.medium` median µs/op (the harness already prints
  `[bench:zjs] …`).
- **Nim:** build the same app with `ZAPP_NATIVE_LANG=nim`, run, record the same.
- **Compare:** same machine, back-to-back, ≥3 runs each, take medians; PASS if
  Nim-small ≤ 1.15 × zc-small.

## Risks (carried into the plan)

- **zjs.c's extern callback surface may be larger than expected** — grep it up
  front (like the `.m` surface in the skeleton); exportc real for the invokeService
  path, stub the rest.
- **Confirm the `JsonValue` read-accessor C symbols** Nim `importc`s (from
  `std/json.zc` / `json_safe.zc`: `JsonValue::get_int`/`get_string` → their emitted
  C names).
- **Foreign-thread safety:** the Nim entry called from the C worker pthread must be
  `{.gcsafe.}` and the build needs `--threads:on`; alloc-free handlers make this
  safe (verify no ORC call on that thread).
- **Result lifetime:** confirm `zjs.c` copies the returned cstring synchronously
  into the JS return value (it builds it inline at `zjs.c:518-526`) — so a
  thread-local buffer is safe.
- **vendor/zjs availability:** the dylib may need a one-time `make`; the auto-build
  path must work from `buildNativeNim`.

## References
- `native/worker/engines/zjs.c:456` (`host_invoke_service`), `:363`
  (`zjsvalue_to_jsonvalue`), `:518-526` (result back to JS).
- `native/service/service.zc:153` (`service_invoke_native` — the seam).
- `benchmarks/apps/zapp-host-bridge/src/bench-worker.ts:45-75` (timing loop).
- `cli/src/build-config.ts:1235-1313` (zjs link/auto-build), `:442-545`
  (engine overlay / `generateHeadlessWorkers`).
- `cli/src/native.ts` (`buildNativeNim`).
