# CEF host-event fan-out — foundational fix (macOS) — design

**Date:** 2026-07-08
**Branch:** `feat/cef-host-events` (off `feat/nim-native @ 98e2730`; NO merge to `nim-native` without ask — Windows handoff target)
**Type:** Fix — deliver host-level window events to CEF windows + their panes. Opt-in path is CEF; the change is gated. macOS-only.
**Status:** design approved (approach B — byte-identical gated branch); pending spec review → writing-plans → SDD

## Goal

Host-level window events — `resize`, `move`, `focus`, `blur`, `maximize`, `restore`, `modal-dismissed` — reach a `webEngine:"chromium"` (CEF) window's host pane **and** its sidebar/inspector panes, exactly as they already do on WKWebView. This is the last CEF window-event gap: accessory collapse/resize (sidebar.m/inspector.m) and toolbar clicks already reach CEF; only the host window-event fan-out is WK-only. `webEngine:"system"` (WKWebView) windows stay **byte-identical**.

## Context — the gap

`zapp_dispatch_event_to_js` (`window.m:239`) is the unified host-window-event dispatcher. Every NSWindow-delegate window event routes through it (e.g. `window.m:748` FOCUS; resize/move/maximize/restore/modal-dismissed emit sites). It:
1. resolves `webview = zapp_webviews[window_id]` and `windowId = zapp_window_ids[window_id]`;
2. **early-returns if `!webview || !windowId`** (`window.m:243`);
3. builds the event JS into the static `zapp_js_buf` (an event-name lookup + a modal / resize-move-maximize-restore / plain payload switch, `window.m:245-273`);
4. evals it on the host `webview`, then fans out to the sidebar + inspector panes via `zapp_webviews[slot]`.

For a CEF window, `zapp_webviews[window_id]` is nil (CEF browsers live in `zapp_cef_browsers[]`, not `zapp_webviews[]`) but `zapp_window_ids[window_id]` IS set (C1-C3). So step 2 early-returns and **every host window event is dropped** for CEF windows. The CEF-aware per-slot eval `darwin_window_eval_js(slot, js)` (`window.m`, has the `ZAPP_HAS_CEF` branch → `zapp_cef_eval_in_window`) already exists and reaches a CEF browser at any slot — it's the delivery path C1-C3 use.

## Design — approach B (byte-identical, gated CEF branch)

Insert a `#ifdef ZAPP_HAS_CEF` block **after** the `webview`/`windowId` resolution and **before** the WK early-return (`window.m:243`). For a CEF window (`!webview && windowId`), build the SAME event JS and fan it out via `darwin_window_eval_js` to the host + sidebar + inspector slots, then `return`:

```objc
    WKWebView* webview = zapp_webviews[window_id];
    NSString* windowId = zapp_window_ids[window_id];
#ifdef ZAPP_HAS_CEF
    // A CEF-hosted window has no WKWebView (webview == nil) but DOES have a
    // windowId. The WK early-return below would drop every host window event
    // for it. Build the SAME event JS and fan out to host + sidebar + inspector
    // via the CEF-aware darwin_window_eval_js. The JS-build here MIRRORS the WK
    // build below — KEEP THE TWO IN SYNC. (Approach B: the WK path stays
    // byte-identical by isolating the CEF path in this #ifdef block rather than
    // refactoring the shared dispatcher through darwin_window_eval_js.)
    if (!webview && windowId) {
        const char* event_name = zapp_get_event_name(event_id);
        const char* wid = [windowId UTF8String];
        // <<< MIRROR of the WK build at window.m:255-273 — keep in sync >>>
        if (event_id == ZAPP_EVENT_WINDOW_MODAL_DISMISSED) {
            snprintf(zapp_js_buf, sizeof(zapp_js_buf), <modalId/code format>, wid, event_name, w, h);
        } else {
            bool hasPayload = (RESIZE || MOVE || MAXIMIZE || RESTORE);
            if (hasPayload) snprintf(zapp_js_buf, sizeof(zapp_js_buf), <width/height/x/y format>, wid, event_name, w, h, x, y);
            else            snprintf(zapp_js_buf, sizeof(zapp_js_buf), <no-payload format>, wid, event_name);
        }
        // >>> end mirror <<<
        darwin_window_eval_js(window_id, zapp_js_buf);   // host pane
        int32_t sb = zapp_sidebar_slot_for(window_id);
        if (sb >= 0 && sb != window_id && sb < ZAPP_MAX_WINDOW_CALLBACKS)
            darwin_window_eval_js(sb, zapp_js_buf);       // sidebar pane
        int32_t in = zapp_inspector_slot_for(window_id);
        if (in >= 0 && in != window_id && in < ZAPP_MAX_WINDOW_CALLBACKS)
            darwin_window_eval_js(in, zapp_js_buf);        // inspector pane
        return;
    }
#endif
    if (!webview || !windowId) return;   // <-- WK path, byte-identical from here down
    ...unchanged WK build + fan-out...
```

