# Task 1 Report: Native Route-State Store (`routerstate.nim`)

## Native-test convention

- **Zen-C tests**: `native/tests/*_test.zc` — run by `bun run test:native` via `zc run`.
- **Nim tests**: `native/nim/tests/*_test.nim` — standalone scripts using `doAssert` (no `unittest` module); conventionally end with `echo "module ok"`. Run standalone via `nim r`. They import the module under test with `../module`. Any `importc` symbols are stubbed via `exportc` procs in the test file itself.
- **Registration**: The original `test-native.ts` only ran Zen-C tests. I extended it to also glob `native/nim/tests/*_test.nim` and run each via `nim r`. No manifest/array needed — file discovery is via glob.

## Files created/modified

- **Created**: `native/nim/routerstate.nim` — authoritative per-window route stack (browser-history semantics). Exported procs: `routerSeed`, `routerClear`, `routerPush`, `routerReplace`, `routerPop`, `routerForward`, `routerPopToRoot`, `routerCurrentUrl`, `routerCurrentParams`, `routerCanGoBack`, `routerCanGoForward`.
- **Created**: `native/nim/tests/routerstate_test.nim` — covers all 10 brief scenarios (seed, push/push, pop/forward, truncate-on-push, replace, popToRoot, params, pop-at-root no-op, forward-at-head no-op, clear safety).
- **Modified**: `cli/src/test-native.ts` — extended to also run `native/nim/tests/*_test.nim` via `nim r`. Zen-C tests unmodified; Nim tests added after.

## Gate results

| Gate | Result |
|------|--------|
| `nim r native/nim/tests/routerstate_test.nim` | PASS: "routerstate ok" |
| `bun run test:native` — Zen-C tests | PASS (json_safe, permissions) |
| `bun run test:native` — new routerstate_test.nim | PASS |
| `bun run test:native` — existing Nim tests (most) | PASS (appconfig, callbacks, color, dialog, dispatch, foreign_gc, fs, jsonvalue, permissions, registry, router_subscribe, windowmanager, worker_service, worker_service_thread, worker) |
| `bun run check` | PASS (tsc exits 0) |
| `bun test cli/src` | PASS: 106 pass / 0 fail |

## Pre-existing failures (NOT caused by this task)

Four service tests fail compilation on this branch:
- `service_cabi_test.nim`
- `service_lifecycle_test.nim`
- `service_manifest_test.nim`
- `service_registry_test.nim`

All fail with "type mismatch" on `registerService` — the `AppServiceHandler` type requires `(app: App, args: JsonNode): string` but the tests pass `(args: JsonNode): string`. This signature divergence predates this branch and exists identically on `feat/nim-native`. These tests were not previously surfaced by `bun run test:native` because the original harness only ran Zen-C tests.

By extending `test-native.ts` to include Nim tests, I now surface these failures. The `bun run test:native` exits with code 1 due to these 4 pre-existing failures — the new `routerstate_test.nim` itself passes cleanly.

## Self-review

- The `routerstate.nim` implementation is a verbatim transcription of the brief's code, with the terse one-liner getters expanded to plain `if/else` blocks as requested.
- Test isolation: each test block uses a distinct window id (1-10) to prevent state bleed.
- The brief's "push/push → canGoBack=true" test uses `routerSeed(W, "/a") + routerPush(W, "/b")` rather than two pushes from scratch — this is the minimal 2-entry stack that makes "pop → canGoBack=false" correct (at root index 0).
- `routerPop` and `routerForward` return `bool` (brief spec); `routerPopToRoot` also returns `bool`.

## Concerns

1. **Pre-existing service test failures now visible**: Extending `test-native.ts` to Nim means `bun run test:native` now exits 1 due to 4 pre-existing broken service tests. This was a deliberate trade-off (the harness must run Nim tests per the brief). The failing tests need the `AppServiceHandler` type updated or the test stubs fixed — work for a separate task.
2. **`test:native` gate formally fails**: Because of concern 1, `bun run test:native` exits 1. The `routerstate_test.nim` itself passes. If the caller wants a clean gate, the service tests need to be fixed first.

---

## Fix: revealed service-test rot

**Option chosen: A — fix the tests** (mechanical, no scaffolding needed)

**Why A over B:** The fix was purely mechanical. `AppServiceHandler` changed to `proc(app: App, args: JsonNode): string`. Each test needed:
1. `import ../apptypes` added (so `App` is in scope — `service.nim` imports it but does not re-export it)
2. Handler proc signature updated to `proc h(app: App, args: JsonNode): string`
3. `service_registry_test.nim` additionally needed `setCurrentApp(App(name: "test"))` before calling `invokeService`, since `invokeService` passes `gCurrentApp` to the handler

**Per-file changes:**
- `native/nim/tests/service_cabi_test.nim`: add `import ../apptypes`; update `proc h(args: JsonNode)` → `proc h(app: App, args: JsonNode)`
- `native/nim/tests/service_lifecycle_test.nim`: same two changes
- `native/nim/tests/service_manifest_test.nim`: same two changes
- `native/nim/tests/service_registry_test.nim`: same two changes + add `setCurrentApp(App(name: "test"))` at start of `test()`

**Gate results (post-fix):**

| Gate | Result |
|------|--------|
| `bun run test:native` | PASS — all 22 native tests passed (2 zc + 20 nim incl. routerstate + all 4 service tests) |
| `bun run check` | PASS (tsc exits 0) |
| `bun test cli/src` | PASS: 106 pass / 0 fail |
