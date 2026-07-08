# CEF Host-Event Fan-Out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver host-level window events (resize/move/focus/blur/maximize/restore/modal-dismissed) to CEF windows and their sidebar/inspector panes, exactly as WKWebView already gets them.

**Architecture:** Add a byte-identical, gated `#ifdef ZAPP_HAS_CEF` branch in the shared dispatcher `zapp_dispatch_event_to_js` (`window.m:239`), between the webview/windowId resolution and the WK early-return. For a CEF window (`!webview && windowId`) it mirrors the WK JS-build and fans out to host + sidebar + inspector slots via the CEF-aware `darwin_window_eval_js`, then returns. The WK path from the early-return down is untouched.

**Tech Stack:** Objective-C (`native/platform/darwin/window.m`), the `cef-hello` fixture (TypeScript + HTML), the runtime window-event API (`@zappdev/runtime`).

## Global Constraints

- **Byte-identical `system` build:** the CEF branch is purely additive inside `#ifdef ZAPP_HAS_CEF`. The code from `if (!webview || !windowId) return;` (`window.m:243`) DOWNWARD is UNCHANGED — a `unifdef -UZAPP_HAS_CEF` of the function must equal the pre-change original. Do NOT refactor the shared dispatcher (approach A was explicitly rejected).
- **The CEF JS-build MIRRORS the WK build** (`window.m:255-273`) verbatim — same three `snprintf` format strings, same args. Add a "keep in sync" comment linking the two.
- **Delivery via `darwin_window_eval_js(int32_t slot, const char* js)`** — the CEF-aware per-slot eval (routes to the CEF browser at that slot; copies the string synchronously; main-thread-safe).
- **Verification is native build + human R0 gate** (GUI/native, no unit-test harness — same as C1-C3). Do NOT write unit tests that assert nothing.
- **Engine flip:** before a chromium build, `rm -rf ~/.cache/nim/app_r`.
- **Canonical typecheck:** root `bun run check`.
- **Branch:** `feat/cef-host-events` off `feat/nim-native`. NO merge to `nim-native` without asking.
- **Inclusive language:** allowlist/blocklist.

---

### Task 1: Gated CEF branch in zapp_dispatch_event_to_js + fixture

**Files:**
- Modify: `native/platform/darwin/window.m` (`zapp_dispatch_event_to_js`, insert after `window.m:242`)
- Modify: `examples/cef-hello/index.html` (a window-event readout element)
- Modify: `examples/cef-hello/src/main.ts` (subscribe to window events, render per-pane)

**Interfaces:**
- Consumes: `darwin_window_eval_js(int32_t window_id, const char* js)`; `zapp_get_event_name(int)`; `zapp_sidebar_slot_for(int32_t)` / `zapp_inspector_slot_for(int32_t)`; the static `zapp_js_buf`; the `ZAPP_EVENT_WINDOW_*` constants — all already in `window.m`. Runtime: `Window.current().on(WindowEvent.RESIZE|FOCUS|BLUR, handler)`; `WindowSizePayload.size.{width,height}`; `WindowPayload`.
- Produces: host window events reaching CEF host + accessory panes.

- [ ] **Step 1: Insert the gated CEF branch**

In `native/platform/darwin/window.m`, immediately AFTER the two resolution lines (`window.m:241-242`):
```objc
    WKWebView* webview = zapp_webviews[window_id];
    NSString* windowId = zapp_window_ids[window_id];
```
and BEFORE `if (!webview || !windowId) return;` (`window.m:243`), insert:

```objc
#ifdef ZAPP_HAS_CEF
    // A CEF-hosted window has no WKWebView in zapp_webviews[] (webview == nil)
    // but DOES have a windowId. Without this, the WK early-return below drops
    // every host window event (resize/move/focus/blur/maximize/restore/modal)
    // for CEF windows. Build the SAME event JS and fan out to host + sidebar +
    // inspector via the CEF-aware darwin_window_eval_js.
    //
    // Approach B (see 2026-07-08-cef-host-events-design.md): keep the WK path
    // byte-identical by isolating CEF here rather than refactoring the shared
    // dispatcher. The snprintf block below MIRRORS the WK build at
    // window.m:~255-273 — KEEP THE TWO IN SYNC if the payload shape changes.
    if (!webview && windowId) {
        const char* event_name = zapp_get_event_name(event_id);
        const char* wid = [windowId UTF8String];
        if (event_id == ZAPP_EVENT_WINDOW_MODAL_DISMISSED) {
            snprintf(zapp_js_buf, sizeof(zapp_js_buf),
                "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
                "if(b&&typeof b.dispatchWindowEvent==='function'){"
                "b.dispatchWindowEvent('%s','%s','{\"modalId\":\"win-%d\",\"code\":%d}');}})();",
                wid, event_name, w, h);
        } else {
            bool hasPayload = (event_id == ZAPP_EVENT_WINDOW_RESIZE || event_id == ZAPP_EVENT_WINDOW_MOVE ||
                               event_id == ZAPP_EVENT_WINDOW_MAXIMIZE || event_id == ZAPP_EVENT_WINDOW_RESTORE);
            if (hasPayload) {
                snprintf(zapp_js_buf, sizeof(zapp_js_buf),
                    "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
                    "if(b&&typeof b.dispatchWindowEvent==='function'){"
                    "b.dispatchWindowEvent('%s','%s','{\"width\":%d,\"height\":%d,\"x\":%d,\"y\":%d}');}})();",
                    wid, event_name, w, h, x, y);
            } else {
                snprintf(zapp_js_buf, sizeof(zapp_js_buf),
                    "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
                    "if(b&&typeof b.dispatchWindowEvent==='function'){"
                    "b.dispatchWindowEvent('%s','%s');}})();",
                    wid, event_name);
            }
        }
        darwin_window_eval_js(window_id, zapp_js_buf);   // host pane
        int32_t cef_sb = zapp_sidebar_slot_for(window_id);
        if (cef_sb >= 0 && cef_sb != window_id && cef_sb < ZAPP_MAX_WINDOW_CALLBACKS)
            darwin_window_eval_js(cef_sb, zapp_js_buf);   // sidebar pane
        int32_t cef_in = zapp_inspector_slot_for(window_id);
        if (cef_in >= 0 && cef_in != window_id && cef_in < ZAPP_MAX_WINDOW_CALLBACKS)
            darwin_window_eval_js(cef_in, zapp_js_buf);    // inspector pane
        return;
    }
#endif
```

Confirm before editing: the two snprintf format strings + args are IDENTICAL to `window.m:255-273` (compare character-by-character), and the line `if (!webview || !windowId) return;` and everything below it is UNCHANGED. `darwin_window_eval_js` is declared/defined in this file (used elsewhere).

- [ ] **Step 2: Fixture — a window-event readout element**

In `examples/cef-hello/index.html`, add a readout `<pre>` after the `#tbheight` element (or near the other `<pre>`s):
```html
      <pre id="winevt">window event: (none)</pre>
```

- [ ] **Step 3: Fixture — subscribe to window events (all panes)**

In `examples/cef-hello/src/main.ts`, add (near the other subscriptions; ALL panes run this, which is what proves fan-out). Add `WindowEvent` to the runtime import (`import { Events, Services, Window, WindowEvent } from "@zappdev/runtime";`):
```ts
// Host window events must reach CEF windows + panes (host-event fan-out fix).
// Every pane subscribes; resizing/focusing window 1 should update ALL THREE.
const winevt = document.querySelector<HTMLPreElement>("#winevt")!;
Window.current().on(WindowEvent.RESIZE, (p) => {
  winevt.textContent = `window event: resize ${p.size.width}×${p.size.height}`;
});
Window.current().on(WindowEvent.FOCUS, () => { winevt.textContent = "window event: focus"; });
Window.current().on(WindowEvent.BLUR,  () => { winevt.textContent = "window event: blur"; });
```
(Confirm `WindowEvent` is exported from `@zappdev/runtime` and `.on(WindowEvent.RESIZE, …)` gives a `WindowSizePayload` with `.size.width`/`.size.height` — verified in `runtime/events.ts:145-149` + `runtime/window.ts:1409,1426`.)

- [ ] **Step 4: Typecheck**

Run: `bun run check`
Expected: `tsc --noEmit` clean (no new errors from the fixture change).

- [ ] **Step 5: Build (chromium)**

