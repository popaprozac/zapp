# Worker supervisor auto-restart — design

**Status:** approved by user 2026-06-01 (post-brainstorm). Implementation plan: TBD via `superpowers:writing-plans`.

**Goal:** Headless workers configured with `restart: { maxRetries, withinMs }` in `zapp.config.ts` automatically recreate their JS context after an uncaught throw, until the configured cap is hit. Land identical behavior on `zjs`, `bare`, `txiki`, and `jsc` (the last already partially restart-capable).

Closes the gap noted in `hello-world/zapp.config.ts:25–28`: *"the supervisor records failures and gives up after the cap, but doesn't relaunch yet."*

## Scope decisions (locked during brainstorm)

| Decision | Locked value |
|---|---|
| Engines covered | All four — `zjs`, `bare`, `txiki`, `jsc` |
| Respawn mechanism | Same-thread reset: recycle pthread + `uv_loop_t`, only the engine context is recreated |
| Eligibility | Headless workers only; `new Worker(url)` and `new SharedWorker(url)` keep current unsupervised behavior |

JSC already restarts via `dispatch_async` on its persistent queue; this spec aligns its event payloads with the new uniform shape but leaves its lifecycle untouched.

## Architecture

For each engine's worker thread, the main body becomes an outer reincarnation loop. One iteration = one "incarnation" of the worker.

`setup_state` returns one of three outcomes:

- **`SETUP_OK`** — context, bridge, bootstrap, handles, and script eval all succeeded. Worker is ready to run.
- **`SETUP_CRASHED`** — script eval (or any later setup step) threw. `setup_state` already called `host_worker_crash` synthetically; `wants_restart` is set per supervisor verdict. The while-loop teardown + iterate path handles this exactly like a runtime crash.
- **`SETUP_FATAL`** — unrecoverable: `uv_loop_init` or the engine's `new_context` failed. Worker exits via `fatal:` without invoking the supervisor.

```c
while (1) {
    slot->incarnation++;
    int setup = setup_state(slot);                     /* ctx, bridge, handles, eval */

    if (setup == SETUP_FATAL) goto fatal;              /* loop/context init failed */

    if (setup == SETUP_CRASHED) {
        /* host_worker_crash already fired; wants_restart set per verdict.
           Skip uv_run — there's nothing live to run. Fall through to teardown. */
    } else {
        /* SETUP_OK */
        if (slot->incarnation > 1) {
            dispatch_event_to_all("worker:restarted", payload);
        }
        uv_run(&slot->loop, UV_RUN_DEFAULT);           /* blocks until shutdown_async */
    }

    teardown_state(slot, /*keep_loop=*/1);
    if (slot->wants_terminate) break;
    if (!slot->wants_restart) break;
    slot->wants_restart = 0;
}
```

The pthread and `uv_loop_t` persist across incarnations. The engine context, bridge installation, handle registrations, mutexes, and inbox storage are all per-incarnation and rebuilt fresh on every restart.

**Broken-from-start safety.** A script that throws on every load runs through this loop normally: each `setup_state` returns `SETUP_CRASHED`, supervisor counts the failure, while-loop iterates → next `setup_state` → crash again. Once the supervisor cap is hit, verdict==2 fires `worker:gave-up` without setting `wants_restart`, the while-loop breaks, and the worker exits cleanly. The supervisor's sliding-window cap is what prevents an infinite restart spiral, not any logic inside the engine.

### Slot state

