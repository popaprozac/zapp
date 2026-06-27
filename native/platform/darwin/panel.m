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
// Weak ref to the HOST content webview (the one the panel overlays). Used
// by set_bounds to convert the incoming CSS-viewport rect (relative to the
// host webview's top-left) into the panel parent's coordinate space so the
// panel lands correctly even when the host webview is inset (e.g. sidebar).
@property (nonatomic, weak)   WKWebView* hostWebview;
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

        // Capture the host content webview (weak — no retain cycle). Used in
        // set_bounds to convert CSS-viewport coords (host webview space) into
        // the panel-parent's coordinate space so sidebars/inspectors don't
        // cause the panel to bleed over adjacent panes.
        extern void* darwin_window_get_webview(int32_t window_id);
        void* hostWV = darwin_window_get_webview(window_id);
        if (hostWV) panel.hostWebview = (__bridge WKWebView*)hostWV;

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
    zapp_panel_on_main(^{
        // x,y arrive as CSS top-left (viewport) points in the HOST content
        // webview's coordinate space. The panel webview is parented to the
        // window contentView (full-window root), so when the host webview is
        // inset (e.g. by a sidebar), the two spaces differ. Convert via the
        // host webview when available so the panel tracks the element exactly.
        //
        // WKWebView is flipped on macOS (isFlipped=YES, top-left origin),
        // matching CSS. Non-flipped NSViews use bottom-left origin. We check
        // host.isFlipped at runtime so the conversion is robust regardless of
        // any future WKWebView coordinate-system change.
        NSView* parent = p.webview.superview;
        WKWebView* host = p.hostWebview;
        if (host && parent) {
            CGFloat hy = host.isFlipped
                ? (CGFloat)y
                : (host.bounds.size.height - (CGFloat)y - (CGFloat)h);
            NSRect inHost = NSMakeRect((CGFloat)x, hy, (CGFloat)w, (CGFloat)h);
            NSRect inParent = [host convertRect:inHost toView:parent];
            [p.webview setFrame:inParent];
        } else {
            // Fallback: host webview unavailable (full-window embed). Use the
            // parent-relative flip as before.
            CGFloat oy = (CGFloat)y;
            if (parent && !parent.isFlipped) {
                oy = parent.bounds.size.height - (CGFloat)y - (CGFloat)h;
            }
            [p.webview setFrame:NSMakeRect((CGFloat)x, oy, (CGFloat)w, (CGFloat)h)];
        }
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
