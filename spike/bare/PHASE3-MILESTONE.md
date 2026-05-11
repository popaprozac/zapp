# Bare Phase 3 milestone — user worker scripts running end-to-end

**Date:** 2026-05-09
**State:** bare-jsc workers achieve functional parity with the legacy
jsc.m and txiki.c engines for the core worker contract.

## What works

A bare-jsc worker now boots through a five-stage pipeline that produces
the same JS-side API as the legacy engines:

```
1. bare_setup            (libjs platform + bare runtime + libuv loop)
2. uv_async_init         (inbox + eval_inbox queues for postMessage / broadcast)
3. dispatcher_setup      (`__zappBridge.invokeService`, fsAllowlist, listener registry)
4. zapp_worker_bootstrap (`self.send`, `self.receive`, timer wrap, error handling)
5. user worker script    (wrapped in IIFE; runs as the bundled .mjs)
```

Verified by running the same `ticker.ts` worker script on all three
engines simultaneously in `hello-world`:

```
[ticker] started        # txiki worker
[ticker] started        # bare-jsc worker (same script, same source)
[supervised] ready      # legacy jsc.m worker
```

## Host functions wired in bare.c

| JS API | Native target | Status |
|---|---|---|
| `__zappBridge.log(msg)` | `fprintf(stderr)` | ✓ |
| `__zappBridge.invokeService(method, args)` | `service_invoke_sync` (via JSON-string round-trip) | ✓ |
| `__zappBridge.postToWebview(json)` | `worker_dispatch_to_webview` | ✓ |
| `__zappBridge.postToWorker(id, json)` | `worker_post_message` | ✓ |
| `__zappBridge.dispatchEventToAll(name, json)` | `dispatch_event_to_all` | ✓ |
| `__zappBridge.workerCrash(msg, stack)` | `worker:crashed` event + supervisor.record_failure | ✓ (no restart yet) |
| `__zappBridge.fsAllowlist` (data, not fn) | injected from `zapp_build_fs_allowlist_json` | ✓ |
| `Symbol.for('zapp.bridge')` alias | manual install in dispatcher_setup | ✓ |

## What's still missing for full parity

1. **Worker restart on crash** — bare's supervisor `record_failure` path
   logs but doesn't actually restart the JS env yet. Same gap as txiki
   (project_txiki_worker_restart.md). Half-day of pthread + uv_loop
   teardown when picked up.
2. **Module loading via `bare_load`** — currently we use `js_run_script`
   to evaluate the bundled .mjs. This works because tsup self-bundles
   imports. To support runtime `import 'bare-fetch'` etc., we need
   `bare_load` working with bare-module's resolver. Blocked on T1.6
   (CLI install + cmake-link of bare-* modules into libbare_modules.a).
3. **Sync wait/notify** (`__zappBridge.syncWait` / `syncNotify`) — used
   by Services.invokeSync's blocking variant. Not yet implemented in
   bare.c. Easier than it sounds: blocking wait on a condition variable
   + drain a sync_inbox alongside the regular inbox.
4. **Tier-1 host objects** (`clipboard`, `notif`, `shortcuts`, etc.) —
   currently the rich tier-1 fast-path only exists in jsc.m and
   txiki.c. Bare workers can call them via `invokeService` (slow path)
   today; the fast direct-call versions are a port-each-API job.

## Implication for jsc.m / txiki.c removal

Sequence now visible:

1. Land items 1–3 above ⇒ **bare reaches FULL functional parity** with
   the legacy engines.
2. Soak across an alpha cycle with hello-world's ticker + supervisor on
   bare to surface edge cases.
3. Port the tier-1 host objects (item 4) one-by-one. Each port lets
   one more app-level feature work on bare.
4. Once tier-1 ports are done, the legacy engines can be removed.
   Estimated savings: ~3,500 lines of duplicate engine plumbing,
   ~3-4 MB binary on macOS, drops the entire txiki vendor (libwebsockets
   + ada + miniz + sqlite + mbedtls go away with it).

This phase reduced "deprecate the legacy engines?" from a strategic
question to a sequencing question.
