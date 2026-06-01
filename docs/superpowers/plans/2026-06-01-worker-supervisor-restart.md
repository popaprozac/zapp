# Worker supervisor auto-restart — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Headless workers configured with `restart: { maxRetries, withinMs }` in `zapp.config.ts` automatically recreate their JS context after an uncaught throw, with identical behavior on `zjs`, `bare`, `txiki`, and `jsc` engines.

**Architecture:** Outer-loop reincarnation per worker thread — same `pthread` + `uv_loop_t` persist across restarts; only the engine context (ZjsContext / bare env / QuickJS runtime+context / JSContext) is recreated. `setup_state` has tri-state return (`OK` / `CRASHED` / `FATAL`). Atomic `wants_restart` / `wants_terminate` flags + `shutdown_async` signal coordinate teardown.

**Tech Stack:** Zen-C (registry.zc), C11 (zjs.c, bare.c, txiki.c, `<stdatomic.h>`), Objective-C (jsc.m), libuv (already in tree), hello-world TS demo for manual validation.

**Spec:** [`docs/superpowers/specs/2026-06-01-worker-supervisor-restart-design.md`](../specs/2026-06-01-worker-supervisor-restart-design.md)

---

## Phase 0 — Foundation

Shared infrastructure that engines depend on. Lands first so each engine phase can land independently afterwards.

### Task 0.1: Add supervisor window-state getter

The dev log line in each engine ("`restarting (incarnation 2, fail_count 1/3 in 30000ms window)`") reads the supervisor's window state. Add a read-only getter so engines don't reach into `ZappWorkerEntry` directly.

**Files:**
- Modify: `native/worker/registry.zc:298–302` (after `zapp_worker_supervisor_get_owner`)

- [ ] **Step 1: Add the getter**

After line 302 in `native/worker/registry.zc`, add:

```zc
    // Read-only window-state inspection. Used by engine dev logs on
    // restart ("incarnation N, fail_count X/cap in Yms window"). Returns
    // 0 on success, -1 if the worker isn't registered.
    int zapp_worker_supervisor_get_window_state(
        const char* worker_id,
        int* out_count,
        int* out_cap,
        int* out_window_ms
    ) {
        ZappWorkerEntry* e = zapp_worker_registry_get(worker_id);
        if (!e) return -1;
        if (out_count)     *out_count     = e->fail_count;
        if (out_cap)       *out_cap       = e->restart_max;
        if (out_window_ms) *out_window_ms = e->restart_window_ms;
        return 0;
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run from `/Users/zach/code/zapp`:
```bash
cd hello-world && bun run build
```
Expected: clean build (no `zc` errors). The new getter has no callers yet — that's fine.

- [ ] **Step 3: Commit**

```bash
git add native/worker/registry.zc
git commit -m "feat(worker-supervisor): add get_window_state read-only getter

Engines need fail_count / cap / window_ms for the dev log line on
restart; expose them via a clean getter instead of reaching into
ZappWorkerEntry directly."
```

---

### Task 0.2: Widen JSC event payloads with `incarnation`

JSC already restarts. Only its event payload shape needs to match the new uniform shape. Add an incarnation counter to each JSC worker and include it in the three events.

**Files:**
- Modify: `native/worker/engines/jsc.m:716–823` (supervisor + crash recovery section)
- Modify: the `jsc_workers[]` slot struct (search for `JSC_MAX_WORKERS`)

- [ ] **Step 1: Add `incarnation` field to jsc slot struct**

Find the `jsc_workers` struct definition (it's near `#define JSC_MAX_WORKERS`). Add an `int incarnation;` field next to `int active;`.

- [ ] **Step 2: Initialize incarnation on create + bump on restart**

In `jsc_worker_create` (line 757), after `jsc_workers[i].active = 1;` add:
```objc
jsc_workers[i].incarnation = 1;
```

Find the restart path in `ctx.exceptionHandler` (around line 818). Right after `[jsc_contexts removeObjectForKey:wid];` and before `jsc_worker_init_context(...)`, add:
```objc
for (int i = 0; i < JSC_MAX_WORKERS; i++) {
    if (jsc_workers[i].active && strcmp(jsc_workers[i].worker_id,
                                       [wid UTF8String]) == 0) {
        jsc_workers[i].incarnation++;
        break;
    }
}
```

- [ ] **Step 3: Helper to look up incarnation**

Near `jsc_dispatch_simple` (line 748), add:
```objc
static int jsc_incarnation_for(NSString* wid) {
    for (int i = 0; i < JSC_MAX_WORKERS; i++) {
        if (jsc_workers[i].active && strcmp(jsc_workers[i].worker_id,
                                            [wid UTF8String]) == 0) {
            return jsc_workers[i].incarnation;
        }
    }
    return 0;
}
```

- [ ] **Step 4: Widen `worker:restarted` and `worker:gave-up` payloads**

Replace `jsc_dispatch_simple` (line 748–753) with two helpers:
```objc
static void jsc_dispatch_restarted(NSString* wid) {
    NSDictionary* d = @{ @"id": wid ?: @"", @"incarnation": @(jsc_incarnation_for(wid)) };
    NSData* j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    NSString* payload = j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
    dispatch_event_to_all((char*)"worker:restarted", (char*)[payload UTF8String]);
}

static void jsc_dispatch_gave_up(NSString* wid) {
    int inc = jsc_incarnation_for(wid);
    NSDictionary* d = @{
        @"id": wid ?: @"",
        @"finalIncarnation": @(inc),
        @"retriesAttempted": @(inc > 0 ? inc - 1 : 0),
    };
    NSData* j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    NSString* payload = j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
    dispatch_event_to_all((char*)"worker:gave-up", (char*)[payload UTF8String]);
}
```

Replace the two call sites:
- Line ~807: `jsc_dispatch_simple("worker:gave-up", wid);` → `jsc_dispatch_gave_up(wid);`
- Line ~821: `jsc_dispatch_simple("worker:restarted", wid);` → `jsc_dispatch_restarted(wid);`

(There are two `worker:restarted` call sites if the exceptionHandler has been refactored — search for `jsc_dispatch_simple` and replace each appropriately.)

