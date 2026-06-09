# iOS Embedded Webviews (`<zapp-webview>`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `<zapp-webview>` (embedded native webviews / "panels") work on iOS at full parity with the macOS v1 implementation.

**Architecture:** Port `native/platform/darwin/panel.m` to `native/platform/ios/panel.m` (UIKit-flavored): a child `WKWebView` added as a subview of the owner window's `rootViewController.view`, driven by the existing platform-agnostic router → `panel.zc` → `darwin_panel_*` chain. Events flow back via the existing iOS `darwin_window_eval_js`. One new native helper (`darwin_window_get_by_numeric_id`) is added to `ios/window.m`. The runtime, Zen-C routing, and bootstrap are untouched (already platform-agnostic).

**Tech Stack:** Objective-C (ARC, `-fobjc-arc`), UIKit, WebKit (`WKWebView`/`WKNavigationDelegate`/`WKScriptMessageHandler`/KVO), Zapp CLI (`bun run build --platform ios`), iOS Simulator (`xcrun simctl`).

**Spec:** `docs/superpowers/specs/2026-06-08-ios-embedded-webview-design.md`

---

## Context the engineer needs

- **No TDD unit harness for Obj-C.** Native `.m` files are verified by: (a) the iOS-simulator build compiling + linking (`bun run build --platform ios`, last line must be `[zapp] build complete: …`), (b) the macOS build staying green (`bun run build`), (c) the `#281` iOS symbol-parity lint (`bun test ./cli/src/ios-platform-parity.test.ts`), and (d) a final Simulator screenshot smoke. Treat those as the "tests".
- **Build-success rule:** a build is ONLY successful if its last line is `[zapp] build complete: <path>`. Vite's `✓ built in …ms` is NOT success.
- **`bun run build` does NOT type-check.** Not relevant here (no TS changes) but don't rely on it for types.
- **ARC is on** for both macOS and iOS `.m` sources (`-fobjc-arc`, `cli/src/build-config.ts:568`). Use ARC idioms exactly like the macOS `panel.m` (`strong`/`copy` properties, `__bridge` casts, no manual retain/release).
- **Commit discipline:** commit only the files each task names. NEVER stage the pre-existing working-tree dirt: `hello-world/src/main.ts`, `hello-world/src/worker.ts`, `hello-world/zapp.config.ts`, `vendor/bare`, `vendor/txiki.js`, untracked `native/worker/engines/zjs-cross-eval-test.c`. End every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Work on branch `feat/ios-embed-webview` (already created; the spec is already committed there).
- **iOS primitives this plan relies on** (all in `native/platform/ios/window.m`, confirmed present): `ZAPP_MAX_WINDOW_CALLBACKS` (=64), `static UIWindow* zapp_ios_windows[ZAPP_MAX_WINDOW_CALLBACKS]`, `void darwin_window_eval_js(int32_t, const char*)` (line ~232), and `void* darwin_window_get_webview(int32_t)` (line ~225, the pattern Task 1 mirrors).

## File structure

