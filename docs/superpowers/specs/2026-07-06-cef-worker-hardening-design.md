# CEF sub-cycle A — Worker-on-CEF + hardening sweep (macOS) — design

**Date:** 2026-07-06
**Branch:** `feat/cef-worker-hardening` (off `feat/nim-native @ 1b28bff`; NO merge to nim-native without ask — Windows handoff)
**Type:** Feature (broadcast-delivery gap fix) + fixture/gate + hardening sweep. Opt-in + gated. macOS-only.
**Status:** design approved; pending spec review → writing-plans → SDD

## Goal

Make a real headless **ZJS worker's events reach a CEF-rendered page** (the render-engine-independent worker edge — CEF's whole point), by closing the one delivery gap the render+bridge slice left open, prove it with a fixture + human gate, and clear the 5 self-contained CEF Minors. `system`/WKWebView builds stay byte-identical.

## Context — the gap this closes

The CEF production slice ([[project_cef_webengine_prod_slice]], merged `1b28bff`) wired the CEF page into Zapp's **targeted** native→JS delivery: `darwin_window_eval_js(numericId, js)` gained a `#ifdef ZAPP_HAS_CEF` branch (`window.m:650` → `zapp_cef_eval_in_window(slot, js)`). Service replies + sync reach a CEF page. But the **broadcast** path did NOT:

- `darwin_webview_eval_all(js)` (`webview.m:1247`) delegates to `zapp_registered_webviews_eval(js)`, which walks the WKWebView dispatch table (`window.m`) and calls `evaluateJavaScript`. A CEF window hosts a CEF browser, **not** a WKWebView in that table — so the broadcast never reaches it.
- The broadcast path is what `dispatch_event_to_all` (`dispatch.nim:65`), app-events (`app_events.nim:107`), and **worker-emitted `Events`** ride. So a worker emitting a ticking event → the CEF page never updates.

`resolveWebEngine`/`useCef` gating from the prior cycles is unchanged; this is purely the missing broadcast branch + a fixture + cleanup.

## Design

### 1. The gap fix — CEF branch in `darwin_webview_eval_all` (`native/platform/darwin/webview.m`)

Add a `#ifdef ZAPP_HAS_CEF` block in `darwin_webview_eval_all` that, in addition to `zapp_registered_webviews_eval(js)` (the WKWebView broadcast), also delivers to the CEF page:

```c
void darwin_webview_eval_all(const char* js) {
    extern void zapp_registered_webviews_eval(const char* js);
    zapp_registered_webviews_eval(js);   // WKWebviews (empty in a pure-CEF app)
#ifdef ZAPP_HAS_CEF
    extern int32_t zapp_cef_get_window_slot(void);
    extern int zapp_cef_eval_in_window(int32_t slot, const char* js);
    int32_t slot = zapp_cef_get_window_slot();
    if (js && slot >= 0) zapp_cef_eval_in_window(slot, js);
#endif
}
```

- In a pure-CEF app, `zapp_registered_webviews_eval` is a no-op (no WKWebViews registered) and the CEF eval fires — mirroring the targeted branch at `window.m:650`.
- `zapp_cef_eval_in_window` (already in the CEF host) is main-thread-safe (inline on main, else hops) and NULL-guards the browser — so a broadcast from a worker thread is safe, same as the targeted path.
- **Gated:** without `ZAPP_HAS_CEF` (a `system` build) the function is byte-identical to today.
- **Single-window scope:** delivers to the one active CEF browser (`get_window_slot`, the global slot). Multi-browser broadcast is **sub-cycle B**'s job (the browser↔slot registry).

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

**Gates:** worker→CEF-page visual (human, R0); render + `Services.invoke` regression on CEF; `system` byte-identical (the `eval_all` branch is `#ifdef`-gated); `bunx tsc --noEmit` + `bun test cli/src`; a chromium build of the fixture still builds green.

**Non-goals (deferred to their cycles):**
- Multi-browser broadcast — single-window today; the branch delivers to the one active browser (**sub-cycle B**, the browser↔slot registry).
- The other 5 coupled Minors: `on_before_close`→`[NSApp stop]` quit-guard (**B**); per-request brotli decode cache (a perf pass); `setDragRegion` CEF elision (fullbleed non-goal); `.zc`-legacy chromium→silent WKWebView (config); `g_active_browser` cross-thread read (benign, matches existing pattern).
- Worker on native-chrome-CEF panes (**sub-cycle C**).

## Components / files

- `native/platform/darwin/webview.m` — the `darwin_webview_eval_all` CEF broadcast branch (§1).
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

One native-file gap fix (`webview.m`, gated) + a fixture (`examples/cef-hello`) + a 5-Minor sweep across `native/platform/darwin/cef/` + a FINDINGS update. Single implementation plan; likely ~3 tasks (wire+fixture+gate; hardening sweep; docs/FINDINGS).
