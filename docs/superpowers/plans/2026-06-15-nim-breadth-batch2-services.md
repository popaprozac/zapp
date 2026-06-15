# Nim Breadth Batch 2 — Service Registry + Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify the Nim skeleton's two partial service registries into one authoritative `service.nim` (identity + lifecycle + manifest), replacing the `zapp.nim` manifest/shutdown stubs, without regressing the alloc-free worker path.

**Architecture:** `service.nim` becomes the single source-of-truth — an ordered `seq[ServiceRecord]` (registration order, linear lookup, mirroring `service.zc`'s `g_services[]`). It owns `registerService`, `invokeService` (signature unchanged so `router.nim` is untouched), `runStartupAll`/`runShutdownAll` lifecycle, `serviceManifestJson`, and the two C-ABI exports the `.m`/platform layer calls. `worker_service.nim` (the perf-gate alloc-free projection) is **untouched**. Per-service mutex, stateful `register(service_ptr)`, and the worker JSON-string `invoke_sync` are deferred to later batches.

**Tech Stack:** Nim (`--mm:orc`), `std/json`, `std/options`. Unit tests via `nim c -r --hints:off`. Full build via the CLI Nim driver (`ZAPP_NATIVE_LANG=nim`).

---

## Background the engineer needs

- **Branch:** `feat/nim-native`. All work is additive to the Nim layer; the `zc` path stays default and untouched.
- **The two registries today:**
  - `native/nim/service.nim` — webview INVOKE path. Currently a `Table[string, ServiceHandler]` with `addService`/`invokeService`. **This file is rewritten by this plan.**
  - `native/nim/worker_service.nim` — worker host-object path. An alloc-free `array`; `service_invoke_native` runs on the zjs worker pthread and must stay allocation-free. **Do NOT touch this file.**
- **The source of truth** is `native/service/service.zc` (read it): `service_run_startup_all` (forward order), `service_run_shutdown_all` (REVERSE order), `service_get_manifest_json` → `{"v":1,"services":[{"name":"…"}]}`.
- **C-ABI callers** (these symbols must keep their exact C names):
  - `service_get_manifest_json()` — `native/platform/darwin/webview.m:906` injects its return as `globalThis[Symbol.for('zapp.bindingsManifest')]`.
  - `service_run_shutdown_all()` — `native/platform/darwin/platform.m:312`, `native/platform/windows/platform.c:243`, `native/platform/ios/platform.m:250`.
  - `service_run_startup_all` has **no `.m` caller** (only `app.zc:413`); in the Nim build, `app.nim` calls `runStartupAll()` directly — **no C-ABI export needed**.
- **The two stubs being replaced** live in `native/nim/zapp.nim`:
  - `service_run_shutdown_all` no-op — lines 64–67.
  - `gServiceManifest = "[]"` + `service_get_manifest_json` — lines 149–155 (the `"[]"` is a *shape mismatch*; the real contract is the object form).
- **Nim test pattern** (see `native/nim/tests/callbacks_test.nim`): a standalone `.nim` file that `import ../<module>`, defines `proc test()`, uses `doAssert`, prints `"<name> ok"`, then calls `test()`. Run with `nim c -r --hints:off <file>.nim` from `native/nim/tests/`. Each test is its own compiled binary → fresh module-global state (no cross-test registry bleed).
- **Idiomatic-Nim guiding principle** (load-bearing): write idiomatic Nim, not a transliteration. No `{.emit.}`. `.m` layer untouched.
- **STANDING CONSTRAINT — never `git add -A`.** Stage only the explicit `native/nim/...` paths named in each commit step. Never stage `hello-world/`, `kitchen-sink/`, `vendor/`, `native/worker/engines/zjs-cross-eval-test.c`, or any user-WIP.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/service.nim` | The authoritative registry: identity, lifecycle, manifest, C-ABI seam | **Rewrite** |
| `native/nim/app.nim` | Boot orchestration + greet registration | Modify (rename call; add `runStartupAll`) |
| `native/nim/zapp.nim` | Remaining platform-callback stubs | Modify (remove 2 stubs) |
| `native/nim/worker_service.nim` | Alloc-free worker projection | **Untouched** |
| `native/nim/tests/service_registry_test.nim` | Task 1 unit test | Create |
| `native/nim/tests/service_lifecycle_test.nim` | Task 2 unit test | Create |
| `native/nim/tests/service_manifest_test.nim` | Task 3 unit test | Create |
| `native/nim/tests/service_cabi_test.nim` | Task 4 unit test | Create |

---

## Task 1: Core registry — `registerService` + `invokeService` (Table → ordered seq)

**Files:**
- Modify: `native/nim/service.nim` (full rewrite of the registry core)
- Modify: `native/nim/app.nim:43` (rename the greet registration call)
- Test: `native/nim/tests/service_registry_test.nim` (create)

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/service_registry_test.nim`:

```nim
import ../service
import std/[json, options]

proc handlerA(args: JsonNode): string = """{"a":1}"""

proc test() =
  registerService("svcA", handlerA)
  doAssert invokeService("svcA", newJNull()).get == """{"a":1}"""
  doAssert invokeService("missing", newJNull()).isNone
  echo "service registry ok"
test()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off service_registry_test.nim 2>&1 | tail -5`
Expected: FAIL — compile error, `undeclared identifier: 'registerService'` (today's `service.nim` only has `addService`).

- [ ] **Step 3: Rewrite `service.nim` core**

Replace the entire contents of `native/nim/service.nim` with:

```nim
## Native service registry — the single source-of-truth for service identity,
## lifecycle, and the JS bindings manifest. The webview INVOKE path (router.nim)
## looks methods up here by name and runs the registered handler. The zero-overhead
## worker host-object path does NOT use this registry — it stays in the alloc-free
## worker_service.nim projection (populated per-service in a later batch).
##
## Ported from native/service/service.zc. Idiomatic-Nim wins over the zc original:
## an ordered seq[ServiceRecord] + linear scan replaces g_services[64] + strcmp;
## std/json builds the manifest instead of a static char[4096] snprintf buffer;
## Option[string] replaces the Result/sentinel miss. Per-service mutex + stateful
## register(service_ptr) + the worker JSON-string invoke_sync are deferred (no
## consumer until the worker-subsystem / leaf-service batches).
import std/[json, options]

type
  ServiceHandler* = proc(args: JsonNode): string {.nimcall.}
  LifecycleHook*  = proc() {.nimcall.}
  ServiceRecord = object
    name: string
    handler: ServiceHandler
    startup, shutdown: LifecycleHook

var gRegistry: seq[ServiceRecord]

proc registerService*(name: string, handler: ServiceHandler,
                      startup: LifecycleHook = nil,
                      shutdown: LifecycleHook = nil) =
  ## Register a service (registration order preserved for lifecycle). Mirrors
  ## ServiceManager.add — stateless handler; optional startup/shutdown hooks.
  gRegistry.add ServiceRecord(name: name, handler: handler,
                              startup: startup, shutdown: shutdown)

proc invokeService*(name: string, args: JsonNode): Option[string] =
  ## Run the handler for `name`; none when unregistered (router maps that to a
  ## NOT_FOUND rejection). Linear scan — service counts are tiny, matching zc.
  for rec in gRegistry:
    if rec.name == name: return some rec.handler(args)
  none(string)
```

- [ ] **Step 4: Update the app.nim call site**

In `native/nim/app.nim`, `registerSkeletonServices` (line 43): change `addService("greet", greetService)` to `registerService("greet", greetService)`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off service_registry_test.nim 2>&1 | tail -3`
Expected: PASS — prints `service registry ok`.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/service.nim native/nim/app.nim native/nim/tests/service_registry_test.nim
git commit -m "$(printf 'feat(nim): unify service registry into ordered seq (Batch 2 core)\n\nRewrite service.nim Table -> ordered seq[ServiceRecord] with registerService\n+ invokeService (signature unchanged, router untouched). Linear scan mirrors\nservice.zc g_services[]; Option[string] replaces the sentinel miss. app.nim\ngreet registration moves to registerService.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: Lifecycle — `runStartupAll` (forward) + `runShutdownAll` (reverse)

**Files:**
- Modify: `native/nim/service.nim` (add lifecycle procs)
- Test: `native/nim/tests/service_lifecycle_test.nim` (create)

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/service_lifecycle_test.nim`:

```nim
import ../service
import std/json

var order: seq[string]
proc h(args: JsonNode): string = ""
proc upA() = order.add "startA"
proc dnA() = order.add "stopA"
proc upB() = order.add "startB"
proc dnB() = order.add "stopB"

proc test() =
  registerService("A", h, startup = upA, shutdown = dnA)
  registerService("B", h, startup = upB, shutdown = dnB)
  registerService("C", h)                       # no hooks -> skipped
  runStartupAll()
  doAssert order == @["startA", "startB"]        # forward registration order
  runShutdownAll()
  doAssert order == @["startA", "startB", "stopB", "stopA"]   # reverse order
  echo "service lifecycle ok"
test()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off service_lifecycle_test.nim 2>&1 | tail -5`
Expected: FAIL — compile error, `undeclared identifier: 'runStartupAll'`.

- [ ] **Step 3: Add the lifecycle procs**

Append to `native/nim/service.nim` (after `invokeService`):

```nim
proc runStartupAll*() =
  ## Fire startup() for every service that has one, in registration order
  ## (service.zc:service_run_startup_all).
  for rec in gRegistry:
    if rec.startup != nil: rec.startup()

proc runShutdownAll*() =
  ## Fire shutdown() in REVERSE registration order
  ## (service.zc:service_run_shutdown_all).
  for i in countdown(gRegistry.len - 1, 0):
    if gRegistry[i].shutdown != nil: gRegistry[i].shutdown()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off service_lifecycle_test.nim 2>&1 | tail -3`
Expected: PASS — prints `service lifecycle ok`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/service.nim native/nim/tests/service_lifecycle_test.nim
git commit -m "$(printf 'feat(nim): service lifecycle runStartupAll/runShutdownAll (Batch 2)\n\nStartup hooks fire in registration order, shutdown in reverse, skipping\nservices without a hook. Mirrors service.zc startup_all/shutdown_all.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 3: Manifest — `serviceManifestJson` (std/json, not a static buffer)

**Files:**
- Modify: `native/nim/service.nim` (add `serviceManifestJson`)
- Test: `native/nim/tests/service_manifest_test.nim` (create)

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/service_manifest_test.nim`:

```nim
import ../service
import std/json

proc h(args: JsonNode): string = ""

proc test() =
  doAssert serviceManifestJson() == """{"v":1,"services":[]}"""
  registerService("greet", h)
  registerService("ping", h)
  doAssert serviceManifestJson() ==
    """{"v":1,"services":[{"name":"greet"},{"name":"ping"}]}"""
  echo "service manifest ok"
test()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off service_manifest_test.nim 2>&1 | tail -5`
Expected: FAIL — compile error, `undeclared identifier: 'serviceManifestJson'`.

- [ ] **Step 3: Add `serviceManifestJson`**

Append to `native/nim/service.nim` (after `runShutdownAll`):

```nim
proc serviceManifestJson*(): string =
  ## The JS bindings manifest webview.m injects as zapp.bindingsManifest. Shape
  ## matches service.zc:service_get_manifest_json exactly: {"v":1,"services":[…]}.
  ## std/json (compact `$`) replaces the zc static char[4096] snprintf builder.
  var services = newJArray()
  for rec in gRegistry:
    services.add(%*{"name": rec.name})
  $(%*{"v": 1, "services": services})
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off service_manifest_test.nim 2>&1 | tail -3`
Expected: PASS — prints `service manifest ok`.

(If `$` ever emitted spaces the exact-string assert would catch it; Nim's `$JsonNode` is the compact `toUgly` form, so the expected strings above are correct.)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/service.nim native/nim/tests/service_manifest_test.nim
git commit -m "$(printf 'feat(nim): serviceManifestJson via std/json (Batch 2)\n\nBuilds {\"v\":1,\"services\":[{\"name\":..}]} from the registry, matching\nservice.zc:service_get_manifest_json. Idiomatic std/json replaces the zc\nstatic char[4096] snprintf buffer (no truncation, no fixed size).\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 4: C-ABI exports + stub removal + boot wiring → GATE

This is the "make it live in the real binary" task: add the two `{.exportc.}` symbols the platform layer calls, remove their `zapp.nim` stubs (resolving the duplicate-symbol state), wire `runStartupAll()` into boot, and do the first full Nim build of the batch.

**Files:**
- Modify: `native/nim/service.nim` (add C-ABI exports)
- Modify: `native/nim/zapp.nim` (remove 2 stubs)
- Modify: `native/nim/app.nim` (add `runStartupAll()` to `run`)
- Test: `native/nim/tests/service_cabi_test.nim` (create)

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/service_cabi_test.nim`:

```nim
import ../service
import std/json

var shutOrder: seq[string]
proc h(args: JsonNode): string = ""
proc dn() = shutOrder.add "down"

proc test() =
  registerService("greet", h, shutdown = dn)
  # service_get_manifest_json returns a cstring; $ converts for comparison.
  doAssert $service_get_manifest_json() ==
    """{"v":1,"services":[{"name":"greet"}]}"""
  service_run_shutdown_all()           # C-ABI wrapper must run the shutdown hooks
  doAssert shutOrder == @["down"]
  echo "service cabi ok"
test()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off service_cabi_test.nim 2>&1 | tail -5`
Expected: FAIL — compile error, `undeclared identifier: 'service_get_manifest_json'` (it lives in `zapp.nim`, not imported by this test).

- [ ] **Step 3: Add the C-ABI seam to `service.nim`**

Append to `native/nim/service.nim` (after `serviceManifestJson`):

```nim
# --- C-ABI seam (the .m / platform layer calls these) -----------------------

# service_get_manifest_json — consumed by webview.m (zapp.bindingsManifest). The
# built JSON is cached in a module-level var so the returned cstring outlives the
# call (webview.m copies it synchronously).
var gManifestCache: string
proc service_get_manifest_json(): cstring {.exportc, cdecl.} =
  gManifestCache = serviceManifestJson()
  gManifestCache.cstring

# service_run_shutdown_all — called by platform.m / platform.c / ios platform.m
# at teardown. service_run_startup_all needs no C-ABI export: its only caller was
# app.zc, and in the Nim build app.nim calls runStartupAll() directly.
proc service_run_shutdown_all() {.exportc, cdecl.} =
  runShutdownAll()
```

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off service_cabi_test.nim 2>&1 | tail -3`
Expected: PASS — prints `service cabi ok`.

- [ ] **Step 5: Remove the two `zapp.nim` stubs**

In `native/nim/zapp.nim`:

Delete the shutdown stub (currently lines 64–67):
```nim
# service_run_shutdown_all — was service/service.zc. Tears down services in
# reverse order at quit. No services yet. TEMP until service.nim.
proc service_run_shutdown_all() {.exportc, cdecl.} =
  discard
```

Delete the manifest stub (currently lines 149–155):
```nim
# service_get_manifest_json — the WEBVIEW service-bindings manifest (JSON array)
# consumed by webview.m to expose JS proxies. Distinct from the native registry
# in service.nim (which the router dispatches to). Empty set: the skeleton's
# greet is invoked via the bootstrap bridge's generic invoke(), not a generated
# proxy. TEMP until the CLI emits the real manifest.
let gServiceManifest = "[]"
proc service_get_manifest_json(): cstring {.exportc, cdecl.} = gServiceManifest.cstring
```

(Leave every other stub in `zapp.nim` untouched. `service.nim` is already imported transitively via `app.nim`, so the real defs link.)

- [ ] **Step 6: Wire `runStartupAll()` into boot**

In `native/nim/app.nim`, `run` (lines 22–29): add `runStartupAll()` between `registerWorkerServices()` and `zapp_start_headless_workers()` so services are "started" before any worker can invoke them. The proc body becomes:

```nim
proc run*(app: App): int =
  ## Register worker-path services, run service startup hooks, spawn the configured
  ## zjs headless workers, then enter the Cocoa run loop (blocks).
  registerWorkerServices()
  runStartupAll()
  zapp_start_headless_workers()
  platformRun(app.terminateAfterLastWindowClosed)
```

(`runStartupAll` is exported from `service`, already imported by `app.nim`. greet has no startup hook, so this is a no-op today but exercises the path.)

- [ ] **Step 7: Full Nim build of hello-world (the build gate)**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -6`
Expected: the LAST line is `[zapp] build complete: <path>`. (Vite's `✓ built` is NOT success — require the `[zapp] build complete:` line.) If the link reports a duplicate `service_get_manifest_json` / `service_run_shutdown_all`, a `zapp.nim` stub was not fully removed — re-check Step 5.

Do NOT `git add` anything under `hello-world/` — the build is verification only.

- [ ] **Step 8: Re-run all four service unit tests (regression)**

Run:
```bash
cd /Users/zach/code/zapp/native/nim/tests && \
for t in service_registry_test service_lifecycle_test service_manifest_test service_cabi_test; do \
  nim c -r --hints:off $t.nim 2>&1 | tail -1; done
```
Expected: four lines — `service registry ok`, `service lifecycle ok`, `service manifest ok`, `service cabi ok`.

- [ ] **Step 9: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/service.nim native/nim/zapp.nim native/nim/app.nim native/nim/tests/service_cabi_test.nim
git commit -m "$(printf 'feat(nim): service C-ABI exports + boot wiring; drop zapp.nim stubs (Batch 2)\n\nservice.nim now provides the real service_get_manifest_json (module-cached\ncstring) + service_run_shutdown_all; remove their zapp.nim stubs. app.nim run()\ncalls runStartupAll() before spawning workers. bindingsManifest now lists the\nreal registered services instead of the [] stub.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 10: GATE — human smoke (controller pauses here)**

The controller pauses for the human to confirm on the Nim build (`ZAPP_NATIVE_LANG=nim`) of hello-world:
1. `greet` still round-trips — the demo UI renders (the top-level-awaited `greet()` resolves).
2. `globalThis[Symbol.for('zapp.bindingsManifest')]` is `{"v":1,"services":[{"name":"greet"}]}` (read it in the webview console, or lldb a breakpoint on `service_get_manifest_json`'s return) — i.e. the real manifest, not `[]`.

Do not proceed to the final review until the human confirms.

---

## Self-Review

**1. Spec coverage:**
- Rewrite `service.nim` Table → ordered seq + `registerService`/`invokeService` → Task 1. ✓
- Lifecycle `runStartupAll`/`runShutdownAll` (reverse) → Task 2. ✓
- Real `serviceManifestJson` (`{"v":1,"services":[…]}`) → Task 3. ✓
- C-ABI `service_get_manifest_json` (module-let-backed cstring) + `service_run_shutdown_all` → Task 4 Steps 3. ✓
- Remove the two `zapp.nim` stubs → Task 4 Step 5. ✓
- `app.nim` rename + `runStartupAll()` in `run` → Task 1 Step 4 + Task 4 Step 6. ✓
- `worker_service.nim` untouched → not in any task's file list. ✓
- Deferred (mutex / stateful register / invoke_sync) → not implemented, documented in plan header + spec. ✓
- Gate (greet round-trips + manifest lists greet) → Task 4 Step 10. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code step shows complete code. ✓

**3. Type consistency:** `ServiceHandler = proc(args: JsonNode): string {.nimcall.}` and `invokeService(name, args): Option[string]` used identically in Task 1 and the tests. `LifecycleHook = proc() {.nimcall.}` consistent across Tasks 1/2. `registerService(name, handler, startup, shutdown)` arity matches all call sites (tests + app.nim). `serviceManifestJson(): string` and `service_get_manifest_json(): cstring` distinct names, used consistently. ✓
