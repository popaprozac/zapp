# CEF sub-cycle A — Worker-on-CEF + hardening sweep (macOS) — design

**Date:** 2026-07-06
**Branch:** `feat/cef-worker-hardening` (off `feat/nim-native @ 1b28bff`; NO merge to nim-native without ask — Windows handoff)
**Type:** Feature (broadcast-delivery gap fix) + fixture/gate + hardening sweep. Opt-in + gated. macOS-only.
**Status:** SDD complete. Spec review (pre-implementation) found this design's §1 premise **stale**: the broadcast→CEF branch it proposed adding was already shipped, same-day, in `6f58489` (`window.m:154-164`) — see the corrected Context + §1 below. No code change was made there; §2's fixture doubles as the proof. Plan written and executed: §2 (worker→CEF fixture) landed in `b4d30cc`; §3 (5 Minors) landed in `20b0faf`/`eb477bc`/`f7278cb`. §2's human visual gate (R0) has not yet been run — see `examples/cef-hello/SMOKE.md` GATE 5 (PENDING).

## Goal

Make a real headless **ZJS worker's events reach a CEF-rendered page** (the render-engine-independent worker edge — CEF's whole point), by closing the one delivery gap the render+bridge slice left open, prove it with a fixture + human gate, and clear the 5 self-contained CEF Minors. `system`/WKWebView builds stay byte-identical.

## Context — the gap this design THOUGHT was open (corrected in spec review)

The CEF production slice ([[project_cef_webengine_prod_slice]], merged `1b28bff`) wired the CEF page into Zapp's **targeted** native→JS delivery: `darwin_window_eval_js(numericId, js)` gained a `#ifdef ZAPP_HAS_CEF` branch (`window.m:650` → `zapp_cef_eval_in_window(slot, js)`). Service replies + sync reach a CEF page. This design's original premise was that the **broadcast** path did NOT:

- `darwin_webview_eval_all(js)` (`webview.m:1247`) delegates to `zapp_registered_webviews_eval(js)`, which walks the WKWebView dispatch table (`window.m`) and calls `evaluateJavaScript`. A CEF window hosts a CEF browser, **not** a WKWebView in that table — so (the premise went) the broadcast never reaches it.
- The broadcast path is what `dispatch_event_to_all` (`dispatch.nim:65`), app-events (`app_events.nim:107`), and **worker-emitted `Events`** ride. So (the premise went) a worker emitting a ticking event → the CEF page never updates.

**This premise is STALE.** The branch this design proposed adding in §1 (below) was **already implemented and committed, same day, earlier, in `6f58489`** ("wire the zapp bridge to the real Nim router (R1)") — not in `webview.m`, but one layer down, inside `zapp_registered_webviews_eval` itself (`native/platform/darwin/window.m:154-164`):

```c
// window.m:154-164 — already shipped in 6f58489, not new
#ifdef ZAPP_HAS_CEF
    extern int zapp_cef_eval_in_window(int32_t slot, const char* js);
    extern int32_t zapp_cef_get_window_slot(void);
    int32_t cefSlot = zapp_cef_get_window_slot();
    if (cefSlot >= 0) zapp_cef_eval_in_window(cefSlot, [script UTF8String]);
#endif
```

`darwin_webview_eval_all` (`webview.m:1247`) is a one-line delegator to `zapp_registered_webviews_eval(js)` — it has no logic of its own to branch on. So every broadcast — `dispatch_event_to_all` (`dispatch.nim:65`), app-events (`app_events.nim:107`), and **worker-emitted `Events`** — already fans out through the existing CEF branch, one function below where this design was looking. There was never a second place that needed one.

**Consequence: the branch proposed in §1 below must NOT be added.** Adding a second `#ifdef ZAPP_HAS_CEF` block in `darwin_webview_eval_all` would call `zapp_cef_eval_in_window` a **second time** per broadcast — every worker tick, every `Events.emit`, every app-event would double-deliver to the CEF page (duplicate DOM updates / double-fired page handlers — a real regression, not a no-op).

§2's fixture (a real headless ZJS worker ticking to a CEF page, `examples/cef-hello`) is what surfaces this: implementing it required actually exercising the broadcast path end-to-end, with **zero changes to `webview.m` or `window.m`** — the tick already lands. Spec review confirmed the root cause by reading `window.m:154-164` directly and tracing the delegation chain from `webview.m:1247`.