```c
typedef struct {
    /* Identity — persists */
    char worker_id[64];
    char owner_id[64];
    char script_url[256];

    /* Thread + loop — persist */
    pthread_t  thread;
    uv_loop_t  loop;
    int        loop_initialized;
    int        incarnation;          /* 1 on first start, +1 per restart */

    /* Control flags — written from any thread; atomic */
    _Atomic int wants_restart;       /* set by host_worker_crash on verdict==1 */
    _Atomic int wants_terminate;     /* set by e_worker_terminate; wins over restart */

    /* Per-incarnation — torn down + recreated on restart */
    ZjsContext*     ctx;
    uv_check_t      check;
    uv_timer_t      zjs_wake;
    uv_async_t      shutdown_async;
    uv_async_t      inbox_async;
    uv_async_t      eval_inbox_async;
    pthread_mutex_t inbox_mutex;
    pthread_mutex_t eval_inbox_mutex;
    char*           inbox[256];
    char*           eval_inbox[256];
    /* Rooted helpers */
    ZjsRoot         object_keys_root;
    ZjsRoot         json_parse_root;
    ZjsRoot         json_stringify_root;
    int             active;          /* 1 only while uv_run is live */
} ZjsWorkerSlot;
```

(Equivalent shapes exist in `bare.c` and `txiki.c`; field names differ per engine, structure is identical.)

### Crash → restart signal flow

```
JS throw (top-level eval OR async cb wrapped by bootstrap)
  └─> host_worker_crash(ctx, msg, stack)
        ├─ dispatch_event_to_all("worker:crashed", {id, message, stack, incarnation})
        ├─ verdict = supervisor_record_failure(worker_id)
        ├─ verdict == 2: dispatch "worker:gave-up", return     /* worker idles, dead-ish */
        ├─ verdict == 0: return                                /* no policy; worker idles */
        └─ verdict == 1:
             slot->wants_restart = 1;
             uv_async_send(&slot->shutdown_async);
             return                                            /* JS unwinds */
   └─> uv_run returns (shutdown_async handler stopped the loop)
   └─> teardown_state(keep_loop=1)
   └─> while-loop body re-enters: setup_state → uv_run
   └─> setup_state's caller fires "worker:restarted" when incarnation > 1
```

## Events

| Event | Fires when | Payload |
|---|---|---|
| `worker:crashed` | Every uncaught throw reaching `host_worker_crash` (top-level eval OR async cb). | `{ id, message, stack, incarnation }` |
| `worker:restarted` | After `setup_state` completes for incarnation ≥ 2. | `{ id, incarnation }` |
| `worker:gave-up` | Supervisor verdict == 2 (cap exhausted). | `{ id, finalIncarnation, retriesAttempted }` |

`incarnation` is new on all three. Lets the webview correlate a crash → which restart cycle it belongs to. JSC's `worker:restarted` / `worker:gave-up` currently send `{id}` only; this spec widens them to match.

### Dev log line

`setup_state` on `incarnation > 1` logs to stderr:
```
[zapp] zjs worker 'h-supervised' restarting (incarnation 2, fail_count 1/3 in 30000ms window)
```
Backed by a new read-only getter `zapp_worker_supervisor_get_window_state(worker_id, *count, *cap, *window_ms)` in `registry.zc`.

## Edge cases & failure modes

### Top-level eval throws are now crashes

Today `zjs_eval_module_source` / `bare_load_script` / `JS_Eval` errors at script load time just print to stderr; supervisor is never told. JSC's `exceptionHandler` already covers top-level + async. To unify: after the script-eval call in `setup_state`, if `zjs_had_error(ctx)` (or engine equivalent) is set, call `host_worker_crash` synthetically with the error's `message` + `stack`, then return false from `setup_state` so the while-loop sees `wants_restart` and either re-enters or `worker:gave-up` per the supervisor verdict.

### Race: terminate signaled while restart pending

`host_worker_crash` writes `wants_restart=1` then signals. If `e_worker_terminate` writes `wants_terminate=1` between those writes, the while-loop checks `wants_terminate` first → wins, thread exits cleanly. The atomic writes are happens-before the `uv_async_send`, so by the time the next while-loop iteration runs, both writes are visible. No mutex needed.

### Messages arriving during the restart gap

Between `teardown_state` (slot->ctx == NULL, slot->active == 0) and the next `setup_state` (ctx recreated, slot->active = 1), `worker_post_message` / `Workers.send` see `slot->active == 0` and **drop the message** with:
```
[zapp] worker 'h-supervised' message dropped (worker restarting; incarnation 2 not yet ready)
```
Webview pattern: gate sends on `worker:restarted` after a `worker:crashed`. Documented in `api-reference.md` + `patterns.md`.

