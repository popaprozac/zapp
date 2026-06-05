# Embeddable webviews (`<zapp-webview>`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `<zapp-webview src>` custom element backed by a native child `WKWebView` (macOS) — an iframe-like embed that can load any URL (incl. `X-Frame-Options` sites), tracked to its DOM rect reflow-free.

**Architecture:** Native-first chain. A `darwin_panel_*` C layer (`native/platform/darwin/panel.m`) owns a registry of child `WKWebView`s added as subviews of a window's `contentView`, positioned by absolute content-view points. A Zen-C `panel.zc` routes `panel*` actions from `router.zc` to those C primitives. The TS runtime (`runtime/webview.ts`) defines the `ZappWebviewElement` custom element + `Webview` factory; a reflow-free tracking layer (IntersectionObserver re-arm + ResizeObserver) converts the element's CSS rect to bottom-left native points and posts `panelSetBounds`. Native nav/message events eval back into the owner window's JS via `bridge.dispatchPanelEvent`.

**Tech Stack:** Objective-C (WKWebView), Zen-C (`zc`), TypeScript (`bun:test`, custom elements, IntersectionObserver/ResizeObserver), Bun.

**Branch:** `feat/embed-webview` (created, spec committed).

**Spec:** `docs/superpowers/specs/2026-06-05-embeddable-webviews-design.md`

**V1 scope note (read first):** The **sandboxed embed path ships fully** (any URL, host↔embed `postMessage`/`execJS`, nav events, tracking, lifecycle). The `bridge` and `partition` attributes are **plumbed end-to-end through the API + the `darwin_panel_create` signature but are inert in v1** — `bridge` does not yet inject `__zappBridge`, and `partition` always uses the shared default `WKWebsiteDataStore`. Both are documented follow-ups. This is a deliberate, forward-compatible reduction from the spec; the spec's Non-goals already list incognito partitions, and §"V1 scope note" here records the bridge-injection deferral.