`resolveWebEngine`/`useCef` gating from the prior cycles is unchanged either way; this cycle is a fixture + gate + hardening cleanup, not a broadcast-delivery fix.

## Design

### 1. VERIFIED ALREADY-PRESENT — no new code needed (originally scoped as "add the branch"; corrected in spec review)

**Original plan — do NOT implement this** (kept here only so the historical record, and any discussion that referenced this section before the correction, still makes sense):

> ~~Add a `#ifdef ZAPP_HAS_CEF` block in `darwin_webview_eval_all` that, in addition to `zapp_registered_webviews_eval(js)` (the WKWebView broadcast), also delivers to the CEF page:~~
>
> ```c
> void darwin_webview_eval_all(const char* js) {
>     extern void zapp_registered_webviews_eval(const char* js);
>     zapp_registered_webviews_eval(js);   // WKWebviews (empty in a pure-CEF app)
> #ifdef ZAPP_HAS_CEF
>     extern int32_t zapp_cef_get_window_slot(void);
>     extern int zapp_cef_eval_in_window(int32_t slot, const char* js);
>     int32_t slot = zapp_cef_get_window_slot();
>     if (js && slot >= 0) zapp_cef_eval_in_window(slot, js);
> #endif
> }
> ```

**Adding this would double-deliver every broadcast** — see Context above: `zapp_registered_webviews_eval` already contains the equivalent branch (`window.m:154-164`, shipped in `6f58489`), and `darwin_webview_eval_all` calls exactly that function. Stacking a second CEF eval on top means every worker tick / `Events.emit` / app-event reaches the CEF page twice.

**What's actually true, confirmed by reading the shipped source at `native/platform/darwin/window.m:154-164`:**

```c
#ifdef ZAPP_HAS_CEF
    extern int zapp_cef_eval_in_window(int32_t slot, const char* js);
    extern int32_t zapp_cef_get_window_slot(void);
    int32_t cefSlot = zapp_cef_get_window_slot();
    if (cefSlot >= 0) zapp_cef_eval_in_window(cefSlot, [script UTF8String]);
#endif
```

- `darwin_webview_eval_all` (`webview.m:1247`) is a one-line delegator to `zapp_registered_webviews_eval(js)` — it has no branch of its own, so there is nowhere in `webview.m` to "add" a second one without duplicating delivery.
- In a pure-CEF app, the WKWebView loop above this `#ifdef` (inside `zapp_registered_webviews_eval`) is a no-op (no `zapp_webviews[]` entries) and the CEF eval fires — already mirroring the targeted branch at `window.m:650`, just one function over from where this design was looking.
- `zapp_cef_eval_in_window` is main-thread-safe (the surrounding block dispatches to main if called off-thread) and NULL-guards the browser — a broadcast from a worker thread is already safe.
- **Gated:** without `ZAPP_HAS_CEF` (a `system` build), `window.m` compiles byte-identical to today — unaffected by this correction.
- **Single-window scope, unchanged:** delivers to the one active CEF browser (`zapp_cef_get_window_slot`, the global slot). Multi-browser broadcast is still **sub-cycle B**'s job (the browser↔slot registry).

**Action this cycle takes in `webview.m` / `window.m`: none.** §2's fixture (`examples/cef-hello`, a real headless ZJS worker ticking to the CEF page) is the deliverable that proves the above with zero production-code changes.

### 2. Fixture + the gate — a real ZJS worker ticking to the CEF page

