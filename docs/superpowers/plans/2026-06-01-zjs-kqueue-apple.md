# zjs Apple loop migration (kqueue + CFRunLoop) — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace libuv with a hybrid `kqueue()` + `CFRunLoopRunInMode()` loop in Zapp's zjs worker harness (`native/worker/engines/zjs.c`) on Apple platforms (macOS + iOS Simulator). Open the CLI's macOS-only zjs gate to also cover iOS Sim, unblocking zjs as a worker engine on iOS.

**Architecture:** Hybrid loop required because zjs upstream now ships fetch/WebSocket via NSURLSession unconditionally on Apple (`src/platform/http_apple.m` + `ws_apple.m`), and NSURLSession completions dispatch through CFRunLoop. Loop body: `kevent()` for cross-thread signals + timers, then a non-blocking `CFRunLoopRunInMode(..., 0.0, true)` tick to drain any NSURLSession completions, then a final microtask drain. Non-Apple targets keep the existing libuv path under `#else`.

**Tech Stack:** C11 (zjs.c, kqueue + CFRunLoop), CoreFoundation (CFRunLoop), Foundation/NSURLSession (already linked via zjs's libzjs.a), TypeScript (CLI build-config + native source-list resolver), Zen-C (engine overlay generators). No automated test suite — verification is `bun run build` clean + hello-world supervisor demo manual smoke per [[verify-native-build-not-vite-output]].

**Spec:** [`docs/superpowers/specs/2026-06-01-zjs-kqueue-apple-design.md`](../specs/2026-06-01-zjs-kqueue-apple-design.md)

---

## Task 0: Setup commits + branch

**Files:** spec + plan files (commit to main); none for branch creation.

- [ ] **Step 1: Confirm starting state**

Run from `/Users/zach/code/zapp`:
```bash
git status --short
git branch --show-current
```
Expected: working tree may have uncommitted vendor submodule pointers and the new spec/plan files. Branch should be `main`.

- [ ] **Step 2: Commit spec + plan to main as a setup commit**

```bash
git add docs/superpowers/specs/2026-06-01-zjs-kqueue-apple-design.md docs/superpowers/plans/2026-06-01-zjs-kqueue-apple.md
git commit -m "$(cat <<'EOF'
docs(superpowers): zjs Apple kqueue migration design + plan

Spec covers the hybrid kqueue + CFRunLoop replacement for libuv in
Zapp's zjs worker harness on Apple platforms. Plan is 5 phased commits
within one feat/zjs-kqueue-apple branch (vendor bump, loop rewrite on
Apple, drop Homebrew libuv on CLI's Apple path, wire iOS Sim, verify).
Unblocks zjs as a worker engine on iOS.
EOF
)"
```

- [ ] **Step 3: Stash remaining drift + create branch**

```bash
git stash push -u -m "pre-zjs-kqueue-apple stash $(date +%s)"
git checkout -b feat/zjs-kqueue-apple
git status --short
```
Expected after stash + checkout: working tree may still show submodule pointer drift (`m vendor/bare` etc. — git stash doesn't touch submodule pointer changes). Branch should be `feat/zjs-kqueue-apple`.

---

## Task 1: Verify vendor/zjs bump (already landed on main)

**Status:** The `vendor/zjs` pointer was bumped to upstream `11ea98d` on `main` as commit `9f3dc49` (during pre-branch cleanup). This branch inherits the bump — no new commit needed in Task 1. Steps below are verification only.

**Files:**
- None (verification only)

- [ ] **Step 1: Confirm the pointer is at 11ea98d**

```bash
cd /Users/zach/code/zapp
git submodule status vendor/zjs
```

Expected: leading hash `11ea98d6a629c4a7071574a6b253000721c9b65e`. If it's at the old pointer (`9999869...`), the submodule wasn't checked out — run `git submodule update --init vendor/zjs` before proceeding.

- [ ] **Step 2: Build vendor/zjs**

```bash
cd /Users/zach/code/zapp/vendor/zjs
make
ls build/libzjs.dylib
cd /Users/zach/code/zapp
```

Expected: `build/libzjs.dylib` exists. If `make` fails, STOP and report BLOCKED with the last 30 lines of make output.

- [ ] **Step 3: Verify hello-world builds against the new vendor**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

LAST line MUST be `[zapp] build complete: /Users/zach/code/zapp/hello-world/bin/hello-world (XXX KB)` — not Vite's `✓ built in XXms`. Binary mtime within the last minute.

If the build fails with "undefined symbol" / "unknown identifier" pointing at a zjs API name, the upstream may have renamed something we depend on. STOP and report BLOCKED with the specific symbol.

- [ ] **Step 4: No commit**

The bump is already on main. Move directly to Task 2.

---

## Task 2: Commit 2 — kqueue + CFRunLoop loop on Apple

**Goal:** Replace libuv handles in `zjs.c` with the kqueue + CFRunLoop architecture from the spec, gated `#if defined(__APPLE__)`. Keep the libuv path under `#else` for non-Apple targets. Hello-world supervisor demo must still produce the 4×crashed / 2×restarted / 2×gave-up sequence on macOS post-rewrite.

**Files:**
- Modify: `/Users/zach/code/zapp/native/worker/engines/zjs.c`

- [ ] **Step 1: Survey the current slot struct and worker thread**

Run from `/Users/zach/code/zapp`:
```bash
grep -n 'uv_loop_t\|uv_check_t\|uv_timer_t\|uv_async_t\|uv_run\|uv_stop\|uv_async_send\|uv_loop_init\|uv_loop_close\|uv_close\|uv_async_init\|uv_check_init\|uv_timer_init\|uv_check_start\|uv_timer_start' native/worker/engines/zjs.c | head -40
```

Read the slot struct (lines ~100–165) and `zjs_worker_thread` (search: `grep -n "static void\* zjs_worker_thread" native/worker/engines/zjs.c`). The supervisor-restart work landed an outer reincarnation loop; the libuv calls live inside `zjs_worker_setup_state` and `zjs_worker_teardown_state`, plus the inner-loop `uv_run` call.

The functions to surgically replace:
- Slot field declarations (5 libuv handle types).
- `uv_loop_init` + `uv_loop_close` in setup/teardown.
- `uv_check_init/start`, `uv_timer_init`, `uv_async_init` × 3 in setup_state.
- `uv_close` × 5 in teardown_state, plus the drain `uv_run`.
- `uv_run(loop, UV_RUN_DEFAULT)` in the main loop body.
- `uv_async_send` call sites (search: `grep -n 'uv_async_send' native/worker/engines/zjs.c`).
- The `on_check`, `on_zjs_wake`, `on_inbox_async`, `on_eval_inbox_async`, `on_shutdown_async` callbacks — these get inlined or replaced with direct drain code.

- [ ] **Step 2: Add Apple-side includes**

Near the top of `zjs.c`, find the include block. Wrap the `#include <uv.h>` in a platform split:

Before:
```c
#include <uv.h>
```

After:
```c
#if defined(__APPLE__)
  #include <sys/event.h>
  #include <CoreFoundation/CoreFoundation.h>
#else
  #include <uv.h>
#endif
```

- [ ] **Step 3: Add Apple-side EVFILT_USER ident constants**

Below the include block (or near the slot struct definition), add:

```c
#if defined(__APPLE__)
// EVFILT_USER idents for cross-thread signaling. Each is one-shot
// (EV_CLEAR) so the trigger fires once per kevent() drain. Coalesces
// naturally — multiple triggers between drains = one wake (matches
// uv_async_send semantics).
#define FILTER_SHUTDOWN     1
#define FILTER_INBOX        2
#define FILTER_EVAL_INBOX   3
#endif
```

- [ ] **Step 4: Replace the libuv slot fields with a platform split**

Find the `ZjsWorkerSlot` struct (around line 105+ per the audit). Locate the 5 libuv handle fields:

```c
    uv_loop_t    loop;
    ZjsContext*  ctx;
    // Loop integration: drained on every uv_check, re-armed to next zjs
    // timer deadline so libuv knows when to wake.
    uv_check_t   check;
    uv_timer_t   zjs_wake;
    uv_async_t   shutdown_async;     // signaled from terminate to wake the loop
    uv_async_t   inbox_async;        // signaled from post_message to drain inbox
    uv_async_t   eval_inbox_async;   // signaled from broadcast_eval_js to drain eval ring
    int          loop_initialized;
```

Replace with:

```c
    ZjsContext*  ctx;

#if defined(__APPLE__)
    // Apple loop: kqueue() fd + EVFILT_USER triggers (FILTER_SHUTDOWN /
    // FILTER_INBOX / FILTER_EVAL_INBOX). zjs's timer queue is polled
    // each iteration via zjs_next_timer_ms; no separate uv_timer_t /
    // uv_check_t needed (drain happens inline after kevent returns).
    // CFRunLoopRunInMode is ticked each iteration to drain NSURLSession
    // completions for zjs's fetch/WebSocket.
    int          kq;
    int          kq_initialized;
#else
    // Non-Apple loop: libuv (Linux/Windows). Apple targets use the
    // kqueue + CFRunLoop path above.
    uv_loop_t    loop;
    uv_check_t   check;
    uv_timer_t   zjs_wake;
    uv_async_t   shutdown_async;
    uv_async_t   inbox_async;
    uv_async_t   eval_inbox_async;
    int          loop_initialized;
#endif
```

Verify only the loop-specific fields are inside the gate; cross-platform fields (worker_id, owner_id, ctx, atomic flags, etc.) stay outside.

- [ ] **Step 5: Replace `zjs_worker_setup_state` loop setup with kqueue on Apple**

Find the libuv setup block in `zjs_worker_setup_state`. Looks roughly like:

```c
    if (uv_loop_init(&slot->loop) != 0) { ... return ZJS_SETUP_FATAL; }
    slot->loop_initialized = 1;

    uv_check_init(&slot->loop, &slot->check);
    slot->check.data = slot;
    uv_check_start(&slot->check, on_check);

    uv_timer_init(&slot->loop, &slot->zjs_wake);
    slot->zjs_wake.data = slot;
    // (no uv_timer_start here — armed on demand after script eval)

    uv_async_init(&slot->loop, &slot->shutdown_async, on_shutdown_async);
    slot->shutdown_async.data = slot;

    uv_async_init(&slot->loop, &slot->inbox_async, on_inbox_async);
    slot->inbox_async.data = slot;

    uv_async_init(&slot->loop, &slot->eval_inbox_async, on_eval_inbox_async);
    slot->eval_inbox_async.data = slot;
```

Replace with a platform split:

```c
#if defined(__APPLE__)
    slot->kq = kqueue();
    if (slot->kq < 0) {
        fprintf(stderr, "[zapp] zjs worker '%s' kqueue() failed\n", slot->worker_id);
        return ZJS_SETUP_FATAL;
    }
    slot->kq_initialized = 1;
    {
        // Register three EVFILT_USER triggers. EV_CLEAR makes each
        // trigger one-shot per kevent() drain. Idents are stable so
        // cross-thread signals can target a specific filter without
        // any per-slot state lookup.
        struct kevent change[3];
        EV_SET(&change[0], FILTER_SHUTDOWN,   EVFILT_USER, EV_ADD|EV_CLEAR, 0, 0, NULL);
        EV_SET(&change[1], FILTER_INBOX,      EVFILT_USER, EV_ADD|EV_CLEAR, 0, 0, NULL);
        EV_SET(&change[2], FILTER_EVAL_INBOX, EVFILT_USER, EV_ADD|EV_CLEAR, 0, 0, NULL);
        if (kevent(slot->kq, change, 3, NULL, 0, NULL) < 0) {
            fprintf(stderr, "[zapp] zjs worker '%s' kevent EV_ADD failed\n", slot->worker_id);
            close(slot->kq);
            slot->kq_initialized = 0;
            return ZJS_SETUP_FATAL;
        }
    }
#else
    if (uv_loop_init(&slot->loop) != 0) {
        fprintf(stderr, "[zapp] zjs worker '%s' uv_loop_init failed\n", slot->worker_id);
        return ZJS_SETUP_FATAL;
    }
    slot->loop_initialized = 1;

    uv_check_init(&slot->loop, &slot->check);
    slot->check.data = slot;
    uv_check_start(&slot->check, on_check);

    uv_timer_init(&slot->loop, &slot->zjs_wake);
    slot->zjs_wake.data = slot;

    uv_async_init(&slot->loop, &slot->shutdown_async, on_shutdown_async);
    slot->shutdown_async.data = slot;

    uv_async_init(&slot->loop, &slot->inbox_async, on_inbox_async);
    slot->inbox_async.data = slot;

    uv_async_init(&slot->loop, &slot->eval_inbox_async, on_eval_inbox_async);
    slot->eval_inbox_async.data = slot;
#endif
```

- [ ] **Step 6: Replace the main loop body — `uv_run` call site**

Find the inner-loop `uv_run(&slot->loop, UV_RUN_DEFAULT)` call inside `zjs_worker_thread`. The current shape is roughly:

```c
        if (slot->incarnation > 1) {
            // ... worker:restarted dispatch ...
        }
        uv_run(&slot->loop, UV_RUN_DEFAULT);

        zjs_worker_teardown_state(slot, /*keep_loop=*/1);
```

Replace the single `uv_run` call with the platform-split loop body:

```c
        if (slot->incarnation > 1) {
            // ... worker:restarted dispatch ... (KEEP existing code here)
        }

#if defined(__APPLE__)
        // Hybrid kqueue + CFRunLoop loop. See design doc:
        // docs/superpowers/specs/2026-06-01-zjs-kqueue-apple-design.md
        while (1) {
            // Drain JS work BEFORE blocking so any pending timers /
            // microtasks fire immediately on entry.
            zjs_run_pending_timers(slot->ctx);
            zjs_drain_microtasks(slot->ctx);

            if (atomic_load(&slot->wants_terminate)) break;
            if (atomic_load(&slot->wants_restart))   break;

            // Compute next sleep duration. zjs_next_timer_ms returns
            // -1 if no timer is pending — but we cap at 1s anyway so
            // CFRunLoop sources (NSURLSession completions) can't be
            // starved if the worker is otherwise idle.
            int64_t next_ms = zjs_next_timer_ms(slot->ctx);
            struct timespec ts;
            if (next_ms < 0 || next_ms > 1000) {
                ts.tv_sec  = 1;
                ts.tv_nsec = 0;
            } else if (next_ms == 0) {
                ts.tv_sec  = 0;
                ts.tv_nsec = 1000000;  // 1ms minimum to avoid spin
            } else {
                ts.tv_sec  = next_ms / 1000;
                ts.tv_nsec = (next_ms % 1000) * 1000000;
            }

            struct kevent events[8];
            int n = kevent(slot->kq, NULL, 0, events, 8, &ts);
            if (n < 0) {
                if (errno == EINTR) continue;
                fprintf(stderr, "[zapp] zjs worker '%s' kevent() failed: %s\n",
                        slot->worker_id, strerror(errno));
                break;
            }

            // Drain triggered EVFILT_USER events. Order doesn't matter —
            // each filter has its own drain helper; multiple triggers
            // coalesce so we get at most one of each per iteration.
            for (int i = 0; i < n; i++) {
                if (events[i].filter != EVFILT_USER) continue;
                if (events[i].ident == FILTER_SHUTDOWN)    { /* handled below via wants_terminate */ }
                else if (events[i].ident == FILTER_INBOX)       drain_inbox_apple(slot);
                else if (events[i].ident == FILTER_EVAL_INBOX)  drain_eval_inbox_apple(slot);
            }

            // Tick CFRunLoop for NSURLSession completions. 0.0 timeout
            // = non-blocking; returns after handling one source or
            // immediately if none pending. May fire JS callbacks that
            // schedule microtasks; re-drain below.
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
            zjs_drain_microtasks(slot->ctx);
        }
#else
        uv_run(&slot->loop, UV_RUN_DEFAULT);
#endif

        zjs_worker_teardown_state(slot, /*keep_loop=*/1);
```

This replaces both the implicit "run until something stops the loop" of libuv and the per-tick drains that `on_check`/`on_zjs_wake` were doing.

- [ ] **Step 7: Extract `drain_inbox_apple` and `drain_eval_inbox_apple` helpers**

The existing `on_inbox_async` and `on_eval_inbox_async` libuv callbacks contain the inbox/eval_inbox drain logic. Extract their bodies (excluding the `uv_async_t*` parameter conversion) into reusable helpers:

```c
#if defined(__APPLE__)
// Apple loop's inbox drain — same body as the libuv on_inbox_async
// callback's inner work (without the handle->data unpack since the
// caller already has slot).
static void drain_inbox_apple(ZjsWorkerSlot* slot) {
    // Copy of on_inbox_async's body verbatim, replacing the
    // `(ZjsWorkerSlot*) h->data` unpack at the top with the slot
    // parameter directly. See existing on_inbox_async for reference.
    // (Search: grep -n "static void on_inbox_async" native/worker/engines/zjs.c)

    // PASTE the existing on_inbox_async body here, modulo the unpack.
}

static void drain_eval_inbox_apple(ZjsWorkerSlot* slot) {
    // Same pattern for on_eval_inbox_async.
}
#endif
```

The implementer should read the existing `on_inbox_async` + `on_eval_inbox_async` callbacks first, then copy-paste the bodies into these new helpers, removing the `(ZjsWorkerSlot*) h->data` unpacks (since `slot` is already in scope). The libuv callbacks themselves stay in place (still needed for the `#else` branch).

- [ ] **Step 8: Replace `uv_async_send` call sites with `kevent` triggers on Apple**

Search for all `uv_async_send` calls:
```bash
grep -n 'uv_async_send' native/worker/engines/zjs.c
```

Each call site signals one of the three async handles. Wrap each with a platform split. Example for the inbox signal:

```c
#if defined(__APPLE__)
{
    struct kevent trigger;
    EV_SET(&trigger, FILTER_INBOX, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(slot->kq, &trigger, 1, NULL, 0, NULL);
}
#else
uv_async_send(&slot->inbox_async);
#endif
```

For the shutdown signal:
```c
#if defined(__APPLE__)
{
    struct kevent trigger;
    EV_SET(&trigger, FILTER_SHUTDOWN, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(slot->kq, &trigger, 1, NULL, 0, NULL);
}
#else
uv_async_send(&slot->shutdown_async);
#endif
```

For the eval_inbox signal:
```c
#if defined(__APPLE__)
{
    struct kevent trigger;
    EV_SET(&trigger, FILTER_EVAL_INBOX, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(slot->kq, &trigger, 1, NULL, 0, NULL);
}
#else
uv_async_send(&slot->eval_inbox_async);
#endif
```

Each call site needs the correct ident. Read the surrounding code at each site to determine which async handle was being signaled.

- [ ] **Step 9: Replace `zjs_worker_teardown_state` loop teardown with `close(kq)` on Apple**

Find the libuv teardown block in `zjs_worker_teardown_state`. It contains `uv_close` calls for the 5 handles plus the drain `uv_run` plus `uv_loop_close` (gated on `keep_loop`). Wrap in a platform split:

```c
#if defined(__APPLE__)
    if (slot->kq_initialized) {
        // No per-handle close needed — closing the kqueue fd reclaims
        // all registered EVFILT_USER triggers atomically.
        close(slot->kq);
        slot->kq = -1;
        slot->kq_initialized = 0;
    }
#else
    if (slot->loop_initialized) {
        uv_check_stop(&slot->check);
        uv_timer_stop(&slot->zjs_wake);
        uv_close((uv_handle_t*)&slot->check, NULL);
        uv_close((uv_handle_t*)&slot->zjs_wake, NULL);
        uv_close((uv_handle_t*)&slot->shutdown_async, NULL);
        uv_close((uv_handle_t*)&slot->inbox_async, NULL);
        uv_close((uv_handle_t*)&slot->eval_inbox_async, NULL);
        uv_run(&slot->loop, UV_RUN_DEFAULT);
        if (!keep_loop) {
            uv_loop_close(&slot->loop);
            slot->loop_initialized = 0;
        }
    }
#endif
```

Apple side: kqueue's `close(fd)` is synchronous — no equivalent of libuv's async close-callback drain.

The `keep_loop` parameter is semi-irrelevant on Apple (closing the kqueue fd is cheap; we always close and reopen between incarnations). If `keep_loop=1` on Apple, we close anyway — the kqueue fd doesn't survive the engine context lifecycle and there's no setup cost to recreating it.

- [ ] **Step 10: Update `zjs_worker_thread`'s outer loop "final cleanup" block**

Find the post-`while(1)` cleanup at the bottom of `zjs_worker_thread`. It currently does `uv_run(&loop, UV_RUN_NOWAIT)` + `uv_loop_close(&loop)`. Wrap:

```c
#if defined(__APPLE__)
    // No-op on Apple — kqueue fd was closed in teardown_state.
#else
    uv_run(&loop, UV_RUN_NOWAIT);
    uv_loop_close(&loop);
#endif
```

(The `loop` variable in the outer `zjs_worker_thread` was a `uv_loop_t` stack local. On Apple, that local doesn't exist — verify by searching for `uv_loop_t loop;` in `zjs_worker_thread` and wrapping it in the same platform split if present.)

- [ ] **Step 11: Verify libuv callback functions are still referenced (non-Apple) or stub on Apple**

The functions `on_check`, `on_zjs_wake`, `on_shutdown_async`, `on_inbox_async`, `on_eval_inbox_async` are used in the libuv setup block. On Apple, they're not called — the loop body inlines the drain logic. They should still compile (they're file-static functions) but unused on Apple will produce `-Wunused-function` warnings.

Wrap them in `#if !defined(__APPLE__)` if you want to keep the warning clean, OR mark them `__attribute__((unused))` and leave them callable on both platforms. The latter keeps the code shape uniform and lets the callbacks be reused if a future refactor needs them.

Recommended: wrap the function definitions in `#if !defined(__APPLE__) ... #endif` — they're libuv-shaped (take `uv_check_t*` / `uv_async_t*` etc.) so they don't compile on Apple anyway since libuv types aren't included there.

- [ ] **Step 12: Build verification (macOS)**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

LAST line MUST be `[zapp] build complete: /Users/zach/code/zapp/hello-world/bin/hello-world (XXX KB)` — not Vite's `✓ built in XXms`. Binary mtime within the last minute.

If the build fails with "undefined reference to uv_*" or "unknown type 'uv_*'" on Apple, the `#if defined(__APPLE__)` gates aren't covering all the libuv references. Run:
```bash
grep -n 'uv_' /Users/zach/code/zapp/native/worker/engines/zjs.c | grep -v '^[0-9]*:#if\|^[0-9]*:#else\|^[0-9]*://' | head -20
```
to find naked libuv references and wrap them.

- [ ] **Step 13: Smoke test — hello-world supervisor demo on macOS**

```bash
cd /Users/zach/code/zapp/hello-world && bun run dev
```

The supervised worker is `engine: "zjs"` per the current `zapp.config.ts`. Click "force-crash" 4× in the webview UI. Verify in the output panel:
- Click 1: `worker:crashed` → `worker:restarted`
- Click 2: `worker:crashed` → `worker:restarted`
- Click 3: `worker:crashed` → `worker:gave-up`
- Click 4: `worker:crashed` → `worker:gave-up`

Verify in stderr:
- `[zapp] zjs worker 'h-supervised' restarting (incarnation 2, fail_count 1/2 in 30000ms window)` on click 1
- `[zapp] zjs worker 'h-supervised' restarting (incarnation 3, fail_count 2/2 in 30000ms window)` on click 2

The ticker worker should still tick at its expected interval (confirms `zjs_next_timer_ms` + the kevent timeout still drive timer firing).

Kill with Ctrl-C. If anything diverges, STOP and report BLOCKED with the divergence — the kqueue path is wrong somewhere.

- [ ] **Step 14: Commit**

```bash
cd /Users/zach/code/zapp
git add native/worker/engines/zjs.c
git commit -m "$(cat <<'EOF'
feat(zjs-worker): kqueue + CFRunLoop loop on Apple

Replaces libuv with a hybrid kqueue + CFRunLoop loop in zjs's worker
harness on Apple platforms. The libuv path is preserved under
#if !defined(__APPLE__) for Linux/Windows.

Apple loop architecture (see design doc):
- kqueue() fd per worker; 3× EVFILT_USER triggers replace uv_async_t
  for cross-thread shutdown/inbox/eval_inbox signaling.
- uv_check_t + uv_timer_t collapse into inline drain after each kevent
  return; zjs_next_timer_ms feeds the kevent timeout directly.
- 1s timeout cap so NSURLSession completions (CFRunLoop-driven for
  zjs's fetch/WebSocket) aren't starved when the worker is otherwise
  idle.
- CFRunLoopRunInMode tick at the bottom of each iteration drains
  NSURLSession sources; microtasks re-drained after.

Hello-world supervisor demo passes on macOS with engine: "zjs": 4×
worker:crashed, 2× worker:restarted, 2× worker:gave-up for the 4-click
force-crash flow. Ticker worker continues to tick at its expected
cadence.

CLI Homebrew libuv removal + iOS Sim wiring follow in commits 3 and 4.
EOF
)"
```

---

## Task 3: Commit 3 — Drop Homebrew libuv on Apple from CLI build path

**Goal:** Remove the `brew install libuv` prerequisite, the `uvLibDir` lookup, and the `-luv` / `-Wl,-rpath` / Frameworks-bundling lines from the zjs build path in `cli/src/build-config.ts` when targeting Apple. Keep them under a non-Apple branch for future Linux/Windows.

**Files:**
- Modify: `/Users/zach/code/zapp/cli/src/build-config.ts`

- [ ] **Step 1: Survey the current zjs build block**

```bash
grep -n 'hasZjs\|uvInclude\|uvLib\|libuv\|brew install libuv\|libzjs' /Users/zach/code/zapp/cli/src/build-config.ts | head -20
```

Read lines ~965–1050 of `cli/src/build-config.ts`. The block currently contains:
- The `if (hasZjs && target === "macos")` gate.
- The `make -C vendor/zjs` auto-build invocation.
- The `install_name_tool` install_name fixup.
- The `uvIncludeCandidates` / `uvLibCandidates` Homebrew lookup.
- The error-path that throws "brew install libuv" if not found.
- The cflags + link line emission with `-luv` and `-Wl,-rpath`.

- [ ] **Step 2: Remove the Homebrew libuv lookup + error**

Inside the `if (hasZjs && target === "macos")` block (still macOS-only for now; Task 4 opens this gate to iOS), delete:

```typescript
    const uvIncludeCandidates = ["/opt/homebrew/include", "/usr/local/include"];
    const uvLibCandidates     = ["/opt/homebrew/lib",     "/usr/local/lib"];
    const uvInclude = uvIncludeCandidates.find(p => existsSync(path.join(p, "uv.h")));
    const uvLibDir  = uvLibCandidates.find(p => existsSync(path.join(p, "libuv.dylib")));
    if (!uvInclude || !uvLibDir) {
      throw new Error(
        `[zapp] zjs engine requires libuv (brew install libuv). ` +
        `Searched ${uvIncludeCandidates.join(", ")} for uv.h.`
      );
    }
```

(Read the actual block first — these lines may have drifted post-vendor-bump. Use a Read tool with offset/limit to get exact line numbers.)

- [ ] **Step 3: Drop `-luv` and the libuv-related cflags/link directives**

Find the cflags + link line emission below the lookup. It currently looks like (approximate):

```typescript
    content += `//> macos: cflags: -I${shortPath(zjsInclude)} -I${uvInclude}\n`;
    content += `//> macos: link: -L${uvLibDir} -luv -Wl,-rpath,${uvLibDir}\n`;
    content += `//> macos: link: ${shortPath(zjsLib)} -Wl,-rpath,${shortPath(zjsBuildDir)}\n`;
```

Replace with the libuv-free version on Apple:

```typescript
    content += `//> macos: cflags: -I${shortPath(zjsInclude)}\n`;
    content += `//> macos: framework: CoreFoundation\n`;
    content += `//> macos: framework: Foundation\n`;
    content += `//> macos: link: ${shortPath(zjsLib)} -Wl,-rpath,${shortPath(zjsBuildDir)}\n`;
```

Notes:
- `CoreFoundation` is needed for `CFRunLoopRunInMode` + `kCFRunLoopDefaultMode`.
- `Foundation` is needed because zjs's `http_apple.m` + `ws_apple.m` link `NSURLSession` (and Foundation may already be implicitly linked via WebKit; explicit doesn't hurt).
- Run `grep -n 'CoreFoundation\|Foundation' cli/src/build-config.ts` first to see if either framework is already emitted elsewhere — if so, no need to add. The frameworks are idempotent in clang's link line.

- [ ] **Step 4: Build verification — Homebrew libuv NOT needed**

Simulate a machine without Homebrew libuv by temporarily masking the lib:

```bash
sudo mv /opt/homebrew/lib/libuv.dylib /opt/homebrew/lib/libuv.dylib.zapp-mask
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
sudo mv /opt/homebrew/lib/libuv.dylib.zapp-mask /opt/homebrew/lib/libuv.dylib
```

LAST line of the build MUST be `[zapp] build complete: ...`. If it fails with "library not found for -luv" or "Symbol not found: _uv_*", a libuv reference survived — find and remove. If `sudo mv` is impractical, run with `LIBRARY_PATH` masking instead:
```bash
LIBRARY_PATH=/tmp/empty cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts
git commit -m "$(cat <<'EOF'
feat(cli): drop Homebrew libuv on Apple zjs builds

Now that zjs.c's Apple loop uses kqueue + CFRunLoop (commit 2),
libuv is no longer a runtime or build-time dependency on macOS or iOS.

Drops from cli/src/build-config.ts's zjs branch:
- uvInclude / uvLibDir Homebrew path lookup.
- "brew install libuv" error if not found.
- -L<uvLibDir> -luv -Wl,-rpath<uvLibDir> link line.

Adds CoreFoundation framework directive (CFRunLoopRunInMode) and an
explicit Foundation framework directive for NSURLSession in zjs's
fetch/WebSocket platform sources.

Hello-world builds clean on a machine with /opt/homebrew/lib/libuv.dylib
masked away — confirms the dependency is genuinely gone on Apple.
Linux/Windows paths (under future #if !defined(__APPLE__) in zjs.c
+ a separate CLI branch when those targets are wired) keep libuv.
EOF
)"
```

---

## Task 4: Commit 4 — Wire zjs for iOS Simulator builds

**Goal:** Open the CLI's `target === "macos"` gate to also handle `ios-simulator`. Invoke `make -C vendor/zjs ios-simulator-arm64`. Link `vendor/zjs/build/ios/simulator-arm64/libzjs.a` instead of macOS's `build/libzjs.dylib`. Add `zjs.c` to the iOS source list. Update `_zapp_build_ios.zc` generation to emit `ZAPP_WORKER_ENGINE_ZJS` when the config has zjs workers.

**Files:**
- Modify: `/Users/zach/code/zapp/cli/src/build-config.ts`
- Modify: `/Users/zach/code/zapp/cli/src/native.ts`

- [ ] **Step 1: Pre-flight — verify Foundation + CoreFoundation are linked on iOS**

```bash
grep -n 'Foundation\|CoreFoundation' /Users/zach/code/zapp/cli/src/native.ts | head -10
```

If absent from the iOS framework list, add a step to include them. If present (likely — Foundation is typically already linked via UIKit / WebKit), skip the framework addition; only the source-list update is needed.

- [ ] **Step 2: Verify zjs.c is currently excluded from the iOS source list**

```bash
grep -n 'iosDir\|iosSrc\|ios_files\|engines/zjs\|engines/bare\|engines/jsc' /Users/zach/code/zapp/cli/src/native.ts | head -20
```

Read the iOS source-list construction. zjs.c was likely excluded (or never explicitly added) because the macOS-only gate at build-config.ts:970 prevented zjs from being targeted at iOS. We need to add `zjs.c` to the iOS source list. Specifically:

- Find where iOS sources are assembled (e.g., a `const iosSources = [...]` array or a `getIosSources(...)` function).
- If `bare.c` is in the iOS sources but `zjs.c` is not, add `zjs.c` next to it.
- If the source list comes from a directory sweep, ensure `zjs.c` isn't filtered out.

- [ ] **Step 3: Open the zjs build gate in cli/src/build-config.ts to include iOS**

Find the `if (hasZjs && target === "macos")` line. Change to:

```typescript
if (hasZjs && (target === "macos" || target === "ios-simulator")) {
```

(Skip `ios-device` for this branch — out of scope per spec.)

- [ ] **Step 4: Branch the make invocation + lib path by target**

Inside the gate, find the `make -C vendor/zjs` invocation and the `zjsLib` path computation. Wrap them:

Before (approximate):
```typescript
    const zjsLib = path.join(zjsDir, "build", "libzjs.dylib");
    if (!existsSync(zjsLib)) {
      process.stdout.write(`[zapp] building vendor/zjs (first run; ~30s)...\n`);
      const proc = Bun.spawn(["make", "-C", zjsDir], { stdout: "pipe", stderr: "pipe" });
      const exitCode = await proc.exited;
      if (exitCode !== 0 || !existsSync(zjsLib)) { ... }
    }
```

After:
```typescript
    let zjsLib: string;
    let makeTarget: string[];
    if (target === "ios-simulator") {
      zjsLib = path.join(zjsDir, "build", "ios", "simulator-arm64", "libzjs.a");
      makeTarget = ["make", "-C", zjsDir, "ios-simulator-arm64"];
    } else {
      // target === "macos"
      zjsLib = path.join(zjsDir, "build", "libzjs.dylib");
      makeTarget = ["make", "-C", zjsDir];
    }

    if (!existsSync(zjsLib)) {
      const label = target === "ios-simulator" ? "vendor/zjs (iOS Sim arm64; first run; ~30s)" : "vendor/zjs (first run; ~30s)";
      process.stdout.write(`[zapp] building ${label}...\n`);
      const proc = Bun.spawn(makeTarget, { stdout: "pipe", stderr: "pipe" });
      const exitCode = await proc.exited;
      if (exitCode !== 0 || !existsSync(zjsLib)) {
        const stderr = await new Response(proc.stderr).text();
        throw new Error(
          `[zapp] failed to build vendor/zjs (exit ${exitCode}). ` +
          `Tried: ${makeTarget.join(" ")}. Build vendor/zjs by hand and rerun.\n${stderr}`
        );
      }
    }
```

- [ ] **Step 5: Skip install_name_tool on iOS (static lib)**

The `install_name_tool -id` fixup is only relevant for dylibs. Wrap it in a macOS-only branch:

Before:
```typescript
    const otoolD = Bun.spawnSync(["otool", "-D", zjsLib]);
    const installName = ...;
    if (installName && installName !== zjsLib) {
      const fix = Bun.spawnSync(["install_name_tool", "-id", zjsLib, zjsLib]);
      ...
    }
```

After:
```typescript
    if (target === "macos") {
      // dylib install_name fixup — only needed for the macOS dynamic
      // lib. iOS uses a static .a so there's no install_name to fix.
      const otoolD = Bun.spawnSync(["otool", "-D", zjsLib]);
      const installName = new TextDecoder().decode(otoolD.stdout).split("\n")[1]?.trim();
      if (installName && installName !== zjsLib) {
        const fix = Bun.spawnSync(["install_name_tool", "-id", zjsLib, zjsLib]);
        if (fix.exitCode !== 0) {
          throw new Error(
            `[zapp] failed to set absolute install_name on ${zjsLib}: ` +
            new TextDecoder().decode(fix.stderr)
          );
        }
      }
    }
```

- [ ] **Step 6: Emit per-target cflags + link directives**

The current emission writes `//> macos: cflags:` and `//> macos: link:` directives. We need parallel `//> ios:` directives for the iOS build. Wrap:

Before (post-Task-3 state):
```typescript
    content += `//> macos: cflags: -I${shortPath(zjsInclude)}\n`;
    content += `//> macos: framework: CoreFoundation\n`;
    content += `//> macos: framework: Foundation\n`;
    content += `//> macos: link: ${shortPath(zjsLib)} -Wl,-rpath,${shortPath(zjsBuildDir)}\n`;
```

After:
```typescript
    if (target === "ios-simulator") {
      content += `//> ios: cflags: -I${shortPath(zjsInclude)}\n`;
      content += `//> ios: framework: CoreFoundation\n`;
      content += `//> ios: framework: Foundation\n`;
      // Static lib; no rpath needed.
      content += `//> ios: link: ${shortPath(zjsLib)}\n`;
    } else {
      // target === "macos"
      content += `//> macos: cflags: -I${shortPath(zjsInclude)}\n`;
      content += `//> macos: framework: CoreFoundation\n`;
      content += `//> macos: framework: Foundation\n`;
      content += `//> macos: link: ${shortPath(zjsLib)} -Wl,-rpath,${shortPath(zjsBuildDir)}\n`;
    }
```

The `zjsBuildDir` variable is only computed for macOS (it's the `-rpath` target). Make sure it's only computed inside the macOS branch.

- [ ] **Step 7: Update the iOS engine overlay generator to emit ZAPP_WORKER_ENGINE_ZJS**

```bash
grep -n '_zapp_build_ios\|ZAPP_WORKER_ENGINE_BARE_JSC\|engineNameToId' /Users/zach/code/zapp/cli/src/build-config.ts | head -20
```

Find where `_zapp_build_ios.zc` is generated. It currently hardcodes `ZAPP_WORKER_ENGINE_BARE_JSC`. Update it to use the same `generateEngineOverlay` machinery that the macOS build uses — emit defines for every engine the config references (zjs, bare-*, etc.).

The simplest path: factor the macOS overlay generator to be platform-parameterized, then call it for iOS too. Read the existing generator function and the iOS-specific entry-point generator side by side to find the simplest unification point.

If unifying is more work than warranted, the minimum required change is: in the iOS entry-point generator, walk `config.headless` and emit a `//> ios: define: ZAPP_WORKER_ENGINE_<UPPER>` for every distinct engine name (replacing the hardcoded `BARE_JSC` line).

- [ ] **Step 8: Add zjs.c to the iOS source list in cli/src/native.ts**

Per Step 2's reconnaissance, locate the iOS source list. Add `path.join(nativeDir, "worker", "engines", "zjs.c")` (or whatever the existing pattern is for `bare.c`'s entry).

Note: zjs.c is now Apple-aware (it has the `#if defined(__APPLE__)` gate from Task 2), so it should compile cleanly for the iOS Simulator target.

- [ ] **Step 9: Build verification (iOS Simulator)**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -10
ls -la /Users/zach/code/zapp/hello-world/bin/ios/
```

Expected: a successful iOS Simulator build producing an `.app` bundle under `bin/ios/` (or similar — the iOS build output layout may differ from macOS). LAST line of the build should indicate completion; no `'zjs.h' file not found` errors (which was the original blocker).

If the build fails with "library not found for ... libzjs.a", the make-build step didn't produce the file at the expected path. Check `vendor/zjs/build/ios/simulator-arm64/libzjs.a` exists; if not, run `make -C vendor/zjs ios-simulator-arm64` manually and inspect the output.

- [ ] **Step 10: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts cli/src/native.ts
git commit -m "$(cat <<'EOF'
feat(cli): wire zjs for iOS Simulator builds

Opens the macOS-only zjs build gate to also handle ios-simulator
targets. Now that zjs.c runs on Apple via kqueue + CFRunLoop (commit
2) with no libuv dependency (commit 3), iOS Sim is unblocked.

Build path changes:
- The make invocation branches on target: ios-simulator runs
  `make -C vendor/zjs ios-simulator-arm64`, which produces
  build/ios/simulator-arm64/libzjs.a (static).
- install_name_tool fixup stays macOS-only (no install_name on a .a).
- Per-target cflags/link directive emission: //> ios: cflags +
  framework + link line for iOS, mirroring the //> macos: set but
  pointing at the static .a (no -rpath needed).
- zjs.c added to the iOS source list in cli/src/native.ts.
- The iOS engine-overlay generator emits ZAPP_WORKER_ENGINE_ZJS
  alongside any other engines the config references, replacing the
  previous hardcoded ZAPP_WORKER_ENGINE_BARE_JSC.

Verification: `cd hello-world && bun run build --platform ios`
produces a clean iOS Sim bundle. End-to-end smoke verification of
the supervisor demo on the booted iOS Simulator follows in commit 5.
EOF
)"
```

---

## Task 5: Commit 5 — Hello-world iOS Sim verification + cleanup

**Goal:** Manually verify the supervisor demo on iOS Simulator. Update hello-world's cross-engine smoke matrix comment. Remove the "iOS waiting on libuv" caveat from `docs/engines.md`.

**Files:**
- Modify: `/Users/zach/code/zapp/hello-world/zapp.config.ts`
- Modify: `/Users/zach/code/zapp/docs/engines.md`

- [ ] **Step 1: Boot an iOS Simulator + launch hello-world**

```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
cd /Users/zach/code/zapp/hello-world && bun run dev --platform ios
```

(`simctl list devices available` shows what's installed if "iPhone 17 Pro" isn't present — use any iPhone Simulator device.) The dev command builds + installs + launches with console streaming.

- [ ] **Step 2: Manually verify the supervisor demo on iOS Sim**

In the iOS Sim webview, click "force-crash" 4×. Verify in the output panel:
- Click 1: `worker:crashed (h-supervised)` → `worker:restarted (h-supervised)`
- Click 2: `worker:crashed (h-supervised)` → `worker:restarted (h-supervised)`
- Click 3: `worker:crashed (h-supervised)` → `worker:gave-up (h-supervised)`
- Click 4: `worker:crashed (h-supervised)` → `worker:gave-up (h-supervised)`

In the dev console (streamed from simctl), look for:
- `[supervised] received force-crash → throwing in 0ms` after each click
- `[zapp] zjs worker 'h-supervised' restarting (incarnation N, fail_count X/2 in 30000ms window)` on clicks 1+2
- Ticker output continuing throughout (confirms timers work via kevent timeout + zjs_next_timer_ms)

If anything diverges (sequence wrong, ticker stops, crash dispatches missing), STOP and report — the iOS Sim path is different from macOS somewhere and needs investigation before commit.

Kill the iOS Sim app with Ctrl-C when verified.

- [ ] **Step 3: Update hello-world's cross-engine smoke matrix comment**

Read `/Users/zach/code/zapp/hello-world/zapp.config.ts`. Find the smoke matrix comment (added in the previous legacy-engine-removal cycle, around line 43-47). Currently:

```typescript
    // Cross-engine smoke matrix (manual verification — click force-crash 4 times):
    //   zjs       → crashed×3, restarted×2, gave-up×1, 4th click silent
    //   bare-jsc  → same sequence
    //   bare-v8   → same sequence (Win/Linux JIT)
```

Update the comment to reflect iOS Sim verification:

```typescript
    // Cross-engine smoke matrix (manual verification — click force-crash 4 times):
    //   zjs (macOS)      → crashed×4, restarted×2, gave-up×2
    //   zjs (iOS Sim)    → same sequence
    //   bare-jsc (macOS) → same sequence
    //   bare-v8          → same sequence (Win/Linux JIT)
```

Note: the original comment said `crashed×3, restarted×2, gave-up×1, 4th click silent` — that wasn't quite right per the actual behavior verified in the supervisor restart cycle (the 4th click also dispatches worker:gave-up because the gave-up flag is sticky in the supervisor). Correcting to `crashed×4, restarted×2, gave-up×2` matches the documented behavior.

- [ ] **Step 4: Remove the "iOS waiting on libuv" caveat from docs/engines.md**

```bash
grep -n 'iOS\|libuv\|kqueue' /Users/zach/code/zapp/docs/engines.md | head -10
```

Find any line that says zjs is unavailable on iOS or is waiting for libuv. Replace with the post-this-work state: zjs runs on macOS + iOS Sim via kqueue + CFRunLoop; Linux/Windows continue on libuv until ported.

Specific replacements likely needed:
- Any "iOS / Windows plumbing follows once zjs ships uv-free platform shims or we vendor libuv ourselves" text → "zjs runs on macOS + iOS Sim via kqueue + CFRunLoop; Linux/Windows continue on libuv (port pending)."
- Any platform-recommendation row that says zjs is macOS-only → update to say zjs is the recommended engine on macOS + iOS, with bare-v8 still the JIT path for Linux/Windows.

Use the Read tool to inspect the file first; the exact line numbers depend on its current state.

- [ ] **Step 5: Build verification**

```bash
cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -3
ls -la /Users/zach/code/zapp/hello-world/bin/hello-world
```

LAST line MUST be `[zapp] build complete: ...`. Fresh binary mtime. (Docs-only changes don't affect the build, but this confirms nothing accidentally broke.)

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add hello-world/zapp.config.ts docs/engines.md
git commit -m "$(cat <<'EOF'
chore: zjs on iOS Sim verified; drop "iOS waiting on libuv" caveat

Manual end-to-end verification: hello-world supervisor demo on iOS
Simulator (engine: "zjs") produces the same 4×crashed / 2×restarted /
2×gave-up event sequence as macOS for the 4-click force-crash flow.
Ticker worker ticks at expected cadence — confirms timers drive
correctly via kevent timeout + zjs_next_timer_ms.

Updates:
- hello-world/zapp.config.ts: cross-engine smoke matrix comment
  adds the iOS Sim zjs row.
- docs/engines.md: drops the "iOS waiting on libuv" caveat from
  platform-recommendation lines; zjs is now the recommended engine
  on macOS + iOS Sim.

Closes the iOS unblock that motivated this branch. Linux/Windows
zjs ports remain future work; libuv path under #if !defined(__APPLE__)
is preserved unchanged.
EOF
)"
```

---

## Self-review

**1. Spec coverage.** Walking the spec section-by-section:

| Spec section | Plan task(s) |
|---|---|
| Hybrid loop architecture (kqueue + CFRunLoop) | Task 2 Steps 4–7, 10 |
| Handle mapping (libuv → kqueue/CFRunLoop) | Task 2 Steps 4–10 (per-handle replacements) |
| Commit 1: vendor bump | Task 1 |
| Commit 2: kqueue+CFRunLoop loop | Task 2 |
| Commit 3: drop Homebrew libuv | Task 3 |
| Commit 4: iOS Sim wiring | Task 4 |
| Commit 5: iOS Sim verification + cleanup | Task 5 |
| iOS build wiring (Foundation pre-flight) | Task 4 Step 1 |
| iOS build wiring (cross-compile via `make ios-simulator-arm64`) | Task 4 Step 4 |
| iOS build wiring (`_zapp_build_ios.zc` engine overlay) | Task 4 Step 7 |
| iOS build wiring (zjs.c in iOS source list) | Task 4 Step 8 |
| Testing per stage | Each task has a build-verification step + smoke step where relevant |
| Risk 1: CFRunLoop tick latency | 1s kevent timeout cap is in Task 2 Step 6 |
| Risk 2: vendor pointer drift | Task 1 (standalone vendor bump with own verification) |
| Risk 3: Foundation already linked? | Task 4 Step 1 pre-flight grep |
| Risk 4: cancellation race | EVFILT_USER triggers are slot-stored — covered by the architecture; no test step needed |
| Risk 5: multi-arch iOS Sim | Out of scope per spec; not in plan |
| Risk 6: Linux/Windows path stays on libuv | Each Apple-side change in Task 2 explicitly uses `#if defined(__APPLE__) ... #else` to preserve the libuv path |

No gaps.

**2. Placeholder scan.** Each step lists exact files, exact commands, exact code blocks (including PR-message HEREDOCs). Task 2 Step 7's "PASTE the existing on_inbox_async body here" is the most ambiguous — but the implementer is explicitly directed to read the existing callback first and copy its body verbatim (minus the `h->data` unpack). The alternative would be quoting hundreds of lines of existing code into the plan, which is worse. Acceptable trade-off given the implementer is also doing inline plan reading via the build verification at Step 12.

**3. Type consistency.** `FILTER_SHUTDOWN`, `FILTER_INBOX`, `FILTER_EVAL_INBOX` ident constants are introduced in Task 2 Step 3, used consistently in Steps 5, 6, 8. `drain_inbox_apple` / `drain_eval_inbox_apple` helper names match between their definition (Step 7) and call sites (Step 6). `slot->kq` / `slot->kq_initialized` field names match between struct (Step 4), setup (Step 5), and teardown (Step 9). The 1s kevent timeout cap is consistent between Task 2 Step 6 (implementation) and the spec's architecture section.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-01-zjs-kqueue-apple.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between them. Task 2 in particular benefits from a fresh-context subagent reading zjs.c carefully and applying the surgical replacements; reviewers can verify the libuv-vs-Apple split is correct.
2. **Inline Execution** — batch through tasks in this session with checkpoints. Faster wall-clock; lower margin if the kqueue path is wrong in a non-obvious way (the libuv path is preserved as a fallback under `#else`, but the build verification at each task gate is what catches issues).

Which approach?