| File | Responsibility | Task |
|---|---|---|
| `native/platform/ios/window.m` | Add `darwin_window_get_by_numeric_id` → returns the `UIWindow` for a numeric id (panel.m's hook to the owner window). | 1 |
| `native/platform/ios/panel.m` | Replace the no-op stub with the full UIKit panel: `ZappIOSPanel`-style class, registry, 11 `darwin_panel_*` functions, delegate/handler/KVO, event emit. | 2 |
| `docs/api-reference.md` | Embedded-webview section: drop "macOS-only", note iOS support + the iOS leak nuance. | 3 |
| `hello-world/src/main.ts` | **Temporary** (cp-backup/restore) auto-create an embed for the Simulator smoke. Not committed. | 4 |

No changes to `native/panel/panel.zc`, `native/app/router.zc`, `cli/src/native.ts` (already lists `ios/panel.m`), `runtime/webview.ts`, `runtime/webview-geometry.ts`, or `bootstrap/webview.ts`.

---

## Task 1: Add `darwin_window_get_by_numeric_id` to iOS window.m

**Files:**
- Modify: `native/platform/ios/window.m` (insert after the existing `darwin_window_get_webview`, ~line 228)

`panel.m` (Task 2) calls `darwin_window_get_by_numeric_id(window_id)` to reach the owner `UIWindow`. macOS defines it in `darwin/window.m`; iOS needs the mirror. It must exist before Task 2 links.

- [ ] **Step 1: Add the function**

Find this existing function in `native/platform/ios/window.m`:

```objc
void* darwin_window_get_webview(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_ios_webviews[numeric_id]) {
        return (__bridge void*)zapp_ios_webviews[numeric_id];
    }
    return NULL;
}
```

Immediately AFTER it, add:

```objc
// Look up the UIWindow for a numeric window id (mirrors macOS
// darwin_window_get_by_numeric_id, which returns the NSWindow). panel.m uses
// this to reach the owner window's rootViewController.view as the host view
// for a child WKWebView.
void* darwin_window_get_by_numeric_id(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_ios_windows[numeric_id]) {
        return (__bridge void*)zapp_ios_windows[numeric_id];
    }
    return NULL;
}
```

- [ ] **Step 2: Verify the iOS build still compiles**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -3`
Expected: last line `[zapp] build complete: …/bin/ios/hello-world.app/hello-world (… KB)` (the new, as-yet-uncalled function compiles cleanly).

- [ ] **Step 3: Verify the iOS symbol-parity lint passes**

Run: `cd /Users/zach/code/zapp && bun test ./cli/src/ios-platform-parity.test.ts 2>&1 | tail -4`
Expected: `… pass`, `0 fail`.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/window.m
git commit -F - <<'EOF'
feat(ios): darwin_window_get_by_numeric_id for panel host lookup

Mirrors the macOS window-layer helper. Returns the UIWindow for a numeric
window id off the existing zapp_ios_windows[] dispatch table; panel.m takes
its rootViewController.view as the host for a child WKWebView.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 2: Implement `ios/panel.m` (full UIKit panel)

**Files:**
- Replace: `native/platform/ios/panel.m` (currently a 24-line stub)

This is a near-1:1 port of `native/platform/darwin/panel.m`. iOS deltas: UIKit/WebKit imports; host view is `window.rootViewController.view` (not `[window contentView]`); **no Y-flip** in `set_bounds` (UIView is top-left origin); a log on missing owner window. Everything else (the `WKWebView`/delegate/handler/KVO/registry/emit) is identical because those WebKit APIs are cross-platform.

- [ ] **Step 1: Replace the file with the full implementation**

Overwrite `native/platform/ios/panel.m` with exactly:

```objc
// iOS embedded-webview ("panel") implementation — pure Objective-C (ARC).
// A panel is a child WKWebView added as a subview of the owner window's
// rootViewController.view, positioned by CSS top-left points (UIView origin
// is top-left, so no coordinate flip — unlike macOS). The TS runtime drives
// it via darwin_panel_* (router -> panel.zc -> here).
//
// V1: sandboxed only. `bridge` and `partition` params are accepted for
// forward-compat but ignored (shared default data store, no __zappBridge).
#import <UIKit/UIKit.h>
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

// Eval `bridge.dispatchPanelEvent(panelId, event, dataJson)` into the owner window.
static void zapp_panel_emit(ZappPanel* p, NSString* event, NSString* dataJson) {
    if (!p) return;
    // dataJson is already JSON; escape backslashes + single-quotes for the JS literal.
    NSString* dataArg = @"undefined";
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
        if (!win_ptr) { NSLog(@"[zapp] panel: owner window %d not available", window_id); return; }
        UIWindow* window = (__bridge UIWindow*)win_ptr;
        UIView* host = window.rootViewController.view;
        if (!host) { NSLog(@"[zapp] panel: owner window %d has no root view", window_id); return; }

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

        WKWebView* wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:config];
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
    zapp_panel_on_main(^{
        // UIView uses a top-left origin, matching the CSS top-left points the
        // runtime emits — so the incoming rect maps directly (no isFlipped
        // branch like macOS).
        [p.webview setFrame:CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h)];
    });
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

