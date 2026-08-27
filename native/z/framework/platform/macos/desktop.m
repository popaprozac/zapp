#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <compression.h>

#include "zapp_router.h"
#import "zapp_desktop.h"

#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const char *zapp_webview_bootstrap_script(void);
extern const char *zapp_desktop_frontend_origin(void);

typedef struct {
  const char *path;
  const uint8_t *data;
  size_t length;
  size_t original_length;
  int is_brotli;
} ZAppDesktopAsset;

extern const ZAppDesktopAsset zapp_desktop_assets[];
extern const size_t zapp_desktop_assets_count;

@class ZAppDesktopHost;

static __weak ZAppDesktopHost *active_host = nil;
static ZAppDesktopHost *prepared_host = nil;

@interface ZAppDesktopHost : NSObject <NSWindowDelegate, WKNavigationDelegate>
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, weak) WKWebView *webView;
@property(nonatomic, weak) WKUserContentController *userContentController;
@property(nonatomic, strong) id<WKURLSchemeHandler> assetSchemeHandler;
@property(nonatomic, assign) BOOL receivedResponse;
@property(nonatomic, assign) BOOL smokeMode;
@property(nonatomic, assign) BOOL windowVisible;
@property(nonatomic, copy) NSString *logicalURL;
@property(nonatomic, assign) int32_t result;
- (int32_t)run;
- (void)deliverPayload:(NSString *)payload
             requestId:(uint64_t)requestId
                    ok:(BOOL)ok
              windowId:(int32_t)windowId;
@end

static NSString *zapp_desktop_mime_type(NSString *path) {
  static NSDictionary<NSString *, NSString *> *types;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    types = @{
      @"html": @"text/html",
      @"css": @"text/css",
      @"js": @"text/javascript",
      @"mjs": @"text/javascript",
      @"json": @"application/json",
      @"svg": @"image/svg+xml",
      @"png": @"image/png",
      @"jpg": @"image/jpeg",
      @"jpeg": @"image/jpeg",
      @"gif": @"image/gif",
      @"webp": @"image/webp",
      @"ico": @"image/x-icon",
      @"woff": @"font/woff",
      @"woff2": @"font/woff2",
      @"ttf": @"font/ttf",
      @"wasm": @"application/wasm",
    };
  });
  return types[path.pathExtension.lowercaseString]
    ?: @"application/octet-stream";
}

static const ZAppDesktopAsset *zapp_desktop_asset(NSString *path) {
  const char *requested = path.UTF8String;
  if (requested == NULL) return NULL;
  for (size_t index = 0; index < zapp_desktop_assets_count; index++) {
    if (strcmp(zapp_desktop_assets[index].path, requested) == 0) {
      return &zapp_desktop_assets[index];
    }
  }
  return NULL;
}

static void zapp_desktop_scheme_error(
  id<WKURLSchemeTask> task,
  NSInteger status,
  NSString *message
) {
  fprintf(
    stderr,
    "[zapp] frontend request failed status=%ld url=%s: %s\n",
    (long)status,
    task.request.URL.absoluteString.UTF8String ?: "<invalid>",
    message.UTF8String ?: "<unknown>"
  );
  NSError *error = [NSError
    errorWithDomain:@"com.zapp.frontend"
    code:status
    userInfo:@{NSLocalizedDescriptionKey: message}];
  [task didFailWithError:error];
}

@interface ZAppDesktopAssetSchemeHandler : NSObject <WKURLSchemeHandler>
@end

@implementation ZAppDesktopAssetSchemeHandler

