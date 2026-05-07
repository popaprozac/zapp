// iOS WKWebView — port of darwin/webview.m. Asset scheme handler and
// message handler are identical (WKURLSchemeHandler / WKScriptMessage-
// Handler are cross-platform WebKit APIs). Window/contentView wiring
// differs: macOS uses NSWindow + NSView, iOS uses UIWindow +
// UIViewController + view.
//
// Phase 1 surface — boot a webview, load assets, ferry bridge
// messages. Phase 2 ports drag regions, modal sheets, and the rest of
// the navigation policy machinery.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Foundation/Foundation.h>
#include <compression.h>
#include <stdint.h>

// Embedded asset struct — local mirror of the layout defined in the
// generated zapp_assets.zc (cli/src/assets.ts). Weak externs let the
// final link succeed even when assets aren't embedded (dev mode).
typedef struct {
    const char* path;
    uint8_t* data;
    int len;
    int uncompressed_len;
    int is_brotli;
} ZappEmbeddedAsset;
extern ZappEmbeddedAsset zapp_embedded_assets[] __attribute__((weak));
extern int zapp_embedded_assets_count __attribute__((weak));

// --- Forward declarations from Zen-C / other .m files ---
extern void* app_get_active(void);
extern const char* zapp_build_initial_url(void);
extern int zapp_build_use_embedded_assets(void);
extern const char* zapp_build_csp(void);
extern const char* app_get_allowed_navigation_json(void);
extern int zapp_build_is_dev(void);
extern const char* zapp_webview_bootstrap_script(void);
extern const char* app_get_bootstrap_name(void);
extern bool app_get_bootstrap_web_content_inspectable(void);
extern bool app_get_bootstrap_application_should_terminate_after_last_window_closed(void);
extern int app_get_bootstrap_max_workers(void);
extern const char* service_get_manifest_json(void);
extern const char* darwin_get_theme(void);
extern const char* darwin_escape_js_string(const char* raw);
extern int32_t darwin_window_id_for_webview(void* webview);
extern void zapp_handle_message_from_window(void* app, char* msg, int32_t window_id);
extern const char* zapp_build_asset_root(void);

// --- MIME type lookup ---

static NSDictionary* zapp_ios_mime_map = nil;

static NSString* zapp_ios_mime_for_path(NSString* path) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        zapp_ios_mime_map = @{
            @"html": @"text/html", @"htm": @"text/html",
            @"css": @"text/css", @"js": @"application/javascript",
            @"mjs": @"application/javascript", @"json": @"application/json",
            @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg",
            @"gif": @"image/gif", @"svg": @"image/svg+xml",
            @"ico": @"image/x-icon", @"woff": @"font/woff",
            @"woff2": @"font/woff2", @"ttf": @"font/ttf",
            @"wasm": @"application/wasm",
        };
    });
    NSString* ext = [[path pathExtension] lowercaseString];
    return zapp_ios_mime_map[ext] ?: @"application/octet-stream";
}

// --- Initial URL + asset root ---

static NSURL* zapp_ios_initial_url(void) {
    const char* configuredUrl = zapp_build_initial_url();
    if (configuredUrl && configuredUrl[0] != '\0') {
        return [NSURL URLWithString:[NSString stringWithUTF8String:configuredUrl]];
    }
    return [NSURL URLWithString:@"zapp://index.html"];
}

static NSString* zapp_ios_asset_root_path(void) {
    const char* configured = zapp_build_asset_root();
    if (configured && configured[0] != '\0') {
        return [NSString stringWithUTF8String:configured];
    }
    NSString* bundleResources = [[NSBundle mainBundle] resourcePath];
    NSString* indexInBundle = [bundleResources stringByAppendingPathComponent:@"index.html"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:indexInBundle]) {
        return bundleResources;
    }
    return @".";
}

// --- Asset Scheme Handler (zapp://) ---

@interface ZappIOSAssetSchemeHandler : NSObject <WKURLSchemeHandler>
@end

