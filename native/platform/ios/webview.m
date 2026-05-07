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
#include <libkern/OSAtomic.h>
#include <objc/runtime.h>

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

// --- Custom protocols (G19) — iOS port of darwin's ZappCustomSchemeHandler.
// Same shape: stash the task by request id, fire `__protocol:request` into
// the originating window's JS, wait for the runtime's Protocols.register
// handler to call back via `darwin_protocol_respond`. Tasks are cancellable
// from WebKit (stopURLSchemeTask:) so a late respond becomes a no-op.

extern void darwin_window_eval_js(int32_t window_id, const char* js);

static NSMutableDictionary<NSString*, id<WKURLSchemeTask>>* zapp_ios_protocol_pending = nil;
static int32_t zapp_ios_protocol_request_counter = 0;

@interface ZappIOSCustomSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, copy) NSString* schemeName;
@end

@implementation ZappIOSCustomSchemeHandler
- (void)webView:(WKWebView*)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    if (!zapp_ios_protocol_pending) zapp_ios_protocol_pending = [NSMutableDictionary dictionary];
    int32_t reqId = OSAtomicIncrement32(&zapp_ios_protocol_request_counter);
    NSString* reqIdStr = [NSString stringWithFormat:@"p%d", reqId];
    zapp_ios_protocol_pending[reqIdStr] = task;

    NSDictionary* payload = @{
        @"id":     reqIdStr,
        @"scheme": self.schemeName ?: @"",
        @"url":    [task.request.URL absoluteString] ?: @"",
        @"method": task.request.HTTPMethod ?: @"GET",
    };
    NSData* j = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString* payloadStr = j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
    NSString* escaped = [payloadStr stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];

    int32_t windowId = darwin_window_id_for_webview((__bridge void*)webView);
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        @"if(b&&typeof b._onEvent==='function'){b._onEvent('__protocol:request','%@');}})();",
        escaped];
    darwin_window_eval_js(windowId, [js UTF8String]);
}

- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    (void)webView;
    if (!zapp_ios_protocol_pending) return;
    for (NSString* k in [zapp_ios_protocol_pending allKeys]) {
        if (zapp_ios_protocol_pending[k] == task) {
            [zapp_ios_protocol_pending removeObjectForKey:k];
            break;
        }
    }
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

// --- File drag-drop (G10 port) ---
//
// iOS uses UIDropInteraction (iPadOS-first but iPhone too with split-
// screen / Files app). Same JS event surface as macOS:
//   `file-drop-enter` / `file-drop-over` / `file-drop-leave` / `file-drop`
// with `{ paths: [...], x, y }` payloads scoped to the receiving window.
//
// Caveat that iOS adds: the URLs returned by UIDropSession items are
// security-scoped temp files copied into the app's container. The
// runtime FS allowlist gets each path granted automatically (matching
// dialog-open's behavior); apps should `FS.readFile` synchronously
// from inside the `file-drop` handler since iOS may clean up the temp
// copies once the drop session ends.

extern void darwin_window_eval_js(int32_t window_id, const char* js);

static NSString* zapp_ios_build_drop_payload(NSArray<NSString*>* paths, CGPoint p) {
    NSDictionary* obj = paths
        ? @{ @"paths": paths, @"x": @((int)p.x), @"y": @((int)p.y) }
        : @{ @"x": @((int)p.x), @"y": @((int)p.y) };
    NSData* j = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!j) return @"{}";
    NSString* s = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    s = [s stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    return s;
}

@interface ZappIOSDropDelegate : NSObject <UIDropInteractionDelegate>
@property (nonatomic, assign) NSTimeInterval lastOverTime;
@property (nonatomic, weak) WKWebView* webview;
@end

@implementation ZappIOSDropDelegate

- (void)dispatchEvent:(const char*)name payload:(NSString*)payload {
    if (!self.webview) return;
    int32_t windowId = darwin_window_id_for_webview((__bridge void*)self.webview);
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        @"if(b&&typeof b._onEvent==='function'){b._onEvent('%s','%@');}})();",
        name, payload];
    darwin_window_eval_js(windowId, [js UTF8String]);
}

- (BOOL)dropInteraction:(UIDropInteraction*)interaction canHandleSession:(id<UIDropSession>)session {
    (void)interaction;
    return [session hasItemsConformingToTypeIdentifiers:@[@"public.file-url", @"public.url", @"public.item"]];
}

- (UIDropProposal*)dropInteraction:(UIDropInteraction*)interaction
                  sessionDidUpdate:(id<UIDropSession>)session {
    (void)interaction;
    static const NSTimeInterval kOverMinInterval = 1.0 / 60.0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastOverTime >= kOverMinInterval && self.webview) {
        self.lastOverTime = now;
        CGPoint p = [session locationInView:self.webview];
        [self dispatchEvent:"file-drop-over" payload:zapp_ios_build_drop_payload(nil, p)];
    }
    return [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
}

