# Worker event delivery audit — design

## Context

Three pre-existing gaps surfaced during the legacy-engine removal cycle ([[legacy-engines-removed-2026-06-01]] and [[supervisor-restart-followups]]):

- **Gap A — window events.** `native/window/callbacks.zc:127-134` has a Layer 3 dispatch block that used to broadcast to JSC/txiki workers. After those engines were removed, the block is now a TODO comment — bare and zjs workers calling `bridge.subscribeWindowEvent(windowId, eventId)` register their interest (the bit-field `zapp_window_backend_listeners` is set) but receive nothing.
- **Gap B — shortcut events.** `native/platform/darwin/shortcuts.m:206` (and the iOS sibling) call `darwin_webview_eval_all(js)` to broadcast `app:shortcut-triggered` to the webview, but have no equivalent worker-broadcast call. Workers with `Events.on("app:shortcut-triggered", ...)` never fire.
- **Gap C — sync results.** `native/platform/darwin/sync.m:290-291` dispatches `Services.invokeSync` results via `bare_worker_eval_js(worker_id, js_c)` — a targeted per-worker eval. There's no `zjs_worker_eval_js` equivalent, so a zjs worker calling `invokeSync` never sees its result resolve.

While auditing, eight more native-emit sites turned out to share the same shape (calls `darwin_webview_eval_all` for the webview but doesn't broadcast to workers): `menu.m`, `tray.m`, `notification.m` (macOS + iOS), `platform.m`, `app_events.zc`, and the rest of `sync.m`'s webview broadcasts. None of those events reach worker `Events.on(...)` subscribers today.

The audit closes all 13 sites in one pass via a unified worker-broadcast helper that mirrors the engine-fanout block already inside `dispatch_event_to_all`.

## Goal

Every native-emitted app event reaches both webviews **and** active workers, regardless of engine. The fanout logic lives in one helper so adding a new engine in the future doesn't require touching 13 call sites.

`Services.invokeSync` from a zjs worker resolves correctly, matching bare's existing behavior.

## Non-goals

- iOS verification — the helpers are platform-agnostic and the iOS sites get the same edits as macOS, but we don't formally exercise the matrix on iOS Sim (incidental coverage only). Same deferred-verification pattern as the supervisor-restart cycle's iOS smoke.
- Windows — Linux / Windows builds don't ship a worker engine yet; the new helpers compile to no-ops there.
- Removing `zapp_window_backend_listeners` bit-field — keep the gate at the window-event call site (avoids waking workers on every mouse-driven resize when nothing subscribed). Cleanup is a separate followup.
- Auto-subscription on `Events.on("window:resize", fn)` — today bare's `subscribeWindowEvent` is an explicit runtime call. Making it implicit when a listener is registered is a runtime concern, not a bridge concern.
- JS-runtime API changes — `Events.on(...)`, `Workers.send(...)`, `bridge.subscribeWindowEvent(...)` all keep their current contracts. This is a native-side plumbing fix; user code is unchanged.

## Architecture

Five layers, each with one clear concern:

```
┌─────────────────────────────────────────────────────────────────┐
│  Native-emit call sites (13 sites across darwin/, ios/, zc)     │
│  Pattern: darwin_webview_eval_all(js)                            │
│           + worker_broadcast_eval_js(js)   ← new, 1 line per site│
└────────────────────┬────────────────────────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Bridge layer — native/bridge/dispatch.zc                        │
│  ▸ worker_broadcast_eval_js(js)     — fans to engine broadcasts  │
│  ▸ worker_eval_js(worker_id, js)    — looks up engine, dispatches│
│  ▸ dispatch_event_to_all(...)       — REFACTORED to use the new  │
│                                       worker_broadcast helper    │
└────────────────────┬────────────────────────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Worker registry + dispatch                                      │
│  registry.zc:                                                    │
│    ▸ zapp_worker_registry_get_engine(id) -> int  ← new           │
│  worker.zc:                                                      │
│    ▸ zapp_dispatch_worker_eval_js(eng, id, js)  ← new            │
│      (mirrors existing zapp_dispatch_worker_post)                │
└────────────────────┬────────────────────────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Engine layer                                                    │
│  bare.c:  bare_worker_eval_js     ✓ exists                       │
│           bare_broadcast_eval_js  ✓ exists                       │
│  zjs.c:   zjs_broadcast_eval_js   ✓ exists                       │
│           zjs_worker_eval_js      ← new (mirrors bare)           │
└─────────────────────────────────────────────────────────────────┘
```

**Two key principles:**

1. **`dispatch_event_to_all` becomes a consumer of the new helpers**, not a parallel implementation. Today it inlines `bare_broadcast_eval_js` + `zjs_broadcast_eval_js` under `#if` gates. After the refactor, it calls `worker_broadcast_eval_js(js)` — same fanout, factored. Eliminates the divergence risk where one path picks up a new engine and the other doesn't.

2. **Window-event gate stays.** `callbacks.zc` already has `zapp_window_backend_listeners[window_id] & (1u << event_id)` checking whether any worker subscribed. The new `worker_broadcast_eval_js(js)` call gates on the same bit. Avoids waking workers on every mouse-driven resize event when nothing's listening. Bit-field is already maintained by `bridge.subscribeWindowEvent`; no runtime API change needed.

## Components

### Engine layer (new)

```c
// native/worker/engines/zjs.h + zjs.c
//
// Target a specific zjs worker by ID. Walks the slot table, pushes the
// JS snippet onto the matching slot's eval_inbox queue. No-op when the
// id doesn't resolve.
//
// Mirrors bare_worker_eval_js (bare.c:1210). Same eval_inbox queue +
// trigger pattern the broadcast variant already uses, scoped to one
// slot. ~30 LOC.
void zjs_worker_eval_js(const char* worker_id, const char* js);
```

### Worker registry (new)

```c
// native/worker/registry.zc
//
// Returns the engine ID stored on the worker entry, or -1 if no active
// entry matches. Mirrors the worker_id lookup at the top of every
// existing zapp_dispatch_worker_* function — extracted so dispatch.zc
// can route by engine without recompiling the search loop.
extern fn zapp_worker_registry_get_engine(worker_id: string) -> int;
```

### Worker dispatcher (new)

```c
// native/worker/worker.zc — sits next to zapp_dispatch_worker_post.
//
// Engine-aware targeted dispatch. Switch on engine ID:
//   case 2..6 (bare-*): bare_worker_eval_js(worker_id, js)
//   case 7 (zjs):       zjs_worker_eval_js(worker_id, js)
//   default:            no-op (worker doesn't exist OR engine not built in)
//
// Engines that aren't compiled in stub out via the existing #if-stub
// machinery in worker.zc.
extern fn zapp_dispatch_worker_eval_js(eng: int, worker_id: string, js: string) -> void;
```

### Bridge layer (new — the call-site-facing API)

```c
// native/bridge/dispatch.zc
//
// Broadcast: evaluate the JS in every active worker, every engine.
// Identical to the inline block currently in dispatch_event_to_all,
// extracted so other call sites can reuse it.
extern fn worker_broadcast_eval_js(js: string) -> void;

// Targeted: evaluate the JS in one specific worker, routed by registry.
// Looks up the worker's engine via zapp_worker_registry_get_engine,
// then dispatches via zapp_dispatch_worker_eval_js. Silent no-op when
// the ID is unknown (registry lookup returns -1).
extern fn worker_eval_js(worker_id: string, js: string) -> void;
```

### Bridge layer (refactor)

```c
// dispatch_event_to_all stays the same signature, but its inline
// worker-broadcast block (the #if defined(ZAPP_WORKER_ENGINE_ZJS) /
// #if defined(ZAPP_HAS_BARE) block under "// Workers" comment) is
// replaced with a single call to worker_broadcast_eval_js(js). One
// source of truth for "broadcast to all workers."
fn dispatch_event_to_all(event_name: string, payload: string) -> void {
    /* ... existing IIFE construction ... */
    darwin_webview_eval_all(js);    // or windows_webview_eval_all on Win
    worker_broadcast_eval_js(js);   // ← replaces the inline #if block
    free(js);
}
```

## Semantics

- **`worker_eval_js(unknown_id, ...)` is a silent no-op.** Matches the documented behavior at `sync.m:286-291` (the comment "bare_worker_eval_js is a no-op when the worker_id doesn't match" becomes accurate again, now engine-agnostic).
- **`worker_broadcast_eval_js`** broadcasts to ALL active workers regardless of subscription state. Worker JS self-filters via `Events.on(name, fn)`. Native side does not track per-event subscription (except the existing window-event bit-field, which gates at the call site BEFORE invoking the helper — the helper itself is unconditional).
- **`zjs_worker_eval_js`** uses the same eval_inbox queue + EVFILT_USER trigger as the broadcast variant (just filtered to one slot). On Apple this means a kqueue wake; on Linux/Windows it'd be `uv_async_send`. Slot lifecycle is the same — if the worker is terminating mid-call, the queue push is dropped safely (slot mutex protects).
- **No JS-runtime API change.** User code is unchanged.

## Call sites

13 sites, each a 1-line addition (or 1-line replacement for `sync.m:290` and `dispatch.zc`):

| # | File:line | Event category | Edit |
|---|---|---|---|
| 1 | `native/window/callbacks.zc:135` | Window resize / move / close | `if (zapp_window_backend_listeners[window_id] & (1u << event_id)) worker_broadcast_eval_js(js);` (gated) |
| 2 | `native/platform/darwin/shortcuts.m:206` | Global shortcut | `worker_broadcast_eval_js(js);` |
| 3 | `native/platform/darwin/menu.m:30` | Menu item activated | `worker_broadcast_eval_js([js UTF8String]);` |
| 4 | `native/platform/darwin/tray.m:167` | Tray icon clicked | `worker_broadcast_eval_js(js);` |
| 5 | `native/platform/darwin/notification.m:23,31` | Notification click / action | `worker_broadcast_eval_js([js UTF8String]);` (two sites) |
| 6 | `native/platform/darwin/platform.m:138` | Theme change | `worker_broadcast_eval_js([js UTF8String]);` |
| 7 | `native/platform/darwin/sync.m:259,263` | Sync result broadcast (webview path) | `worker_broadcast_eval_js([js UTF8String]);` |
| 8 | `native/platform/darwin/sync.m:290-291` | Targeted sync result (Gap C) | Replace `bare_worker_eval_js(...)` with `worker_eval_js(...)` |
| 9 | `native/platform/ios/shortcuts.m` | iOS global shortcut equivalent | `worker_broadcast_eval_js(js);` |
| 10 | `native/platform/ios/sync.m` | iOS sync result | Broadcast + targeted, same as macOS sync.m |
| 11 | `native/platform/ios/notification.m:24,31` | iOS notification | `worker_broadcast_eval_js([js UTF8String]);` |
| 12 | `native/app/app_events.zc:104` | App reopen / deep link | `worker_broadcast_eval_js(js_buf);` |
| 13 | `native/bridge/dispatch.zc:117-135` | `dispatch_event_to_all` refactor | Replace inline `#if` block with `worker_broadcast_eval_js(js);` |

Site 1 is gated on `zapp_window_backend_listeners[window_id] & (1u << event_id)` to avoid waking workers on mouse-driven resize storms when nothing subscribed. All other sites broadcast unconditionally — these event categories are low-rate (clicks, theme changes, etc.) and JS-side self-filtering via `Events.on` is the natural pattern.

## Testing

Manual verification on macOS using hello-world's existing supervised worker as the subscriber. Add 6 new `Events.on` listeners to `hello-world/src/workers/supervised.ts`, each logging when it fires. Then manually exercise each event source:

| Gap | Trigger | Expected supervised worker log |
|---|---|---|
| Window event | Resize a window | `[supervised] window:resize received` |
| Shortcut | Press the app's registered global shortcut | `[supervised] app:shortcut-triggered received` |
| Menu | Click a custom menu item | `[supervised] app:menu received` |
| Tray | Click the tray icon | `[supervised] app:tray received` |
| Notification | Click a notification banner | `[supervised] app:notification-action received` |
| Sync result | Webview calls a service that invokes back into supervised via syncWait | `[supervised] sync resolved` |

Each gap category gets one observation; if it fires, the unified path works for that category. No automated harness — same manual approach as supervisor-restart smoke.

Build verification per the standard rule: last line must be `[zapp] build complete: ...`, not Vite's `✓ built in XXms`. Binary mtime fresh.

## Error handling

- `zapp_worker_registry_get_engine(id)` returns -1 on miss. `worker_eval_js` checks for -1 and no-ops — no log spam for terminated workers.
- `zapp_dispatch_worker_eval_js(eng=-1, ...)` no-ops on the default branch.
- `zjs_worker_eval_js(unknown_id, ...)` walks the slot table, finds no match, returns silently (mirrors bare).
- Slot mutex protects against concurrent terminate during eval_inbox push (existing pattern preserved).

## Out of scope (recap)

- iOS verification (incidental coverage only; no formal matrix on iOS Sim)
- Windows worker engine paths (helpers compile to no-ops there)
- `zapp_window_backend_listeners` bit-field removal (followup)
- Auto-subscription via `Events.on` (runtime-side concern; separate followup)
- JS-runtime API changes

## Risks

- **Risk 1 — broadcast amplification.** With 13 native-emit sites now reaching all workers, high-rate events (notification reactions during a heavy banner storm; theme-change cycle during dev work) could push more eval_inbox traffic. Mitigation: every non-window site is intrinsically low-rate (user-driven clicks, OS-driven theme changes). Window resize is the one high-rate source and stays gated on the listener bit-field. No additional throttling needed.
- **Risk 2 — slot mutex contention.** `worker_broadcast_eval_js` acquires each engine's slot mutex once per call. With both bare and zjs compiled in, that's 2 mutex acquires per event. Same cost as `dispatch_event_to_all` pays today. No change.
- **Risk 3 — registry lookup on every targeted dispatch.** `worker_eval_js` does a registry scan (≤64 slots). Sync results are rare; cost is comparable to `Workers.send` which already pays this. Not load-bearing.
- **Risk 4 — divergent native-emit IIFE shapes.** Most call sites build the IIFE inline with the event name baked in (e.g. shortcuts.m uses `'app:shortcut-triggered'`). If the JS template ever changes (e.g. to add a transport version field), each call site needs to be updated independently. Not a regression from this work — the IIFE shape was already duplicated across these sites. Followup: factor IIFE construction into a helper. Tracked as out-of-scope cleanup.

## Related memories

- [[supervisor-restart-followups]] — the source memo identifying gaps A, B, C
- [[legacy-engines-removed-2026-06-01]] — the cycle that exposed gap A (Layer 3 broadcast block was JSC/txiki-gated)
- [[zjs-kqueue-cycle-2026-06-01]] — the cycle that made iOS Sim a real target (motivates iOS edits even when verification stays macOS-only)
- [[verify-native-build-not-vite-output]] — the build verification rule