@implementation ZappIOSAssetSchemeHandler
- (void)webView:(WKWebView*)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    (void)webView;
    NSURL* url = [task request].URL;
    NSString* host = url.host ?: @"";
    NSString* path = url.path ?: @"/";

    NSString* rel = path;
    if ((rel.length == 0 || [rel isEqualToString:@"/"]) && host.length > 0) {
        rel = [@"/" stringByAppendingString:host];
    }
    if ([rel isEqualToString:@"/"] || rel.length == 0) rel = @"/index.html";
    while ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];

    if ([rel rangeOfString:@".."].location != NSNotFound) {
        NSHTTPURLResponse* forbidden = [[NSHTTPURLResponse alloc]
            initWithURL:url statusCode:403 HTTPVersion:@"HTTP/1.1"
            headerFields:@{ @"Content-Type": @"text/plain" }];
        [task didReceiveResponse:forbidden];
        [task didReceiveData:[@"Forbidden" dataUsingEncoding:NSUTF8StringEncoding]];
        [task didFinish];
        return;
    }

    // Embedded asset lookup (brotli decompression). iOS has libcompression
    // (linked via -lcompression in build-config.ts), same API as macOS.
    if (zapp_build_use_embedded_assets() && &zapp_embedded_assets_count != NULL) {
        NSString* lookupPath = [@"/" stringByAppendingString:rel];
        for (int i = 0; i < zapp_embedded_assets_count; i++) {
            NSString* assetPath = [NSString stringWithUTF8String:zapp_embedded_assets[i].path];
            if ([assetPath isEqualToString:lookupPath]) {
                NSData* assetData;
                if (zapp_embedded_assets[i].is_brotli && zapp_embedded_assets[i].uncompressed_len > 0) {
                    uint8_t* out = malloc(zapp_embedded_assets[i].uncompressed_len);
                    size_t decoded = compression_decode_buffer(
                        out, zapp_embedded_assets[i].uncompressed_len,
                        zapp_embedded_assets[i].data, zapp_embedded_assets[i].len,
                        NULL, COMPRESSION_BROTLI);
                    assetData = [NSData dataWithBytesNoCopy:out length:decoded freeWhenDone:YES];
                } else {
                    assetData = [NSData dataWithBytes:zapp_embedded_assets[i].data
                                              length:zapp_embedded_assets[i].len];
                }
                NSString* mime = zapp_ios_mime_for_path(rel);
                NSHTTPURLResponse* resp = [[NSHTTPURLResponse alloc]
                    initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
                    headerFields:@{ @"Content-Type": mime }];
                [task didReceiveResponse:resp];
                [task didReceiveData:assetData];
                [task didFinish];
                return;
            }
        }
    }

    // Filesystem fallback (dev mode or asset not in embedded table).
    NSString* assetRoot = zapp_ios_asset_root_path();
    NSString* filePath = [assetRoot stringByAppendingPathComponent:rel];
    NSData* data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        NSHTTPURLResponse* notFound = [[NSHTTPURLResponse alloc]
            initWithURL:url statusCode:404 HTTPVersion:@"HTTP/1.1"
            headerFields:@{ @"Content-Type": @"text/plain" }];
        [task didReceiveResponse:notFound];
        [task didReceiveData:[@"Not Found" dataUsingEncoding:NSUTF8StringEncoding]];
        [task didFinish];
        return;
    }

    NSString* mime = zapp_ios_mime_for_path(rel);
    NSHTTPURLResponse* response = [[NSHTTPURLResponse alloc]
        initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{ @"Content-Type": mime, @"Content-Length": [@(data.length) stringValue] }];
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
}

- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    (void)webView; (void)task;
}
@end

// --- Message handler (JS → native bridge) ---

@interface ZappIOSMsgHandler : NSObject <WKScriptMessageHandler>
@end

@implementation ZappIOSMsgHandler
- (void)userContentController:(WKUserContentController*)ucc didReceiveScriptMessage:(WKScriptMessage*)msg {
    (void)ucc;
    id body = [msg body];
    if (![body isKindOfClass:[NSString class]]) return;
    const char* raw_msg = [(NSString*)body UTF8String];
    if (!raw_msg) return;
    int32_t window_id = darwin_window_id_for_webview((__bridge void*)msg.webView);
    void* app_ptr = app_get_active();
    if (app_ptr != NULL) {
        zapp_handle_message_from_window(app_ptr, (char*)raw_msg, window_id);
    }
}
@end