Extend `examples/cef-hello`:
- Add a headless **ZJS** worker (the default macOS engine; the spike's T5 proved libzjs coexists with CEF) that emits a tick event on an interval (e.g. `Events.emit("tick", n)` every second), configured via the app's `workers`.
- The `cef-hello` page subscribes (`Events.on("tick", …)`) and renders the count.
- **Human visual gate (R0):** the tick counter increments on the CEF-rendered page. Plus a regression check that the existing render + `Services.invoke("greet")` button still work, and a `webEngine:"system"` build of the fixture is byte-identical to pre-change.

This proves the edge end-to-end: a native, render-engine-independent worker driving a Chromium view via `zapp build`.

### 3. Hardening sweep — the 5 self-contained Minors (`native/platform/darwin/cef/`)

1. **Remove dead `zapp_cef_run_main_loop`** (`zapp_cef_mac_entry.m` + its `.h` decl + any comment refs) — defined but never called since the prod slice integrated the pump into Zapp's real loop.
2. **`app_get_active()` NULL-guard parity** in the CEF client — mirror `webview.m:403`'s `if (app_ptr != NULL)` guard before `zapp_handle_message_from_window`.
3. **`host.m` OOM NULL-hardening** — guard `cef_dictionary_value_create()` and the `strdup`'d `bootstrap_js` against NULL before deref.
4. **Shared msg-name header** — `ZAPP_MSG_INVOKE` (currently `#define`'d in both `zapp_cef_bridge.c` render + `zapp_cef_client.c` browser) hoisted into a shared header (e.g. a small `zapp_cef_messages.h`, or into `zapp_cef.h`), so the cross-process protocol constant has one definition.
5. **Decode-fail diagnostic log** in `zapp_cef_scheme_handler.c` — the brotli-decode path currently serves a silent empty-200 on `compression_decode_buffer` failure; add a warning log (parity with a diagnostic, not a behavior change).

### 4. Gates + non-goals

**Gates:** worker→CEF-page visual (human, R0 — **pending**, see `examples/cef-hello/SMOKE.md` GATE 5); render + `Services.invoke` regression on CEF; `system` byte-identical (the existing `window.m` CEF branch stays `#ifdef`-gated; nothing new was added to gate); `bunx tsc --noEmit` + `bun test cli/src`; a chromium build of the fixture still builds green.

**Non-goals (deferred to their cycles):**
- Multi-browser broadcast — single-window today; the branch delivers to the one active browser (**sub-cycle B**, the browser↔slot registry).
- The other 5 coupled Minors: `on_before_close`→`[NSApp stop]` quit-guard (**B**); per-request brotli decode cache (a perf pass); `setDragRegion` CEF elision (fullbleed non-goal); `.zc`-legacy chromium→silent WKWebView (config); `g_active_browser` cross-thread read (benign, matches existing pattern).
- Worker on native-chrome-CEF panes (**sub-cycle C**).

## Components / files

- `native/platform/darwin/window.m` — NOT modified; §1 verified the existing CEF broadcast branch (`zapp_registered_webviews_eval`, lines 154-164, shipped in `6f58489`) already covers this edge. `native/platform/darwin/webview.m` is likewise untouched.
- `examples/cef-hello/` — the ZJS worker + the page's tick subscription (§2).
- `native/platform/darwin/cef/{zapp_cef_mac_entry.m, zapp_cef.h, zapp_cef_client.c, zapp_cef_host.m, zapp_cef_bridge.c, zapp_cef_scheme_handler.c}` (+ a new `zapp_cef_messages.h`) — the 5 Minors (§3).
- `spikes/cef-macos/FINDINGS.md` — mark worker-on-CEF closed + which Minors cleared.

## Testing

- **Human visual (R0):** ZJS worker tick counter increments on the CEF page; greet button still round-trips.
- **Byte-identical:** a `webEngine:"system"` build's generated native + the `darwin_webview_eval_all` preprocessed output (without `ZAPP_HAS_CEF`) match pre-change.
- **Build regression:** chromium build of the fixture builds green + renders (no `FrameWidgetHost` errors).
- **CLI:** `bunx tsc --noEmit` + `bun test cli/src` unchanged (no CLI logic changes; the fixture's config is data).

## Error handling

- `zapp_cef_eval_in_window` NULL-guards the browser (no active browser → safe no-op) — a broadcast before/after the CEF window exists is safe.
- Minor #3 hardens OOM paths (NULL → skip, don't deref).
- Minor #5 logs decode failures instead of silently serving empty.

## Scope

§1's proposed native-file gap fix (`webview.m`, gated) turned out to be already shipped — no code change there — leaving: a fixture (`examples/cef-hello`) + a 5-Minor sweep across `native/platform/darwin/cef/` + a FINDINGS/SMOKE update. Single implementation plan; 3 tasks (fixture+gate; hardening sweep; docs/FINDINGS/SMOKE).
