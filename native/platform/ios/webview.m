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

// Synchronous HTTP fetcher used by worker engines on iOS to load worker
// bundles from the Vite dev server in dev mode (the host filesystem
// isn't reachable from inside the Simulator's app sandbox). Returns
// a malloc'd UTF-8 string or NULL; caller frees. Synchronous on
// purpose — this fires once per worker at startup, off the main
// queue (worker thread). Mirrors `[NSData dataWithContentsOfURL:]`
// behavior, including the same lack of timeout — Vite usually
// responds in <100ms so a hard timeout isn't worth the surface.
char* zapp_ios_fetch_url_sync(const char* url_c, int* out_len) {
    if (!url_c || !url_c[0]) return NULL;
    @autoreleasepool {
        NSString* urlStr = [NSString stringWithUTF8String:url_c];
        NSURL* url = [NSURL URLWithString:urlStr];
        if (!url) return NULL;
        NSData* data = [NSData dataWithContentsOfURL:url];
        if (!data) return NULL;
        char* buf = (char*)malloc(data.length + 1);
        if (!buf) return NULL;
        memcpy(buf, data.bytes, data.length);
        buf[data.length] = '\0';
        if (out_len) *out_len = (int)data.length;
        return buf;
    }
}

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
extern const char* zapp_form_factor(void);
extern const char* zapp_webview_bootstrap_script(void);
extern const char* app_get_bootstrap_name(void);
extern bool app_get_bootstrap_web_content_inspectable(void);
extern bool app_get_bootstrap_application_should_terminate_after_last_window_closed(void);
extern int app_get_bootstrap_max_workers(void);
extern const char* service_get_manifest_json(void);
extern const char* permissions_bootstrap_json(void);
extern const char* darwin_get_theme(void);
extern const char* darwin_get_power_state(void);
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