// --- Navigation delegate (minimal — phase 2 ports the full allowlist
//     and target=_blank → openExternal flow) ---

@interface ZappIOSNavDelegate : NSObject <WKNavigationDelegate>
@end

@implementation ZappIOSNavDelegate
- (void)webView:(WKWebView*)webView decidePolicyForNavigationAction:(WKNavigationAction*)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    (void)webView; (void)action;
    handler(WKNavigationActionPolicyAllow);
}
@end

static ZappIOSNavDelegate* zapp_ios_shared_nav_delegate = nil;

// --- WebView creation ---
//
// `darwin_webview_create` matches the macOS signature so app.zc can
// call into it the same way. The window_ptr here is a UIWindow (the
// caller passes its UIWindow*); we attach a UIViewController hosting
// a WKWebView as its rootViewController.

void darwin_webview_create(void* window_ptr, bool inspectable, bool accept_first_mouse,
                           const char* url_override, int32_t numeric_id_pre_alloc,
                           bool transparent_background) {
    (void)accept_first_mouse;       // iOS has no equivalent
    (void)transparent_background;   // iOS vibrancy is a separate model (UIBlurEffect / UIVisualEffectView) — Phase 2
    UIWindow* window = (__bridge UIWindow*)window_ptr;

    WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
    ZappIOSAssetSchemeHandler* schemeHandler = [[ZappIOSAssetSchemeHandler alloc] init];
    [config setURLSchemeHandler:schemeHandler forURLScheme:@"zapp"];

    WKUserContentController* ucc = [[WKUserContentController alloc] init];

    // Bootstrap injection — same scripts the macOS path uses.
    const char* bootstrapName = app_get_bootstrap_name();
    NSString* appName = bootstrapName ? [NSString stringWithUTF8String:bootstrapName] : @"Zapp";
    appName = [NSString stringWithUTF8String:darwin_escape_js_string([appName UTF8String])];
    BOOL terminate = app_get_bootstrap_application_should_terminate_after_last_window_closed();
    BOOL inspect = app_get_bootstrap_web_content_inspectable();
    int maxWorkers = app_get_bootstrap_max_workers();

    NSString* themeStr = [NSString stringWithUTF8String:darwin_get_theme() ?: "light"];

    NSString* configScript = [NSString stringWithFormat:
        @"(function(){globalThis[Symbol.for('zapp.bootstrapConfig')]="
        "{name:'%@',applicationShouldTerminateAfterLastWindowClosed:%@,"
        "webContentInspectable:%@,maxWorkers:%d,theme:'%@'};})();",
        appName, terminate ? @"true" : @"false", inspect ? @"true" : @"false",
        maxWorkers, themeStr];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:configScript
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];

    const char* bindingsRaw = service_get_manifest_json();
    NSString* bindingsJson = [NSString stringWithUTF8String:darwin_escape_js_string(bindingsRaw)];
    NSString* bindingsScript = [NSString stringWithFormat:
        @"(function(){globalThis[Symbol.for('zapp.bindingsManifest')]='%@';})();", bindingsJson];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:bindingsScript
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];

    // Owner + window IDs (windowId baked from the pre-allocated
    // numeric id; iOS materialization passes d->numeric_id through).
    NSString* ownerId = [NSString stringWithFormat:@"owner-%p", window];
    NSString* ownerScript = [NSString stringWithFormat:
        @"(function(){globalThis[Symbol.for('zapp.ownerId')]='%@';})();", ownerId];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:ownerScript
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];

    if (numeric_id_pre_alloc >= 0) {
        NSString* windowIdScript = [NSString stringWithFormat:
            @"(function(){globalThis[Symbol.for('zapp.windowId')]='win-%d';})();",
            numeric_id_pre_alloc];
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:windowIdScript
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }

    const char* bootstrapSrc = zapp_webview_bootstrap_script();
    if (bootstrapSrc) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:[NSString stringWithUTF8String:bootstrapSrc]
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }

    ZappIOSMsgHandler* handler = [[ZappIOSMsgHandler alloc] init];
    [ucc addScriptMessageHandler:handler name:@"zapp"];
    [config setUserContentController:ucc];

    // Use full screen bounds for the initial frame. window.bounds may
    // be CGRectZero pre-UIApplicationMain (windows created from Zen-C
    // app.run() startup before UIApplicationMain takes over);
    // autoresizingMask makes the webview track the eventual window
    // size once display layout happens.
    CGRect initialFrame = UIScreen.mainScreen.bounds;
    WKWebView* webview = [[WKWebView alloc] initWithFrame:initialFrame configuration:config];
    if (@available(iOS 16.4, *)) {
        webview.inspectable = inspectable ? YES : NO;
    }
    webview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    if (!zapp_ios_shared_nav_delegate) {
        zapp_ios_shared_nav_delegate = [[ZappIOSNavDelegate alloc] init];
    }
    webview.navigationDelegate = zapp_ios_shared_nav_delegate;

    NSURL* url = (url_override && url_override[0] != '\0')
        ? [NSURL URLWithString:[NSString stringWithUTF8String:url_override]]
        : zapp_ios_initial_url();
    if (!url) url = zapp_ios_initial_url();
    [webview loadRequest:[NSURLRequest requestWithURL:url]];

    // Add the webview to the window's root view controller. Setting
    // root.view.frame here too — on pre-UIApplicationMain creation,
    // accessing root.view triggers loadView which produces a 0x0 frame;
    // forcing it to screen bounds matches what UIApplicationMain would
    // do once layout starts.
    UIViewController* root = window.rootViewController;
    if (!root) {
        root = [[UIViewController alloc] init];
        window.rootViewController = root;
    }
    root.view.frame = initialFrame;
    [root.view addSubview:webview];

    // Stash for later lookups (window.m's dispatch table).
    extern void zapp_ios_register_webview(void* window_ptr, void* webview_ptr);
    zapp_ios_register_webview(window_ptr, (__bridge void*)webview);
}