```bash
cd examples/cef-hello && rm -rf ~/.cache/nim/app_r && bun run build
```
Expected: both markers — `[zapp] CEF app bundle:` AND `[zapp] build complete: …/cef-hello (…KB)`; no `Undefined symbols` / `error:`.

- [ ] **Step 6: Headless smoke**

Launch the binary from the project dir ~6s, kill it (background + wait + kill), confirm 4 `browser created (slot N)` lines and NO crash/abort/assert. (Window events + the visual readout need a human — do NOT test them here.)

- [ ] **Step 7: Commit**

```bash
git add native/platform/darwin/window.m examples/cef-hello/index.html examples/cef-hello/src/main.ts
git commit -m "fix(cef): deliver host window events to CEF windows + panes (gated, byte-identical WK)"
```

- [ ] **Step 8: Human R0 gates** (controller runs WITH the user — not the implementer)

```bash
cd examples/cef-hello && ./bin/cef-hello.app/Contents/MacOS/cef-hello
```
- **Resize fan-out:** resize window 1 → the host pane's `window event:` line shows `resize WxH`, AND the sidebar + inspector panes show the same (fan-out). Window 2 (plain) shows it in its host pane.
- **Focus/blur:** click away from window 1 then back → panes show `blur` then `focus`.
- **Regression:** the C1-C3 gates still hold (panes render/tick, sidebar/inspector toggle, toolbar, teardown).
- **Byte-identical:** (controller) confirm the WK path (`window.m:243` downward) is unchanged vs pre-edit.

---

### Task 2: Docs — close the host-event fan-out fix

**Files:**
- Modify: `spikes/cef-macos/FINDINGS.md`
- Modify: `examples/cef-hello/SMOKE.md`

- [ ] **Step 1: FINDINGS — record the fix**

Append a section (match the file's structure/tone). Record: `zapp_dispatch_event_to_js` was WK-only (early-returned for CEF windows because `zapp_webviews[window_id]` is nil); a gated `#ifdef ZAPP_HAS_CEF` branch now mirrors the WK JS-build and fans host window events (resize/move/focus/blur/maximize/restore/modal) to the CEF host + sidebar + inspector panes via `darwin_window_eval_js`. Approach B (byte-identical WK, ~15-line JS-build mirror) chosen over refactoring the shared dispatcher, to preserve the `unifdef → original-bytes` guarantee. This closes the last CEF window-event gap flagged during C2/C3. Note the ~15-line WK-build mirror as a known keep-in-sync point.

- [ ] **Step 2: SMOKE — record the gates**

Add the gates (match the GATE format): host window resize fans to all 3 CEF panes of window 1 + window 2's host pane; focus/blur reach the CEF panes; WK byte-identical (dispatch path unchanged).

- [ ] **Step 3: Verify + commit**

```bash
bun run check && bun run test
```
Expected: green (docs-only; 292 pass / 0 fail).
```bash
git add spikes/cef-macos/FINDINGS.md examples/cef-hello/SMOKE.md
git commit -m "docs(cef): close host-event fan-out fix — findings + gates"
```

---

## Self-Review

**1. Spec coverage:**
- Gated CEF branch mirroring the WK build + fan-out via `darwin_window_eval_js` → Task 1 Step 1. ✅
- Byte-identical WK (code from the early-return down unchanged) → Global Constraints + Task 1 Step 1 confirm + Step 8 gate. ✅
- All events (resize/move/focus/blur/maximize/restore/modal) → covered by routing the whole function's build through the branch (the payload switch mirrors the WK one). ✅
- Fixture + resize/focus fan-out gate → Task 1 Steps 2-3, 8. ✅
- Docs → Task 2. ✅

**2. Placeholder scan:** No TBD/TODO. Step 1's CEF branch is complete code (the snprintf formats are the exact WK strings); Steps 2-3 show exact fixture edits. Docs steps describe content with the specific facts to record (prose docs).

**3. Type consistency:** `darwin_window_eval_js(int32_t, const char*)`, `zapp_sidebar_slot_for`/`zapp_inspector_slot_for(int32_t)`, `zapp_get_event_name(int)`, and the `ZAPP_EVENT_WINDOW_*` constants match their `window.m` definitions; the snprintf formats match `window.m:255-273`; `WindowEvent.RESIZE/FOCUS/BLUR` + `WindowSizePayload.size.{width,height}` match `runtime/events.ts`/`window.ts`.