- (void)dropInteraction:(UIDropInteraction*)interaction sessionDidEnter:(id<UIDropSession>)session {
    (void)interaction;
    if (!self.webview) return;
    CGPoint p = [session locationInView:self.webview];
    [self dispatchEvent:"file-drop-enter" payload:zapp_ios_build_drop_payload(nil, p)];
}

- (void)dropInteraction:(UIDropInteraction*)interaction sessionDidExit:(id<UIDropSession>)session {
    (void)interaction;
    if (!self.webview) return;
    CGPoint p = [session locationInView:self.webview];
    [self dispatchEvent:"file-drop-leave" payload:zapp_ios_build_drop_payload(nil, p)];
}

- (void)dropInteraction:(UIDropInteraction*)interaction performDrop:(id<UIDropSession>)session {
    (void)interaction;
    if (!self.webview) return;
    CGPoint p = [session locationInView:self.webview];
    NSArray<UIDragItem*>* items = session.items;

    __block NSInteger pending = items.count;
    NSMutableArray<NSString*>* paths = [NSMutableArray array];
    void (^maybeFire)(void) = ^{
        if (pending == 0) {
            // Grant the FS allowlist for each path so apps can immediately
            // read them with FS.readFile (iOS hands us security-scoped
            // copies in the app container).
            for (NSString* p2 in paths) {
                extern void fs_grant_path(char*);
                fs_grant_path((char*)[p2 UTF8String]);
            }
            [self dispatchEvent:"file-drop"
                        payload:zapp_ios_build_drop_payload(paths, p)];
        }
    };

    for (UIDragItem* item in items) {
        [item.itemProvider loadFileRepresentationForTypeIdentifier:@"public.item"
            completionHandler:^(NSURL* fileURL, NSError* error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (fileURL && !error) {
                        NSString* path = fileURL.path;
                        if (path) {
                            // iOS deletes the temp file after this callback
                            // returns. Copy it to a stable location inside
                            // the app's tmp dir so reads after the drop
                            // session ends still work.
                            NSString* dest = [NSTemporaryDirectory()
                                stringByAppendingPathComponent:fileURL.lastPathComponent];
                            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
                            NSError* copyErr = nil;
                            [[NSFileManager defaultManager] copyItemAtPath:path toPath:dest error:&copyErr];
                            if (!copyErr) [paths addObject:dest];
                            else [paths addObject:path]; // best-effort
                        }
                    }
                    pending--;
                    maybeFire();
                });
            }];
    }

    if (items.count == 0) {
        [self dispatchEvent:"file-drop"
                    payload:zapp_ios_build_drop_payload(@[], p)];
    }
}
@end

// --- Navigation policy (allowlist + target=_blank → openExternal) ---
//
// Ported from native/platform/darwin/webview.m's ZappNavigationDelegate.
// Same allowlist semantics: built-in schemes + dev-mode localhost +
// user-config patterns (suffix wildcards). Disallowed user-initiated
// link clicks open in the system browser via `[UIApplication openURL:]`.

static NSArray* zapp_ios_cached_allowlist = nil;

static BOOL zapp_ios_is_navigation_allowed(NSURL* url) {
    if (!url) return NO;
    NSString* scheme = [[url scheme] lowercaseString];

    if ([scheme isEqualToString:@"zapp"] || [scheme isEqualToString:@"about"] || [scheme isEqualToString:@"blob"]) {
        return YES;
    }

    if (zapp_build_is_dev()) {
        NSString* host = [url host];
        if (host && ([host isEqualToString:@"localhost"] || [host isEqualToString:@"127.0.0.1"])) {
            return YES;
        }
    }

    if (!zapp_ios_cached_allowlist) {
        const char* json = app_get_allowed_navigation_json();
        if (json && json[0] != '\0') {
            NSData* data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([parsed isKindOfClass:[NSArray class]]) {
                zapp_ios_cached_allowlist = parsed;
            }
        }
        if (!zapp_ios_cached_allowlist) {
            zapp_ios_cached_allowlist = @[];
        }
    }

    NSString* urlStr = [url absoluteString];
    for (NSString* pattern in zapp_ios_cached_allowlist) {
        if ([pattern hasSuffix:@"*"]) {
            NSString* prefix = [pattern substringToIndex:pattern.length - 1];
            if ([urlStr hasPrefix:prefix]) return YES;
        } else {
            if ([urlStr isEqualToString:pattern]) return YES;
        }
    }

    return NO;
}