### Script unreachable on restart

`setup_state`'s `load_script` returns NULL → log + treat as a crash (synthetic `host_worker_crash` call). Goes through the supervisor cap normally; eventually `worker:gave-up`. No infinite restart loop on a missing script.

### Inbox state on restart

Clean-slate semantics. Stranded `inbox[]` and `eval_inbox[]` entries are freed inside `teardown_state`; the new incarnation starts with empty inboxes. JS-side `setInterval`/`setTimeout` callbacks scheduled by the previous incarnation are gone (handle close + ctx free).

### Final-incarnation cleanup vs `keep_loop`

`teardown_state(keep_loop=1)` keeps `uv_loop_t` valid for the next iteration's handle re-init. The final teardown after the while-loop exits doesn't call `teardown_state` again — instead, the `fatal:` exit path runs `uv_run(NOWAIT)` to drain stragglers, then `uv_loop_close`. Avoids a `keep_loop=0` branch inside `teardown_state` and keeps that helper single-purpose.

### Out of scope

- Native-level faults (segfault, abort). A native crash takes down the process; that doesn't change with this spec. Per-worker process isolation is a separate architectural conversation.
- Restart backoff between attempts. Supervisor's sliding-window cap already prevents run-away restarts.
- Webview-spawned `new Worker(url)` and `new SharedWorker(url)` restart. User chose headless-only. SharedWorker's continued existence is itself an open question (see `project_sharedworker_deprecation` memory).
- Runtime API to reset supervisor state after `worker:gave-up`. No customer ask.

## Per-engine deltas

The outer loop, slot shape, signal flow, and event payloads are identical across all engines. The differences live entirely inside each engine's `setup_state` / `teardown_state` implementation.

### `zjs` — `native/worker/engines/zjs.c`

**Setup.** `zjs_new_context` → `zjs_setup_bridge` (roots `object_keys_root`, `json_parse_root`, `json_stringify_root` and registers host functions) → eval `var self = globalThis` → eval bootstrap → eval `setTimeout = globalThis.setTimeout` re-alias quartet → install uv handles (`check`, `zjs_wake`, three asyncs, two mutexes) → `load_script` → `zjs_eval_module_source` or `zjs_eval_bytecode` → check `zjs_had_error`; on error call synthetic `host_worker_crash` and return `false`.

**Teardown.** `uv_check_stop` + `uv_timer_stop` → `uv_close` on all 5 handles → `uv_run(loop, UV_RUN_DEFAULT)` to drain close callbacks → drain + `free()` inbox + eval_inbox entries → `pthread_mutex_destroy` on both mutexes → `zjs_unroot` the three helpers → `zjs_free_context` → null `slot->ctx`.

### `bare` — `native/worker/engines/bare.c`

**Setup.** `bare_init` → bridge host-function install (Services.invokeSync, postToWebview, postToWorker, workerCrash, dispatchEventToAll) → uv handles → script eval via `bare_load_script` → post-eval error check (synthetic crash on error).

**Teardown.** `bare_destroy` (manages NAPI ref counts and env teardown) → uv handles + inboxes per the zjs pattern.

### `txiki` — `native/worker/engines/txiki.c`

**Setup.** `JS_NewRuntime` → `JS_NewContext` → txiki bootstrap (which installs the QuickJS+libuv globals) → bridge install → script eval via `JS_Eval` → post-eval error check.

**Teardown.** `JS_FreeContext` → `JS_FreeRuntime` → uv handles + inboxes per the zjs pattern.

The `#ifdef __APPLE__` guards inside txiki.c's host objects (notification, dock, createWindow, quit — per `WINDOWS_PORTING.md:62–70`) are unrelated to restart and stay as-is.

### `jsc` — `native/worker/engines/jsc.m`

Already restart-capable. Only changes:
1. `jsc_dispatch_simple` widens to `jsc_dispatch_with_incarnation` so `worker:restarted` and `worker:gave-up` payloads carry `{id, incarnation}` matching the other engines. ~10 line change.
2. The `worker:crashed` payload gains `incarnation` from `jsc_build_crash_payload`.