- [ ] **Step 5: Widen `worker:crashed` payload with `incarnation`**

In `jsc_build_crash_payload` (line 739), change:
```objc
NSDictionary* d = @{ @"id": wid ?: @"", @"message": msg ?: @"", @"stack": stack ?: @"" };
```
to:
```objc
NSDictionary* d = @{
    @"id": wid ?: @"",
    @"message": msg ?: @"",
    @"stack": stack ?: @"",
    @"incarnation": @(jsc_incarnation_for(wid)),
};
```

- [ ] **Step 6: Build hello-world to verify the JSC path still works**

```bash
cd hello-world && bun run dev
```

Manually verify the supervisor demo:
1. Click "force-crash" three times.
2. Output panel shows: `worker:crashed × 3`, `worker:restarted × 2`, `worker:gave-up × 1`.
3. Each event's payload includes `incarnation` (visible in webview console).

Kill with Ctrl-C when verified.

- [ ] **Step 7: Commit**

```bash
git add native/worker/engines/jsc.m
git commit -m "feat(jsc-worker): widen event payloads with incarnation field

Aligns jsc.m's worker:crashed / worker:restarted / worker:gave-up
payloads with the upcoming uniform shape across zjs/bare/txiki.
Existing JSC restart path is otherwise unchanged."
```

---

## Phase 1 — zjs engine implementation

The biggest delta because of zjs's rooted helpers + 5 uv handles + custom timer-loop integration. Once this lands, zjs workers restart end-to-end.

### Task 1.1: Add atomic flags + incarnation field to slot

Replace the existing `int shutting_down;` field with two atomic flags + an incarnation counter.

**Files:**
- Modify: `native/worker/engines/zjs.c:155–161` (`ZjsWorkerSlot` definition)

- [ ] **Step 1: Add `<stdatomic.h>` include**

After line 36 (`#include <uv.h>`), add:
```c
#include <stdatomic.h>
```

- [ ] **Step 2: Replace `shutting_down` with the new fields**

In `ZjsWorkerSlot` (line 155–161), replace:
```c
    // Shutdown latch — set by zjs_worker_terminate from any thread,
    // observed by the worker thread when shutdown_async fires.
    int          shutting_down;
```
with:
```c
    // Reincarnation counter — 1 on first start, +1 each successful restart.
    // Read on the worker thread inside setup_state; written there too.
    int incarnation;

    // Control flags — set from host_worker_crash (worker thread) or
    // from zjs_worker_terminate (any thread). The shutdown_async signal
    // wakes the loop; the while-loop in zjs_worker_thread reads these
    // after uv_run returns. wants_terminate wins over wants_restart.
    _Atomic int wants_restart;
    _Atomic int wants_terminate;
```

- [ ] **Step 3: Update `zjs_worker_terminate` to set the new flag**

Search for the existing `slot->shutting_down = 1;` assignment (probably in `zjs_worker_terminate`). Replace with:
```c
atomic_store(&slot->wants_terminate, 1);
```

Search for any other reads of `shutting_down` (e.g., in `on_shutdown_async`) and replace with `atomic_load(&slot->wants_terminate)`.

- [ ] **Step 4: Build to verify**

```bash
cd hello-world && bun run build
```
Expected: clean compile. Behavior is unchanged — flags are written but not yet driving any new logic.

- [ ] **Step 5: Commit**

```bash
git add native/worker/engines/zjs.c
git commit -m "refactor(zjs-worker): replace shutting_down latch with atomic wants_restart/wants_terminate

Prep for outer-loop reincarnation: the worker thread will need to
distinguish 'graceful termination requested' from 'crash-and-restart
requested' after uv_run returns. Behavior unchanged."
```

---

### Task 1.2: Extract `zjs_worker_setup_state` / `zjs_worker_teardown_state`

The current `zjs_worker_thread` (line 970–1199) has one linear body. Extract the setup half (post-`uv_loop_init`) into one helper and the teardown half (handle close + ctx free) into another. **No behavior change** — pure refactor.

**Files:**
- Modify: `native/worker/engines/zjs.c:970–1199`

- [ ] **Step 1: Define the tri-state enum and helper signatures**

Above `zjs_worker_thread` (around line 965), add:
```c
// setup_state outcome — drives the outer reincarnation loop.
typedef enum {
    ZJS_SETUP_OK = 0,         // ctx + bridge + bootstrap + script eval all OK
    ZJS_SETUP_CRASHED = 1,    // script eval threw; host_worker_crash already called
    ZJS_SETUP_FATAL = 2,      // uv_loop_init or zjs_new_context failed — unrecoverable
} ZjsSetupResult;

static ZjsSetupResult zjs_worker_setup_state(ZjsWorkerSlot* slot);
static void zjs_worker_teardown_state(ZjsWorkerSlot* slot, int keep_loop);
```

- [ ] **Step 2: Move the setup body into `zjs_worker_setup_state`**

Cut lines 980–1156 of the current `zjs_worker_thread` (from `slot->ctx = zjs_new_context();` through `uv_timer_start(&slot->zjs_wake, ...)`) and paste them into:
```c
static ZjsSetupResult zjs_worker_setup_state(ZjsWorkerSlot* slot) {
    slot->ctx = zjs_new_context();
    if (!slot->ctx) {
        fprintf(stderr, "[zapp] zjs worker '%s' zjs_new_context failed\n", slot->worker_id);
        return ZJS_SETUP_FATAL;
    }

    // <existing setup code: zjs_setup_bridge, self alias, bootstrap eval,
    //  setTimeout re-alias, uv handle inits, load_script, zjs_eval_module_source
    //  or zjs_eval_bytecode, the post-eval error reporting, free(code),
    //  uv_timer_start for next zjs timer>

    return ZJS_SETUP_OK;  // we'll return CRASHED from inside the eval-error block next task
}
```

- [ ] **Step 3: Move teardown into `zjs_worker_teardown_state`**