**Why B (decided with the human):** this touches the *shared* dispatcher, not gated CEF-only code. Approach A (refactor the whole function to route through `darwin_window_eval_js`) is DRY but changes the WK path's bytes — trading the project's mechanical `unifdef -UZAPP_HAS_CEF → original-bytes` guarantee for a regression gate. B keeps that guarantee (the WK code from the early-return down is untouched; the `#ifdef` block strips to nothing on a `system` build). The cost is one bounded, ~15-line JS-build mirror, adjacent to its twin with a "keep in sync" comment — an acceptable, contained price (DRY is the softer principle here).

**Buffer safety:** `zapp_js_buf` is the existing static buffer; window events fire serialized on the main thread; `darwin_window_eval_js` copies the string synchronously (WK: `stringWithUTF8String`; CEF: `execute_java_script` copies) before returning — same safety as the current WK code.

## Fixture

`examples/cef-hello/` — the host pane (and, to prove fan-out, the sidebar/inspector panes) subscribe to a couple of host window events via the runtime window-event API (`Window.current().on(WindowEvent.RESIZE …)` / `FOCUS` / `BLUR` — the real names confirmed at plan time) and render the latest into the page. Window 1 (3-pane) is the fan-out gate; window 2 (plain) proves the host-only path.

## Testing (human R0 gates)

- **Resize:** resize window 1 → the host pane shows the new `{width,height}`, and the sidebar + inspector panes show it too (fan-out). Window 2 (plain) shows it in its host pane.
- **Focus/blur:** click away from window 1 then back → panes show blur then focus.
- **(Optional) move/maximize:** drag / green-button → panes update.
- **Byte-identical:** a `webEngine:"system"` build is unaffected — the WK dispatch path is unchanged (verify the `#else`/post-`#ifdef` code is identical to the pre-change function; a `system` build of a WK sidebar app still receives window events in every pane).

## Error handling

- CEF branch guarded by `!webview && windowId`; bounds-checked pane slots (`>= 0 && != window_id && < MAX`), mirroring the WK fan-out guards.
- `darwin_window_eval_js` no-ops on an absent/torn-down slot (its own bounds + nil checks).
- Non-CEF (`webEngine:"system"`) build: the `#ifdef` block compiles out entirely.

## Non-goals

- No change to WHICH events exist or their payloads — this only extends the existing dispatch to CEF.
- No refactor of the shared dispatcher (approach A) — explicitly rejected to preserve byte-identical.
- Reload-persistence, devtools, vibrancy — unrelated, unchanged.

## Scope

`window.m` (the gated CEF branch in `zapp_dispatch_event_to_js`) + the `cef-hello` window-event fixture + FINDINGS/SMOKE. Likely **~2 tasks**: (1) the CEF branch + fixture + the resize/focus fan-out gate; (2) docs. Small, well-diagnosed; the only subtlety is the byte-identical discipline (keep the WK path untouched) and the JS-build mirror.
