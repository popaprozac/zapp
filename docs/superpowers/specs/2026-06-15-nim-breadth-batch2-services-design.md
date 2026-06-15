# Nim Migration — Phase 2 Breadth, Batch 2: Service Registry + Lifecycle — Design

**Status:** Design (approved 2026-06-15). **Branch:** `feat/nim-native`.
**Part of:** the Nim migration breadth phase (`docs/superpowers/specs/2026-06-15-nim-migration-design.md`).
Batch 1 (event dispatch) is done/passed. **This is Batch 2** — consolidate the
service registry and add the lifecycle + manifest machinery downstream leaf
services (Batch 6) will register against.

## Goal

Port `native/service/service.zc` to idiomatic Nim, unifying the skeleton's **two
partial registries** — `native/nim/service.nim` (webview INVOKE path, a
`Table[string, ServiceHandler]`) and `native/nim/worker_service.nim` (worker path,
an alloc-free `array`, perf-gate-critical) — into **one authoritative registry**
that is the single source-of-truth for service identity, lifecycle, and the JS
bindings manifest, **without regressing the alloc-free worker path**.

## The reconciliation problem (why this needs a design)

`service.zc` is **one** `g_services[64]`: the same registry serves both the webview
path (`service_invoke`, args as `JsonValue*`) and the worker path
(`service_invoke_native`, also `JsonValue*`). It can be one physical store because
**zc's allocator is thread-safe malloc** — a handler taking `JsonValue*` allocates
freely on any thread.

Nim cannot share one physical store as cheaply because the two paths have
**incompatible allocation models**:
- **Webview path** runs on the Cocoa main thread → idiomatic `JsonNode` handlers,
  ORC allocation is fine.
- **Worker path** runs on the zjs worker pthread → must stay **allocation-free**
  (no ORC, no `setupForeignThreadGc`). This is the perf gate we already passed and
  must not regress.

**Decision (Approach 2):** one authoritative registry + one registration API as the
single source-of-truth for identity/lifecycle/manifest; the alloc-free worker array
stays as a **derived projection**, byte-for-byte untouched in this batch. This is
the honest reading of "idiomatic Nim, use Nim's better mechanism": the two threads
genuinely want different allocation models, so the right unification is one
registration front door + one identity/manifest source, not one physical array
fighting two memory models.

## Success criteria (the gate)

In hello-world on the Nim build (`ZAPP_NATIVE_LANG=nim`):
- `greet` still round-trips from the webview (the `service.nim` rewrite did not
  break INVOKE dispatch — the demo UI still renders via the top-level-awaited
  `greet()`).
- The injected `globalThis[Symbol.for('zapp.bindingsManifest')]` is the real
  `{"v":1,"services":[{"name":"greet"}]}` (not the `"[]"` stub) — verifiable via
  lldb on `service_get_manifest_json`'s return, or by reading the symbol in the
  webview.
- Build ends `[zapp] build complete:`; `.m` layer untouched; no `{.emit.}`;
  `bun run check` clean; the Nim service unit tests pass.

## Scope

**In:**
- Rewrite `native/nim/service.nim`: `Table` → ordered `seq[ServiceRecord]` (identity
  + webview handler + optional lifecycle hooks); `registerService` replaces
  `addService`; `invokeService` keeps its signature (router untouched).
- Real `service_get_manifest_json` (`{"v":1,"services":[…]}` via `std/json`),
  replacing the `zapp.nim` `"[]"` stub.
- Real `service_run_shutdown_all` (reverse-order hooks, `{.exportc, cdecl.}`),
  replacing the `zapp.nim` no-op stub; a Nim-internal `runStartupAll()` called from
  `app.nim`'s boot.
- Update `app.nim`'s call site (`addService` → `registerService`) and wire
  `runStartupAll()` into `run`.

**Out (deferred, dependency-correct):**
- **Per-service mutex + stateful `register(service_ptr, impl_ptr)`** — no
  stateful + concurrently-invoked service consumer until Batch 6/7. The record
  shape leaves room to add a lock later; nothing needs it now.
- **`service_invoke_sync` (worker JSON-string path)** — Batch 7 worker subsystem.
  It parses args on the worker thread (`zapp_json_parse`) and would allocate via
  ORC on the worker pthread; porting it needs the thread-safe-allocator decision,
  out of scope here.
- **Worker-handler population from the unified registry** — Batch 6, when the first
  worker-callable leaf service lands. `worker_service.nim` stays exactly as-is; no
  service is invoked from a worker in hello-world today.

## Architecture — what's being ported

### `service.nim` — the authoritative registry (rewrite)

Replace the `Table[string, ServiceHandler]` with an **ordered** record list so
lifecycle can run in registration order (and shutdown in reverse), mirroring
`service.zc`'s `g_services[]` + linear scan:

```nim
type
  ServiceHandler* = proc(args: JsonNode): string {.nimcall.}   # webview path (unchanged)
  LifecycleHook*  = proc() {.nimcall.}                          # nil = none
  ServiceRecord = object
    name: string
    handler: ServiceHandler
    startup, shutdown: LifecycleHook

var gRegistry: seq[ServiceRecord]      # registration order; linear lookup (like zc)

proc registerService*(name: string, handler: ServiceHandler,
                      startup: LifecycleHook = nil,
                      shutdown: LifecycleHook = nil)
proc invokeService*(name: string, args: JsonNode): Option[string]  # signature unchanged
proc runStartupAll*()                  # forward order, skip nil hooks
proc runShutdownAll*()                 # REVERSE order, skip nil hooks
proc serviceManifestJson*(): string    # {"v":1,"services":[{"name":…}]} via std/json
```