- (void)webView:(WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)webView;
  NSURL *url = task.request.URL;
  if (![url.scheme isEqualToString:@"zapp"] || ![url.host isEqualToString:@"app"]) {
    zapp_desktop_scheme_error(task, 403, @"Forbidden application origin");
    return;
  }

  NSString *path = url.path.length == 0 ? @"/" : url.path;
  NSArray<NSString *> *components = path.pathComponents;
  if ([components containsObject:@".."] || [components containsObject:@"."]) {
    zapp_desktop_scheme_error(task, 403, @"Forbidden asset path");
    return;
  }
  if ([path isEqualToString:@"/"]) path = @"/index.html";

  const ZAppDesktopAsset *asset = zapp_desktop_asset(path);
  if (asset == NULL && path.pathExtension.length == 0) {
    // Application routes resolve through the frontend entry while concrete
    // asset paths remain honest 404s.
    path = @"/index.html";
    asset = zapp_desktop_asset(path);
  }
  if (asset == NULL) {
    zapp_desktop_scheme_error(task, 404, @"Asset not found");
    return;
  }

  NSData *data = nil;
  if (asset->is_brotli) {
    if (asset->original_length == 0) {
      data = [NSData data];
    } else {
      uint8_t *decoded = malloc(asset->original_length);
      if (decoded == NULL) {
        zapp_desktop_scheme_error(task, 500, @"Could not allocate asset buffer");
        return;
      }
      size_t length = compression_decode_buffer(
        decoded,
        asset->original_length,
        asset->data,
        asset->length,
        NULL,
        COMPRESSION_BROTLI
      );
      if (length != asset->original_length) {
        free(decoded);
        zapp_desktop_scheme_error(task, 500, @"Could not decode embedded asset");
        return;
      }
      data = [NSData dataWithBytesNoCopy:decoded length:length freeWhenDone:YES];
    }
  } else {
    data = [NSData dataWithBytesNoCopy:(void *)asset->data
                                length:asset->length
                          freeWhenDone:NO];
  }

  NSString *mimeType = zapp_desktop_mime_type(path);
  NSString *encoding = (
    [mimeType hasPrefix:@"text/"]
    || [mimeType isEqualToString:@"application/json"]
  ) ? @"utf-8" : nil;
  NSURLResponse *response = [[NSURLResponse alloc]
    initWithURL:url
    MIMEType:mimeType
    expectedContentLength:(NSInteger)data.length
    textEncodingName:encoding];
  [task didReceiveResponse:response];
  [task didReceiveData:data];
  [task didFinish];
}

- (void)webView:(WKWebView *)webView
    stopURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)webView;
  (void)task;
}

@end

@interface ZAppDesktopRegistrationOwner ()
@property(nonatomic, strong) WKUserContentController *contentController;
@end

@implementation ZAppDesktopRegistrationOwner

- (instancetype)initWithContentController:(WKUserContentController *)controller {
  self = [super init];
  if (self != nil) _contentController = controller;
  return self;
}

- (void)addHandler:(id<WKScriptMessageHandler>)handler {
  [self.contentController addScriptMessageHandler:handler name:@"zapp"];
}

- (void)removeHandler {
  [self.contentController removeScriptMessageHandlerForName:@"zapp"];
}

@end

@implementation ZAppDesktopBridge

+ (void)configureWebViewConfiguration:(WKWebViewConfiguration *)configuration {
  ZAppDesktopAssetSchemeHandler *handler = [[ZAppDesktopAssetSchemeHandler alloc] init];
  [configuration setURLSchemeHandler:handler forURLScheme:@"zapp"];
  ZAppDesktopHost *host = active_host != nil ? active_host : prepared_host;
  host.assetSchemeHandler = handler;
}

+ (void)attachWindow:(NSWindow *)window
             webView:(WKWebView *)webView
   contentController:(WKUserContentController *)contentController
             visible:(BOOL)visible {
  ZAppDesktopHost *host = active_host;
  if (host == nil) return;
  host.window = window;
  host.webView = webView;
  host.userContentController = contentController;
  host.windowVisible = visible;
  window.delegate = host;
}

@end

void zapp_deliver_response_from_z(
  const char *payload,
  uint64_t request_id,
  bool ok,
  int32_t window_id
) {
  ZAppDesktopHost *host = active_host;
  if (host == nil) return;
  NSString *text = payload == NULL
    ? @""
    : [NSString stringWithUTF8String:payload];
  if (text == nil) {
    host.result = 44;
    [host.window close];
    return;
  }
  [host deliverPayload:text
             requestId:request_id
                    ok:ok
              windowId:window_id];
}

static ZAppDesktopHost *zapp_desktop_active_window_host(void) {
  return active_host != nil ? active_host : prepared_host;
}

