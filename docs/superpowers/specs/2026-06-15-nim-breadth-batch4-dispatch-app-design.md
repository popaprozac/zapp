# Nim Migration — Phase 2 Breadth, Batch 4: Bridge/Dispatch + App — Design

**Status:** Design (approved 2026-06-15). **Branch:** `feat/nim-native`.
**Part of:** the Nim migration breadth phase (`2026-06-15-nim-migration-design.md`); applies
the type-modeling convention (`2026-06-15-nim-type-modeling-convention-design.md`).
B1 events, B2 services, B3 permissions done. **This is Batch 4** — the dispatch/worker
fan-out layer (closing the B1 Layer-3 deferral) + the app-config getters.

## Goal

Port `native/bridge/dispatch.zc` (worker-broadcast dispatch infra) and the `app.zc`
AppConfig getters to Nim — making **window/app events actually reach the headless worker**
(today the worker fan-out is a no-op stub), and replacing the four hardcoded
`app_get_bootstrap_*` stubs with real `AppConfig` reads. Introduce the user-facing
`Inspectable {.pure.}` enum (the convention's deferred item) here.

## Scope — one batch, two halves

### Half 1 — Dispatch / worker fan-out (`native/nim/dispatch.nim`, new)

The worker-fan-out helpers from `dispatch.zc`. New module so `callbacks.nim` / `app_events.nim`
import it without a cycle (it's leaf — no back-imports).

- **`zapp_escape_dup(src: cstring): cstring {.exportc, cdecl, gcsafe.}`** — the REAL escaping
  allocator from `dispatch.zc:30` (escape `\` `'` `\n` `\r`, `malloc` 2n+1, caller frees),
  **replacing the non-escaping `strdup` stub** in `zapp.nim:257`. libc-based (`c_malloc` +
  manual char loop, no Nim heap) so it stays `{.gcsafe.}` and safe on any thread — `zjs.c`
  calls it (and frees the result) for worker→webview payloads, and the Nim dispatch builders
  use it too. Fixes the latent bug where event payloads containing `'`/newlines broke the
  injected JS.
- **`worker_broadcast_eval_js(js: cstring) {.exportc, cdecl.}`** — broadcast a JS snippet to
  every worker via `importc zjs_broadcast_eval_js` (zjs.c, in the build). `{.exportc.}` so the
  B6/B8 native-emit `.m` sites (shortcuts/menu/tray/sync) link against it when they land; the
  Nim dispatch path calls it now. (The bare-engine branch is compiled out — zjs-only build.)
- **`dispatch_event_to_all(eventName, payload: cstring) {.exportc, cdecl, gcsafe.}`** — the
  global event broadcast (`dispatch.zc:138`): build the `_onEvent('name','payload')` IIFE
  (escaped), `darwin_webview_eval_all` (importc) to every webview, then `worker_broadcast_eval_js`
  to every worker. **Replaces the `zapp.nim:220` no-op stub.**
- A small `iifeOnEvent(name, payload: cstring): string` helper builds the shared
  `(function(){var b=globalThis[Symbol.for('zapp.bridge')];if(b&&typeof b._onEvent==='function'){b._onEvent('<name>','<payload>');}})();`
  shape (escaping via `zapp_escape_dup`), used by `dispatch_event_to_all` and the wiring below.

### Half 1 wiring (make the deferred Layer-3 real)

- **`callbacks.nim` Layer-3** (`workerBroadcastEvalJs(cstring"")`, currently `discard` + a
  placeholder empty call): build the window→worker IIFE `b._onEvent('window:event', <payload>)`
  (the literal name `window:event` + the event payload — mirroring `callbacks.zc:128-134`),
  gated on the existing `gBackendListeners` bitmask, and broadcast via
  `dispatch.worker_broadcast_eval_js`. Import `dispatch`.
- **`app_events.nim` Layer-2** (`workerBroadcastAppEvent(cstring"")` stub): build the app-event
  `_onEvent('<name>','<data>')` IIFE (same builder it already uses for the webview Layer-3) and
  broadcast to workers via `dispatch.worker_broadcast_eval_js`, skipping STARTED/SHUTDOWN like
  the webview layer. Import `dispatch`. (Confirm against `app_events.zc` whether the webview
  Layer-3 data is escaped or passthrough; match it — apply `zapp_escape_dup` only where the zc does.)

### Half 2 — App config (`native/nim/app.nim` + a new `Inspectable` enum)

- Give the Nim `App` (app.nim) a real `AppConfig` value object — `{name, terminateAfterLastWindowClosed,
  inspectable: Inspectable, maxWorkers}` (mirroring `app.zc:302` AppConfig; `qjsStackSize`
  omitted — no consumer in the Nim build) — set in `newApp`, stored in an app.nim module-global
  `gActiveApp` so the C-ABI getters can read it (the existing `app_get_active()` sentinel is NOT
  a real App and is left as-is for the bridge gate).
- **`Inspectable* {.pure.} = enum Auto, On, Off`** — the user-facing config enum (the
  convention's deferred item, mirroring `app.zc:296` `ZappInspectable`). Lives in `app.nim`
  (app-config domain). Distinct from the window-tag `TriState`: this resolves to a bool.
- Port the getters to `app.nim` (real, reading `gActiveApp.config`), **removing the four
  `zapp.nim` stubs** (`app_get_bootstrap_name`/`_web_content_inspectable`/`_application_should_
  terminate_after_last_window_closed`/`_max_workers`) and the `app_get_allowed_navigation_json`
  stub:
  - `app_get_bootstrap_name → config.name`
  - `app_get_bootstrap_web_content_inspectable → ` resolve `Inspectable`: `On→true`, `Off→false`,
    `Auto→ zapp_build_dev_tools_default() > 0` (exactly `app.zc:52-56`).
  - `app_get_bootstrap_application_should_terminate_after_last_window_closed → config.terminate…`
  - `app_get_bootstrap_max_workers → config.maxWorkers`
  - `app_get_allowed_navigation_json → ""` (security.zc not ported; stays `""` with a note —
    same value the stub returns, but now co-located in app.nim).
- The boot (`zapp.nim`) `newApp("Zapp Nim Skeleton")` passes the config (name + sane defaults:
  `Inspectable.Auto`, terminate true, maxWorkers 0). The `opts.inspectable` window-tag boot
  assignment (Batch enums cycle) is unchanged.

## Deferred (dependency-correct)

- **Targeted `worker_eval_js`** (one worker by id) — needs `zapp_worker_registry_get_engine` /
  `zapp_dispatch_worker_eval_js` from `registry.zc` → **Batch 7** (worker subsystem). Not ported.
- **The cancellation guard** in `dispatch_invoke_response`/`sendInvokeResponse` — needs
  `zapp_is_cancelled` from `protocol.zc` → **Batch 5** (router/protocol). The `bridge.nim` TODO
  stays. (Note: `dispatch_invoke_response` itself is already covered by `bridge.nim`'s
  `sendInvokeResponse`; no separate C-ABI export needed — confirm no `.m` calls
  `dispatch_invoke_response` directly.)
- **Other `zapp.nim` worker stubs** (`worker_post_message`, `worker_dispatch_to_webview`,
  supervisor, registry) — **Batch 7**.

## Success criteria (the gate)

- **Worker fan-out works:** a window event (e.g. resize/focus on a subscribed window) and/or an
  app event (theme change / activate) causes `zjs_broadcast_eval_js` to fire with the `_onEvent`
  IIFE → the headless zjs worker's bridge `_onEvent` runs. Verify by lldb on
  `zjs_broadcast_eval_js` (breakpoint hit + the IIFE string), or a worker-side `_onEvent`
  listener that logs (`[zapp/<worker>] …`). (The hello-world worker subscribing is user-WIP;
  lldb is the fallback proof.)
- **App config real:** the injected `bootstrapConfig` reflects real `AppConfig` (name, the
  dev-gated `inspectable`), and the four getters read `gActiveApp.config` (not the stubs).
- **Escaping fixed:** an event payload containing `'` / newline reaches the webview/worker
  intact (no broken JS).
- Build ends `[zapp] build complete:`; all Nim unit tests pass; `.m`/zjs.c untouched; no `{.emit.}`.

## Architecture notes / convention

- `dispatch.nim` is the new module mirroring `bridge/dispatch.zc`; `zapp_escape_dup` is the one
  worker-safe libc primitive (POD, like permissions/worker_service); the IIFE builders run on
  the main thread (Cocoa delegate / dispatch) so Nim-string building is fine there.
- `Inspectable {.pure.}` enum per the convention (app-config domain → app.nim); resolves to a
  bool at the getter. No magic numbers introduced.
- Worker-reachable code stays `{.gcsafe.}`; `worker_broadcast_eval_js`/`zapp_escape_dup` are
  POD/libc (callable from zjs.c off the main thread).

## Risks (into the plan)

- **`zapp_escape_dup` replacement** must keep zjs.c's contract (malloc'd, caller frees, escapes)
  — confirm zjs.c's call sites + that the perf-gate strdup stub's removal doesn't regress (it
  only strdup'd; the real one escapes + mallocs, a superset).
- **`window:event` worker IIFE** — confirm the exact name + payload shape `callbacks.zc:128-134`
  broadcasts (the literal `'window:event'` + which fields), and that the worker bridge's
  `_onEvent` handles it.
- **app_events escaping parity** — match the zc (escape vs passthrough) per layer; don't diverge.
- **`dispatch.nim` import graph** — leaf module, no back-imports from callbacks/app_events
  (avoid a cycle). `zapp.nim` drops `dispatch_event_to_all` + `zapp_escape_dup` stubs (now in
  dispatch.nim) — verify single definition each.
- **app config module-global** — `gActiveApp` set in `newApp` before any window/worker; the
  getters run after boot (webview creation), so it's populated. Confirm ordering.

## References

- `native/bridge/dispatch.zc` (full: `zapp_escape_dup:30`, `dispatch_invoke_response:55`,
  `worker_broadcast_eval_js:103`, `worker_eval_js:127`, `dispatch_event_to_all:138`).
- `native/window/callbacks.zc:128-134` (window→worker Layer-3 IIFE), `native/app/app_events.zc`
  (app→worker + escaping).
- `native/app/app.zc:43-79` (getters), `:296-308` (ZappInspectable + AppConfig).
- `native/nim/zapp.nim:220` (dispatch_event_to_all stub), `:257` (strdup zapp_escape_dup stub),
  `:132-138` (app_get_bootstrap_* stubs); `native/nim/callbacks.nim:84,112` (Layer-3 stub);
  `native/nim/app_events.nim` (Layer-2 stub); `native/nim/app.nim` (App + newApp).
- `native/worker/engines/zjs.c` (`zjs_broadcast_eval_js`, `zapp_escape_dup` consumer).
