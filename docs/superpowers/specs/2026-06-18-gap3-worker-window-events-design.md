# Gap #3 — finish the worker event story on zjs — design

**Date:** 2026-06-18
**Branch:** `feat/nim-native`
**Roadmap:** gap #3 of `docs/nim-migration-roadmap.md` ("deferred worker event fan-out")
**Status:** approved, ready for implementation plan

## Background — the gap is mislocated in the roadmap

The roadmap framed gap #3 as "zc fans app/window events to workers; **Nim drops them**." Exploration proved that **factually wrong**. The Nim build has full worker-event **parity** with the zc build:

| Path | zc (zjs worker) | Nim (zjs worker) |
|---|---|---|
| App events (theme/active/power/…) | ✅ ungated broadcast | ✅ identical (`app_events.nim:90-96` → `worker_broadcast_eval_js`) |
| Global events (menu/tray/shortcut/notif via `dispatch_event_to_all`) | ✅ | ✅ identical (`dispatch.nim`) |
| Targeted (sync, worker→worker) | ✅ | ✅ identical (`worker.nim`) |
| **Window events (resize/focus/close/…)** | ❌ | ❌ — **same** |

The Layer-2/3 worker fan-out was wired for Nim in commit `87d745a`; the "DEFERRED no-op (Batch 4/7)" doc-comments in `app_events.nim`/`callbacks.nim` are simply **stale**.

The one genuine hole is **window events never reach zjs workers** — on **both** builds. Root cause: the worker bridge's `subscribeWindowEvent` host function exists only in `bare.c` (`1139-1159`, registered `1681-1684`); **`zjs.c` lacks it**. So `callbacks.nim` Layer 3 (window→worker broadcast) is gated on `gBackendListeners`, which only `zapp_window_set_backend_listener` sets — and the only caller is bare's host fn. On a zjs worker the bridge method is `undefined`, so `bootstrap/worker.ts:56-57` no-ops and the backend-listener bit is never set.

This is a **zjs-engine-glue gap, not a Nim-migration gap.** `native/worker/engines/zjs.c` is Zapp's C embedder (reused untouched by both builds; the migration ports `.zc`→Nim, not `.c`/`.m`). Per the worker-engine strategy (zjs is the default/jitless/iOS engine we invest in; bare is backlogged/reference-only), closing this on zjs is the right move — and `bare.c` is the reference.

## Goal

Close the window→worker hole on zjs by adding `subscribeWindowEvent` to `zjs.c` (mirroring `bare.c`), correct the stale record, and verify the full round-trip on the Nim build.

## The round-trip already exists except one function

- **Worker-side (shared TS, already present):** `bootstrap/worker.ts:56-57` calls `bridge.subscribeWindowEvent(-1, eventId)` when a worker adds a `window:*` listener, guarded on `typeof bridge.subscribeWindowEvent === "function"`. The worker's `_onEvent` (`bootstrap/worker.ts:140`) maps an incoming `window:event` payload back to the named listener.
- **Native-side (already present):** `callbacks.nim` Layer 3 (`108-114`) broadcasts the `window:event` IIFE to all workers via `worker_broadcast_eval_js`, gated on the `gBackendListeners` bitmask, which `zapp_window_set_backend_listener` sets.

The **only** missing link is the zjs host function that bridges the worker's `subscribeWindowEvent` call to `zapp_window_set_backend_listener`. Adding it closes the loop — **no TS, router, or Nim changes required.**

## Components

### 1. `native/worker/engines/zjs.c` — the host function (the substance)

Add a host function mirroring `bare_host_subscribe_window_event`, in the verified zjs idiom (`static ZjsValue host_x(ZjsContext* ctx, ZjsValue* argv, uint32_t argc)`, ints via `zjs_as_int32(argv[i])`, void-return via `zjs_undefined()` — which takes **no** ctx argument, per `vendor/zjs/include/zjs.h:88` and the sibling host fns):

