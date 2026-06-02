# zjs Apple loop migration: kqueue + CFRunLoop — design

**Status:** approved by user 2026-06-01 (post-brainstorm). Implementation plan: TBD via `superpowers:writing-plans`.

**Goal:** Replace libuv with a hybrid `kqueue()` + `CFRunLoopRunInMode()` loop in Zapp's zjs worker harness (`native/worker/engines/zjs.c`) on Apple platforms (macOS + iOS Simulator). Defer Linux/Windows behind a `#if defined(__APPLE__) ... #else` split, keeping the existing libuv path intact for those targets.

**Why.** Two reasons stacked on top of each other:

1. **iOS unblock.** Today, zjs cannot run on iOS because the CLI gates the zjs build path to `target === "macos"` (per `cli/src/build-config.ts:970`), with a comment: *"iOS / Windows plumbing follows once zjs ships uv-free platform shims or we vendor libuv ourselves."* Replacing libuv with Apple-native primitives closes that gate.
2. **Operational simplification on macOS.** Today macOS workers link `libuv.dylib` from Homebrew (`/opt/homebrew/lib`), requiring a `brew install libuv` prerequisite on every dev machine and CI host, plus an `install_name_tool` dance and Frameworks-bundling story for shipped `.app` bundles. Removing the libuv link removes that operational tax — kqueue is in `libSystem`, CFRunLoop is in `CoreFoundation`, both already linked.

The deeper context: zjs is **already uv-free** at the engine level (its public ABI is pure polling — `zjs_has_pending_work` / `zjs_next_timer_ms` / `zjs_run_pending_timers` / `zjs_drain_microtasks`). The `uv_loop_t` declared in `native/worker/engines/zjs.c:105` is *Zapp's* event-loop scaffolding wrapping the polling interface, not zjs's. So this is a Zapp-side enhancement; no upstream zjs work is needed.

## Scope decisions (locked during brainstorm)

| Decision | Value |
|---|---|
| Loop shape | **Hybrid** kqueue + CFRunLoop — forced by zjs upstream including `src/platform/http_apple.m` + `ws_apple.m` unconditionally in libzjs.a today; NSURLSession completions require CFRunLoop ticks. Pure-kqueue ruled out. |
| Apple coverage | macOS first, iOS Simulator follow-up **in the same branch** (5 phased commits). iOS device deferred. |
| Linux/Windows | Defer. Wrap existing libuv path under `#if !defined(__APPLE__)` so non-Apple targets are unchanged. |
| iOS Sim arch | `ios-simulator-arm64` only. Intel-host fat-lipo deferred. |
| Commit shape | 5 phased commits, each producing buildable state for bisect (vendor bump, kqueue+CFRunLoop loop, drop Homebrew libuv on Apple, iOS Sim wiring, iOS Sim verification). |
| Out of scope | Pure-kqueue variant, iOS device, fat-sim, Linux/Windows kqueue equivalents, `uv_queue_work` replacement (unused by zjs). |

## Architecture

Per-worker thread loop body on Apple targets:

```c
int kq = kqueue();
struct kevent change[3];
EV_SET(&change[0], FILTER_SHUTDOWN,    EVFILT_USER, EV_ADD|EV_CLEAR, 0, 0, NULL);
EV_SET(&change[1], FILTER_INBOX,       EVFILT_USER, EV_ADD|EV_CLEAR, 0, 0, NULL);
EV_SET(&change[2], FILTER_EVAL_INBOX,  EVFILT_USER, EV_ADD|EV_CLEAR, 0, 0, NULL);
kevent(kq, change, 3, NULL, 0, NULL);

while (1) {
    int64_t next_ms = zjs_next_timer_ms(slot->ctx);              /* -1 if no timer */
    struct timespec ts;
    struct timespec* tsp = build_timeout(next_ms, &ts);          /* capped at 1s; see Risk 1 */

    struct kevent events[8];
    int n = kevent(kq, NULL, 0, events, 8, tsp);

    /* drain triggered user events */
    for (int i = 0; i < n; i++) {
        if (events[i].ident == FILTER_SHUTDOWN)    handle_shutdown(slot);
        if (events[i].ident == FILTER_INBOX)       drain_inbox(slot);
        if (events[i].ident == FILTER_EVAL_INBOX)  drain_eval_inbox(slot);
    }

    /* tick zjs (timers + microtasks) */
    zjs_run_pending_timers(slot->ctx);
    zjs_drain_microtasks(slot->ctx);

    /* tick CFRunLoop — NSURLSession completions for fetch/WebSocket */
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
    zjs_drain_microtasks(slot->ctx);   /* re-drain if CFRunLoop fired anything */

    if (atomic_load(&slot->wants_terminate)) break;
    if (atomic_load(&slot->wants_restart))   break;   /* outer reincarnation loop handles */
}
close(kq);
```