## Testing

| Test | Setup | Assertions |
|---|---|---|
| **Hello-world demo extension** | Run hello-world's supervisor demo on `engine: "zjs"`, `"bare-jsc"`, `"txiki"` (today it only works on legacy `jsc`). | Force-crash button produces: `worker:crashed` → `worker:restarted` × 2 → `worker:crashed` → `worker:gave-up` on the 3rd crash. Identical sequence across all 4 engines. |
| **Broken-from-start** | Headless worker with `throw new Error("immediate")` at module top, `restart: { maxRetries: 2, withinMs: 30000 }`. | 3 `worker:crashed` events fire in < 1s (top-level throws caught), then `worker:gave-up`. No infinite loop. |
| **Restart-window decay** | Crash 2× (max=2), wait 31s past `withinMs`, crash again. | The third crash starts a *new* window — `worker:restarted` fires, not `worker:gave-up`. Validates `registry.zc`'s sliding-window logic from the engine side. |
| **Send during gap** | Headless worker mid-restart; webview fires `Workers.send("h-…", "ping")` between `worker:crashed` and `worker:restarted`. | Native logs the drop line; no segfault; no hang in webview's send promise (returns synchronously). |
| **Terminate during restart-pending** | Crash, then immediately call `Workers.terminate("h-…")` before `worker:restarted` fires. | Thread exits cleanly. No `worker:restarted` event. Slot becomes inactive. No leaked pthread. |
| **No-policy worker still crashes cleanly** | Headless worker with no `restart` field (defaults to `{maxRetries: 0}`). | `worker:crashed` fires once; supervisor verdict==0; worker idles (current behavior preserved). No restart attempted. |
| **Inbox drained on restart** | Send 5 messages, then crash. New incarnation. | New incarnation's `onmessage` does NOT receive any of the 5 pre-crash messages. Confirmed via JS-side counter that resets on each `worker:restarted`. |

The hello-world test is the integration baseline. The targeted tests land in a new `tests/workers/supervisor/` harness OR as benchmarks-style apps under `benchmarks/apps/` — to be decided in the implementation plan.

## File map

| File | Change |
|---|---|
| `native/worker/registry.zc` | Add `zapp_worker_supervisor_get_window_state(worker_id, *count, *cap, *window_ms)`. No protocol change. |
| `native/worker/engines/zjs.{c,h}` | Wrap `zjs_worker_thread` in outer loop; extract `setup_state` / `teardown_state(keep_loop)`; post-eval error check; new `worker:restarted` dispatch site; atomic flag handling; widen `host_worker_crash` payload. |
| `native/worker/engines/bare.{c,h}` | Same outer-loop + extracted helpers + post-eval check + widened payloads, applied to bare's lifecycle. |
| `native/worker/engines/txiki.{c,h}` | Same, applied to txiki's lifecycle. |
| `native/worker/engines/jsc.m` | Widen `jsc_dispatch_simple` → `jsc_dispatch_with_incarnation`; `jsc_build_crash_payload` gains `incarnation`. |
| `runtime/events.ts` | No change — events are string-keyed and payloads come via JSON. |
| `docs/api-reference.md` | Document `worker:crashed` / `worker:restarted` / `worker:gave-up` event shapes with the new `incarnation` field. |
| `docs/patterns.md` | New section: "Headless worker auto-restart" — covers config shape, event flow, send-gate pattern. |
| `hello-world/zapp.config.ts` | Drop the line that says supervisor "doesn't relaunch yet"; restart now works. |

## Out-of-scope follow-ons (track separately)

- SharedWorker deprecation question (`project_sharedworker_deprecation` memory).
- `Workers.list()` debug API (existing task #150) — would expose `incarnation` + supervisor state.
- Worker crash assertion test (existing task #154) — overlaps with the testing section above; merge in the implementation plan.
- Webview-spawned worker restart policy (future spec if customer ask emerges).