// Resolve a per-window url_override as an RFC 3986 relative-reference against the
// initial URL — so "#sidebar-pane", "?tab=2", "/path", or a bare path work in
// dev (http://...) and prod (zapp://index.html) alike. Mirrors macOS
// zapp_resolve_url (darwin/webview.m). The sidebar/inspector panes pass a bare
// "#..." that MUST resolve against the base, or the pane loads blank (a plain
// [NSURL URLWithString:@"#x"] has no scheme/host → loads nothing).
static NSURL* zapp_ios_resolve_url(const char* url_cstr) {
    if (!url_cstr || url_cstr[0] == '\0') return zapp_ios_initial_url();
    NSString* s = [NSString stringWithUTF8String:url_cstr];
    if (!s) return zapp_ios_initial_url();
    if ([s rangeOfString:@"://"].location != NSNotFound) {
        NSURL* absolute = [NSURL URLWithString:s];
        if (absolute) return absolute;
    }
    NSURL* base = zapp_ios_initial_url();
    NSURL* resolved = [NSURL URLWithString:s relativeToURL:base];
    if (resolved) return [resolved absoluteURL];
    return base;
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

// --- Workaround: WKWebView's drop → paste pipeline ---
//
// WKWebView (specifically WKContentView) installs a pasteConfiguration
// and fulfills only half the contract — UIKit's drop-end synthesizes a
// paste event and walks the responder chain to deliver via either:
//   - `pasteItemProviders:` (private SPI, single-arg) — UIResponder's
//     default throws when pasteConfiguration is non-nil but the method
//     isn't overridden;
//   - `paste:itemProviders:` (public, two-arg) — receives an
//     NSArray<NSItemProvider*> with the actual drop data.
//
// We need both: stub the throwing one to a no-op so the app doesn't
// crash, AND override the public one to dispatch our file-drop event
// (since WKWebView's UIDropInteraction usually claims the session,
// our own UIDropInteraction.performDrop: never fires — but the paste
// fallback does).

extern void darwin_window_eval_js(int32_t window_id, const char* js);

// Forward decl of the iOS drop payload helper.
static NSString* zapp_ios_build_drop_payload(NSArray<NSString*>* paths, CGPoint p);

static void zapp_ios_dispatch_filedrop_from_paste(NSArray<NSItemProvider*>* providers,
                                                  WKWebView* webview, CGPoint p) {
    if (!webview || !providers || providers.count == 0) return;

    int32_t windowId = darwin_window_id_for_webview((__bridge void*)webview);
    if (windowId < 0) return;

    NSMutableArray<NSString*>* paths = [NSMutableArray array];
    __block NSInteger pending = providers.count;
    void (^maybeFire)(void) = ^{
        if (pending != 0) return;
        // Grant the FS allowlist for each path.
        for (NSString* path in paths) {
            extern void fs_grant_path(char*);
            fs_grant_path((char*)[path UTF8String]);
        }
        NSString* payload = zapp_ios_build_drop_payload(paths, p);
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            @"if(b&&typeof b._onEvent==='function'){b._onEvent('file-drop','%@');}})();",
            payload];
        darwin_window_eval_js(windowId, [js UTF8String]);
    };

    for (NSItemProvider* provider in providers) {
        NSArray<NSString*>* registered = provider.registeredTypeIdentifiers;
        NSString* typeId = registered.firstObject ?: @"public.item";

        [provider loadFileRepresentationForTypeIdentifier:typeId
            completionHandler:^(NSURL* fileURL, NSError* error) {
                if (fileURL && !error) {
                    NSString* dest = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:fileURL.lastPathComponent];
                    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
                    NSError* copyErr = nil;
                    [[NSFileManager defaultManager] copyItemAtPath:fileURL.path toPath:dest error:&copyErr];
                    NSString* finalPath = copyErr ? fileURL.path : dest;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (finalPath) [paths addObject:finalPath];
                        pending--;
                        maybeFire();
                    });
                    return;
                }
                [provider loadDataRepresentationForTypeIdentifier:typeId
                    completionHandler:^(NSData* data, NSError* dataError) {
                        NSString* finalPath = nil;
                        if (data && !dataError) {
                            NSString* ext = @"bin";
                            if ([typeId isEqualToString:@"public.jpeg"]) ext = @"jpg";
                            else if ([typeId isEqualToString:@"public.png"]) ext = @"png";
                            else if ([typeId isEqualToString:@"public.heic"]) ext = @"heic";
                            else if ([typeId isEqualToString:@"public.tiff"]) ext = @"tiff";
                            else if ([typeId isEqualToString:@"public.gif"]) ext = @"gif";
                            else if ([typeId hasPrefix:@"public.image"]) ext = @"png";
                            else if ([typeId isEqualToString:@"public.text"]) ext = @"txt";
                            else if ([typeId isEqualToString:@"public.html"]) ext = @"html";
                            else if ([typeId isEqualToString:@"public.pdf"]) ext = @"pdf";
                            NSString* basename = provider.suggestedName ?:
                                [NSString stringWithFormat:@"drop-%lu",
                                    (unsigned long)[NSDate timeIntervalSinceReferenceDate]];
                            if (![[basename pathExtension] length]) {
                                basename = [basename stringByAppendingPathExtension:ext];
                            }
                            NSString* dest = [NSTemporaryDirectory() stringByAppendingPathComponent:basename];
                            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
                            if ([data writeToFile:dest atomically:YES]) {
                                finalPath = dest;
                            }
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (finalPath) [paths addObject:finalPath];
                            pending--;
                            maybeFire();
                        });
                    }];
            }];
    }
}

// Strong ref to the most-recent webview so the swizzled paste handler
// (which fires on a generic responder, not on the webview directly) can
// route file-drop events to the right window. Multi-window iOS (iPad
// scenes) would need per-scene tracking; not a v1 concern.
static WKWebView* zapp_ios_drop_webview = nil;