**Cross-thread signaling** becomes `kevent(kq, &trigger, 1, NULL, 0, NULL)` where `trigger` is an `EV_ENABLE|EV_CLEAR|NOTE_TRIGGER` event for the relevant FILTER_* ident. EVFILT_USER coalesces naturally (multiple triggers between drains → one wake), matching `uv_async_send` semantics.

**Why EVFILT_USER is the right primitive:** it's the kqueue equivalent of `uv_async_send` — a userspace-triggered wake, no kernel object behind it, no pipe-pair, no eventfd. One kqueue fd, three idents, three fire-and-forget triggers.

**1s kevent timeout cap.** When `zjs_next_timer_ms()` returns `-1` (no pending JS timer), we still cap the kevent timeout at 1 second instead of blocking indefinitely. Reason: NSURLSession completions dispatch through CFRunLoop sources we tick at the bottom of each iteration. Without a cap, a worker with no JS timers but an outstanding `fetch()` would block in `kevent()` forever — fetch arrives, CFRunLoop has it queued, but our loop is parked. Worst-case 1s latency on fetch when no other event wakes the loop. Tunable.

## Handle mapping (libuv → kqueue/CFRunLoop)

| Current libuv handle (zjs.c) | Replacement on Apple |
|---|---|
| `uv_loop_t loop` (slot field) | `int kqueue_fd` (slot field) |
| `uv_check_t check` (per-tick drain) | inlined: drain after every `kevent()` return |
| `uv_timer_t zjs_wake` (next deadline) | inlined: `zjs_next_timer_ms()` → `struct timespec` → kevent timeout |
| `uv_async_t shutdown_async` | `EVFILT_USER` ident `FILTER_SHUTDOWN = 1` |
| `uv_async_t inbox_async` | `EVFILT_USER` ident `FILTER_INBOX = 2` |
| `uv_async_t eval_inbox_async` | `EVFILT_USER` ident `FILTER_EVAL_INBOX = 3` |
| `uv_run(loop, UV_RUN_DEFAULT)` | `while (1) { kevent + drain + CFRunLoop tick }` |
| `uv_stop(loop)` | `atomic_store(wants_terminate, 1); kevent(... NOTE_TRIGGER on FILTER_SHUTDOWN)` |
| `uv_async_send(&handle)` | `kevent(kq, &trigger_for_<ident>, 1, NULL, 0, NULL)` |
| `uv_loop_init` / `uv_loop_close` | `kq = kqueue()` / `close(kq)` |
| Homebrew `libuv` dep (CLI `build-config.ts`) | gone on Apple — `Foundation` + `libSystem` are already linked via the existing macOS framework set; `<sys/event.h>` (kqueue) and `<CoreFoundation/CoreFoundation.h>` are includes only |

Net disk impact on Apple targets: one fewer dynamic dependency (`libuv.dylib` no longer linked); two new system includes inside the Apple `#if`. Source-line count: roughly net-neutral — kqueue setup is more verbose than `uv_async_init`, but collapsing `uv_check_t` + `uv_timer_t` into inlined drain logic and removing the per-handle init/close ceremony evens out.

## Commit shape (5 phased commits)

