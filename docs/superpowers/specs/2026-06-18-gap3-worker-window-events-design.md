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

The one genuine hole is **window lifecycle events (resize/focus/close/…) never reach workers** — on **both** builds, and via **two** independent breaks (deeper investigation while pinning the smoke surfaced the second one):

1. **Native/engine — zjs lacks the arming host fn.** The worker bridge's `subscribeWindowEvent` host function exists only in `bare.c` (`1139-1159`, registered `1681-1684`); **`zjs.c` lacks it**. `callbacks.nim` Layer 3 (window→worker broadcast) is gated on `gBackendListeners`, which only `zapp_window_set_backend_listener` sets — and the only caller is bare's host fn. On a zjs worker `bridge.subscribeWindowEvent` is `undefined`, so `bootstrap/worker.ts:56-57` no-ops and the backend-listener bit is never set.

2. **Worker-side TS — subscribe-name vs delivery-name incoherence** (the "window auto-subscription" WED-audit gap; shared TS, so it breaks **bare too**). Arming fires only for *specific* names in `windowEventIds` (`window:resize`→3, …), but native **delivers** under the generic envelope `_onEvent('window:event', {event:3,…})`, and `_onEvent` fires `listeners[name]` by the literal delivered name with **no** remap. Net: `Events.on('window:resize', cb)` arms the bitmask but its handler never fires (delivery is `'window:event'`); `Events.on('window:event', cb)` receives nothing (not in the arming map). So even with break #1 fixed, the obvious worker code silently fails.

This is a **worker-event-delivery gap, not a Nim-migration gap.** `native/worker/engines/zjs.c` is Zapp's C embedder (reused untouched by both builds; the migration ports `.zc`→Nim, not `.c`/`.m`); the worker-side mapping is shared TS. Per the worker-engine strategy (zjs is the default/jitless/iOS engine we invest in; bare is backlogged/reference-only), closing this on zjs is the right move — and `bare.c` is the reference for break #1.

### Event taxonomy (for clarity — only category 2 → workers is broken)

- **Custom app events** — `Events.emit(anyName, data)` / `Events.on(anyName, cb)`, arbitrary names, broadcast to all webviews **+** workers (`dispatch_event_to_all`, ungated). Works today, all directions (window↔window↔worker). **Not** what `'window:event'` is.
- **Native window-lifecycle events** — framework-typed names (`window:resize`, or the `WindowEvent.Resize` enum via `eventName()`). Webview/main already gets these *windowId-scoped* (`win.on(WindowEvent.RESIZE, cb)` exists in `runtime/window.ts`, returns an unsubscribe fn). **Worker delivery is the hole this spec closes.** `'window:event'` is the *internal envelope* for this category → workers, never a user-facing name.
- **Native app-lifecycle events** — `app:theme-changed`, etc. Reach workers ungated. Works.

## Goal

Make native window-lifecycle events reach **zjs** workers, with the same per-event typed API the rest of the framework uses (`Events.on(WindowEvent.RESIZE, cb)` works in a worker and returns an unsubscribe fn). Two-part fix — the zjs arming host fn **and** the worker-side subscribe/deliver coherence — plus record correction and a live smoke. No router or Nim-native changes required.

## What's already there (don't rebuild)

- `callbacks.nim` Layer 3 (`108-114`) already broadcasts the `window:event` envelope to all workers via `worker_broadcast_eval_js`, gated on `gBackendListeners` (set by `zapp_window_set_backend_listener`). The native broadcast side is done.
- `bootstrap/worker.ts:52-57` `bridge.on` already arms via `subscribeWindowEvent(-1, eventId)` for specific window-event names, guarded on the method existing.
- Per-window scoped listening already exists on the **main/webview** side: `win.on(WindowEvent.RESIZE, cb)` (`runtime/window.ts`), windowId-filtered, returns an unsubscribe fn. This spec does **not** add a worker-side `win.on()` handle (see Out of scope).

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

### 2. Worker-side TS — subscribe/deliver coherence

**`bootstrap/worker.ts`** — fix break #2 so a specific-name subscription actually fires:
- `bridge.on` already arms via `subscribeWindowEvent(-1, eventId)` for names in `windowEventIds` — keep as-is.
- `bridge._onEvent` — when the delivered `name === 'window:event'`, parse the payload, read its numeric `event` field, **reverse-map** it (inverse of `windowEventIds`, e.g. `3 → 'window:resize'`) and fire `listeners[specificName]` with the parsed payload. All other names (custom events, app events) keep firing `listeners[name]` exactly as today. `'window:event'` stays an internal envelope — it is not surfaced as a user-facing listener name.
- Net: `Events.on('window:resize', cb)` now both arms (existing) and receives (new reverse-map) in a single call; the returned unsubscribe closure already works.