@interface ZappIOSPasteFix : NSObject
@end
@implementation ZappIOSPasteFix
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // -[UIResponder pasteItemProviders:] is the UIPasteConfiguration-
        // Supporting protocol method: it RECEIVES the dropped/pasted
        // NSItemProviders. UIResponder's default impl throws when
        // pasteConfiguration is non-nil but the method isn't overridden
        // — and WKContentView (WebKit) sets pasteConfiguration without
        // a working override. We replace it on UIResponder with a
        // dispatcher that fires our `file-drop` bridge event when the
        // drop arrives via this path (which is what happens when
        // WKContentView wins the drop session over our own
        // UIDropInteraction). Returns void per the protocol.
        IMP receiveImp = imp_implementationWithBlock(
            ^void(id self_, NSArray<NSItemProvider*>* providers) {
                (void)self_;
                if (zapp_ios_drop_webview && providers.count > 0) {
                    zapp_ios_dispatch_filedrop_from_paste(providers,
                                                          zapp_ios_drop_webview,
                                                          CGPointMake(0, 0));
                }
            });
        class_replaceMethod([UIResponder class],
                            NSSelectorFromString(@"pasteItemProviders:"),
                            receiveImp, "v@:@");
    });
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
    // Be permissive — accept anything the system says is a droppable
    // item. Photos drags are PHAsset-backed and can be flaky with
    // narrower UTI checks. We only need at least one item to bother
    // dispatching.
    return session.items.count > 0;
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
        NSItemProvider* provider = item.itemProvider;
        // Pick the first registered type identifier that looks loadable.
        // Photos items typically register public.jpeg / public.image;
        // Files items register public.item or specific UTIs like
        // public.png. We only really care about getting bytes — try the
        // most-specific registered type rather than a generic.
        NSArray<NSString*>* registered = provider.registeredTypeIdentifiers;
        NSString* typeId = registered.firstObject ?: @"public.item";

        // Try loadFileRepresentation first (works for items already on
        // disk like Files-app drags). If that fails, fall back to
        // loadDataRepresentation (works for in-memory items like
        // Photos).
        [provider loadFileRepresentationForTypeIdentifier:typeId
            completionHandler:^(NSURL* fileURL, NSError* error) {
                if (fileURL && !error) {
                    NSString* dest = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:fileURL.lastPathComponent];
                    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
                    NSError* copyErr = nil;
                    [[NSFileManager defaultManager] copyItemAtPath:fileURL.path toPath:dest error:&copyErr];
                    NSString* finalPath = copyErr ? fileURL.path : dest;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (finalPath) [paths addObject:finalPath];
                        pending--;
                        maybeFire();
                    });
                    return;
                }

                // File-rep failed — try data-rep. Photos PHAsset drags
                // hit this path. Write the data to NSTemporaryDirectory
                // with a guessed extension based on the UTI.
                [provider loadDataRepresentationForTypeIdentifier:typeId
                    completionHandler:^(NSData* data, NSError* dataError) {
                        NSString* finalPath = nil;
                        if (data && !dataError) {
                            // Map common image/data UTIs → extensions.
                            NSString* ext = @"bin";
                            if ([typeId isEqualToString:@"public.jpeg"]) ext = @"jpg";
                            else if ([typeId isEqualToString:@"public.png"]) ext = @"png";
                            else if ([typeId isEqualToString:@"public.heic"]) ext = @"heic";
                            else if ([typeId isEqualToString:@"public.tiff"]) ext = @"tiff";
                            else if ([typeId isEqualToString:@"public.gif"]) ext = @"gif";
                            else if ([typeId hasPrefix:@"public.image"]) ext = @"png";
                            else if ([typeId isEqualToString:@"public.text"]) ext = @"txt";
                            else if ([typeId isEqualToString:@"public.html"]) ext = @"html";
                            else if ([typeId isEqualToString:@"public.pdf"]) ext = @"pdf";

                            NSString* basename = provider.suggestedName ?:
                                [NSString stringWithFormat:@"drop-%lu", (unsigned long)[NSDate timeIntervalSinceReferenceDate]];
                            // Append the extension only if the suggested
                            // name doesn't already carry one.
                            if (![[basename pathExtension] length]) {
                                basename = [basename stringByAppendingPathExtension:ext];
                            }
                            NSString* dest = [NSTemporaryDirectory() stringByAppendingPathComponent:basename];
                            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
                            if ([data writeToFile:dest atomically:YES]) {
                                finalPath = dest;
                            }
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (finalPath) [paths addObject:finalPath];
                            pending--;
                            maybeFire();
                        });
                    }];
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
// `darwin_webview_create_ext` is the iOS port of darwin/webview.m's extended
// entry, matching its signature EXACTLY (param names, order, types) so the
// sidebar/inspector call sites (window.m) and the ios-platform-parity lint
// stay aligned with the macOS contract. The trailing params widen the legacy
// signature without changing behavior at their defaults (NULL / -1 / 0 /
// false / false) — which is how the thin darwin_webview_create delegator
// below calls it. Sidebar/inspector callers pass:
//   - container_view: the UIView* to mount into (a pane's container view),
//     instead of the window's rootViewController.view. NULL = legacy mount.
//   - identity_window_id: the HOST window's numeric id, baked into the
//     Symbol.for('zapp.windowId') JS identity so a pane's runtime reports the
//     host's windowId. TRANSPORT registration stays on numeric_id_pre_alloc;
//     only the JS-visible identity switches. -1 = self identity (legacy).
//   - pane_role: 0 = main pane, 1 = sidebar pane (sets zapp.isSidebar),
//     2 = popover pane (sets zapp.isPopover),
//     3 = inspector pane (sets zapp.isInspector). Document-start markers.
//   - host_has_sidebar: inject zapp.hasSidebar into this pane when true.
//   - host_has_inspector: inject zapp.hasInspector into this pane when true.
//
// The window_ptr here is a UIWindow (the caller passes its UIWindow*); the
// legacy mount path attaches a UIViewController hosting the WKWebView as its
// rootViewController.
//
// iOS-specific notes: accept_first_mouse and transparent_background have no
// iOS equivalent yet (vibrancy is UIBlurEffect/UIVisualEffectView — Phase 2);
// both are accepted to keep the signature identical and ignored via (void).