| # | Commit | What lands |
|---|---|---|
| 1 | `chore(vendor): bump zjs to current main` | Submodule pointer `5a30e7b` → upstream HEAD. No Zapp code changes. Surfaces any zjs API drift early. Build verifiable on macOS via hello-world. |
| 2 | `feat(zjs-worker): kqueue + CFRunLoop loop on Apple` | Replace libuv handles per the handle-mapping table, gated `#if defined(__APPLE__) ... #else` (libuv preserved for non-Apple). Slot fields change shape under the same gate. Drop `#include <uv.h>` on Apple; add `<sys/event.h>` + `<CoreFoundation/CoreFoundation.h>`. Hello-world supervisor demo must still produce 4×crashed / 2×restarted / 2×gave-up. |
| 3 | `feat(cli): drop Homebrew libuv on Apple zjs builds` | `cli/src/build-config.ts:970+`: drop the `uvIncludeCandidates` / `uvLibCandidates` lookup, the `brew install libuv` error, and the `-luv` / `-Wl,-rpath` / Frameworks-bundling lines. Keep them under a `target !== "macos" && target !== "ios..."` branch for future Linux/Windows. |
| 4 | `feat(cli): wire zjs for iOS Simulator builds` | Open the `target === "macos"` gate to include `ios-simulator`. Invoke `make -C vendor/zjs ios-simulator-arm64`. Link `vendor/zjs/build/ios/simulator-arm64/libzjs.a` instead of macOS's `build/libzjs.dylib`. Add `zjs.c` to the iOS source list in `cli/src/native.ts`. Have `_zapp_build_ios.zc` generation emit `ZAPP_WORKER_ENGINE_ZJS` when the config has zjs workers (unified with the macOS overlay generator). |
| 5 | `chore: hello-world iOS Sim verification + cleanup` | `bun run dev --platform ios` on hello-world with `engine: "zjs"` for supervised + ticker. Verify supervisor demo. Update `hello-world/zapp.config.ts` cross-engine smoke matrix comment to include `iOS Sim zjs → same sequence`. Drop the "iOS waiting on libuv" caveat from `docs/engines.md` platform recommendations. |

Each commit produces working software on its own slice.

## iOS build wiring details