// host -> embed structured message. data_json is an already-JSON value (object/
// array/string/null) — itself a valid JS literal. Built on the heap (no fixed
// buffer) so large payloads are never truncated.
void darwin_panel_post_message(const char* panel_id, const char* data_json) {
    ZappPanel* p = zapp_panel_get(panel_id);
    if (!p || !data_json) return;
    NSString* data = [NSString stringWithUTF8String:data_json];
    if (!data) return;
    zapp_panel_on_main(^{
        NSString* js = [NSString stringWithFormat:
            @"window.dispatchEvent(new MessageEvent('message',{data:%@}));", data];
        [p.webview evaluateJavaScript:js completionHandler:nil];
    });
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

- [ ] **Step 2: Verify the iOS build compiles + links**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -3`
Expected: last line `[zapp] build complete: …/bin/ios/hello-world.app/hello-world (… KB)`. (Compiles the new panel.m and links `darwin_window_get_by_numeric_id` from Task 1.)

- [ ] **Step 3: Verify the macOS build is still green (untouched path)**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build 2>&1 | tail -3`
Expected: last line `[zapp] build complete: …/bin/hello-world (… KB)`.

- [ ] **Step 4: Verify the iOS symbol-parity lint passes**

Run: `cd /Users/zach/code/zapp && bun test ./cli/src/ios-platform-parity.test.ts 2>&1 | tail -4`
Expected: `… pass`, `0 fail`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/panel.m
git commit -F - <<'EOF'
feat(ios): real embedded-webview (panel.m) — macOS v1 parity

Port darwin/panel.m to UIKit: a child WKWebView added to the owner window's
rootViewController.view, with the same 11 darwin_panel_* ops + 5 events
(did-navigate, load-finished, load-failed, title-change, message), the
zappPanel message handler, and the zappHost.postMessage shim. Sandboxed-only
(shared default data store; bridge/partition inert). No coordinate flip —
UIView is top-left origin. Events reuse darwin_window_eval_js.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 3: Update api-reference docs

**Files:**
- Modify: `docs/api-reference.md` (the `## Webview (embedded webviews) — macOS` section, ~line 758, and the "Known limitations (v1)" subsection ~line 793)

- [ ] **Step 1: Update the section heading**

Find:

```markdown
## Webview (embedded webviews) — macOS
```

Replace with:

```markdown
## Webview (embedded webviews) — macOS + iOS
```

- [ ] **Step 2: Note iOS support + the iOS leak nuance in the limitations subsection**

Find the "Known limitations (v1)" paragraph (~line 793). Immediately after that paragraph, add a new paragraph:

```markdown
**iOS.** Embedded webviews work on iOS with the same API and the same v1
limitations. One nuance: on iOS the native embed paints above the page (flat
z-order, like macOS), so app sheets/modals/popovers cannot cover an embed —
keep embeds clear of regions you'll overlay with native iOS UI. iPad
multi-window (UIScene) bucketing is a follow-up; iPhone single-window works today.
```

- [ ] **Step 3: Verify the docs render (no broken markdown)**

Run: `cd /Users/zach/code/zapp && grep -n "macOS + iOS" docs/api-reference.md`
Expected: one match on the heading line.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -F - <<'EOF'
docs(api): embedded webviews now macOS + iOS

Drop the macOS-only qualifier and document the iOS flat-z-order nuance
(native embed paints above the page; sheets/modals can't cover it) plus the
iPad-multi-scene follow-up.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 4: iOS Simulator smoke verification

**Files:**
- Temporarily modify (cp-backup/restore, NOT committed): `hello-world/src/main.ts`

Prove the embed actually renders an iframe-blocked site on iOS. Because the embed is normally created by a UI interaction, auto-create one at startup for an automated, reproducible smoke, then restore the file.

- [ ] **Step 1: Confirm a Simulator is booted**

Run: `xcrun simctl list devices booted | grep -i booted || echo "NONE BOOTED"`
Expected: a booted device (e.g. `iPhone 17 Pro … (Booted)`). If none, boot one: `xcrun simctl boot "iPhone 16"` (or any installed device), then re-check.

- [ ] **Step 2: Back up main.ts and append a startup auto-embed**

```bash
cd /Users/zach/code/zapp/hello-world
cp src/main.ts /tmp/main.ts.embed-verify-bak
cat >> src/main.ts <<'EOF'

// [VERIFY-EMBED temp] auto-create an embed at startup pointing at an
// X-Frame-Options:DENY site — proves the native webview loads a site an
// <iframe> can't. Removed after verification.
setTimeout(() => {
  try {
    const el = Webview.create({ src: "https://github.com" });
    el.style.cssText = "position:fixed;left:16px;top:96px;width:320px;height:420px;border:2px solid #4af;z-index:9999";
    document.body.appendChild(el);
  } catch (e) { console.error("[verify-embed]", e); }
}, 800);
EOF
grep -c "VERIFY-EMBED" src/main.ts   # expect 1
```

Note: `Webview` must be imported in `main.ts`. If `grep -n "Webview" src/main.ts` shows no import, add `Webview` to the existing `@zappdev/runtime` import (it already imports `Tray`, `Window`, etc.) before building.

- [ ] **Step 3: Build for the Simulator**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -3`
Expected: last line `[zapp] build complete: …/bin/ios/hello-world.app/hello-world (… KB)`.

- [ ] **Step 4: Install + launch on the booted Simulator**

```bash
cd /Users/zach/code/zapp/hello-world
xcrun simctl uninstall booted com.zapp.helloworld 2>/dev/null
xcrun simctl install booted bin/ios/hello-world.app
xcrun simctl launch booted com.zapp.helloworld
sleep 4
xcrun simctl io booted screenshot /tmp/ios-embed-after.png
```

- [ ] **Step 5: Inspect the screenshot**

Open `/tmp/ios-embed-after.png` (Read tool, or `open /tmp/ios-embed-after.png`).
Expected: a blue-bordered embed box at top-left showing **GitHub's page content** (NOT a blank box / NOT an X-Frame-Options error). That proves the native child `WKWebView` rendered a site an `<iframe>` would refuse. If the box is blank, check `xcrun simctl spawn booted log stream --predicate 'eventMessage CONTAINS "[zapp] panel"' --style compact` (run during launch) for the owner-window log line.

- [ ] **Step 6: Restore main.ts (cp, NOT git checkout — preserves pre-existing WIP)**

```bash
cd /Users/zach/code/zapp/hello-world
cp /tmp/main.ts.embed-verify-bak src/main.ts
grep -c "VERIFY-EMBED" src/main.ts   # expect 0
git status --short src/main.ts        # should show only the pre-existing WIP diff (or nothing new)
```

- [ ] **Step 7: Rebuild clean so bin/ has no temp embed**

Run: `cd /Users/zach/code/zapp/hello-world && bun run build --platform ios 2>&1 | tail -1`
Expected: `[zapp] build complete: …`. (No commit — this task is verification only; nothing of ours is staged.)

---

## After all tasks: finish the branch

Use **superpowers:finishing-a-development-branch**. Before presenting options, verify the suite:

```bash
cd /Users/zach/code/zapp && bun run test:all 2>&1 | tail -6
```
Expected: bun tests pass, native tests pass, `tsc --noEmit` clean.

Then present the merge/PR options. (User's standing rule: commit/merge locally only; do NOT push without an explicit ask.)

---

## Self-review

**1. Spec coverage:**
- Full parity (11 ops + 5 events, sandboxed-only, bridge/partition inert) → Task 2 (the complete file). ✓
- `darwin_window_get_by_numeric_id` helper → Task 1. ✓
- No coordinate flip (UIView top-left) → Task 2 `set_bounds`. ✓
- No deferred panel queue + log-on-missing-window → Task 2 `darwin_panel_create` guards + `NSLog`. ✓
- Event delivery via existing `darwin_window_eval_js` → Task 2 `zapp_panel_emit`. ✓
- Runtime/Zen-C/bootstrap unchanged → no task touches them (stated in File structure). ✓
- Docs (drop macOS-only + iOS nuance) → Task 3. ✓
- Simulator verification against X-Frame-Options site → Task 4. ✓
- iPad/leak-mitigation/bridge-injection deferred → not in any task (correctly out of scope). ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every verify step has an exact command + expected output. ✓

**3. Type/symbol consistency:** `darwin_window_get_by_numeric_id` (Task 1 def) ↔ `extern` decl + call in Task 2 — names/signatures match. `darwin_window_eval_js` and `zapp_ios_windows[]`/`ZAPP_MAX_WINDOW_CALLBACKS` referenced as they exist in `ios/window.m`. All 11 `darwin_panel_*` signatures match the existing stub (so the parity lint and router calls stay valid). ✓