**`runtime/events.ts`** — typed ergonomics: add a `WindowEvent`-enum-accepting overload to `Events.on` (convert via `eventName(enum)` then delegate) so `Events.on(WindowEvent.RESIZE, cb)` is first-class in any context (it currently takes only the `EventName` string). Returns the same unsubscribe fn.

No native broadcast/router/Nim changes — `callbacks.nim` Layer 3 already ships the envelope; this part only makes the worker JS arm + route it coherently.

### 3. Record correction + hello-world

- `native/nim/app_events.nim` (~line 9) and `native/nim/callbacks.nim` (~line 10): replace the stale "Layer 2/3 … DEFERRED no-op (Batch 4/7)" comments with the real state — worker fan-out wired in `87d745a`; Layer 2 (app) ungated broadcast, Layer 3 (window) gated on the backend-listener bitmask now set via the zjs `subscribeWindowEvent` host fn.
- `docs/nim-migration-roadmap.md` gap #3: reframe to "Nim has worker-event parity with zc (app/global/targeted verified). The residual window→worker hole had two breaks — zjs missing the `subscribeWindowEvent` host fn (engine glue, shared by zc) and the worker-side subscribe/deliver name incoherence (shared TS) — both closed here." Note gap #4 (bare-* engines) is **deferred** per the worker-engine strategy; the live path after gap #3 is zjs-centric (iOS gap #5, Windows gap #6, default-flip gap #7).
- `hello-world/src/workers/supervised.ts:89`: rewrite the `Events.on("window:event", …)` demo (which never fired — it used the internal envelope name) to the specific typed name (`Events.on(WindowEvent.RESIZE, …)` / `'window:resize'`), which now works end-to-end.

## Testing

- **Unit (worker-side reverse-map):** the inverse-map + `_onEvent` routing is pure TS — add a `bun:test` that feeds a `'window:event'` payload (`{event:3,…}`) and asserts a listener registered under `'window:resize'` fires with the payload, and that a non-window name routes unchanged. Plus a test that `Events.on(WindowEvent.RESIZE, …)` resolves to the `'window:resize'` string path.
- **Build gate:** `ZAPP_NATIVE_LANG=nim bun run build` of kitchen-sink completes with `[zapp] build complete: …`; `bun test` + `bunx tsc --noEmit` green.
- **Live smoke (the real proof):** a zjs worker on the Nim build does `Events.on(WindowEvent.RESIZE, cb)` (single call) and logs receipt — with the window's `windowId` — when the window is resized. Confirms both breaks closed end-to-end. The kitchen-sink Workers section is the natural host; the rewritten hello-world `supervised.ts` listener also serves.
- **Parity sanity:** app/global event delivery to a zjs worker still works (unchanged paths) — observable alongside.

## Out of scope (deferred follow-ups)

- **Worker-side per-window scoped `win.on()` handle** — workers are app-scoped and hear the broadcast for all windows (filter by `payload.windowId`); the scoped handle already exists where it's most natural (main/webview `win.on`). Clean follow-up if a worker-owns-a-window case arises.
- **Explicit `.off(event, handler)` methods** — the returned-unsubscribe-closure idiom is consistent across `win.on`/`Events.on`/worker `bridge.on`; an explicit `.off()` is a broader API addition for later.
- **Porting `zjs.c` to Nim** — shared C glue (like the `.m` files); rides along with the eventual zjs-*engine* Nim rewrite.
- **bare-* engines (gap #4)** — backlogged / reference-only per the worker-engine strategy. (bare already has break #1 fixed; break #2's worker-side TS fix benefits it for free.)

## Risks

- **Reverse-map correctness** — the inverse of `windowEventIds` must be exact (id→name) and only applied to the `'window:event'` envelope; covered by the unit test.
- **Void-return / window-cap mismatch (zjs.c)** — mitigated by mirroring the exact sibling host-fn idiom (`zjs_undefined()`, loop bound `64`) and the internally-bounds-checked setter.
- **zc build regression** — `zjs.c` change is purely additive (new host fn + registration); the worker-side TS fix is shared and additive (new reverse-map branch + an overload). No existing symbol/behavior changes.
- **Parity drift** — none; this *adds* zjs parity with `bare` and fixes the shared worker-side mapping for both. Per the (relaxed) worker-engine-parity stance, zjs is the priority.