// --- JS evaluation ---

void darwin_webview_eval(void* window_ptr, const char* js) {
    if (!window_ptr || !js) return;
    UIWindow* window = (__bridge UIWindow*)window_ptr;
    extern void* zapp_ios_get_webview_for_window(void* window_ptr);
    void* wv_ptr = zapp_ios_get_webview_for_window(window_ptr);
    if (!wv_ptr) return;
    WKWebView* wv = (__bridge WKWebView*)wv_ptr;
    NSString* script = [NSString stringWithUTF8String:js];
    if (!script) return;
    void (^run)(void) = ^{ [wv evaluateJavaScript:script completionHandler:nil]; };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
    (void)window;
}

void darwin_window_load_url(int32_t window_id, const char* url) {
    if (!url) return;
    extern void* darwin_window_get_webview(int32_t numeric_id);
    void* wv_ptr = darwin_window_get_webview(window_id);
    if (!wv_ptr) return;
    WKWebView* wv = (__bridge WKWebView*)wv_ptr;
    NSURL* nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (!nsurl) return;
    void (^run)(void) = ^{ [wv loadRequest:[NSURLRequest requestWithURL:nsurl]]; };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

void darwin_webview_eval_all(const char* js) {
    if (!js) return;
    extern void zapp_ios_eval_js_all_webviews(const char* js);
    zapp_ios_eval_js_all_webviews(js);
}

void darwin_webview_set_drag_region(int32_t window_id, bool drag) {
    (void)window_id; (void)drag;  // no drag regions on iOS — phase 2/3
}

// G19 custom protocols — iOS stub. WKURLSchemeHandler exists on iOS
// (WebKit framework parity with macOS) but the iOS webview module
// doesn't yet wire up scheme registration; this is the matching no-op
// for the router's `__protocol:respond` invoke. Phase 2 follow-up work
// will actually plumb through a ZappCustomSchemeHandler analogous to
// the macOS path.
void darwin_protocol_respond(const char* request_id, const char* body_base64,
                             const char* content_type, int32_t status) {
    (void)request_id; (void)body_base64; (void)content_type; (void)status;
}