// N3a: per-route URL identity. routing.m sets this immediately before minting a
// pushed route VC's webview; create_ext consumes it ONCE as a document-start
// zapp.route global so that webview renders its OWN fixed route (not the latest
// broadcast route). Main-thread only; set + consume are synchronous in one call.
static const char* g_pending_route_url = NULL;
void zapp_ios_set_pending_route_url(const char* url) { g_pending_route_url = url; }

void darwin_webview_create_ext(void* window_ptr, bool inspectable, bool accept_first_mouse,
                               const char* url_override, int32_t numeric_id_pre_alloc,
                               bool transparent_background,
                               void* container_view /* UIView*; NULL = legacy mount */,
                               int32_t identity_window_id /* -1 = self identity */,
                               int32_t pane_role,
                               bool host_has_sidebar,
                               bool host_has_inspector) {
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
    // Per-window resolved inspectable — consistent with the native inspector gate.
    BOOL inspect = inspectable;
    int maxWorkers = app_get_bootstrap_max_workers();

    NSString* themeStr = [NSString stringWithUTF8String:darwin_get_theme() ?: "light"];

    // permissions: forward the permissions manifest so the runtime can answer
    // Permissions.query() synchronously and throw PermissionDeniedError on
    // gated fire-and-forget calls without a round-trip to native.
    const char* permsJson = permissions_bootstrap_json();
    if (!permsJson || !permsJson[0]) permsJson = "{\"platform\":\"ios\",\"active\":false,\"allow\":[]}";

    // formFactor: runtime device idiom (iPad → "tablet", else "phone").
    NSString* ffStr = [NSString stringWithUTF8String:zapp_form_factor()];
    NSString* configScript = [NSString stringWithFormat:
        @"(function(){globalThis[Symbol.for('zapp.bootstrapConfig')]="
        "{name:'%@',applicationShouldTerminateAfterLastWindowClosed:%@,"
        "webContentInspectable:%@,maxWorkers:%d,theme:'%@',powerState:%s,"
        "formFactor:'%@',env:'%@',permissions:%s};})();",
        appName, terminate ? @"true" : @"false", inspect ? @"true" : @"false",
        maxWorkers, themeStr, darwin_get_power_state(),
        ffStr, (zapp_build_is_dev() ? @"dev" : @"prod"),
        permsJson];
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

    // JS identity: a pane (sidebar/inspector) webview reports the HOST window's
    // id so its runtime's Window.current() / event filtering resolve to the
    // host, while its TRANSPORT (the dispatch slot it registers under) stays on
    // its own numeric_id_pre_alloc. Only this identity string switches — mirrors
    // darwin/webview.m. -1 identity_window_id = self identity (legacy).
    int32_t identity_id = (identity_window_id >= 0) ? identity_window_id : numeric_id_pre_alloc;
    if (identity_id >= 0) {
        NSString* windowIdScript = [NSString stringWithFormat:
            @"(function(){globalThis[Symbol.for('zapp.windowId')]='win-%d';})();",
            identity_id];
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:windowIdScript
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }

    // zapp.route (N3a): a pushed route VC's webview renders its OWN fixed route
    // and ignores ROUTE_CHANGED — consume the pending url routing.m set just
    // before this call. Document-start so it is visible at the app's first paint.
    if (g_pending_route_url && g_pending_route_url[0]) {
        NSString* routeStr = [NSString stringWithUTF8String:darwin_escape_js_string(g_pending_route_url)];
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            [NSString stringWithFormat:
                @"(function(){globalThis[Symbol.for('zapp.route')]='%@';})();", routeStr]
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
        g_pending_route_url = NULL;   // consume once
    }

    // Pane role marker — lets the runtime branch on the pane type at bootstrap
    // without a round-trip. Mirrors the macOS user-script strings exactly.
    if (pane_role == 1) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isSidebar')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    } else if (pane_role == 2) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isPopover')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    } else if (pane_role == 3) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.isInspector')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }

    // has{Sidebar,Inspector} markers — injected into every pane of a window that
    // has the corresponding accessory, so Window.current() in ANY pane wires the
    // matching handle. Document-start so they survive the real page commit.
    if (host_has_sidebar) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.hasSidebar')]=true;})();"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
    if (host_has_inspector) {
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:
            @"(function(){globalThis[Symbol.for('zapp.hasInspector')]=true;})();"
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

    // --- User-declared webview preferences (zapp.config.ts) ---
    // Tri-state encoding for booleans: getter returns -1 when the
    // user didn't set the field — we leave the WKWebView default
    // untouched in that case. iOS path mirrors darwin/webview.m.
    extern int zapp_build_webview_autoplay_without_user_gesture(void);
    extern int zapp_build_webview_text_interaction_enabled(void);
    extern int zapp_build_webview_minimum_font_size(void);
    {
        int autoplay = zapp_build_webview_autoplay_without_user_gesture();
        if (autoplay == 1) {
            [config setMediaTypesRequiringUserActionForPlayback:WKAudiovisualMediaTypeNone];
        } else if (autoplay == 0) {
            [config setMediaTypesRequiringUserActionForPlayback:WKAudiovisualMediaTypeAll];
        }
        int textIA = zapp_build_webview_text_interaction_enabled();
        if (textIA != -1) {
            WKPreferences* prefs = [config preferences];
            if (@available(iOS 14.5, *)) {
                [prefs setValue:(textIA ? @YES : @NO) forKey:@"textInteractionEnabled"];
            }
        }
        int minFont = zapp_build_webview_minimum_font_size();
        if (minFont >= 0) {
            [[config preferences] setMinimumFontSize:(CGFloat)minFont];
        }
    }

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

    // Back/forward swipe gestures — webview-level, not config-level.
    extern int zapp_build_webview_back_forward_gestures(void);
    {
        int backFwd = zapp_build_webview_back_forward_gestures();
        if (backFwd != -1) {
            webview.allowsBackForwardNavigationGestures = (backFwd ? YES : NO);
        }
    }

    if (!zapp_ios_shared_nav_delegate) {
        zapp_ios_shared_nav_delegate = [[ZappIOSNavDelegate alloc] init];
    }
    webview.navigationDelegate = zapp_ios_shared_nav_delegate;
    // UIDelegate handles target="_blank" / window.open() — without this
    // the createWebViewWithConfiguration: callback never fires.
    webview.UIDelegate = zapp_ios_shared_nav_delegate;

    // Resolve relative refs ("#sidebar-pane", "?tab=2", "/path") against the
    // base URL — a bare [NSURL URLWithString:@"#x"] has no scheme/host and the
    // pane loads blank. (Mirrors macOS zapp_resolve_url.)
    NSURL* url = zapp_ios_resolve_url(url_override);
    [webview loadRequest:[NSURLRequest requestWithURL:url]];

    // Mount: pane path (container_view != NULL) adds the webview into the
    // caller-provided container (a sidebar/inspector pane's view) and fills it
    // via frame + autoresizing, instead of touching the window's
    // rootViewController. The legacy branch below is unchanged: add the webview
    // to the window's root view controller. Setting root.view.frame here too —
    // on pre-UIApplicationMain creation, accessing root.view triggers loadView
    // which produces a 0x0 frame; forcing it to screen bounds matches what
    // UIApplicationMain would do once layout starts.
    if (container_view) {
        UIView* host = (__bridge UIView*)container_view;
        webview.frame = host.bounds;
        webview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:webview];
    } else {
        UIViewController* root = window.rootViewController;
        if (!root) {
            root = [[UIViewController alloc] init];
            window.rootViewController = root;
        }
        root.view.frame = initialFrame;
        [root.view addSubview:webview];
    }

    // File drag-drop (G10 port). WKWebView ships internal
    // UIDropInteractions on WKContentView (private subview) that claim
    // drag sessions via hit-test before parent-view interactions can.
    // canHandleSession on our delegate fires (iOS asks every registered
    // interaction up the chain), but sessionDidEnter goes to whoever
    // wins hit-test — and WKContentView wins. Walk the subview tree
    // and remove any UIDropInteractions WebKit installed; then add
    // our own to the WKWebView so we own the drop session.
    void (^scrubDrops)(UIView*) = ^void(UIView* v) {
        for (id<UIInteraction> ix in [v.interactions copy]) {
            if ([ix isKindOfClass:[UIDropInteraction class]]) {
                [v removeInteraction:ix];
            }
        }
    };
    // Recursive walk via a self-referencing block.
    __block __weak void (^walkRef)(UIView*) = nil;
    void (^walk)(UIView*) = ^void(UIView* v) {
        scrubDrops(v);
        for (UIView* sub in v.subviews) walkRef(sub);
    };
    walkRef = walk;

    // Track this webview as the active drop target. Single-window
    // iPhone makes this trivially correct; iPad multi-scene wedge work
    // can revisit if/when secondary scenes open with their own webview.
    zapp_ios_drop_webview = webview;

    ZappIOSDropDelegate* dropDelegate = [[ZappIOSDropDelegate alloc] init];
    dropDelegate.webview = webview;
    UIDropInteraction* dropInteraction = [[UIDropInteraction alloc] initWithDelegate:dropDelegate];
    [webview addInteraction:dropInteraction];
    objc_setAssociatedObject(webview, "zapp_ios_drop_delegate",
        dropDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // WebKit re-installs UIDropInteractions on WKContentView during
    // layout. Scrub once now and again on next runloop tick (and a
    // third time after a short delay) to catch the late-arriving
    // ones. Repeated scrubs are cheap (no-op when already removed).
    walk(webview);
    dispatch_async(dispatch_get_main_queue(), ^{ walk(webview); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{ walk(webview); });

    // Stash for later lookups (window.m's dispatch table).
    extern void zapp_ios_register_webview(void* window_ptr, void* webview_ptr);
    zapp_ios_register_webview(window_ptr, (__bridge void*)webview);
}

// Legacy entry point — delegates to the ext path with pane params at their
// no-op defaults, so the single-pane behavior is byte-for-byte equivalent.
// Matches the macOS signature so app.zc can call into it the same way.
void darwin_webview_create(void* window_ptr, bool inspectable, bool accept_first_mouse,
                           const char* url_override, int32_t numeric_id_pre_alloc,
                           bool transparent_background) {
    darwin_webview_create_ext(window_ptr, inspectable, accept_first_mouse, url_override,
                              numeric_id_pre_alloc, transparent_background,
                              /*container_view*/NULL, /*identity_window_id*/-1,
                              /*pane_role*/0, /*host_has_sidebar*/false,
                              /*host_has_inspector*/false);
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