Cut lines 1159–1199 of the current `zjs_worker_thread` (from the `teardown:` label through `slot->active = 0;`) and paste into:
```c
static void zjs_worker_teardown_state(ZjsWorkerSlot* slot, int keep_loop) {
    if (slot->loop_initialized) {
        uv_check_stop(&slot->check);
        uv_timer_stop(&slot->zjs_wake);
        uv_close((uv_handle_t*) &slot->check,            NULL);
        uv_close((uv_handle_t*) &slot->zjs_wake,         NULL);
        uv_close((uv_handle_t*) &slot->shutdown_async,   NULL);
        uv_close((uv_handle_t*) &slot->inbox_async,      NULL);
        uv_close((uv_handle_t*) &slot->eval_inbox_async, NULL);
        // Drain close callbacks. UV_RUN_DEFAULT would block forever if
        // any handle were still open, but we closed everything above —
        // it returns once the close callbacks all fire.
        uv_run(&slot->loop, UV_RUN_DEFAULT);
        if (!keep_loop) {
            uv_loop_close(&slot->loop);
            slot->loop_initialized = 0;
        }
    }
    // Drain stranded inbox + eval_inbox before destroying mutexes.
    {
        char* drained;
        while ((drained = inbox_pop(slot)) != NULL) free(drained);
        pthread_mutex_destroy(&slot->inbox_mutex);
        while ((drained = eval_inbox_pop(slot)) != NULL) free(drained);
        pthread_mutex_destroy(&slot->eval_inbox_mutex);
    }
    if (slot->ctx) {
        if (slot->object_keys_root)    zjs_unroot(slot->ctx, slot->object_keys_root);
        if (slot->json_parse_root)     zjs_unroot(slot->ctx, slot->json_parse_root);
        if (slot->json_stringify_root) zjs_unroot(slot->ctx, slot->json_stringify_root);
        zjs_free_context(slot->ctx);
        slot->ctx = NULL;
    }
    slot->active = 0;
}
```

- [ ] **Step 4: Slim `zjs_worker_thread` to call the helpers**

Replace the now-emptied middle of `zjs_worker_thread` so the function becomes:
```c
static void* zjs_worker_thread(void* arg) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) arg;

    if (uv_loop_init(&slot->loop) != 0) {
        fprintf(stderr, "[zapp] zjs worker '%s' uv_loop_init failed\n", slot->worker_id);
        slot->active = 0;
        return NULL;
    }
    slot->loop_initialized = 1;
    slot->incarnation = 1;

    ZjsSetupResult setup = zjs_worker_setup_state(slot);
    if (setup == ZJS_SETUP_FATAL) {
        zjs_worker_teardown_state(slot, /*keep_loop=*/0);
        fprintf(stderr, "[zapp] zjs worker '%s' setup failed\n", slot->worker_id);
        return NULL;
    }

    uv_run(&slot->loop, UV_RUN_DEFAULT);

    zjs_worker_teardown_state(slot, /*keep_loop=*/0);
    fprintf(stderr, "[zapp] zjs worker '%s' exited\n", slot->worker_id);
    return NULL;
}
```

- [ ] **Step 5: Build + smoke test (no behavior change expected)**

```bash
cd hello-world && bun run dev
```