void zapp_desktop_set_logical_url(const char *logical_url) {
  ZAppDesktopHost *host = zapp_desktop_active_window_host();
  NSString *logical = logical_url == NULL
    ? nil
    : [NSString stringWithUTF8String:logical_url];
  host.logicalURL = logical.length == 0 ? @"/" : logical;
}

NSRect zapp_desktop_make_rect(uint32_t width, uint32_t height) {
  return NSMakeRect(0.0, 0.0, (CGFloat)width, (CGFloat)height);
}

void zapp_desktop_window_show(const char *window_id) {
  (void)window_id;
  ZAppDesktopHost *host = zapp_desktop_active_window_host();
  [host.window makeKeyAndOrderFront:nil];
}

void zapp_desktop_window_hide(const char *window_id) {
  (void)window_id;
  ZAppDesktopHost *host = zapp_desktop_active_window_host();
  [host.window orderOut:nil];
}

void zapp_desktop_window_close(const char *window_id) {
  (void)window_id;
  ZAppDesktopHost *host = zapp_desktop_active_window_host();
  [host.window close];
}

void zapp_desktop_window_set_title(
  const char *window_id,
  const char *title
) {
  (void)window_id;
  ZAppDesktopHost *host = zapp_desktop_active_window_host();
  NSString *value = title == NULL
    ? @""
    : [NSString stringWithUTF8String:title];
  if (value != nil) host.window.title = value;
}

static NSURL *zapp_desktop_resolve_logical_url(NSString *logicalURL) {
  NSString *logical = logicalURL.length == 0 ? @"/" : logicalURL;
  NSURLComponents *logicalParts = [NSURLComponents componentsWithString:logical];
  if (logicalParts == nil || logicalParts.scheme != nil || [logical hasPrefix:@"//"]) {
    return nil;
  }

  const char *originBytes = zapp_desktop_frontend_origin();
  NSString *origin = originBytes == NULL
    ? nil
    : [NSString stringWithUTF8String:originBytes];
  NSURL *base = origin == nil ? nil : [NSURL URLWithString:origin];
  if (base == nil) return nil;
  return [[NSURL URLWithString:logical relativeToURL:base] absoluteURL];
}

static BOOL zapp_desktop_has_frontend_origin(NSURL *url) {
  const char *originBytes = zapp_desktop_frontend_origin();
  NSString *originText = originBytes == NULL
    ? nil
    : [NSString stringWithUTF8String:originBytes];
  NSURL *origin = originText == nil ? nil : [NSURL URLWithString:originText];
  if (url == nil || origin == nil) return NO;
  BOOL sameScheme = [url.scheme caseInsensitiveCompare:origin.scheme]
    == NSOrderedSame;
  BOOL sameHost = [url.host caseInsensitiveCompare:origin.host]
    == NSOrderedSame;
  BOOL samePort = (url.port == nil && origin.port == nil)
    || [url.port isEqualToNumber:origin.port];
  return sameScheme && sameHost && samePort;
}

@implementation ZAppDesktopHost

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _receivedResponse = NO;
    _windowVisible = YES;
    const char *smoke = getenv("ZAPP_Z_DESKTOP_SMOKE");
    _smokeMode = smoke != NULL && strcmp(smoke, "1") == 0;
    _result = _smokeMode ? 41 : 0;
  }
  return self;
}

