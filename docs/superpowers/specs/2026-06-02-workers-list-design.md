# Workers.list() — runtime debug API + worker naming + log format revamp

**Date:** 2026-06-02
**Branch:** TBD (cut after spec approval)
**Tracks:** Issue #150 — `Workers.list()` runtime debug API

## Goal

Land a single coherent change that ships three tightly-bound pieces:

1. **`Workers.list(): Promise<WorkerInfo[]>`** — public runtime debug API on the existing `Workers` namespace, returns the active worker registry as a typed list.
2. **Optional `name` field** on headless config (`zapp.config.ts`) AND `new Worker(url, { name })`. Plumbed through to the native registry as a first-class column.
3. **Worker log format revamp** — `[zapp] zjs worker 'h-supervised' restarting...` becomes `[zapp/h-supervised] restart 2 (fail 1/2 in 30s)`. Prefers `name` over `worker_id` for display. App-level logs stay `[zapp] ...`.

These three are bundled because they share the same plumbing point (the registry's display-name helper + the `name` column).

## Why now

- The supervisor-restart cycle landed a richer `ZappWorkerEntry` record (restart_max, restart_window_ms, fail_count, gave_up). All that state is invisible to userland today.
- The worker-event-delivery cycle multiplied the number of native call sites that log per-worker activity. The current `[zapp] zjs worker 'h-id' …` format is verbose and `worker_id`s are opaque (`h-supervised`, `h-ticker`, auto-generated GUIDs for `new Worker(url)`).
- Building a debug API without the name field forces users to memorize their auto-generated IDs in the dev console.

## Non-goals

- No new metrics (memory, CPU, message throughput). The spec exposes existing registry state only.
- No subscribe API (`Workers.onChange(...)`). One-shot snapshot via `list()` is the v1.
- No control surface beyond what already exists (`terminate`, `postMessage`, `send`). `list()` is read-only.
- No log-level configuration. The format revamp is a one-shot replacement.

## Public API

### `runtime/worker.ts`

```ts
export interface WorkerInfo {
  id: string;
  name?: string;
  scriptUrl: string;
  engine: "zjs" | "bare-jsc" | "bare-v8" | "bare-quickjs" | "bare-mqjs" | "bare-hermes";
  shared: boolean;
  owners: string[];
  supervisor?: {
    maxRetries: number;
    withinMs: number;
    failCount: number;
    gaveUp: boolean;
  };
}

export const Workers = {
  // existing:
  terminate(id: string): Promise<void>,
  postMessage(id: string, data: unknown): Promise<void>,
  send(id: string, event: string, payload: unknown): Promise<void>,

  // new:
  list(): Promise<WorkerInfo[]>,
};
```

- `supervisor` is `undefined` when the worker isn't supervised (no `restart_max` set). It's populated even when `failCount === 0` so userland code can detect "this is a supervised worker that hasn't failed yet" vs. "this isn't supervised."
- `name` is `undefined` when no name was supplied at create time. UIs/logs fall back to `id`.

### `cli/src/config.ts` — `HeadlessWorkerConfig`

```ts
export interface HeadlessWorkerConfig {
  script: string;
  engine?: WorkerEngine;
  name?: string;               // NEW
  bytecode?: boolean;
  shared?: boolean;
  restart?: { max: number; withinMs: number };
  // ...
}
```

### `runtime/worker.ts` — `new Worker()`

```ts
new Worker(url: string, opts?: { shared?: boolean; name?: string });
```

`name` is opaque to the framework — display only. No uniqueness enforcement (two workers with the same name is fine; logs disambiguate by `id` shown alongside name when ambiguous — see Section "Log format" below).

## Architecture

Three layers, single source of truth in `native/worker/registry.zc`:

```
┌──────────────────────────────────────────────────────────────┐
│ runtime/worker.ts                                            │
│   Workers.list() → await bridge.listWorkers()                │
└────────────────┬─────────────────────────────────────────────┘
                 │
       ┌─────────┴──────────┐
       │                    │
┌──────▼──────────┐  ┌──────▼──────────────────────────────────┐
│ webview context │  │ worker context                          │
│ bridge.list..() │  │ bridge.list..() — host obj per engine   │
│ = IPC roundtrip │  │ (zjs.c: direct ZjsValue array)          │
│                 │  │ (bare.c: NAPI array — shared across     │
│                 │  │   bare-jsc/v8/quickjs/mqjs/hermes)      │
└──────┬──────────┘  └──────┬──────────────────────────────────┘
       │                    │
       │  ┌─────────────────┘
       │  │
┌──────▼──▼──────────────────────────────────────────────────────┐
│ native/app/router.zc — __zapp:workers-list                     │
│   (webview IPC path only)                                      │
└────────────────┬───────────────────────────────────────────────┘
                 │
┌────────────────▼───────────────────────────────────────────────┐
│ native/worker/registry.zc                                       │
│   zapp_workers_registry_list() → List<WorkerInfoRecord>         │
│   zapp_worker_registry_get_display_name(worker_id) → string     │
│ Single source of truth: ZappWorkerEntry + name field            │
└─────────────────────────────────────────────────────────────────┘
```

- **Worker context** calls the per-engine host object directly. Sync at the native layer; `Workers.list()` wraps the result in `Promise.resolve()` so the API shape matches both contexts.
- **Webview context** has no direct registry access — round-trips through `__zapp:workers-list` via the existing async-invoke IPC.
- **Both paths** converge on the same `zapp_workers_registry_list()` function. No duplication of the walk/filter/serialize logic.

## Log format

### Current

```
[zapp] zjs worker 'h-supervised' restarting (incarnation 2, fail_count 1/2 in 30000ms window)
[zapp] starting worker h-ticker (engine=zjs)
[zapp] worker h-supervised: ready
```

### New

```
[zapp/h-supervised] restart 2 (fail 1/2 in 30s)
[zapp/h-ticker] starting (zjs)
[zapp/h-supervised] ready
```

### With `name: "sync-engine"` set

```
[zapp/sync-engine] restart 2 (fail 1/2 in 30s)
[zapp/sync-engine] ready
```

### App-level logs (unchanged)

```
[zapp] initializing app...
[zapp] webview ready
[zapp] dispatch_event_to_all: 4 workers
```

### Rules

- **Prefix is `[zapp/<display-name>]`** where `display-name = name || worker_id`.
- **Time fields compacted:** `30000ms` → `30s`, `1500ms` → `1.5s`. Threshold: < 1s shows `ms`, ≥ 1s shows `s` with one decimal if fractional.
- **Restart counter:** `restart N (fail M/MAX in WINDOW)`. Reads as "Nth restart, M failures in window of MAX allowed."
- **App-level events** (no per-worker context) stay flat `[zapp] ...`.
- **No id disambiguation when name collides** — users picked the name; we trust it. If they need disambiguation, they can include the role in the name.

## Native components

### `native/worker/registry.zc` (~80 LOC added)

- Add `char name[64]` field to `ZappWorkerEntry`. Empty string means unset.
- Update `zapp_worker_registry_add*` constructor variants to accept `name` (or add `_with_name` variants delegating to a shared core).
- Add `zapp_workers_registry_list()` — walks active entries, builds typed records. Includes supervisor fields only when `restart_max > 0`.
- Add `zapp_worker_registry_get_display_name(worker_id) -> string` — returns `name` if non-empty, else `worker_id`. Used by all log call sites.

### `native/worker/engines/zjs.c` (~50 LOC added)

- Register `__zappBridge.listWorkers` as a host function via `zjs_set_global_property`.
- Implementation: call `zapp_workers_registry_list()`, walk result, build `ZjsValue` array of objects directly. Engine ID int → string mapping (`ZAPP_ENGINE_ZJS` → `"zjs"`) happens here.
- No JSON serialize step — direct value marshalling (the zjs perf wedge).

### `native/worker/engines/bare.c` (~60 LOC added)

- Register `__zappBridge.listWorkers` via NAPI: `napi_create_function` + `napi_set_named_property` on the bridge object.
- Implementation: walk `zapp_workers_registry_list()`, build NAPI arrays/objects.
- Shared across all 5 bare-* engines (single `bare.c`).

### `native/app/router.zc` (~30 LOC added)

- New route: `"__zapp:workers-list"` → call `zapp_workers_registry_list()`, JSON-serialize the result, return through existing async-response infrastructure.

### Log-line touch points (~30 LOC across 5 files)

| File | Sites |
|---|---|
| `native/worker/engines/zjs.c` | ~3 fprintf calls (worker create, ready, terminate) |
| `native/worker/engines/bare.c` | ~3 fprintf calls (same shape, bare side) |
| `native/worker/registry.zc` | ~2 calls (supervisor restart, gave-up) |
| `native/worker/worker.zc` | ~3 calls (general worker lifecycle) |
| `cli/src/zapp-cli.ts` | ~2 console.log calls (dev mode worker spawn echo) |

Each call uses `zapp_worker_registry_get_display_name(id)` instead of raw `id`. New prefix format: `"[zapp/%s] ..."`.

## Runtime + bootstrap plumbing

### `runtime/worker.ts` (~30 LOC added)

```ts
async list(): Promise<WorkerInfo[]> {
  const bridge = getBridge() as any;
  return await bridge.listWorkers();
}
```

Identical call site for both contexts. Worker bridge returns synchronously (host call); webview bridge returns a Promise (IPC). `await` works for both.

### `bootstrap/webview.ts` (~15 LOC added)

```ts
bridge.listWorkers = () => invoke("__zapp:workers-list", null);
```

### `bootstrap/worker.ts` (no JS plumbing needed)

`bridge.listWorkers` is registered natively at worker init (the per-engine host object). Bootstrap doesn't touch it.

### Name plumbing (~50 LOC added across bootstrap + codegen)

- `bootstrap/webview.ts`: `createWorker` call gains `name` param threaded from `new Worker(url, { name })`.
- `bootstrap/worker.ts`: same.
- `cli/src/build-config.ts`: `generateHeadlessWorkers` emits the `name` arg into the generated `zapp_start_headless_worker_full(...)` call. Empty string when not set.

## Verification

### Build verify
- macOS build → must see `[zapp] build complete:` as final line (per [[feedback_verify_native_build]]). Verify fresh binary mtime.
- iOS Sim build → same.

### Manual smoke (hello-world)
1. `bun run dev` → app boots.
2. Dev console: `await Workers.list()` returns array. Confirm at minimum:
   - `h-supervised` (engine: zjs, supervisor populated)
   - `h-ticker` (engine: zjs, no supervisor field)
3. Add `name: "sync-engine"` to supervised in `hello-world/zapp.config.ts`. Rebuild.
4. Re-run `Workers.list()` → `h-supervised` now has `name: "sync-engine"`.
5. Verify log lines show `[zapp/sync-engine] ready` (not `[zapp/h-supervised] ready`).
6. Force-crash supervised (existing `workerCrash` button) → log line: `[zapp/sync-engine] restart 1 (fail 1/2 in 30s)`.
7. Open the hello-world UI, click the new "Show workers" button → result div renders pretty-printed `Workers.list()` output. (Adds a small JSON.stringify display to `main.ts`.)
8. Worker-context smoke: add `Workers.list()` call inside a worker (one-line addition to `ticker.ts` or supervised handler), confirm same shape returned from worker.

### Cross-engine
- Run hello-world with `engine: "bare-jsc"` on supervised → confirm `Workers.list()` works through the bare host path.
- Other bare-* engines: deferred to manual followup unless trivial to smoke.

## Estimated effort

- Registry + name field + display-name helper: ~2 hrs
- zjs host object: ~1.5 hrs
- bare host object: ~1.5 hrs
- Router IPC path: ~1 hr
- Bootstrap + runtime: ~1 hr
- Config + codegen plumbing for `name`: ~1 hr
- Log format sweep across 5 files: ~1 hr
- hello-world UI smoke button + manual verify: ~1 hr

**Total: ~10 hrs / ~1.5 dev days.** ~370 LOC added, mostly mechanical.

## Logical commits

1. `feat(registry): add name field + display-name helper`
2. `feat(workers): Workers.list() runtime API`
3. `feat(workers): per-engine listWorkers host object (zjs + bare)`
4. `feat(router): __zapp:workers-list IPC route`
5. `feat(config): optional name on headless + new Worker()`
6. `refactor(logs): compact [zapp/<name>] prefix across worker call sites`
7. `feat(hello-world): Workers.list() smoke UI`

## Related memories

- [[project_supervisor_restart_brainstorm]] — supervisor state we're now exposing
- [[project_worker_event_delivery_cycle]] — adds many of the call sites being relogged
- [[feedback_verify_native_build]] — build verification rule applies here

## Open questions

None remaining at spec-write time — Sections 1-5 walked through architecture, public API, log format, native components, and verification with the user; all approved.