Click around — ticker should tick, supervisor demo should still produce `worker:crashed` (without restart yet — that's the next task). Behavior must be identical to before the refactor. Kill with Ctrl-C.

- [ ] **Step 6: Commit**

```bash
git add native/worker/engines/zjs.c
git commit -m "refactor(zjs-worker): extract setup_state/teardown_state helpers

Pure refactor splitting zjs_worker_thread's linear body into reusable
setup/teardown halves with a tri-state outcome enum. Prep for the outer
reincarnation loop. No behavior change."
```

---

### Task 1.3: Wire the outer reincarnation loop

Now wrap the setup/run/teardown sequence in a `while (1)` reincarnation loop and check the atomic flags after each iteration.

**Files:**
- Modify: `native/worker/engines/zjs.c` `zjs_worker_thread`

- [ ] **Step 1: Replace `zjs_worker_thread` body with the outer loop**

Replace the body from Task 1.2 Step 4 with:
```c
static void* zjs_worker_thread(void* arg) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) arg;

    if (uv_loop_init(&slot->loop) != 0) {
        fprintf(stderr, "[zapp] zjs worker '%s' uv_loop_init failed\n", slot->worker_id);
        slot->active = 0;
        return NULL;
    }
    slot->loop_initialized = 1;
    slot->incarnation = 0;

    while (1) {
        slot->incarnation++;

        ZjsSetupResult setup = zjs_worker_setup_state(slot);

        if (setup == ZJS_SETUP_FATAL) {
            fprintf(stderr, "[zapp] zjs worker '%s' setup fatal\n", slot->worker_id);
            break;
        }

        if (setup == ZJS_SETUP_CRASHED) {
            // host_worker_crash already fired; wants_restart set per
            // supervisor verdict. Skip uv_run — nothing live to run.
            zjs_worker_teardown_state(slot, /*keep_loop=*/1);
        } else {
            // SETUP_OK
            if (slot->incarnation > 1) {
                char payload[128];
                snprintf(payload, sizeof(payload),
                         "{\"id\":\"%s\",\"incarnation\":%d}",
                         slot->worker_id, slot->incarnation);
                dispatch_event_to_all("worker:restarted", payload);
                fprintf(stderr, "[zapp] zjs worker '%s' restarting (incarnation %d)\n",
                        slot->worker_id, slot->incarnation);
            }

            uv_run(&slot->loop, UV_RUN_DEFAULT);

            zjs_worker_teardown_state(slot, /*keep_loop=*/1);
        }

        if (atomic_load(&slot->wants_terminate)) break;
        if (!atomic_load(&slot->wants_restart)) break;
        atomic_store(&slot->wants_restart, 0);
    }

    // Final cleanup — close the loop now that we're really exiting.
    if (slot->loop_initialized) {
        uv_run(&slot->loop, UV_RUN_NOWAIT);
        uv_loop_close(&slot->loop);
        slot->loop_initialized = 0;
    }
    slot->active = 0;
    fprintf(stderr, "[zapp] zjs worker '%s' exited\n", slot->worker_id);
    return NULL;
}
```

- [ ] **Step 2: Build + verify the worker still starts/stops cleanly**

```bash
cd hello-world && bun run dev
```

The ticker worker should tick normally — outer loop runs one incarnation and waits in `uv_run`. Crash a worker via the supervisor demo: `worker:crashed` still fires once and then idles (no restart yet because `host_worker_crash` doesn't set `wants_restart` yet — that's Task 1.4).

Kill with Ctrl-C. Worker should exit cleanly with the "exited" log line.

- [ ] **Step 3: Commit**

```bash
git add native/worker/engines/zjs.c
git commit -m "feat(zjs-worker): wrap thread main in outer reincarnation loop

The loop checks wants_terminate then wants_restart after each iteration's
teardown. host_worker_crash and synthetic crash detection in setup_state
will drive wants_restart in the next two tasks."
```

---

### Task 1.4: Make `host_worker_crash` request a restart on verdict==1

The existing `host_worker_crash` at line 589–625 fires `worker:gave-up` for *any* non-zero verdict, conflating restart-approved (1) with gave-up (2). Fix that and add the restart-request path.

**Files:**
- Modify: `native/worker/engines/zjs.c:589–625`

- [ ] **Step 1: Replace the verdict handling**

In `host_worker_crash`, find:
```c
    int decision = zapp_worker_supervisor_record_failure(slot->worker_id);
    if (decision != 0) {
        char giveUp[256];
        snprintf(giveUp, sizeof(giveUp), "{\"id\":\"%s\"}", slot->worker_id);
        dispatch_event_to_all("worker:gave-up", giveUp);
    }
```

Replace with:
```c
    int decision = zapp_worker_supervisor_record_failure(slot->worker_id);
    if (decision == 1) {
        // Restart approved. Signal the outer loop in zjs_worker_thread
        // to break uv_run and re-incarnate the JS state.
        atomic_store(&slot->wants_restart, 1);
        uv_async_send(&slot->shutdown_async);
    } else if (decision == 2) {
        // Cap exhausted — supervisor's gave_up flag is now sticky.
        char payload[256];
        snprintf(payload, sizeof(payload),
                 "{\"id\":\"%s\",\"finalIncarnation\":%d,\"retriesAttempted\":%d}",
                 slot->worker_id, slot->incarnation,
                 slot->incarnation > 0 ? slot->incarnation - 1 : 0);
        dispatch_event_to_all("worker:gave-up", payload);
    }
    // decision == 0: no policy configured, worker idles in current state.
```

- [ ] **Step 2: Widen the `worker:crashed` payload with incarnation**

Earlier in `host_worker_crash` (the snprintf call near line 603), change:
```c
        snprintf(payload, need,
                 "{\"id\":\"%s\",\"message\":%s,\"stack\":%s}",
                 slot->worker_id, msg_v, stack_v);
```
to:
```c
        snprintf(payload, need,
                 "{\"id\":\"%s\",\"message\":%s,\"stack\":%s,\"incarnation\":%d}",
                 slot->worker_id, msg_v, stack_v, slot->incarnation);
```

(The `need` calc adds 64 of slack — incarnation is ≤10 digits, fits easily.)

- [ ] **Step 3: Build + manually verify restart fires**

```bash
cd hello-world && bun run dev
```

Open the webview. Verify hello-world has the supervisor demo on the engine you're testing. The headless `supervised` worker is already on `engine: "zjs"` (per `hello-world/zapp.config.ts:45`).

Click "force-crash":
1. First click → output panel shows: `worker:crashed (h-supervised, "forced crash from supervisor demo", incarnation 1)` then `worker:restarted (h-supervised, incarnation 2)`.
2. Stderr in your terminal shows: `[zapp] zjs worker 'h-supervised' restarting (incarnation 2)`.
3. Second click → same pattern, incarnation goes to 3.
4. Third click → `worker:crashed (... incarnation 3)` then `worker:gave-up (... finalIncarnation 3, retriesAttempted 2)`. No restart.
5. Fourth click → nothing happens (worker stays dead).

Kill with Ctrl-C when verified.

- [ ] **Step 4: Commit**

```bash
git add native/worker/engines/zjs.c
git commit -m "feat(zjs-worker): host_worker_crash drives wants_restart on verdict==1

Splits the supervisor verdict handling so verdict==1 requests an in-place
incarnation reset (atomic flag + uv_async_send) and verdict==2 fires the
new worker:gave-up payload with finalIncarnation/retriesAttempted.
Payload of worker:crashed gains incarnation."
```

---

### Task 1.5: Synthetic crash on post-eval error in `setup_state`

Top-level script-eval throws today print to stderr and the worker idles. Make them count as crashes so the supervisor can restart broken-from-start workers and eventually give up.

**Files:**
- Modify: `native/worker/engines/zjs.c` `zjs_worker_setup_state` (extracted in Task 1.2)

- [ ] **Step 1: Add a static helper to synthesize a crash**

Above `zjs_worker_setup_state`, add a small helper that mirrors what `host_worker_crash` does but takes the message + stack as C strings (since we're not inside a JS host-call):
```c
// Synthetic crash signal — called from setup_state when zjs_eval_module_source
// or zjs_eval_bytecode returns an error at top level. Mirrors host_worker_crash's
// dispatch + supervisor handshake without needing a live JS frame.
static void zjs_setup_synthesize_crash(ZjsWorkerSlot* slot, const char* msg, const char* stack) {
    size_t mlen = msg ? strlen(msg) : 0;
    size_t slen = stack ? strlen(stack) : 0;
    size_t need = strlen(slot->worker_id) + mlen + slen + 128;
    char* payload = (char*) malloc(need);
    if (payload) {
        // Embed message + stack as JSON strings — for safety we JSON-escape
        // here. msg/stack already came from zjs_string_bytes so they're UTF-8
        // but may contain quotes/backslashes/control chars. Hand off to the
        // existing safe-escape helper used elsewhere in the file (zapp_escape_dup
        // is declared in bridge/dispatch.zc).
        extern char* zapp_escape_dup(const char* s);
        char* msg_esc   = zapp_escape_dup(msg   ? msg   : "");
        char* stack_esc = zapp_escape_dup(stack ? stack : "");
        snprintf(payload, need,
                 "{\"id\":\"%s\",\"message\":\"%s\",\"stack\":\"%s\",\"incarnation\":%d}",
                 slot->worker_id,
                 msg_esc   ? msg_esc   : "",
                 stack_esc ? stack_esc : "",
                 slot->incarnation);
        dispatch_event_to_all("worker:crashed", payload);
        free(msg_esc);
        free(stack_esc);
        free(payload);
    }

    int decision = zapp_worker_supervisor_record_failure(slot->worker_id);
    if (decision == 1) {
        atomic_store(&slot->wants_restart, 1);
    } else if (decision == 2) {
        char gp[256];
        snprintf(gp, sizeof(gp),
                 "{\"id\":\"%s\",\"finalIncarnation\":%d,\"retriesAttempted\":%d}",
                 slot->worker_id, slot->incarnation,
                 slot->incarnation > 0 ? slot->incarnation - 1 : 0);
        dispatch_event_to_all("worker:gave-up", gp);
    }
}
```

- [ ] **Step 2: Call it from the post-eval error block, return CRASHED**

In `zjs_worker_setup_state`, find the existing post-eval error-reporting block (where `zjs_had_error(slot->ctx)` is checked after `zjs_eval_module_source` / `zjs_eval_bytecode`). After printing the error, capture msg + stack into stack-allocated buffers and call the helper:

```c
    if (zjs_had_error(slot->ctx)) {
        ZjsValue err = zjs_get_error(slot->ctx);
        const char* msg = NULL;
        uint32_t    mlen = 0;
        ZjsValue    msg_val = zjs_get_property(slot->ctx, err, "message");
        if (zjs_is_string(msg_val)) msg = zjs_string_bytes(msg_val, &mlen);
        if (!msg)                   msg = zjs_string_bytes(err, &mlen);

        const char* stack = NULL;
        uint32_t    slen  = 0;
        ZjsValue    stack_val = zjs_get_property(slot->ctx, err, "stack");
        if (zjs_is_string(stack_val)) stack = zjs_string_bytes(stack_val, &slen);

        fprintf(stderr, "[zapp] zjs worker '%s' script threw: %.*s%s%.*s\n",
            slot->worker_id,
            (int) mlen, msg ? msg : "<unreadable>",
            stack ? "\n" : "",
            (int) slen, stack ? stack : "");

        // Copy to NUL-terminated buffers before the slot's error state changes.
        char msg_buf[1024]   = {0};
        char stack_buf[4096] = {0};
        if (msg)   { size_t cp = mlen < sizeof(msg_buf)   - 1 ? mlen : sizeof(msg_buf)   - 1; memcpy(msg_buf,   msg,   cp); }
        if (stack) { size_t cp = slen < sizeof(stack_buf) - 1 ? slen : sizeof(stack_buf) - 1; memcpy(stack_buf, stack, cp); }

        free(code);
        zjs_setup_synthesize_crash(slot, msg_buf, stack_buf);
        return ZJS_SETUP_CRASHED;
    }
    free(code);
```

(Move the existing `free(code);` to *only* happen on the non-error path now. If your refactor already had `free(code)` before the `if (had_error)`, leave that alone and just add `free(code)` inside the error block before the synthesize call.)

- [ ] **Step 3: Also handle script-load failure as a synthetic crash**

Earlier in `setup_state`, where `zjs_load_script` returns NULL — currently `goto teardown` (or similar). Replace with:
```c
    if (!code) {
        fprintf(stderr, "[zapp] zjs worker script not found: %s\n", slot->script_url);
        zjs_setup_synthesize_crash(slot, "script load failed", "");
        return ZJS_SETUP_CRASHED;
    }
```

- [ ] **Step 4: Build + verify broken-from-start works**

Author a temporary broken-on-start worker in hello-world for manual verification:

Create `hello-world/src/workers/broken-from-start.ts`:
```ts
console.log("[broken] starting");
throw new Error("broken from start, immediate top-level throw");
```

Wire it into `hello-world/zapp.config.ts`:
```ts
headless: {
  // ... existing ...
  broken: {
    script: "src/workers/broken-from-start.ts",
    engine: "zjs",
    restart: { maxRetries: 2, withinMs: 30_000 },
  },
},
```

Run:
```bash
cd hello-world && bun run dev
```

Expected within ~1 second of launch:
- 3 `worker:crashed` events for `h-broken` (incarnations 1, 2, 3).
- 2 `worker:restarted` events (incarnations 2, 3).
- 1 `worker:gave-up` event (finalIncarnation 3, retriesAttempted 2).
- Stderr shows the synthetic crash messages from each incarnation.

Kill with Ctrl-C.

- [ ] **Step 5: Revert hello-world changes**

The broken-from-start worker was for verification only — leave it as a comment in `zapp.config.ts` for future testing but keep it disabled:
```ts
// Verification-only — re-enable to exercise broken-from-start supervisor flow.
// broken: {
//   script: "src/workers/broken-from-start.ts",
//   engine: "zjs",
//   restart: { maxRetries: 2, withinMs: 30_000 },
// },
```

Keep `hello-world/src/workers/broken-from-start.ts` in place so re-enabling is one comment toggle away.

- [ ] **Step 6: Commit**

```bash
git add native/worker/engines/zjs.c hello-world/src/workers/broken-from-start.ts hello-world/zapp.config.ts
git commit -m "feat(zjs-worker): top-level script throws count as supervised crashes

Synthetic host_worker_crash equivalent fires from setup_state when
zjs_eval_module_source returns with had_error, or when zjs_load_script
fails to find the file. Both now go through the supervisor cap.
Adds a disabled broken-from-start hello-world worker for regression
verification."
```

---

### Task 1.6: Dev log line + message-during-gap drop

Two small polishes: a richer dev log line at restart, and a clear stderr message when `worker_post_message` drops a message because the worker is mid-restart.

**Files:**
- Modify: `native/worker/engines/zjs.c` (the restart log line in `zjs_worker_thread`)
- Modify: `native/worker/engines/zjs.c` (`zjs_worker_post_message` or equivalent)

- [ ] **Step 1: Declare the supervisor getter near the existing externs**

Near line 86 (where `zapp_worker_supervisor_record_failure` is declared), add:
```c
extern int zapp_worker_supervisor_get_window_state(
    const char* worker_id, int* out_count, int* out_cap, int* out_window_ms);
```

- [ ] **Step 2: Enrich the restart log line**

In `zjs_worker_thread`'s `if (slot->incarnation > 1)` block, replace the existing log with:
```c
    if (slot->incarnation > 1) {
        char payload[128];
        snprintf(payload, sizeof(payload),
                 "{\"id\":\"%s\",\"incarnation\":%d}",
                 slot->worker_id, slot->incarnation);
        dispatch_event_to_all("worker:restarted", payload);
        int fc = 0, cap = 0, win = 0;
        zapp_worker_supervisor_get_window_state(slot->worker_id, &fc, &cap, &win);
        fprintf(stderr, "[zapp] zjs worker '%s' restarting (incarnation %d, "
                        "fail_count %d/%d in %dms window)\n",
                slot->worker_id, slot->incarnation, fc, cap, win);
    }
```

- [ ] **Step 3: Drop messages during the restart gap**

Find `zjs_worker_post_message` (search for the function). At the top, after the slot lookup, add:
```c
    if (!slot || !slot->active || !slot->ctx) {
        fprintf(stderr, "[zapp] zjs worker '%s' message dropped "
                        "(worker not ready; incarnation %d)\n",
                worker_id, slot ? slot->incarnation : 0);
        return;
    }
```
(Adjust to match the existing function signature — the slot might be looked up before this point.)

- [ ] **Step 4: Build + verify the log line**

```bash
cd hello-world && bun run dev
```

Force-crash the supervisor demo once; stderr should show:
```
[zapp] zjs worker 'h-supervised' restarting (incarnation 2, fail_count 1/2 in 30000ms window)
```

(Cap is 2 because `restart: { maxRetries: 2 }` in hello-world/zapp.config.ts.)

- [ ] **Step 5: Commit**

```bash
git add native/worker/engines/zjs.c
git commit -m "feat(zjs-worker): dev log + drop messages arriving during restart gap

worker:restarted log line now includes fail_count/cap/window_ms via
the new supervisor getter. worker_post_message drops with a stderr
line if the slot is mid-restart so callers don't lose messages silently."
```

---

## Phase 2 — bare engine implementation

Mirror Phase 1 for `bare.c`. The structure is identical; the only differences live inside `setup_state` / `teardown_state` (bare's NAPI lifecycle vs. zjs's ZjsContext).

### Task 2.1: Atomic flags + incarnation on bare slot

**Files:**
- Modify: `native/worker/engines/bare.c` (slot struct definition)

- [ ] **Step 1: Add `<stdatomic.h>` include and the new fields**

Same shape as Task 1.1 — add `incarnation`, `_Atomic int wants_restart`, `_Atomic int wants_terminate` to bare's slot struct. Replace any existing `shutting_down` flag with `wants_terminate`. Update any reads.

- [ ] **Step 2: Build + smoke**

```bash
cd hello-world && bun run dev
```
(Flip the supervised worker temporarily to `engine: "bare-jsc"` in hello-world/zapp.config.ts. Behavior should be unchanged — flags written but inert.)

- [ ] **Step 3: Commit**

```bash
git add native/worker/engines/bare.c
git commit -m "refactor(bare-worker): atomic wants_restart/wants_terminate + incarnation"
```

### Task 2.2: Extract `bare_worker_setup_state` / `bare_worker_teardown_state`

**Files:**
- Modify: `native/worker/engines/bare.c` (current `bare_worker_thread`)

- [ ] **Step 1: Define tri-state enum + helper signatures**

Same shape as Task 1.2 Step 1 but with `BARE_SETUP_OK/CRASHED/FATAL` and `bare_worker_setup_state` / `bare_worker_teardown_state`.

- [ ] **Step 2: Move bare's context init into `setup_state`**

`setup_state` contents (in order):
- `bare_init(loop)` (or whatever the bare entry call is — check bare.c's existing thread body)
- Host-function registration (the `bare_host_*` table at line ~1371)
- Script load
- `bare_load` of the script
- Post-load error check (will return `BARE_SETUP_CRASHED` once Task 2.5 lands; for this task, mirror the zjs error path as a `return BARE_SETUP_OK;` placeholder)

- [ ] **Step 3: Move teardown into `teardown_state(keep_loop)`**

- `bare_destroy` (or equivalent) — drops NAPI refs, frees the env.
- uv handle close + drain (same pattern as zjs).
- Inbox drain + mutex destroy.
- If `!keep_loop`: `uv_loop_close`.

- [ ] **Step 4: Slim `bare_worker_thread` to call helpers**

Same shape as zjs in Task 1.2 Step 4.

- [ ] **Step 5: Build + smoke**

```bash
cd hello-world && bun run dev
```
Verify ticker / supervised workers run normally on `bare-jsc`. No behavior change yet.

- [ ] **Step 6: Commit**

```bash
git add native/worker/engines/bare.c
git commit -m "refactor(bare-worker): extract setup_state/teardown_state helpers"
```

### Task 2.3: Wire the outer reincarnation loop

**Files:**
- Modify: `native/worker/engines/bare.c` `bare_worker_thread`

- [ ] **Step 1: Wrap thread body in `while (1)` loop**

Same shape as Task 1.3 Step 1, swapping `zjs_*` → `bare_*` and `ZjsSetupResult` → `BareSetupResult`.

- [ ] **Step 2: Build + smoke**

- [ ] **Step 3: Commit**

```bash
git add native/worker/engines/bare.c
git commit -m "feat(bare-worker): outer reincarnation loop"
```

### Task 2.4: `bare_host_worker_crash` drives wants_restart

**Files:**
- Modify: `native/worker/engines/bare.c:1218–1253` (`bare_host_worker_crash`)

- [ ] **Step 1: Mirror Task 1.4's verdict handling**

Replace the existing `zapp_worker_supervisor_record_failure(slot->worker_id);` block with the same verdict switch (1 → set `wants_restart`, signal `shutdown_async`; 2 → dispatch `worker:gave-up` with the wider payload; 0 → no-op). Widen `worker:crashed` payload with `incarnation`.

- [ ] **Step 2: Verify with `engine: "bare-jsc"` in hello-world supervised demo**

Identical event sequence to the zjs run (Task 1.4 Step 3).

- [ ] **Step 3: Commit**

```bash
git add native/worker/engines/bare.c
git commit -m "feat(bare-worker): host_worker_crash drives wants_restart on verdict==1"
```

### Task 2.5: Synthetic crash on post-`bare_load` error

**Files:**
- Modify: `native/worker/engines/bare.c` `bare_worker_setup_state`

- [ ] **Step 1: Add `bare_setup_synthesize_crash`**

Same shape as Task 1.5 Step 1, adapted for bare. The dispatch / supervisor call is identical — only the trigger point differs.

- [ ] **Step 2: Wire from the post-load error branch + script-not-found branch**

- [ ] **Step 3: Verify with the broken-from-start worker on `engine: "bare-jsc"`**

Toggle hello-world's broken worker to `engine: "bare-jsc"`. Same expected event sequence as Task 1.5.

- [ ] **Step 4: Commit**

```bash
git add native/worker/engines/bare.c
git commit -m "feat(bare-worker): top-level script throws count as supervised crashes"
```

### Task 2.6: Dev log + message-during-gap drop

Same shape as Task 1.6. Add the supervisor extern, enrich the log, drop messages on `slot->active == 0` in `bare_worker_post_message`.

- [ ] **Steps 1–4: Same as Task 1.6 with bare-prefixed identifiers**

- [ ] **Step 5: Commit**

```bash
git add native/worker/engines/bare.c
git commit -m "feat(bare-worker): dev log + drop messages arriving during restart gap"
```

---

## Phase 3 — txiki engine implementation

Same shape as Phase 2, applied to `txiki.c`. txiki's per-worker context is QuickJS's `JS_NewRuntime` + `JS_NewContext`; teardown is `JS_FreeContext` + `JS_FreeRuntime`.

### Task 3.1: Atomic flags + incarnation on txiki slot

- [ ] Same as Task 2.1 but for `txiki.c`.

### Task 3.2: Extract `txiki_worker_setup_state` / `txiki_worker_teardown_state`

- [ ] Same as Task 2.2. `setup_state` does `JS_NewRuntime` → `JS_NewContext` → txiki bootstrap → bridge install → script load → `JS_Eval`. `teardown_state` does `JS_FreeContext` → `JS_FreeRuntime` → uv handles + inboxes.

### Task 3.3: Wire outer reincarnation loop

- [ ] Same as Task 2.3.

### Task 3.4: `txiki_host_worker_crash` drives wants_restart

**Files:**
- Modify: `native/worker/engines/txiki.c:617–652` (current crash handler)

- [ ] Same shape as Task 2.4. Verify with `engine: "txiki"` in hello-world's supervised demo.

### Task 3.5: Synthetic crash on post-`JS_Eval` error

- [ ] Same as Task 2.5.

### Task 3.6: Dev log + message-during-gap drop

- [ ] Same as Task 2.6.

---

## Phase 4 — Validation & docs

### Task 4.1: Cross-engine smoke matrix on hello-world

**Files:**
- Modify: `hello-world/zapp.config.ts` (temporary per-engine flips)

- [ ] **Step 1: Run the supervisor demo on each engine**

For each engine in `["zjs", "bare-jsc", "txiki"]`:

1. Edit `hello-world/zapp.config.ts`:
   ```ts
   headless: {
     supervised: {
       script: "src/workers/supervised.ts",
       restart: { maxRetries: 2, withinMs: 30_000 },
       engine: "<ENGINE>",   // flip this
     },
     // ...
   }
   ```
2. `cd hello-world && bun run dev`
3. Click "force-crash" four times. Verify event sequence in the output panel:
   ```
   1: worker:crashed (h-supervised, incarnation 1) → worker:restarted (incarnation 2)
   2: worker:crashed (h-supervised, incarnation 2) → worker:restarted (incarnation 3)
   3: worker:crashed (h-supervised, incarnation 3) → worker:gave-up (finalIncarnation 3, retriesAttempted 2)
   4: (nothing — worker is dead)
   ```
4. Kill with Ctrl-C.

- [ ] **Step 2: Restore default engine in zapp.config.ts**

Revert `supervised.engine` to `"zjs"`. Leave a comment:
```ts
// Engine choices verified end-to-end for supervisor auto-restart:
//   zjs, bare-jsc, txiki — identical event sequence.
```

- [ ] **Step 3: Commit**

```bash
git add hello-world/zapp.config.ts
git commit -m "test(supervisor): record cross-engine restart smoke verification"
```

### Task 4.2: Document the events in api-reference.md

**Files:**
- Modify: `docs/api-reference.md` (the `Events` section, around the `eventName` block)

- [ ] **Step 1: Add a "Worker lifecycle events" subsection**

After the `eventName(...)` description (around line 240), add:

```markdown
### Worker lifecycle events

Three engine-fired events let webviews observe supervised headless workers:

- `worker:crashed` — fires on every uncaught throw in a worker. Payload:
  ```ts
  { id: string; message: string; stack: string; incarnation: number }
  ```
- `worker:restarted` — fires after a successful restart (incarnation ≥ 2). Payload:
  ```ts
  { id: string; incarnation: number }
  ```
- `worker:gave-up` — fires once when the supervisor cap is exhausted. Payload:
  ```ts
  { id: string; finalIncarnation: number; retriesAttempted: number }
  ```

`incarnation` lets a UI correlate which restart cycle a crash belongs to.
Webviews wanting to gate sends on a clean worker should listen for
`worker:restarted` after a `worker:crashed`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/api-reference.md
git commit -m "docs: document worker:crashed / worker:restarted / worker:gave-up event payloads"
```

### Task 4.3: Add "Headless worker auto-restart" pattern

**Files:**
- Modify: `docs/patterns.md` (insert near the existing supervisor/headless sections)

- [ ] **Step 1: Add the new pattern section**

Find the existing "Headless worker broadcasting to all windows" section (around `patterns.md:48`). After it, insert:

````markdown
## Headless worker auto-restart

Configure a restart policy in `zapp.config.ts` so the supervisor recreates
the worker's JS context after an uncaught throw. After `maxRetries`
failures inside `withinMs`, the supervisor gives up.

```ts
// zapp.config.ts
headless: {
  sync: {
    script: "src/workers/sync.ts",
    engine: "zjs",
    restart: { maxRetries: 3, withinMs: 60_000 },
  },
}
```

```ts
// src/main.ts — observe the worker's lifecycle
import { Events } from "@zappdev/runtime";

Events.on("worker:crashed", ({ id, message, incarnation }) => {
  console.warn(`[${id}] crashed (incarnation ${incarnation}): ${message}`);
});

Events.on("worker:restarted", ({ id, incarnation }) => {
  console.log(`[${id}] restarted as incarnation ${incarnation}`);
});

Events.on("worker:gave-up", ({ id, retriesAttempted }) => {
  // Supervisor capped out — show a user-facing "background sync paused" toast.
  alert(`${id} stopped after ${retriesAttempted} restart attempts.`);
});
```

**Clean-slate semantics.** Each incarnation starts with a fresh JS
context: timers, channel handlers, in-flight inbox messages from the
prior incarnation are all gone. If a webview tries `Workers.send(id,
"channel", data)` during the restart gap, the message is dropped with
a stderr log. The simplest pattern: gate sends on the next
`worker:restarted` after a `worker:crashed`.

**Top-level vs async throws.** Both count as crashes against the cap. A
worker whose script throws at module top will burn through `maxRetries`
in a few milliseconds and surface `worker:gave-up` — no infinite restart
loop possible.

**Window decay.** The supervisor's `withinMs` is a sliding window: after
the window elapses with no failures, the counter resets. A worker that
crashes once a day stays alive indefinitely with `maxRetries: 0` and
`withinMs: 86_400_000`.
````

- [ ] **Step 2: Commit**

```bash
git add docs/patterns.md
git commit -m "docs(patterns): add 'Headless worker auto-restart' section"
```

### Task 4.4: Drop the stale "doesn't relaunch yet" comment

**Files:**
- Modify: `hello-world/zapp.config.ts`

- [ ] **Step 1: Replace the deferred-feature note**

Find this comment block (around line 22–28):
```ts
  // Every headless worker is pinned to `zjs` — Zapp's first-party
  // engine. The host-bridge surface that the demo exercises is wired:
  // ... Restart-on-crash itself is still the same gap as bare/txiki (tracked in
  // project_txiki_worker_restart) — the supervisor records failures
  // and gives up after the cap, but doesn't relaunch yet.
```

Replace the last sentence with:
```ts
  // Every headless worker is pinned to `zjs` — Zapp's first-party
  // engine. The host-bridge surface that the demo exercises is wired:
  // ... and restart-on-crash works end-to-end (the supervisor recreates
  // the JS context within the configured cap).
```

- [ ] **Step 2: Commit**

```bash
git add hello-world/zapp.config.ts
git commit -m "docs(hello-world): supervisor restart no longer deferred"
```

---

## Self-review

**1. Spec coverage.** Walked every section of the spec:

| Spec section | Plan task(s) |
|---|---|
| Architecture / state model | 1.1 (slot fields), 1.2 (extract), 1.3 (outer loop), plus 2.1–2.3 and 3.1–3.3 for bare/txiki |
| Crash → restart signal flow | 1.4 (zjs), 2.4 (bare), 3.4 (txiki); JSC already does this |
| Events + payloads | 0.2 (jsc), 1.4 + 1.6 (zjs), 2.4 + 2.6 (bare), 3.4 + 3.6 (txiki), 4.2 (docs) |
| Dev log line + supervisor getter | 0.1 (getter), 1.6 (zjs log), 2.6 (bare log), 3.6 (txiki log) |
| Top-level eval throws → crashes | 1.5 (zjs), 2.5 (bare), 3.5 (txiki); JSC already covers |
| Race: terminate vs restart | Handled by atomic ordering in 1.1/2.1/3.1 + while-loop precedence in 1.3/2.3/3.3 |
| Messages during restart gap | 1.6, 2.6, 3.6 (post_message drop) |
| Script unreachable on restart | 1.5 Step 3 (zjs); 2.5/3.5 inherit |
| Inbox drained on restart | Existing teardown_state behavior (Task 1.2 / 2.2 / 3.2 preserves it) |
| Final-incarnation cleanup vs keep_loop | 1.3 Step 1 (outer loop calls teardown with keep_loop=1 in the body, then loop-close once at exit) |
| Per-engine deltas | Phases 1, 2, 3 |
| Testing — hello-world demo | 4.1 |
| Testing — broken-from-start | 1.5 Step 4 (zjs), 2.5/3.5 inherit |
| Testing — restart-window decay | Documented in patterns (4.3); manual exercise on the supervisor demo (4.1) |
| Out-of-scope items | Not in plan (correctly) |

No spec gaps.

**2. Placeholder scan.** Each task lists exact files, exact code, exact commands. Phases 2 and 3 reference Phase 1's code shape ("Same as Task 1.X") rather than repeating verbatim — the engineer is expected to follow them sequentially. If executed out of order, the engineer should re-read the Phase 1 task body. (Acceptable per the "engineer may read out of order" guidance for *concept* references; verbatim duplication would balloon the plan to 1500+ lines without adding signal.) No TODO/TBD/"implement later" patterns.

**3. Type consistency.**
- `wants_restart` / `wants_terminate` / `incarnation` — consistent names across all engines.
- `ZjsSetupResult` / `BareSetupResult` / `TxikiSetupResult` — engine-prefixed enum types per engine, consistent shape (`*_OK / *_CRASHED / *_FATAL`).
- `setup_state(slot)` / `teardown_state(slot, keep_loop)` — consistent signatures across engines.
- Event payload field names — `incarnation`, `finalIncarnation`, `retriesAttempted` — consistent across all engines and docs.

Plan is internally consistent.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-01-worker-supervisor-restart.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks. Best when tasks are independent enough that a clean context per task helps (here: yes — each task touches one file region).
2. **Inline Execution** — execute tasks in this session using executing-plans, batch with checkpoints. Faster wall-clock but more chance of context drift across the ~24 tasks.

Which approach?