static void zapp_ios_open_external(NSURL* url) {
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@interface ZappIOSNavDelegate : NSObject <WKNavigationDelegate, WKUIDelegate>
@end

@implementation ZappIOSNavDelegate

- (void)webView:(WKWebView*)webView decidePolicyForNavigationAction:(WKNavigationAction*)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    (void)webView;
    NSURL* url = action.request.URL;

    if (zapp_ios_is_navigation_allowed(url)) {
        handler(WKNavigationActionPolicyAllow);
        return;
    }

    // Blocked — if user-initiated link click, hand off to Safari.
    if (action.navigationType == WKNavigationTypeLinkActivated) {
        zapp_ios_open_external(url);
    }
    handler(WKNavigationActionPolicyCancel);
}

// target="_blank" / window.open() → open in Safari rather than spawning a
// nested WKWebView (we don't have multi-window on iPhone, and even on iPad
// the wedge UX is "external links go to the browser").
- (WKWebView*)webView:(WKWebView*)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration*)config
    forNavigationAction:(WKNavigationAction*)action
    windowFeatures:(WKWindowFeatures*)features {
    (void)webView; (void)config; (void)features;
    zapp_ios_open_external(action.request.URL);
    return nil;
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

    // Custom protocols (G19) — register one ZappIOSCustomSchemeHandler per
    // declared scheme. Mirrors the macOS path; reserved schemes are filtered
    // out by the CLI shape check.
    extern const char* zapp_build_custom_protocols_json(void);
    const char* protosJsonC = zapp_build_custom_protocols_json();
    if (protosJsonC && protosJsonC[0]) {
        NSData* d = [[NSString stringWithUTF8String:protosJsonC]
                       dataUsingEncoding:NSUTF8StringEncoding];
        NSArray* schemes = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([schemes isKindOfClass:[NSArray class]]) {
            for (id s in schemes) {
                if (![s isKindOfClass:[NSString class]]) continue;
                ZappIOSCustomSchemeHandler* h = [[ZappIOSCustomSchemeHandler alloc] init];
                h.schemeName = (NSString*)s;
                @try {
                    [config setURLSchemeHandler:h forURLScheme:(NSString*)s];
                } @catch (NSException* e) {
                    fprintf(stderr,
                        "[zapp] custom protocol '%s' rejected by WebKit (%s) — skipping\n",
                        [(NSString*)s UTF8String], [[e reason] UTF8String]);
                }
            }
        }
    }

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
    // UIDelegate handles target="_blank" / window.open() — without this
    // the createWebViewWithConfiguration: callback never fires.
    webview.UIDelegate = zapp_ios_shared_nav_delegate;

    // File drag-drop (G10 port). Add a UIDropInteraction to the webview
    // — UIPasteConfiguration is a separate concept (system-paste UI),
    // we want the inline drop-on-content flow.
    ZappIOSDropDelegate* dropDelegate = [[ZappIOSDropDelegate alloc] init];
    dropDelegate.webview = webview;
    UIDropInteraction* dropInteraction = [[UIDropInteraction alloc] initWithDelegate:dropDelegate];
    [webview addInteraction:dropInteraction];
    // Keep a strong ref alive on the webview itself via associated object;
    // when webview deallocs, the drop delegate goes too.
    objc_setAssociatedObject(webview, "zapp_ios_drop_delegate",
        dropDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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

// G19 custom protocols — iOS impl. Mirrors darwin's darwin_protocol_respond
// in native/platform/darwin/webview.m. The router calls this when the
// runtime's Protocols.register handler returns; we look up the pending
// task by id and feed it the response. Silent no-op if WebKit cancelled
// the task (stopURLSchemeTask: removed it from the pending map).
void darwin_protocol_respond(const char* request_id, const char* body_base64,
                             const char* content_type, int32_t status) {
    if (!request_id || !zapp_ios_protocol_pending) return;
    NSString* reqIdStr = [NSString stringWithUTF8String:request_id];
    id<WKURLSchemeTask> task = zapp_ios_protocol_pending[reqIdStr];
    if (!task) return;
    [zapp_ios_protocol_pending removeObjectForKey:reqIdStr];

    NSData* body = nil;
    if (body_base64 && body_base64[0]) {
        body = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:body_base64]
                                                   options:NSDataBase64DecodingIgnoreUnknownCharacters];
    }
    NSString* mime = (content_type && content_type[0])
        ? [NSString stringWithUTF8String:content_type]
        : @"application/octet-stream";
    int code = (status > 0) ? (int)status : 200;

    NSDictionary* headers = @{ @"Content-Type": mime,
                               @"Content-Length": [@(body.length) stringValue] };
    NSHTTPURLResponse* response = [[NSHTTPURLResponse alloc]
        initWithURL:task.request.URL statusCode:code HTTPVersion:@"HTTP/1.1"
        headerFields:headers];

    @try {
        [task didReceiveResponse:response];
        if (body) [task didReceiveData:body];
        [task didFinish];
    } @catch (NSException* _) {
        // Task may have been invalidated by WebKit between our removeObjectForKey
        // and didReceive — swallow rather than crash.
    }
}