- **Lifecycle hooks** take no argument (the zc `void*` service_ptr is the stateful
  path we're deferring). `startup`/`shutdown` default `nil`; greet registers none.
- **`invokeService`** keeps `proc(name: string, args: JsonNode): Option[string]` so
  `router.nim` is untouched: linear scan, run handler, `some`; `none` when absent.
- **`serviceManifestJson`** builds `{"v":1,"services":[{"name":n}]}` with `%*` /
  `$`, replacing zc's `static char[4096]` snprintf builder (idiomatic-win: no
  fixed buffer, no truncation). The object form matches `service.zc:202-215`
  exactly; the runtime reads it from `bindingsManifest`.

### C-ABI exports (the `.m`/platform seam)

- **`service_get_manifest_json(): cstring {.exportc, cdecl.}`** — wraps
  `serviceManifestJson()`, returns a **module-`let`-backed** cstring (cstring
  lifetime rule: cache the built string in a module-level `var`/`let` so the
  pointer outlives the call). Consumed by `webview.m:906` / `ios/webview.m:769`.
- **`service_run_shutdown_all() {.exportc, cdecl.}`** — wraps `runShutdownAll()`.
  Called by `platform.m:312` (darwin), `platform.c:243` (windows),
  `ios/platform.m:250`. **Lives in `service.nim` now → the `zapp.nim:64-67` stub is
  removed** (avoid duplicate symbol).
- **`service_run_startup_all`** needs **no** exportc: the only caller was
  `app.zc:413`, and in the Nim build `app.nim` is the boot orchestrator. `app.nim`
  calls `service.runStartupAll()` directly (Nim-internal).

These exports move into `service.nim` (or a thin C-ABI section of it). `service.nim`
already has no `{.exportc.}`; adding two here is fine and keeps the registry's C
seam co-located with the registry.

### `app.nim` wiring

- `registerSkeletonServices` (`app.nim:41-43`): `addService("greet", greetService)`
  → `registerService("greet", greetService)`.
- `run` (`app.nim:22-29`): add `runStartupAll()` after service registration and
  before `platformRun` (mirrors `app.zc:413`'s placement in boot). `greet` has no
  startup hook, so this is a no-op today but exercises the path.

### `zapp.nim` stub removal

Remove `service_run_shutdown_all` (`zapp.nim:64-67`) and the
`gServiceManifest`/`service_get_manifest_json` stub (`zapp.nim:149-155`) — both now
provided real by `service.nim`. Removing them must not break the link (the real
defs replace them). Leave every other stub alone.

### `worker_service.nim` — untouched

The perf-gate alloc-free projection stays byte-for-byte. Batch 6 will add the
registry→projection wiring when a worker-callable leaf service first appears. (Wart
noted for B7: `registerWorkerServices` hardcodes bench `noop`/`echo` even in
non-bench builds — harmless unused entries; cleaned up when worker services become
config-driven.)

## Idiomatic Nim + boundary rules (carried over)

- Ordered `seq[ServiceRecord]` + linear scan (matches zc's tiny-N linear model);
  lifecycle hooks as `proc {.nimcall.}`; manifest via `std/json` not a stack buffer.
- `Option[string]` for the lookup miss (already the skeleton's shape).
- C-ABI: only the two `{.exportc, cdecl.}` symbols the `.m`/platform layer calls;
  returned cstring is module-`let`-backed; no `{.emit.}`.
- These run on the **main thread** (boot + Cocoa delegate), not a worker pthread —
  ORC allocation is fine here (unlike the worker hot path).

## Risks (carried into the plan)

- **Manifest shape**: the stub returns `"[]"`; the real contract is the **object**
  `{"v":1,"services":[…]}` (`service.zc:202-215`, read by `webview.m:906`). Match
  the object form; confirm the runtime tolerates it (it already parses the zc
  output on the zc build).
- **Stub-removal link**: deleting the two `zapp.nim` stubs while `service.nim`
  defines the real symbols — verify the Nim build links one definition each.
- **Ordering**: `registerSkeletonServices()` (zapp.nim:287, module-init) runs before
  window creation (where `webview.m` calls `service_get_manifest_json`), so the
  manifest already lists greet — confirm this ordering holds after the rewrite.
- **cstring lifetime** on `service_get_manifest_json`: the built JSON must be cached
  in module storage, not a temporary, or the returned cstring dangles.

## References

- `native/service/service.zc` (source of truth: `add`/`register`,
  `service_run_startup_all:93`, `service_run_shutdown_all:104`, `service_invoke:116`,
  `service_invoke_native:153`, `service_invoke_sync:164`,
  `service_get_manifest_json:202`).
- `native/nim/service.nim` (Table registry to rewrite), `native/nim/worker_service.nim`
  (alloc-free projection — untouched), `native/nim/app.nim:22-43` (boot + greet
  registration), `native/nim/zapp.nim:64-67,149-155` (stubs to remove).
- `native/platform/darwin/webview.m:906` (manifest consumer),
  `native/platform/darwin/platform.m:311-312` (shutdown caller), `native/app/app.zc:413`
  (startup caller).