**Conventions:**
- Stage ONLY the files each task names. Never `git add -A`. Never stage `vendor/*`, `native/worker/engines/zjs-cross-eval-test.c`, `hello-world/*` (except Task 8, which names the hello-world files), `benchmarks/*`, `node_modules`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Build success = LAST line `[zapp] build complete: <path>` (NOT Vite's `✓ built`). `bun run build` does NOT type-check — run `bun run check` separately.
- `#ifdef __APPLE__` is true on iOS too; `router.zc` compiles into the iOS binary. Every `darwin_panel_*` referenced from `.zc` MUST have an iOS def (`native/platform/ios/panel.m`) or the iOS link fails — and `cli/src/ios-platform-parity.test.ts` (rides `bun run test`) will flag it. Task 3 provides the stubs.
- Transient `bun test`/`tsc` `EMFILE` = fd exhaustion; re-run (`ulimit -n 4096`).

---

## Task 1: Geometry helpers (pure logic, TDD)

**Files:**
- Create: `runtime/webview-geometry.ts`
- Create: `runtime/webview-geometry.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `runtime/webview-geometry.test.ts`:
```ts
import { test, expect } from "bun:test";
import { toNativeRect, rectsEqual, isVisibleRect } from "./webview-geometry";

test("toNativeRect flips top-left CSS to bottom-left native", () => {
  // contentHeight 600; element top=100 height=200 → native y = 600-100-200 = 300
  expect(toNativeRect({ left: 50, top: 100, width: 300, height: 200 }, 600))
    .toEqual({ x: 50, y: 300, w: 300, h: 200 });
});
test("element at top of viewport sits at native y = contentHeight - height", () => {
  expect(toNativeRect({ left: 0, top: 0, width: 100, height: 100 }, 600).y).toBe(500);
});
test("toNativeRect rounds subpixel values to whole points", () => {
  expect(toNativeRect({ left: 50.4, top: 100.6, width: 300.5, height: 200.2 }, 600))
    .toEqual({ x: 50, y: 299, w: 301, h: 200 });
});
test("rectsEqual compares all fields and handles null", () => {
  const a = { x: 1, y: 2, w: 3, h: 4 };
  expect(rectsEqual(a, { x: 1, y: 2, w: 3, h: 4 })).toBe(true);
  expect(rectsEqual(a, { x: 1, y: 2, w: 3, h: 5 })).toBe(false);
  expect(rectsEqual(null, null)).toBe(true);
  expect(rectsEqual(a, null)).toBe(false);
});
test("isVisibleRect is false for zero-area (display:none) rects", () => {
  expect(isVisibleRect({ width: 10, height: 10 })).toBe(true);
  expect(isVisibleRect({ width: 0, height: 10 })).toBe(false);
  expect(isVisibleRect({ width: 10, height: 0 })).toBe(false);
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/zach/code/zapp && bun test ./runtime/webview-geometry.test.ts`
Expected: FAIL (cannot find module `./webview-geometry`).

- [ ] **Step 3: Implement `runtime/webview-geometry.ts`**

```ts
// Pure geometry for embedded webviews — no DOM/native deps so it unit-tests
// under bun:test. The host WKWebView fills the window content view 1:1 at
// zoom 1, so contentHeight ≈ window.innerHeight and CSS px ≈ native points.

export interface NativeRect { x: number; y: number; w: number; h: number; }

/**
 * Convert a DOMRect-like (CSS px, viewport top-left origin) to native
 * content-view points (macOS bottom-left origin). Rounded to whole points
 * (WKWebView setFrame wants integers; subpixel frames blur the embed).
 */
export function toNativeRect(
  rect: { left: number; top: number; width: number; height: number },
  contentHeight: number,
): NativeRect {
  return {
    x: Math.round(rect.left),
    y: Math.round(contentHeight - rect.top - rect.height),
    w: Math.round(rect.width),
    h: Math.round(rect.height),
  };
}

/** Equal in all four fields. null only equals null. Used to skip redundant posts. */
export function rectsEqual(a: NativeRect | null, b: NativeRect | null): boolean {
  if (a === null || b === null) return a === b;
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;
}

/** Non-zero area. A 0-area rect means display:none / detached → hide the panel. */
export function isVisibleRect(rect: { width: number; height: number }): boolean {
  return rect.width > 0 && rect.height > 0;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/zach/code/zapp && bun test ./runtime/webview-geometry.test.ts`
Expected: 5 pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/webview-geometry.ts runtime/webview-geometry.test.ts
git commit -m "$(cat <<'EOF'
feat(webview): geometry helpers for embedded webview rect tracking

Pure toNativeRect (CSS top-left -> native bottom-left), rectsEqual,
isVisibleRect. Unit-tested under bun:test; no DOM/native deps.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Native panel layer (macOS)

**Files:**
- Create: `native/platform/darwin/panel.m`
- Modify: `cli/src/native.ts` (add `panel.m` to the darwin source list)
- Modify: `native/build.zc` (add `panel.m` to the macOS cflags line — standalone build parity)

- [ ] **Step 1: Write `native/platform/darwin/panel.m`**

```objc
// macOS embedded-webview ("panel") implementation — pure Objective-C.
// A panel is a child WKWebView added as a subview of a window's contentView,
// positioned by absolute content-view points (bottom-left origin). The TS
// runtime drives it via darwin_panel_* (router -> panel.zc -> here).
//
// V1: sandboxed only. `bridge` and `partition` params are accepted for
// forward-compat but ignored (shared default data store, no __zappBridge).
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

// Reuse the window layer's lookups + JS-eval back-channel.
extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);

// One object per panel: it is the WKWebView's navigation delegate AND the
// "zappPanel" script-message handler, and it remembers which window owns it
// so events can be eval'd back into that window's JS.
@interface ZappPanel : NSObject <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView* webview;
@property (nonatomic, copy)   NSString*  panelId;
@property (nonatomic, assign) int32_t    ownerWindowId;
@end

static NSMutableDictionary<NSString*, ZappPanel*>* zapp_panels = nil;

static ZappPanel* zapp_panel_get(const char* panel_id) {
    if (!panel_id || !zapp_panels) return nil;
    return zapp_panels[[NSString stringWithUTF8String:panel_id]];
}

// JSON-escape a C string for embedding in a single-quoted JS string literal.
static NSString* zapp_panel_js_escape(const char* raw) {
    if (!raw) return @"";
    NSString* s = [NSString stringWithUTF8String:raw];
    if (!s) return @"";
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    s = [s stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    return s;
}

// Eval `bridge.dispatchPanelEvent(panelId, event, dataJson)` into the owner window.
static void zapp_panel_emit(ZappPanel* p, NSString* event, NSString* dataJson) {
    if (!p) return;
    NSString* dataArg = dataJson ? [NSString stringWithFormat:@"'%@'",
        [dataJson stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]] : @"undefined";
    // dataJson is already JSON; escape only backslashes + quotes for the JS literal.
    if (dataJson) {
        NSString* esc = [dataJson stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        dataArg = [NSString stringWithFormat:@"'%@'", esc];
    }
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        @"if(b&&typeof b.dispatchPanelEvent==='function'){b.dispatchPanelEvent('%@','%@',%@);}})();",
        p.panelId, event, dataArg];
    darwin_window_eval_js(p.ownerWindowId, [js UTF8String]);
}

@implementation ZappPanel
// embed -> host: window.zappHost.postMessage(d) lands here.
- (void)userContentController:(WKUserContentController*)ucc
      didReceiveScriptMessage:(WKScriptMessage*)message {
    id body = message.body;
    NSString* json = @"null";
    NSData* d = [NSJSONSerialization dataWithJSONObject:(body ?: [NSNull null])
                                               options:0 error:nil];
    if (d) json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    zapp_panel_emit(self, @"message", json);
}
- (void)webView:(WKWebView*)wv didFinishNavigation:(WKNavigation*)nav {
    NSString* url = wv.URL.absoluteString ?: @"";
    NSString* j = [NSString stringWithFormat:@"{\"url\":\"%@\"}",
        [url stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    zapp_panel_emit(self, @"did-navigate", j);
    zapp_panel_emit(self, @"load-finished", nil);
}
- (void)webView:(WKWebView*)wv didFailNavigation:(WKNavigation*)nav withError:(NSError*)error {
    NSString* j = [NSString stringWithFormat:@"{\"code\":%ld,\"description\":\"%@\"}",
        (long)error.code,
        [(error.localizedDescription ?: @"") stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    zapp_panel_emit(self, @"load-failed", j);
}
- (void)webView:(WKWebView*)wv didFailProvisionalNavigation:(WKNavigation*)nav withError:(NSError*)error {
    [self webView:wv didFailNavigation:nav withError:error];
}
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                        change:(NSDictionary*)change context:(void*)context {
    if ([keyPath isEqualToString:@"title"]) {
        NSString* t = self.webview.title ?: @"";
        NSString* j = [NSString stringWithFormat:@"{\"title\":\"%@\"}",
            [t stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
        zapp_panel_emit(self, @"title-change", j);
    }
}
@end

static void zapp_panel_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

void darwin_panel_create(int32_t window_id, const char* panel_id, const char* url,
                         bool bridge, const char* partition) {
    (void)bridge; (void)partition; // v1: sandboxed, shared store
    if (!panel_id) return;
    NSString* pid = [NSString stringWithUTF8String:panel_id];
    NSString* urlStr = url ? [NSString stringWithUTF8String:url] : @"";
    zapp_panel_on_main(^{
        if (!zapp_panels) zapp_panels = [NSMutableDictionary dictionary];
        if (zapp_panels[pid]) return; // already exists
        void* win_ptr = darwin_window_get_by_numeric_id(window_id);
        if (!win_ptr) return;
        NSWindow* window = (__bridge NSWindow*)win_ptr;
        NSView* host = [window contentView];
        if (!host) return;

        WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
        config.websiteDataStore = [WKWebsiteDataStore defaultDataStore]; // v1: shared
        WKUserContentController* ucc = [[WKUserContentController alloc] init];

        ZappPanel* panel = [[ZappPanel alloc] init];
        panel.panelId = pid;
        panel.ownerWindowId = window_id;

        // embed -> host postMessage shim (sandboxed: NO __zappBridge).
        [ucc addScriptMessageHandler:panel name:@"zappPanel"];
        NSString* shim =
            @"window.zappHost={postMessage:function(d){"
            @"try{window.webkit.messageHandlers.zappPanel.postMessage(d);}catch(e){}}};";
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:shim
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
        config.userContentController = ucc;

        WKWebView* wv = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1) configuration:config];
        wv.navigationDelegate = panel;
        wv.hidden = YES; // shown after first setBounds
        [wv addObserver:panel forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:NULL];
        panel.webview = wv;

        [host addSubview:wv];
        zapp_panels[pid] = panel;

        if (urlStr.length) {
            NSURL* nsurl = [NSURL URLWithString:urlStr];
            if (nsurl) [wv loadRequest:[NSURLRequest requestWithURL:nsurl]];
        }
    });
}

void darwin_panel_set_bounds(const char* panel_id, int32_t x, int32_t y, int32_t w, int32_t h) {
    ZappPanel* p = zapp_panel_get(panel_id);
    if (!p) return;
    zapp_panel_on_main(^{ [p.webview setFrame:NSMakeRect(x, y, w, h)]; });
}

void darwin_panel_load_url(const char* panel_id, const char* url) {
    ZappPanel* p = zapp_panel_get(panel_id);
    if (!p || !url) return;
    NSString* urlStr = [NSString stringWithUTF8String:url];
    zapp_panel_on_main(^{
        NSURL* nsurl = [NSURL URLWithString:urlStr];
        if (nsurl) [p.webview loadRequest:[NSURLRequest requestWithURL:nsurl]];
    });
}

void darwin_panel_eval_js(const char* panel_id, const char* js) {
    ZappPanel* p = zapp_panel_get(panel_id);
    if (!p || !js) return;
    NSString* code = [NSString stringWithUTF8String:js];
    zapp_panel_on_main(^{ [p.webview evaluateJavaScript:code completionHandler:nil]; });
}

void darwin_panel_show(const char* panel_id) {
    ZappPanel* p = zapp_panel_get(panel_id);
    if (!p) return;
    zapp_panel_on_main(^{ p.webview.hidden = NO; });
}
void darwin_panel_hide(const char* panel_id) {
    ZappPanel* p = zapp_panel_get(panel_id);
    if (!p) return;
    zapp_panel_on_main(^{ p.webview.hidden = YES; });
}
void darwin_panel_reload(const char* panel_id) {
    ZappPanel* p = zapp_panel_get(panel_id);
    if (!p) return;
    zapp_panel_on_main(^{ [p.webview reload]; });
}
void darwin_panel_go_back(const char* panel_id) {
    ZappPanel* p = zapp_panel_get(panel_id);
    if (!p) return;
    zapp_panel_on_main(^{ if ([p.webview canGoBack]) [p.webview goBack]; });
}
void darwin_panel_go_forward(const char* panel_id) {
    ZappPanel* p = zapp_panel_get(panel_id);
    if (!p) return;
    zapp_panel_on_main(^{ if ([p.webview canGoForward]) [p.webview goForward]; });
}

void darwin_panel_destroy(const char* panel_id) {
    if (!panel_id || !zapp_panels) return;
    NSString* pid = [NSString stringWithUTF8String:panel_id];
    zapp_panel_on_main(^{
        ZappPanel* p = zapp_panels[pid];
        if (!p) return;
        @try { [p.webview removeObserver:p forKeyPath:@"title"]; } @catch (NSException* e) {}
        [p.webview.configuration.userContentController removeScriptMessageHandlerForName:@"zappPanel"];
        p.webview.navigationDelegate = nil;
        [p.webview stopLoading];
        [p.webview removeFromSuperview];
        p.webview = nil;
        [zapp_panels removeObjectForKey:pid];
    });
}
```

- [ ] **Step 2: Register `panel.m` in the app build source list**

In `cli/src/native.ts`, in `getPlatformSources`, add to the **darwin** list (after the `clipboard.m`/`shortcuts.m` entries, ~line 62):
```ts
      path.join(darwinDir, "panel.m"),
```

- [ ] **Step 3: Register `panel.m` in the standalone framework build**

In `native/build.zc`, change the macOS cflags source line (line 16):
```
//> macos: cflags: platform/darwin/platform.m platform/darwin/window.m platform/darwin/webview.m
```
to append `panel.m`:
```
//> macos: cflags: platform/darwin/platform.m platform/darwin/window.m platform/darwin/webview.m platform/darwin/panel.m
```

- [ ] **Step 4: Verify the macOS build compiles `panel.m`**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -3`
Expected: last line `[zapp] build complete: …`. (`panel.m`'s `darwin_panel_*` are compiled but not yet called — unused symbols link fine. If clang errors in `panel.m`, fix the ObjC and rebuild.)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/darwin/panel.m cli/src/native.ts native/build.zc
git commit -m "$(cat <<'EOF'
feat(webview): native macOS panel layer (darwin_panel_*)

Child WKWebView per panel, subview of the window contentView, positioned
by content-view points. Sandboxed (postMessage shim, no __zappBridge);
nav/title/message events eval back into the owner window. bridge/partition
params reserved (v1 inert). Registered in getPlatformSources + build.zc.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: iOS no-op stubs

**Files:**
- Create: `native/platform/ios/panel.m`
- Modify: `cli/src/native.ts` (add `panel.m` to the iOS source list)

- [ ] **Step 1: Write `native/platform/ios/panel.m` (inert stubs)**

Every `darwin_panel_*` the shared `.zc` will call (Task 5) needs an iOS definition or the iOS link fails (and `ios-platform-parity.test.ts` flags it). v1 iOS is no-op.
```objc
// iOS embedded-webview stubs. Panels are macOS-only in v1; these no-ops
// satisfy the shared router.zc references on iOS (#ifdef __APPLE__ is true
// on iOS too). Real iOS impl deferred.
#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

void darwin_panel_create(int32_t window_id, const char* panel_id, const char* url,
                         bool bridge, const char* partition) {
    (void)window_id; (void)panel_id; (void)url; (void)bridge; (void)partition;
}
void darwin_panel_set_bounds(const char* panel_id, int32_t x, int32_t y, int32_t w, int32_t h) {
    (void)panel_id; (void)x; (void)y; (void)w; (void)h;
}
void darwin_panel_load_url(const char* panel_id, const char* url) { (void)panel_id; (void)url; }
void darwin_panel_eval_js(const char* panel_id, const char* js) { (void)panel_id; (void)js; }
void darwin_panel_show(const char* panel_id) { (void)panel_id; }
void darwin_panel_hide(const char* panel_id) { (void)panel_id; }
void darwin_panel_reload(const char* panel_id) { (void)panel_id; }
void darwin_panel_go_back(const char* panel_id) { (void)panel_id; }
void darwin_panel_go_forward(const char* panel_id) { (void)panel_id; }
void darwin_panel_destroy(const char* panel_id) { (void)panel_id; }
```

- [ ] **Step 2: Register `panel.m` in the iOS source list**

In `cli/src/native.ts` `getPlatformSources`, add to the **iOS** list (after the `clipboard.m`/`shortcuts.m` iOS entries, ~line 91):
```ts
      path.join(iosDir, "panel.m"),
```

- [ ] **Step 3: Verify the iOS-simulator build compiles the stubs**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build --platform ios-simulator 2>&1 | tail -3`
Expected: last line `[zapp] build complete: …`. (If iOS toolchain is unavailable in this environment, instead syntax-check: `clang -fsyntax-only -x objective-c native/platform/ios/panel.m -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) 2>&1 | tail -3` → no errors. Report which path you used.)

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/panel.m cli/src/native.ts
git commit -m "$(cat <<'EOF'
feat(webview): iOS no-op panel stubs

darwin_panel_* inert defs so the shared router.zc links on iOS
(#ifdef __APPLE__ is true on iOS). Real iOS panels deferred. Satisfies
the ios-platform-parity lint.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Zen-C panel routing + router/app wiring

**Files:**
- Create: `native/panel/panel.zc`
- Modify: `native/app/app.zc` (import `panel/panel.zc`)
- Modify: `native/app/router.zc` (delegate `panel*` actions to `panel_route`)

- [ ] **Step 1: Write `native/panel/panel.zc`**

Mirrors the `loadUrl` router pattern: read args off the `JsonValue`, call the `darwin_panel_*` externs in a `raw {}` block under `#ifdef __APPLE__`. Returns `true` if it handled the action.
```rust
// Embedded-webview ("panel") routing. router.zc delegates panel* actions
// here; this reads args and calls the darwin_panel_* C primitives. macOS
// real impl; iOS stubs (panel.m); other platforms: the #ifdef leaves the
// calls out, so the action is a silent no-op.
import "std/json.zc";

fn panel_str(args: JsonValue*, key: string) -> string {
    let o = args.get_string(key);
    if o.is_some() { return o.unwrap(); }
    return "";
}

fn panel_int(args: JsonValue*, key: string) -> int {
    let o = args.get_int(key);
    if o.is_some() { return o.unwrap(); }
    return 0;
}

// Returns true if `action` was a panel action (handled), false otherwise.
fn panel_route(window_id: int, action: string, args: JsonValue*) -> bool {
    if action == "panelCreate" {
        let pid = panel_str(args, "panelId");
        let url = panel_str(args, "url");
        let part = panel_str(args, "partition");
        let bridge_opt = args.get_bool("bridge");
        let has_bridge: bool = false;
        if bridge_opt.is_some() { has_bridge = bridge_opt.unwrap(); }
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_create(int32_t window_id, const char* panel_id,
                                            const char* url, bool bridge, const char* partition);
            darwin_panel_create(window_id, (const char*)pid, (const char*)url,
                                has_bridge, (const char*)part);
            #endif
        }
        return true;
    }
    if action == "panelSetBounds" {
        let pid = panel_str(args, "panelId");
        let x = panel_int(args, "x");
        let y = panel_int(args, "y");
        let w = panel_int(args, "w");
        let h = panel_int(args, "h");
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_set_bounds(const char* panel_id, int32_t x, int32_t y,
                                                int32_t w, int32_t h);
            darwin_panel_set_bounds((const char*)pid, x, y, w, h);
            #endif
        }
        return true;
    }
    if action == "panelLoadUrl" {
        let pid = panel_str(args, "panelId");
        let url = panel_str(args, "url");
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_load_url(const char* panel_id, const char* url);
            darwin_panel_load_url((const char*)pid, (const char*)url);
            #endif
        }
        return true;
    }
    if action == "panelExecJs" {
        let pid = panel_str(args, "panelId");
        let code = panel_str(args, "code");
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_eval_js(const char* panel_id, const char* js);
            darwin_panel_eval_js((const char*)pid, (const char*)code);
            #endif
        }
        return true;
    }
    if action == "panelPostMessage" {
        // Deliver as: window.dispatchEvent or a host->embed message. We wrap the
        // JSON payload into a CustomEvent the embed can listen for on `message`.
        let pid = panel_str(args, "panelId");
        let data = panel_str(args, "data"); // already JSON-encoded by the runtime
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_eval_js(const char* panel_id, const char* js);
            char js[4096];
            snprintf(js, sizeof(js),
                "window.dispatchEvent(new MessageEvent('message',{data:%s}));",
                (const char*)data);
            darwin_panel_eval_js((const char*)pid, js);
            #endif
        }
        return true;
    }
    if action == "panelShow" {
        let pid = panel_str(args, "panelId");
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_show(const char* panel_id);
            darwin_panel_show((const char*)pid);
            #endif
        }
        return true;
    }
    if action == "panelHide" {
        let pid = panel_str(args, "panelId");
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_hide(const char* panel_id);
            darwin_panel_hide((const char*)pid);
            #endif
        }
        return true;
    }
    if action == "panelReload" {
        let pid = panel_str(args, "panelId");
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_reload(const char* panel_id);
            darwin_panel_reload((const char*)pid);
            #endif
        }
        return true;
    }
    if action == "panelBack" {
        let pid = panel_str(args, "panelId");
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_go_back(const char* panel_id);
            darwin_panel_go_back((const char*)pid);
            #endif
        }
        return true;
    }
    if action == "panelForward" {
        let pid = panel_str(args, "panelId");
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_go_forward(const char* panel_id);
            darwin_panel_go_forward((const char*)pid);
            #endif
        }
        return true;
    }
    if action == "panelDestroy" {
        let pid = panel_str(args, "panelId");
        raw {
            #ifdef __APPLE__
            extern void darwin_panel_destroy(const char* panel_id);
            darwin_panel_destroy((const char*)pid);
            #endif
        }
        return true;
    }
    return false;
}
```

- [ ] **Step 2: Import `panel.zc` from `app.zc`**

In `native/app/app.zc`, alongside the existing window imports (the `import "../window/window.zc";` lines near the top), add:
```rust
import "../panel/panel.zc";
```

- [ ] **Step 3: Delegate panel actions in `router.zc`**

In `native/app/router.zc`, in the action-dispatch function, insert the panel delegation right AFTER the `loadUrl` block (after its closing `}`, ~line 493, before the `// Dock actions` comment):
```rust
    // Embedded-webview (panel) actions — delegate to panel.zc.
    if panel_route(window_id, action, pre_args) { return; }
```

- [ ] **Step 4: Verify the macOS build links the full chain**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -3`
Expected: last line `[zapp] build complete: …` (router now calls `darwin_panel_*`, defined in `panel.m`).

- [ ] **Step 5: Verify iOS parity lint + iOS build**

```bash
cd /Users/zach/code/zapp
bun test ./cli/src/ios-platform-parity.test.ts 2>&1 | tail -4
cd hello-world && bun run build --platform ios-simulator 2>&1 | tail -2
```
Expected: parity test passes (every `darwin_panel_*` referenced from `.zc` has an iOS def); iOS-sim build → `[zapp] build complete:` (or, if no iOS toolchain, the parity test passing is the gate — report it).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/panel/panel.zc native/app/app.zc native/app/router.zc
git commit -m "$(cat <<'EOF'
feat(webview): Zen-C panel routing + router/app wiring

panel.zc routes panel* actions to darwin_panel_* (macOS) under
#ifdef __APPLE__; router.zc delegates after loadUrl; app.zc imports it.
panelPostMessage delivers host->embed via a MessageEvent.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Bootstrap panel-event dispatch

**Files:**
- Modify: `bootstrap/webview.ts` (add `dispatchPanelEvent` to the bridge object)

- [ ] **Step 1: Add `dispatchPanelEvent` next to `dispatchWindowEvent`**

In `bootstrap/webview.ts`, find the bridge object's `dispatchWindowEvent(windowId, eventName, dataJson)` method (~line 123). Immediately after it, add:
```ts
    dispatchPanelEvent(panelId: string, eventName: string, dataJson?: string): void {
      let data: any = undefined;
      if (dataJson) {
        try { data = JSON.parse(dataJson); } catch {}
      }
      // Routed to runtime/webview.ts via the "panel:<panelId>" event name.
      bridge._onEvent("panel:" + panelId, JSON.stringify({ event: eventName, data }));
    },
```

- [ ] **Step 2: Add `dispatchPanelEvent` to the `ZappBridge` interface**

In `runtime/bridge.ts`, in the `ZappBridge` interface (after the `dispatchWindowEvent(...)` line, ~line 14), add:
```ts
  dispatchPanelEvent(panelId: string, eventName: string, dataJson?: string): void;
```

- [ ] **Step 2b: Run the type gate**

Run: `cd /Users/zach/code/zapp && bun run check 2>&1 | grep -c 'error TS'`
Expected: `0`.

- [ ] **Step 3: Verify the build picks up the bootstrap change**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -1`
Expected: `[zapp] build complete: …` (bootstrap compiles into the binary as a C string).

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add bootstrap/webview.ts runtime/bridge.ts
git commit -m "$(cat <<'EOF'
feat(webview): bootstrap dispatchPanelEvent back-channel

Native panel nav/message events eval bridge.dispatchPanelEvent(panelId,
event, dataJson) into the owner window; it routes to the runtime via the
"panel:<panelId>" event. Typed in the ZappBridge interface.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Runtime — `ZappWebviewElement` + `Webview` + tracking

**Files:**
- Create: `runtime/webview.ts`
- Modify: `runtime/index.ts` (export `Webview`, register the element)

- [ ] **Step 1: Write `runtime/webview.ts`**

```ts
// Embedded webview — the <zapp-webview> custom element + Webview factory.
// Runs in the webview (DOM) context. A native child WKWebView (darwin_panel_*)
// is glued to this element's rect via a reflow-free tracker (IntersectionObserver
// re-arm + ResizeObserver), reading entry.boundingClientRect rather than polling
// getBoundingClientRect in a scroll handler. See pretext (github.com/chenglou/
// pretext) for the "avoid forced sync layout" rationale.
import { getBridge } from "./bridge";
import { toNativeRect, rectsEqual, isVisibleRect, type NativeRect } from "./webview-geometry";

export type PanelEvent = "did-navigate" | "title-change" | "load-finished" | "load-failed" | "message";

export interface WebviewCreateOptions {
  src: string;
  bridge?: boolean;     // v1: plumbed but inert (no __zappBridge injection)
  partition?: string;   // v1: plumbed but inert (shared store)
}

let panelSeq = 0;
function nextPanelId(): string {
  panelSeq = (panelSeq + 1) & 0xffff;
  return "panel-" + Date.now().toString(36) + "-" + panelSeq.toString(36);
}

function currentWindowId(): string | null {
  return (globalThis as any)[Symbol.for("zapp.windowId")] ?? null;
}

// Fire-and-forget post on the t:4 action channel (same as window actions).
function panelPost(action: string, args: Record<string, unknown>): void {
  const bridge = getBridge() as any;
  const msg = JSON.stringify({ t: 4, m: action, a: args });
  if (bridge.post) bridge.post(msg);
  else bridge.emit("__panel:" + action, args);
}

export class ZappWebviewElement extends HTMLElement {
  static get observedAttributes() { return ["src"]; }

  private _panelId = nextPanelId();
  private _created = false;
  private _lastRect: NativeRect | null = null;
  private _io: IntersectionObserver | null = null;
  private _ro: ResizeObserver | null = null;
  private _rafPending = false;
  private _listeners = new Map<PanelEvent, Set<(data: unknown) => void>>();
  private _unsub: (() => void) | null = null;

  connectedCallback(): void {
    if (this._created) return;
    // Placeholder box; the native webview overlays it. Default to block so it
    // participates in layout and getBoundingClientRect returns real geometry.
    if (!this.style.display) this.style.display = "block";
    const src = this.getAttribute("src") ?? "";
    const bridge = this.hasAttribute("bridge");
    const partition = this.getAttribute("partition") ?? "";
    panelPost("panelCreate", {
      windowId: currentWindowId(), panelId: this._panelId, url: src, bridge, partition,
    });
    this._created = true;
    this._subscribe();
    this._startTracking();
  }

  disconnectedCallback(): void {
    if (!this._created) return;
    this._stopTracking();
    if (this._unsub) { this._unsub(); this._unsub = null; }
    panelPost("panelDestroy", { panelId: this._panelId });
    this._created = false;
    this._lastRect = null;
  }

  attributeChangedCallback(name: string, _old: string | null, val: string | null): void {
    if (name === "src" && this._created && val != null) this.loadURL(val);
  }

  // --- public API ---
  loadURL(url: string): void { panelPost("panelLoadUrl", { panelId: this._panelId, url }); }
  execJS(code: string): void { panelPost("panelExecJs", { panelId: this._panelId, code }); }
  postMessage(data: unknown): void {
    panelPost("panelPostMessage", { panelId: this._panelId, data: JSON.stringify(data ?? null) });
  }
  reload(): void { panelPost("panelReload", { panelId: this._panelId }); }
  goBack(): void { panelPost("panelBack", { panelId: this._panelId }); }
  goForward(): void { panelPost("panelForward", { panelId: this._panelId }); }
  destroy(): void { this.remove(); } // triggers disconnectedCallback

  on(event: PanelEvent, cb: (data: unknown) => void): () => void {
    let set = this._listeners.get(event);
    if (!set) { set = new Set(); this._listeners.set(event, set); }
    set.add(cb);
    return () => { set!.delete(cb); };
  }

  // --- events ---
  private _subscribe(): void {
    this._unsub = getBridge().on("panel:" + this._panelId, (payload: unknown) => {
      const p = payload as { event?: PanelEvent; data?: unknown };
      if (!p?.event) return;
      const set = this._listeners.get(p.event);
      if (set) for (const cb of set) cb(p.data);
      this.dispatchEvent(new CustomEvent(p.event, { detail: p.data }));
    });
  }

  // --- reflow-free tracking ---
  private _startTracking(): void {
    this._sync();
    this._ro = new ResizeObserver(() => this._schedule());
    this._ro.observe(this);
    this._armIO();
    window.addEventListener("resize", this._onWinChange, { passive: true });
    // capture-phase scroll catches scrolling in ANY ancestor (reflow-free read
    // happens in _sync via the IO entry / a single rAF-coalesced gBCR).
    window.addEventListener("scroll", this._onWinChange, { passive: true, capture: true });
  }
  private _stopTracking(): void {
    if (this._io) { this._io.disconnect(); this._io = null; }
    if (this._ro) { this._ro.disconnect(); this._ro = null; }
    window.removeEventListener("resize", this._onWinChange);
    window.removeEventListener("scroll", this._onWinChange, { capture: true } as any);
  }
  private _onWinChange = (): void => this._schedule();

  // Coalesce many triggers in a frame into one sync.
  private _schedule(): void {
    if (this._rafPending) return;
    this._rafPending = true;
    requestAnimationFrame(() => { this._rafPending = false; this._sync(); });
  }

  // Re-arm an IntersectionObserver whose rootMargins bound the element tightly,
  // so it re-fires the moment the element moves a pixel relative to the viewport
  // — reflow-free movement detection (entry.boundingClientRect is browser-computed).
  private _armIO(): void {
    if (this._io) this._io.disconnect();
    const r = this.getBoundingClientRect();
    const mTop = Math.floor(r.top);
    const mLeft = Math.floor(r.left);
    const mBottom = Math.floor(window.innerHeight - r.bottom);
    const mRight = Math.floor(window.innerWidth - r.right);
    this._io = new IntersectionObserver((entries) => {
      const rect = entries[0]?.boundingClientRect;
      this._sync(rect ?? undefined);
      this._armIO(); // re-arm at the new position
    }, { threshold: [0, 0.0001, 1], rootMargin: `${-mTop}px ${-mRight}px ${-mBottom}px ${-mLeft}px` });
    this._io.observe(this);
  }

  private _sync(domRect?: DOMRectReadOnly): void {
    const r = domRect ?? this.getBoundingClientRect();
    if (!isVisibleRect(r)) {
      if (this._lastRect !== null) panelPost("panelHide", { panelId: this._panelId });
      this._lastRect = null;
      return;
    }
    const native = toNativeRect(r, window.innerHeight);
    if (rectsEqual(native, this._lastRect)) return;
    const firstShow = this._lastRect === null;
    this._lastRect = native;
    panelPost("panelSetBounds", { panelId: this._panelId, ...native });
    if (firstShow) panelPost("panelShow", { panelId: this._panelId });
  }
}

export const Webview = {
  /** Programmatically create + insert a <zapp-webview>. Append it where you want it. */
  create(opts: WebviewCreateOptions): ZappWebviewElement {
    const el = document.createElement("zapp-webview") as ZappWebviewElement;
    if (opts.bridge) el.setAttribute("bridge", "");
    if (opts.partition) el.setAttribute("partition", opts.partition);
    el.setAttribute("src", opts.src);
    return el;
  },
};

// Register the element once, in webview/DOM contexts only (no-op in workers/SSR).
if (typeof customElements !== "undefined" && !customElements.get("zapp-webview")) {
  customElements.define("zapp-webview", ZappWebviewElement);
}
```

- [ ] **Step 2: Export from `runtime/index.ts`**

In `runtime/index.ts`, after the `Window` export (~line 18), add:
```ts
export { Webview, ZappWebviewElement, type PanelEvent, type WebviewCreateOptions } from "./webview";
```

- [ ] **Step 3: Type gate + unit tests stay green**

```bash
cd /Users/zach/code/zapp
bun run check 2>&1 | grep -c 'error TS'   # expect 0
bun test ./runtime/webview-geometry.test.ts 2>&1 | tail -2   # expect 5 pass
```
Expected: 0 type errors; geometry tests still pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add runtime/webview.ts runtime/index.ts
git commit -m "$(cat <<'EOF'
feat(webview): <zapp-webview> custom element + Webview factory

ZappWebviewElement defines/registers the element, drives panelCreate/
SetBounds/Destroy, and tracks its DOM rect reflow-free (IntersectionObserver
re-arm + ResizeObserver, rAF-coalesced). loadURL/execJS/postMessage/reload/
goBack/goForward/on + Webview.create. Exported from runtime/index.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Docs

**Files:**
- Modify: `docs/api-reference.md` (add a `Webview` / `<zapp-webview>` section)

- [ ] **Step 1: Add the API + concept section**

In `docs/api-reference.md`, add a new top-level section (place it after the `Window` section; match the file's existing heading depth/style):
```markdown
## Webview (embedded webviews) — macOS

`<zapp-webview>` embeds a **full native webview** inside your page — like an
`<iframe>`, but it can load sites that block iframing (`X-Frame-Options` /
`frame-ancestors`), runs in its own process, and keeps its own session.

```html
<zapp-webview src="https://example.com" style="width:360px;height:480px"></zapp-webview>
```
```ts
import { Webview } from "@zappdev/runtime";

const v = document.querySelector("zapp-webview") as import("@zappdev/runtime").ZappWebviewElement;
await /* host -> embed */ v.execJS("document.title");
v.postMessage({ hello: "embed" });               // host -> embed (a MessageEvent)
v.on("did-navigate", (d) => console.log("nav", d));
v.on("message", (d) => console.log("from embed", d)); // embed called window.zappHost.postMessage(d)
v.loadURL("https://wails.io"); v.reload(); v.goBack(); v.destroy();

// programmatic:
const v2 = Webview.create({ src: "https://example.com" });
document.querySelector(".sidebar")!.appendChild(v2);
```

**Attributes:** `src` (URL); `bridge` (reserved — app-origin bridge injection is
a follow-up; inert in v1); `partition` (reserved — named sessions are a follow-up;
inert in v1).

**Events** (via `.on(event, cb)` or DOM `CustomEvent`): `did-navigate` `{url}`,
`title-change` `{title}`, `load-finished`, `load-failed` `{code,description}`,
`message` (data from `window.zappHost.postMessage` in the embed).

**Security:** embeds are **sandboxed** — they do NOT get `__zappBridge`/Services.
Host↔embed communication is only `execJS`/`postMessage` ↔ `window.zappHost.postMessage`.

**Known limitations (v1).** The embed is a separate OS layer composited over your
page, so: (1) it can lag a frame on fast scroll ("swim"); (2) it always paints
**above** your DOM — app modals/dropdowns can't cover it; (3) it won't clip to
`overflow:hidden`/`border-radius` ancestors or follow CSS `transform`. Mitigations
are a planned follow-up. macOS only in v1 (iOS/Windows are no-ops). DevTools can't
be opened programmatically on macOS (right-click → Inspect Element).
```
(If `docs/api-reference.md` uses a table-of-contents or section index, add a `Webview` entry there too.)

- [ ] **Step 2: Verify fences balanced + commit**

```bash
cd /Users/zach/code/zapp
grep -c '```' docs/api-reference.md   # must be even
git add docs/api-reference.md
git commit -m "$(cat <<'EOF'
docs(webview): document <zapp-webview> embedded webviews

API (element + Webview.create), events, sandbox model, and the v1 known
limitations (scroll-swim, flat z-order, clipping) + macOS-only scope.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: hello-world smoke wiring + full verification

**Files:**
- Modify: `hello-world/src/main.ts` (add a `<zapp-webview>` demo — **this is the one task allowed to touch hello-world**)

> NOTE: `hello-world/src/main.ts` + `hello-world/zapp.config.ts` have pre-existing uncommitted user edits. Do NOT discard them. ADD the demo append-only; stage ONLY `hello-world/src/main.ts`; if the diff would also touch `zapp.config.ts`, leave that file alone.

- [ ] **Step 1: Add a minimal embed demo to hello-world**

Append to `hello-world/src/main.ts` (adapt the selector to the app's actual DOM; the goal is one element in normal flow + a couple of event logs):
```ts
import { Webview } from "@zappdev/runtime";

// --- embedded webview smoke ---
const embedHost = document.body;
const embed = Webview.create({ src: "https://example.com" });
embed.style.cssText = "display:block;width:360px;height:300px;margin:16px;border:1px solid #ccc";
embed.on("load-finished", () => console.log("[demo] embed loaded"));
embed.on("did-navigate", (d) => console.log("[demo] embed nav", d));
embedHost.appendChild(embed);
```

- [ ] **Step 2: Full gate — check + tests + both builds**

```bash
cd /Users/zach/code/zapp
bun run check 2>&1 | grep -c 'error TS'                       # 0
bun run test:all 2>&1 | tail -6                                # TS + native + check green
cd hello-world && bun run build 2>&1 | tail -1                 # [zapp] build complete:
bun run build --platform ios-simulator 2>&1 | tail -1         # [zapp] build complete: (or report toolchain absence)
```
Expected: 0 type errors; `test:all` green (incl. the ios-platform-parity lint); macOS build completes; iOS-sim build completes (stubs link).

- [ ] **Step 3: Commit (stage ONLY hello-world/src/main.ts)**

```bash
cd /Users/zach/code/zapp
git add hello-world/src/main.ts
git commit -m "$(cat <<'EOF'
chore(hello-world): embedded webview smoke demo

A <zapp-webview src=example.com> in normal flow with load/nav logging,
for manual macOS smoke of tracking + events.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Hand off the manual smoke checklist**

Report to the controller (for the user's manual macOS run): launch hello-world, confirm (a) the embed renders example.com in its box, (b) it tracks position on window scroll/resize, (c) console shows `[demo] embed loaded` + `[demo] embed nav`, (d) `v.execJS`/`v.postMessage` round-trip, (e) removing the element destroys the native webview. Note the three known leaks are expected (not bugs).

---

## Self-Review (completed during plan authoring)

**Spec coverage:**
- DOM-tracked element + native child WKWebView → Tasks 2/6. ✅
- Reflow-free IO+RO tracking (pretext rationale) → Task 6 `_armIO`/`_schedule`/`_sync`. ✅
- Coordinate conversion → Task 1 `toNativeRect` (tested). ✅
- API surface (element-is-handle, `Webview.create`, events, host↔embed messaging) → Task 6 + Task 4 `panelPostMessage` + Task 2 `zappPanel` handler. ✅
- Sandbox (no `__zappBridge` external) → Task 2 (only the `zappHost` shim injected). ✅
- `bridge`/`partition` plumbed-but-inert → Tasks 2/4/6 + documented (V1 scope note, Task 7). ✅ (deliberate reduction from spec's "full bridge opt-in"; flagged.)
- Native-first chain (C→Zen-C→router→TS→docs) → Tasks 2–7. ✅
- macOS-first + iOS stubs + parity → Tasks 2/3/4. ✅
- Events back to JS via `dispatchPanelEvent` → Task 5. ✅
- Non-goals (leaks, Windows/iOS real, incognito, DevTools-open) → respected; documented in Task 7. ✅
- Verification (`check`, `test:all`, macOS + ios-sim builds) → Tasks 6/8. ✅

**Placeholder scan:** No TBD. Every code step shows complete code. Task 8 Step 1 says "adapt the selector to the app's actual DOM" — that's an unavoidable integration point (hello-world's DOM is user-edited), not a placeholder; the appended code is complete and self-contained (uses `document.body`).

**Type/name consistency:** action strings (`panelCreate`/`panelSetBounds`/`panelLoadUrl`/`panelExecJs`/`panelPostMessage`/`panelShow`/`panelHide`/`panelReload`/`panelBack`/`panelForward`/`panelDestroy`) match between `runtime/webview.ts` (`panelPost`) and `panel.zc` (`panel_route`). `NativeRect {x,y,w,h}` consistent (Task 1 ↔ Task 6 ↔ `panelSetBounds` args ↔ `darwin_panel_set_bounds`). Event names (`did-navigate`/`title-change`/`load-finished`/`load-failed`/`message`) match between `panel.m` (`zapp_panel_emit`) and `runtime/webview.ts` (`PanelEvent`). `dispatchPanelEvent` signature matches across `panel.m` eval, `bootstrap/webview.ts`, and `runtime/bridge.ts`. The `panel:<panelId>` event name matches between `bootstrap` (`_onEvent`) and runtime (`getBridge().on`).

**Known soft spot (flagged for execution):** the IntersectionObserver re-arm `rootMargin` math in `_armIO` is the fiddliest part and is the most likely thing to need tuning during manual smoke (it's reflow-free movement *detection*; the `_sync` always recomputes the real rect, so worst case is an extra/late sync, not a wrong position). The rAF-coalesced `scroll`(capture)+`resize` listeners are the safety net that guarantees correctness even if the IO re-arm is imperfect.
