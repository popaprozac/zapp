# iOS Embedded Webviews (`<zapp-webview>`) — Design

**Date:** 2026-06-08
**Status:** Approved (brainstorm) → ready for implementation plan
**Branch:** `feat/ios-embed-webview`

## Context

Zapp shipped embeddable webviews (`<zapp-webview>` / "panels") on macOS in the
2026-06-05 cycle (main `172f7d9`): a native child `WKWebView` glued to the DOM
rectangle of a `<zapp-webview>` element, which can load sites that block
iframing (`X-Frame-Options` / `frame-ancestors`) because a native webview is a
top-level browsing context. That is the feature's killer property.

iOS got a **24-line no-op stub** (`native/platform/ios/panel.m`) so the shared
Zen-C router (`panel.zc`, compiled into every target) links — the recurring
iOS-parity rule (`#ifdef __APPLE__` is true on iOS; every `darwin_*` referenced
from shared `.zc` needs an iOS definition). So today, `<zapp-webview>` silently
does nothing on iOS. This is the largest functional macOS↔iOS gap.

This cycle fills in the iOS implementation to **full parity with the macOS v1
panel**. The exploration (see "Reference: integration map" below) confirmed the
work is largely a **direct port** of `native/platform/darwin/panel.m`:
`WKWebView` and its `WKNavigationDelegate` / `WKScriptMessageHandler` / KVO are
identical on iOS, event delivery reuses the existing iOS `darwin_window_eval_js`,
and it is *simpler* than macOS because UIView uses a top-left origin (the macOS
`isFlipped` coordinate flip disappears).

## Goals

- `<zapp-webview>` works on iOS with the **same runtime surface as macOS v1**:
  all 11 `darwin_panel_*` operations and all 5 events (`did-navigate`,
  `load-finished`, `load-failed`, `title-change`, `message`).
- Sandboxed-only, exactly like macOS v1: shared default `WKWebsiteDataStore`;
  embed→host `window.zappHost.postMessage` shim + host→embed `execJS` /
  `postMessage`; the `bridge` and `partition` attributes stay **plumbed but
  inert** (no `__zappBridge` injection, no named/ephemeral partitions).
- iPhone single-window. Verified on the iOS Simulator.

## Non-goals (this cycle)

- **iPad multi-scene** panel bucketing (UIScene). iPhone is single-window;
  a global panel registry is sufficient. iPad multi-window is a follow-up.
- **Leak mitigation** — flat z-order (native embed paints above the host DOM),
  scroll-swim lag, no clip/rounding/transform following. Same documented v1
  leaks as macOS; deliberately deferred. (Note: flat z-order is *more visible*
  on iOS because sheets/modals/dropdowns are common and cannot cover the embed —
  modal-aware hiding is a named follow-up, below.)
- **App-origin bridge injection** + named/ephemeral `partition`. Inert in v1 on
  both platforms.
- **Windows** panel implementation (separate effort).
- Any change to `runtime/webview.ts`, `bootstrap/webview.ts`, `native/panel/panel.zc`,
  `native/app/router.zc`, or the runtime geometry helpers — all platform-agnostic
  and already compile + run on iOS.

## Approach

**Mirror `darwin/panel.m` 1:1 in `ios/panel.m`, UIKit-flavored.** Rejected
alternatives: (B) extracting a shared cross-platform `.m` core — refactors the
verified-sound macOS code and risks regressing its lifecycle/leaks for what is a
port; (C) Swift — the codebase is Obj-C `.m`, Swift adds toolchain overhead. The
mirror keeps the change isolated to `ios/panel.m` plus one small `ios/window.m`
helper and reads as a near-diff against the macOS reference.

## Architecture

```
runtime/webview.ts  (unchanged, platform-agnostic)
        │  panelPost("panelCreate"/"panelSetBounds"/… , {…})  → t:4 action channel
        ▼
native/app/router.zc → panel_route(window_id, action, args)   (unchanged)
        │  #ifdef __APPLE__  (true on iOS)
        ▼
native/platform/ios/panel.m   ← THIS CYCLE (mirror of darwin/panel.m)
        │  darwin_window_get_by_numeric_id(id) → UIWindow → rootViewController.view
        │  child WKWebView added as a subview, tracked via setBounds
        ▼
events: darwin_window_eval_js(ownerWindowId, "(…dispatchPanelEvent…)")  (existing iOS fn)
        ▼
bootstrap/webview.ts dispatchPanelEvent  (unchanged) → runtime element listeners
```

### Component 1 — `native/platform/ios/panel.m` (replaces the stub)

Mirror of `native/platform/darwin/panel.m`:

- **`ZappIOSPanel`** Obj-C class conforming to `WKNavigationDelegate` +
  `WKScriptMessageHandler`. Properties: `WKWebView* webview`, `NSString* panelId`,
  `int32_t ownerWindowId`. Registers KVO on the webview's `title`.