```c
extern void zapp_window_set_backend_listener(int id, int event_id, int has_listener);

static ZjsValue host_subscribe_window_event(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    (void) ctx;                                    // unused (mirror sibling fns if they cast)
    if (argc < 2) return zjs_undefined();
    int wId = zjs_as_int32(argv[0]);
    int eId = zjs_as_int32(argv[1]);
    if (wId < 0) {                                 // negative = all windows
        for (int i = 0; i < 64; i++) zapp_window_set_backend_listener(i, eId, 1);
    } else {
        zapp_window_set_backend_listener(wId, eId, 1);
    }
    return zjs_undefined();
}
```

Register it in `zjs_setup_bridge` alongside the other host fns (`zjs.c:964-984`):

```c
ZjsValue sub_fn = zjs_register_host_function(ctx, "__zapp_subscribe_window_event",
                                             host_subscribe_window_event);
zjs_set_property(ctx, bridge, "subscribeWindowEvent", sub_fn);
```

Verified values:
- Void return = `zjs_undefined()` (no ctx arg) — exactly what `host_post_to_webview`/`host_worker_crash` return.
- All-windows loop bound = `64`, matching `bare.c:1152` and `ZAPP_MAX_WINDOW_CALLBACKS` (`callbacks.zc:11`). `zapp_window_set_backend_listener` bounds-checks `id` internally, so an over-loop is a safe no-op regardless.
- `zjs.c` is shared, so this also fixes window→worker on the **zc** build — parity-positive, brings zjs to `bare`'s capability.
- No JIT dependency → works on iOS (zjs is jitless).

### 2. Record correction (docs)

- `native/nim/app_events.nim` (~line 9) and `native/nim/callbacks.nim` (~line 10): replace the stale "Layer 2/3 … DEFERRED no-op (Batch 4/7)" comments with the real state — worker fan-out wired in `87d745a`; Layer 2 (app) ungated broadcast, Layer 3 (window) gated on the backend-listener bitmask now set via the zjs `subscribeWindowEvent` host fn.
- `docs/nim-migration-roadmap.md` gap #3: reframe to "Nim has worker-event parity with zc (app/global/targeted verified); the residual window→worker hole was a zjs-engine gap (shared by zc), closed by adding `subscribeWindowEvent` to `zjs.c`." Note gap #4 (bare-* engines) is **deferred** per the worker-engine strategy; the live path after gap #3 is zjs-centric (iOS gap #5, Windows gap #6, default-flip gap #7).

## Testing

- **Build gate:** `ZAPP_NATIVE_LANG=nim bun run build` of kitchen-sink completes with `[zapp] build complete: …`.
- **Live smoke (the real proof):** a zjs worker on the Nim build subscribes to a window event (e.g. `window:resize` or `window:focus`) and logs receipt when the window is resized/focused. The kitchen-sink Workers/Sync section is the natural host; if no existing demo subscribes to a window event, add a minimal one for the smoke.
- **Parity sanity:** confirm app/global event delivery to a zjs worker still works (unchanged paths) — observable in the same smoke.

## Out of scope

- **Porting `zjs.c` to Nim** — it's shared C glue (like the `.m` files); a future Nim version rides along with the eventual zjs-*engine* Nim rewrite, not this work.
- **bare-* engines (gap #4)** — backlogged / reference-only per the worker-engine strategy.
- **Worker→worker or app-event subscription changes** — those paths already work; untouched.

## Risks

- **Void-return / window-cap mismatch** — mitigated by mirroring the exact sibling host-fn idiom and the internally-bounds-checked setter; the plan pins exact values read from the file.
- **zc build regression** — `zjs.c` is shared, but the change is purely additive (a new host fn + registration); no existing symbol/behavior changes. The zc build keeps compiling the same file.
- **Parity drift** — none; this *adds* zjs parity with `bare`. Per the (relaxed) worker-engine-parity stance, zjs is the priority and bare already has the capability.
