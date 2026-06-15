# Nim Migration — Phase 2 Breadth, Batch 1: Event Dispatch Foundation — Design

**Status:** Design (approved 2026-06-15). **Branch:** `feat/nim-native`.
**Part of:** the Nim migration breadth phase (`docs/superpowers/specs/2026-06-15-nim-migration-design.md`).
The skeleton + worker perf gate are done/passed; breadth ports the remaining ~32
`.zc` modules in a foundation-first DAG. **This is Batch 1** — the event dispatch
backbone everything downstream needs.

## Goal

Make window + app events actually reach the webview under the Nim build. Port
`native/window/events.zc`, `native/window/callbacks.zc`, and
`native/app/app_events.zc` to idiomatic Nim, replacing the `zapp_dispatch_event`
and `zapp_app_dispatch` no-op stubs (`native/nim/zapp.nim`) with real delivery to
**native callbacks + the webview JS**. Fold in the minimal `subscribe`/
`unsubscribe` router wiring needed to make it testable.

## Success criteria (the gate)

In hello-world on the Nim build (`ZAPP_NATIVE_LANG=nim`):
- Resize / focus / blur / move / close the window → the webview's JS event
  listeners fire (today the stub silently drops them).
- A theme change / app activate-deactivate → the webview receives the app event.
- Verified by the demo reacting, or by lldb confirming the `_onEvent` IIFE is
  `eval_js`'d to the webview for the right event. Build ends `[zapp] build
  complete:`; `.m` layer untouched; no `{.emit.}`.

## Scope

**In:** `events.zc`, `callbacks.zc`, `app_events.zc` → Nim; remove their `zapp.nim`
stubs; a minimal `subscribe`/`unsubscribe` window-action block in the Nim router.
**Out (deferred, dependency-correct):**
- **Worker event delivery (Layer 3 fan-out)** — depends on the worker-broadcast
  helpers in `bridge/dispatch.zc` + `worker/registry.zc` (Batches 4/7). The
  fan-out call stays a no-op stub until then; Batch 1 delivers to native + webview
  JS only.
- The **full window-action router surface** (t:4 handlers for tray/dock/menu/
  panel/etc.) — Batch 5. Only `subscribe`/`unsubscribe` is added here.

## Architecture — what's being ported

### `events.nim` (from `window/events.zc`, 96 LOC)
The event-code set as a Nim `enum` (replacing the C macros + Zen-C structs):
window events `WINDOW_READY=0 … WINDOW_MODAL_DISMISSED=11`; app events
`APP_STARTED=100 … APP_THEME_CHANGED=108`. Values MUST match the existing
constants exactly (the `.m` layer passes these integer codes). Used by
`callbacks.nim` + `app_events.nim`.

### `callbacks.nim` (from `window/callbacks.zc`, 155 LOC) — `zapp_dispatch_event`
The per-window native-callback registry + the **JS-subscription bitmask** per
window, and the dispatcher the `.m` window delegate calls:
```
proc zapp_dispatch_event(windowId, eventId, w, h, x, y: cint): cint {.exportc, cdecl.}
```
Three layers (mirroring `callbacks.zc:94-154`), returning 0=ALLOW / 1=CANCEL:
1. **Native callback** — if a native handler is registered for `windowId`, fire
   it; if it returns CANCEL (1), stop and return CANCEL.
2. **Close-guard (1.5)** — if `eventId == WINDOW_CLOSE` and the window has a JS
   close-guard set, dispatch the close to JS and return CANCEL (the JS side
   decides).
3. **JS bridge** — if the window's JS subscription bitmask includes `eventId`,
   `eval_js` the `_onEvent` IIFE (wire-identical to the zc version) to that
   window's webview via `darwin_window_eval_js` (`importc`).
4. **Worker fan-out** — call the worker-broadcast helper (STUBBED until Batch
   4/7; no-op for now).

### `app_events.nim` (from `app/app_events.zc`, 124 LOC) — `zapp_app_dispatch`
The app-event dispatcher the `.m` app/notification layer calls:
```
proc zapp_app_dispatch(eventId: cint, data: cstring): cint {.exportc, cdecl.}
```
Layers (mirroring `app_events.zc:42-123`), returning the count of native handlers
fired: (1) fire all registered native app callbacks; (2) broadcast to workers
(STUBBED until Batch 4/7); (3) forward to all webviews via the `_onEvent` IIFE
(`eval_js` to each window — using the registered-webviews broadcast that already
exists, or per-window `eval_js`).

### Router wiring (minimal — in `native/nim/router.nim`)
Add a `subscribe` / `unsubscribe` window-action block: when the webview sends the
subscribe action, set the window's JS subscription bitmask in `callbacks.nim`
(the registration fn) so Layer 3-JS delivery is gated correctly. Confirm the exact
action shape (t:4 vs an `__zapp:` invoke) + the event-name→bitmask mapping against
`router.zc` + `bootstrap/webview.ts` during planning. Nothing else of the router
surface is touched.

### `zapp.nim` stub removal
Remove the `zapp_dispatch_event` and `zapp_app_dispatch` `{.exportc.}` stubs (now
provided real by `callbacks.nim` / `app_events.nim` — avoid duplicate symbols).
Keep the worker-broadcast / `dispatch_event_to_all` stubs (still deferred).

## Idiomatic Nim + boundary rules (carried over)
- Event codes → `enum`; callback registries → Nim `array`/`seq`; the per-window
  bitmask → a Nim structure (not C static arrays transliterated).
- `eval_js` via `importc` (`darwin_window_eval_js`). The `_onEvent` IIFE wire shape
  stays **identical** to `dispatch.zc`/the zc version — no new concession.
- No `{.emit.}`. The `.m` layer is untouched (these are `.m`→Nim `exportc`
  callbacks). cstring lifetime: any returned cstring is module-`let`-backed.
- These dispatchers run on the **main thread** (the Cocoa delegate thread), not a
  worker pthread — so normal ORC applies (allocation is fine here, unlike the
  worker hot path).

## Risks (carried into the plan)
- **Exact event-code values + the `_onEvent` wire shape** must match the runtime
  (`bootstrap/webview.ts`'s `_onEvent`) and the `.m` callers — confirm by reading,
  don't guess.
- **The subscribe mechanism** — exact action type, the event-name strings, and how
  the bitmask is keyed; confirm the close-guard registration path too.
- **Per-window vs broadcast delivery** for app events — `app_events.zc` forwards to
  ALL webviews; confirm the iteration mechanism Nim should call.
- **Stub reconciliation** — removing the two `zapp.nim` stubs must not break the
  link (the real defs replace them); keep the worker-delivery stubs.

## References
- `native/window/events.zc`, `native/window/callbacks.zc:94-154`
  (`zapp_dispatch_event`), `native/app/app_events.zc:42-123` (`zapp_app_dispatch`).
- `native/nim/zapp.nim` (the two stubs to remove; the worker stubs to keep).
- `native/nim/router.nim` (where the subscribe block lands), `native/app/router.zc`
  (the zc subscribe/window-action reference).
- `bootstrap/webview.ts` (the `_onEvent` JS contract).