- **Registry:** `static NSMutableDictionary<NSString*, ZappIOSPanel*>* zapp_ios_panels`,
  keyed by panel id. Global (iPhone single-window → no per-window bucketing).
- **`zapp_ios_panel_emit(panel, event, dataJson)`** — builds
  `(function(){var b=globalThis[Symbol.for('zapp.bridge')]; if(b&&typeof b.dispatchPanelEvent==='function'){b.dispatchPanelEvent('<id>','<event>',<data>);}})();`
  and calls `darwin_window_eval_js(panel.ownerWindowId, js)`. Identical string
  shape to macOS so `bootstrap/webview.ts` handling is unchanged.
- **Main-thread helper** (`if ([NSThread isMainThread]) block(); else dispatch_async(main, block)`),
  wrapping every UIKit/WebKit call.

The 11 C functions (exact signatures match the stub / macOS):

| Function | Behavior (iOS) |
|---|---|
| `darwin_panel_create(window_id, panel_id, url, bridge, partition)` | Look up owner `UIWindow` via `darwin_window_get_by_numeric_id`; host view = `window.rootViewController.view`. Alloc `WKWebViewConfiguration` with shared default `WKWebsiteDataStore`, add `zappPanel` script-message handler, inject the `zappHost.postMessage` shim (`WKUserScript`, `AtDocumentStart`). Alloc `WKWebView` (1×1 frame, hidden), set nav delegate + `title` KVO, `addSubview:` on the host view, register in `zapp_ios_panels`. If `url` non-empty, `loadRequest:`. `bridge`/`partition` accepted but ignored (parity with macOS v1). |
| `darwin_panel_set_bounds(panel_id, x, y, w, h)` | `[webview setFrame:CGRectMake(x, y, w, h)]`. **No Y-flip** — UIView is top-left; the runtime already emits top-left CSS coords via `toNativeRect`. |
| `darwin_panel_load_url(panel_id, url)` | `[webview loadRequest:[NSURLRequest requestWithURL:…]]`. |
| `darwin_panel_eval_js(panel_id, js)` | `[webview evaluateJavaScript:js completionHandler:nil]` (fire-and-forget). |
| `darwin_panel_post_message(panel_id, data_json)` | `window.dispatchEvent(new MessageEvent('message',{data:<data_json>}))`, JS built on the **heap** (`stringWithFormat:`) — no fixed buffer (the snprintf-truncation hazard family). |
| `darwin_panel_show(panel_id)` | `webview.hidden = NO`. |
| `darwin_panel_hide(panel_id)` | `webview.hidden = YES`. |
| `darwin_panel_reload(panel_id)` | `[webview reload]`. |
| `darwin_panel_go_back(panel_id)` | `if (webview.canGoBack) [webview goBack]`. |
| `darwin_panel_go_forward(panel_id)` | `if (webview.canGoForward) [webview goForward]`. |
| `darwin_panel_destroy(panel_id)` | `removeObserver:forKeyPath:@"title"` (guarded), `removeScriptMessageHandlerForName:@"zappPanel"`, `navigationDelegate = nil`, `stopLoading`, `removeFromSuperview`, nil the webview, remove from `zapp_ios_panels`. |

Delegate / handler methods (mirror macOS):
- `userContentController:didReceiveScriptMessage:` (name `zappPanel`) → serialize
  `message.body` to JSON → emit `"message"`.
- `webView:didFinishNavigation:` → emit `"did-navigate"` (with `URL`) then `"load-finished"`.
- `webView:didFailNavigation:withError:` and `webView:didFailProvisionalNavigation:withError:`
  → emit `"load-failed"` (code + localizedDescription).
- `observeValueForKeyPath:` (`title`) → emit `"title-change"`.

### Component 2 — `native/platform/ios/window.m` (one new function)

```c
// Mirror of darwin/window.m's darwin_window_get_by_numeric_id (macOS returns
// the NSWindow). iOS returns the UIWindow off the existing dispatch table;
// panel.m then takes window.rootViewController.view as the host view.
void* darwin_window_get_by_numeric_id(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS) {
        return (__bridge void*)zapp_ios_windows[numeric_id];
    }
    return NULL;
}
```

(`zapp_ios_windows[]` is the existing UIWindow dispatch table populated during
`zapp_ios_materialize_pending_windows()`.)

## Coordinate system

iOS UIView always uses a **top-left origin** (non-flipped). The runtime's
`toNativeRect` (in `runtime/webview-geometry.ts`) already produces top-left CSS
coordinates; macOS performs a bottom-left flip *native-side* when the parent
NSView is non-flipped. On iOS that branch is simply **omitted** — incoming
`(x, y, w, h)` map directly to `CGRectMake`. No runtime change; no per-platform
geometry branch in TS.

## Deferred-window-materialization