- **Cross-compile invocation.** CLI runs `make -C vendor/zjs ios-simulator-arm64` exactly once (idempotent; zjs's Makefile checks artifact existence). Output: `vendor/zjs/build/ios/simulator-arm64/libzjs.a`. ~30s on first build, cached after.
- **Link line.** Static `libzjs.a` instead of macOS's dynamic `libzjs.dylib`. No `install_name_tool` / Frameworks-bundling dance on iOS — symbols link directly into the app binary.
- **Foundation framework.** Pre-flight `grep -n "Foundation\|CoreFoundation" cli/src/native.ts` to confirm iOS framework list already includes them (the kqueue code uses no extra frameworks; CFRunLoop is in CoreFoundation; NSURLSession is in Foundation). If absent, add to the iOS framework list as part of commit 4.
- **`hello-world/zapp/_zapp_build_ios.zc`.** Currently auto-generated to hardcode `ZAPP_WORKER_ENGINE_BARE_JSC`. Commit 4 unifies generation with the macOS overlay: emit `ZAPP_WORKER_ENGINE_ZJS` (and/or others) based on what the config's `headless` map references — one codepath, not two.

## Testing

| Stage | Verification |
|---|---|
| Commit 1 (vendor bump) | `cd hello-world && bun run build` clean on macOS. New zjs main has AsyncGenerator/Streams/crypto/WinterCG — none touch the embed ABI; build is the canary. |
| Commit 2 (kqueue+CFRunLoop) | Build clean. Hello-world supervisor demo on `engine: "zjs"`: 4-click force-crash → documented 4×crashed / 2×restarted / 2×gave-up sequence. Stderr should show `[zapp] zjs worker 'h-supervised' restarting (incarnation N, fail_count X/2 in 30000ms window)`. Ticker (setInterval) ticks at expected cadence. |
| Commit 3 (drop libuv on Apple) | Build clean on a machine without Homebrew libuv (move `/opt/homebrew/lib/libuv.dylib` aside to simulate). Confirms the Apple build no longer references `-luv`. |
| Commit 4 (iOS Sim wiring) | `cd hello-world && bun run build --platform ios` clean. `vendor/zjs/build/ios/simulator-arm64/libzjs.a` exists post-build. `bun run dev --platform ios` launches hello-world in the booted iOS Simulator. |
| Commit 5 (iOS Sim verification) | Manual: in iOS Sim webview, click "force-crash" 4× → same event sequence as macOS. Ticker on iOS Sim also ticks. Optional NSURLSession test deferred — CFRunLoop tick is correct by inspection; first real fetch test happens in a downstream app. |

Per [[verify-native-build-not-vite-output]]: require `[zapp] build complete: ...` as the LAST line of stdout AND fresh binary mtime. Vite's `✓ built in XXms` is NOT overall build success.

## Risks

1. **CFRunLoop tick latency on idle workers.** Mitigated by the 1s kevent timeout cap. Worst-case: a `fetch()` completion arrives up to 1s after the network response if no other event wakes the worker. Reasonable starting point; revisit if production traffic shows the latency matters.
2. **zjs vendor pointer is far behind — API drift risk.** Mitigated by Commit 1 being a standalone vendor bump with its own build verification. If commit 1 fails to build cleanly, the cost is one commit revert, not the whole branch.
3. **Foundation already linked on iOS?** Pre-flight grep in Commit 4 confirms before assuming. If absent, add to the iOS framework list (one extra `//> ios: framework: Foundation` directive equivalent in the iOS overlay generator).
4. **Worker thread cancellation race.** EVFILT_USER triggers are slot-stored — a trigger arriving before the loop calls `kevent()` is returned by the next call. Equivalent to libuv's `uv_async_send`. No regression.
5. **Multi-arch iOS Sim users.** We build only `ios-simulator-arm64` (Apple Silicon hosts). Intel hosts would need `ios-simulator-x64` or fat-sim. Out of scope; track as follow-up if it surfaces.
6. **Linux/Windows path stays on libuv.** No regression to non-Apple targets. `#if !defined(__APPLE__)` preserves the existing code path verbatim.

## Out of scope (defer to follow-on)

- Pure-kqueue (no CFRunLoop) — ruled out: zjs ships fetch/WebSocket unconditionally.
- iOS device target — Simulator-only this branch; device adds `make ios-device` + device lib link.
- iOS fat simulator — Apple Silicon-only this branch.
- Linux/Windows kqueue equivalents (epoll, IOCP).
- `uv_queue_work` replacement (zjs doesn't use it).
- Unified loop abstraction layer across platforms. YAGNI until Linux/Windows actually ship.
- Worker event delivery audit (gaps captured in [[supervisor-restart-followups]]) — separate cycle, can run after this lands.

## File map

| Path | Operation | Commit |
|---|---|---|
| `vendor/zjs` | submodule pointer bump | 1 |
| `native/worker/engines/zjs.c` | Apple loop replacement (kqueue + CFRunLoop) under `#if defined(__APPLE__)`; libuv path under `#else` | 2 |
| `cli/src/build-config.ts` (~line 970+) | drop Homebrew libuv lookup + `-luv` / `-rpath` / Frameworks-bundling on Apple targets | 3 |
| `cli/src/build-config.ts` (engine overlay generator) | open the macOS-only gate to also handle `ios-simulator`; emit `ZAPP_WORKER_ENGINE_ZJS` in `_zapp_build_ios.zc` | 4 |
| `cli/src/native.ts` (iOS source list + framework list) | include `zjs.c`; confirm Foundation + CoreFoundation are in the iOS framework list | 4 |
| zjs's Makefile invocation | call `make ios-simulator-arm64` from CLI when target is iOS Sim | 4 |
| `hello-world/zapp.config.ts` | smoke matrix comment update | 5 |
| `docs/engines.md` | platform-recommendation lines drop "iOS waiting on libuv" caveat | 5 |