- (void)deliverPayload:(NSString *)payload
             requestId:(uint64_t)requestId
                    ok:(BOOL)ok
              windowId:(int32_t)windowId {
  NSDictionary *response = @{
    @"id": [NSString stringWithFormat:@"%llu", (unsigned long long)requestId],
    @"ok": @(ok),
    @"payload": payload,
  };
  NSError *serializationError = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:response
                                                 options:0
                                                   error:&serializationError];
  if (data == nil || serializationError != nil) {
    self.result = 43;
    [self.window close];
    return;
  }
  NSString *json = [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
  NSString *script = [NSString stringWithFormat:
    @"(()=>{const r=%@;const b=globalThis[Symbol.for('zapp.bridge')];"
    @"if(!b||typeof b._onInvokeResult!=='function'){"
    @"throw new Error('Zapp bridge is unavailable')}"
    @"b._onInvokeResult(Number(r.id),r.ok,r.payload)})()",
    json];
  __weak ZAppDesktopHost *weakSelf = self;
  [self.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
    (void)value;
    ZAppDesktopHost *strongSelf = weakSelf;
    if (strongSelf == nil) return;
    if (error != nil) {
      strongSelf.result = 45;
      [strongSelf.window close];
      return;
    }
    // Everything below is automated smoke-test instrumentation. Interactive
    // applications own their DOM and lifetime; a partially completed demo
    // scenario must never cause the native host to close their window.
    if (!strongSelf.smokeMode) return;
    if (requestId == 1) {
      printf(
        "cancelled WebView response ignored request=%llu\n",
        (unsigned long long)requestId
      );
      fflush(stdout);
      return;
    }

    dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
      dispatch_get_main_queue(),
      ^{
        [strongSelf.webView
          evaluateJavaScript:
            @"JSON.stringify({"
            @"roundTrip:document.body?.dataset?.roundTrip??null,"
            @"cancellation:document.body?.dataset?.cancellation??null,"
            @"health:document.body?.dataset?.health??null,"
            @"hmr:document.body?.dataset?.hmr??null,"
            @"status:document.querySelector('#status')?.textContent??null,"
            @"bridge:typeof globalThis[Symbol.for('zapp.bridge')]"
            @"})"
          completionHandler:^(id state, NSError *stateError) {
            const char *frontendOrigin = zapp_desktop_frontend_origin();
            BOOL development = frontendOrigin != NULL
              && (strncmp(frontendOrigin, "http://", 7) == 0
                || strncmp(frontendOrigin, "https://", 8) == 0);
            NSString *expectedHMR = development
              ? @"\"hmr\":\"ready\""
              : @"\"hmr\":\"packaged\"";
            BOOL updated = [state isKindOfClass:[NSString class]]
              && [(NSString *)state containsString:@"\"roundTrip\":\"ok\""]
              && [(NSString *)state containsString:@"\"cancellation\":\"ok\""]
              && [(NSString *)state containsString:@"\"health\":\"ok\""]
              && [(NSString *)state containsString:expectedHMR];
            if (stateError != nil || !updated) {
              const char *stateText = state == nil
                ? "<nil>"
                : [[state description] UTF8String];
              const char *errorText = stateError == nil
                ? "<none>"
                : [[stateError description] UTF8String];
              fprintf(
                stderr,
                "WebView DOM verification failed: state=%s error=%s\n",
                stateText,
                errorText
              );
              strongSelf.result = 47;
              [strongSelf.window close];
              return;
            }
            strongSelf.receivedResponse = YES;
            strongSelf.result = 0;
            printf(
              "visible WebView round trip window=%d request=%llu ok=%s hmr=%s payload=%s\n",
              windowId,
              (unsigned long long)requestId,
              ok ? "true" : "false",
              development ? "ready" : "packaged",
              payload.UTF8String
            );
            fflush(stdout);
            if (strongSelf.smokeMode) {
              dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                dispatch_get_main_queue(),
                ^{
                  [strongSelf.window close];
                }
              );
            }
          }];
      }
    );
  }];
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  [NSApp stop:nil];
  NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                     location:NSMakePoint(0.0, 0.0)
                                modifierFlags:0
                                    timestamp:0.0
                                 windowNumber:0
                                      context:nil
                                      subtype:0
                                        data1:0
                                        data2:0];
  [NSApp postEvent:wake atStart:YES];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
    withError:(NSError *)error {
  (void)webView;
  (void)navigation;
  fprintf(
    stderr,
    "[zapp] frontend navigation failed before commit: %s\n",
    error.description.UTF8String ?: "<unknown>"
  );
  if (self.smokeMode) {
    self.result = 54;
    [self.window close];
  }
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
    withError:(NSError *)error {
  (void)webView;
  (void)navigation;
  fprintf(
    stderr,
    "[zapp] frontend navigation failed after commit: %s\n",
    error.description.UTF8String ?: "<unknown>"
  );
  if (self.smokeMode) {
    self.result = 55;
    [self.window close];
  }
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  (void)webView;
  WKFrameInfo *target = navigationAction.targetFrame;
  if (target != nil && !target.mainFrame) {
    decisionHandler(WKNavigationActionPolicyAllow);
    return;
  }
  NSURL *url = navigationAction.request.URL;
  if (target != nil && zapp_desktop_has_frontend_origin(url)) {
    decisionHandler(WKNavigationActionPolicyAllow);
    return;
  }
  fprintf(
    stderr,
    "[zapp] blocked navigation outside the application origin: %s\n",
    url.absoluteString.UTF8String ?: "<invalid>"
  );
  decisionHandler(WKNavigationActionPolicyCancel);
}

- (int32_t)run {
  NSApplication *application = NSApplication.sharedApplication;
  [application setActivationPolicy:NSApplicationActivationPolicyRegular];

  if (
    self.window == nil
    || self.webView == nil
    || self.userContentController == nil
  ) {
    self.result = 49;
    return self.result;
  }

  const char *bootstrapBytes = zapp_webview_bootstrap_script();
  NSString *bootstrapSource = bootstrapBytes == NULL
    ? nil
    : [NSString stringWithUTF8String:bootstrapBytes];
  if (bootstrapSource == nil) {
    self.result = 48;
    return self.result;
  }
  WKUserScript *bootstrap = [[WKUserScript alloc]
    initWithSource:bootstrapSource
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:YES];
  [self.userContentController addUserScript:bootstrap];

  if (self.smokeMode) {
    WKUserScript *smoke = [[WKUserScript alloc]
      initWithSource:
        @"setTimeout(()=>document.querySelector('#cancel')?.click(),350);"
      injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
      forMainFrameOnly:YES];
    [self.userContentController addUserScript:smoke];
  }

  NSURL *initialURL = zapp_desktop_resolve_logical_url(self.logicalURL);
  if (initialURL == nil) {
    self.result = 53;
    return self.result;
  }
  self.webView.navigationDelegate = self;
  [self.webView loadRequest:[NSURLRequest requestWithURL:initialURL]];

  [self.window center];
  if (self.windowVisible) [self.window makeKeyAndOrderFront:nil];
  active_host = self;
  [application activate];
  if (self.smokeMode) {
    __weak ZAppDesktopHost *weakSelf = self;
    dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
      dispatch_get_main_queue(),
      ^{
        ZAppDesktopHost *strongSelf = weakSelf;
        if (strongSelf != nil && !strongSelf.receivedResponse) {
          [strongSelf.webView
            evaluateJavaScript:
              @"JSON.stringify({"
              @"ready:document.readyState,"
              @"services:typeof globalThis.__zappServices,"
              @"bridge:typeof globalThis[Symbol.for('zapp.bridge')],"
              @"cancel:typeof document.querySelector('#cancel')?.onclick,"
              @"status:document.querySelector('#status')?.textContent??null,"
              @"body:document.body?.dataset??null"
              @"})"
            completionHandler:^(id state, NSError *stateError) {
              fprintf(
                stderr,
                "[zapp] frontend smoke timed out state=%s error=%s\n",
                state == nil ? "<nil>" : [[state description] UTF8String],
                stateError == nil ? "<none>" : [[stateError description] UTF8String]
              );
              strongSelf.result = 50;
              [strongSelf.window close];
            }];
        }
      }
    );
  }
  [application run];
  active_host = nil;

  self.window.delegate = nil;
  self.webView.navigationDelegate = nil;
  return self.smokeMode
    ? (self.receivedResponse ? 0 : self.result)
    : self.result;
}

@end

int32_t zapp_desktop_prepare(void) {
  @autoreleasepool {
    if (prepared_host != nil) return 52;
    ZAppDesktopHost *host = [[ZAppDesktopHost alloc] init];
    prepared_host = host;
    active_host = host;
    return 0;
  }
}

int32_t zapp_desktop_run(void) {
  @autoreleasepool {
    ZAppDesktopHost *host = prepared_host;
    if (host == nil) return 51;
    int32_t result = [host run];
    active_host = nil;
    prepared_host = nil;
    return result;
  }
}