iOS defers real `UIWindow`/`UIViewController`/`WKWebView` creation until
`zapp_ios_materialize_pending_windows()` runs in the app delegate's
`didFinishLaunchingWithOptions`. **Panels do not need a parallel deferred queue:**
a panel is only created in response to a message from the owner webview's DOM
(`<zapp-webview>` `connectedCallback` / `Webview.create`), and that JS cannot run
until the owner webview exists — i.e. always *after* materialization. Defensive
posture: if `darwin_window_get_by_numeric_id` returns NULL (or the window has no
`rootViewController`), `darwin_panel_create` logs `[zapp] panel: owner window <id>
not available` and returns — same "return if no window" behavior as macOS
(`darwin/panel.m`).

## Event delivery

Reuses the existing iOS `darwin_window_eval_js(int32_t window_id, const char* js)`
(`native/platform/ios/window.m`), which evaluates JS into
`zapp_ios_webviews[window_id]` on the main thread. No new event plumbing.

## Sandboxing / bridge / partition

v1 sandboxed-only, identical to macOS: shared default `WKWebsiteDataStore`; embed
gets only the injected `window.zappHost.postMessage` shim (embed→host) plus
`execJS` / `postMessage` (host→embed). `bridge` and `partition` are accepted in
`darwin_panel_create`'s signature but ignored. App-origin bridge injection +
named/ephemeral partitions are a cross-platform follow-up.

## Known v1 leaks (parity, documented)

1. **Flat z-order** — the native embed always paints above the host DOM. App
   modals/sheets/dropdowns cannot cover it. More visible on iOS (sheet-heavy UX).
   *Follow-up:* modal-aware hide/lower.
2. **Scroll-swim lag** — the native overlay is a separate compositing layer and
   lags the DOM by a frame on fast scroll (the runtime tracks via
   IntersectionObserver/ResizeObserver/scroll → `setBounds`).
3. **No clip / rounding / transform following.**

## Verification

iOS Simulator is the gate (the Simulator runs real WebKit, so embed rendering is
faithful):

1. `bun run build --platform ios` → `[zapp] build complete:` (the framework build-success marker).
2. `xcrun simctl install booted bin/ios/hello-world.app` (uninstall first if stale).
3. Launch; in the hello-world `<zapp-webview>` demo, point an embed at a site that
   sends `X-Frame-Options: DENY` (the killer case — an `<iframe>` would be blank).
4. `xcrun simctl io booted screenshot` → confirm the embed **renders** content and
   **tracks** the element rect on scroll/resize.
5. Exercise: load-finished / title-change / did-navigate events reach the element
   listeners; `postMessage` host↔embed round-trips; `destroy` removes the embed.

Gates that already cover the native delta:
- **#281 iOS symbol-parity lint** (`bun test cli/src/ios-platform-parity.test.ts`)
  — the new `ios/panel.m` definitions satisfy the `darwin_*`-from-`.zc` rule.
- **ios-sim compile** (build gate) — `darwin_window_get_by_numeric_id` (a `.m`-only
  symbol) is verified by the iOS build linking.
- macOS build stays green (untouched).

## Testing

No new bun unit tests: the geometry helpers (`runtime/webview-geometry.ts`) are
already bun-tested and shared across platforms, and the iOS work is native-only
(Obj-C), verified by the Simulator smoke + parity lint + ios-sim build. (Consistent
with how the macOS panel cycle and other `.m`-only native work are gated.)

## File inventory

| File | Change |
|---|---|
| `native/platform/ios/panel.m` | **Replace stub** with the full UIKit panel (ZappIOSPanel class + registry + 11 functions + delegates/handler/KVO + emit helper). |
| `native/platform/ios/window.m` | **Add** `darwin_window_get_by_numeric_id`. |
| `cli/src/native.ts` | No change — `ios/panel.m` is already in `getPlatformSources` (ios list). |
| `native/panel/panel.zc`, `native/app/router.zc` | No change — platform-agnostic, already route on iOS. |
| `runtime/webview.ts`, `runtime/webview-geometry.ts`, `bootstrap/webview.ts` | No change. |
| `docs/api-reference.md` | Update the embedded-webview section: drop "macOS-only", note iOS support + the iOS-specific leak nuance. |
| `hello-world/*` | No source change required (the `<zapp-webview>` demo already exists); used as the Simulator smoke vehicle only. |

## Follow-ups (out of scope, tracked)

- Modal-aware panel hide/lower on iOS (flat z-order mitigation).
- iPad multi-scene panel bucketing (UIScene).
- App-origin bridge injection + named/ephemeral partitions (cross-platform).
- Windows panel implementation.

## Reference: integration map

Key file:line anchors confirmed during exploration (macOS reference + iOS
architecture): `darwin/panel.m` (create 103–149, set_bounds flip 155–164, emit
44–58, destroy 227–241); `ios/panel.m` stub (1–24); `ios/window.m` deferred
materialization + `zapp_ios_windows[]` table + `darwin_window_eval_js`;
`ios/webview.m` `darwin_webview_create` attaches the main webview to
`window.rootViewController.view`; `native/app/router.zc` delegates to
`panel_route`; `cli/src/native.ts` `getPlatformSources` ios list already includes
`panel.m`.
