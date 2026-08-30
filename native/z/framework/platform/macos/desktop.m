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
extern size_t zapp_webview_injection_count(void);
extern int32_t zapp_webview_injection_profile_exists(const char *profile);
extern const char *zapp_webview_injection_profile(size_t index);
extern int32_t zapp_webview_injection_phase(size_t index);
extern const unsigned char *zapp_webview_injection_source(size_t index);
extern size_t zapp_webview_injection_source_length(size_t index);
extern void zapp_window_closed_owned(const char *window_id, int32_t native_id);
extern void zapp_window_focused_owned(const char *window_id, int32_t native_id);
extern void zapp_window_blurred_owned(const char *window_id, int32_t native_id);
extern void zapp_window_resized_owned(
  const char *window_id,
  int32_t native_id,
  uint32_t width,
  uint32_t height
);

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
@class ZAppDesktopWindowRecord;

static ZAppDesktopHost *prepared_host = nil;

@interface ZAppDesktopWindowRecord : NSObject
@property(nonatomic, copy) NSString *windowId;
@property(nonatomic, assign) int32_t nativeId;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) WKUserContentController *userContentController;
@property(nonatomic, assign) BOOL receivedResponse;
@property(nonatomic, assign) BOOL windowVisible;
@property(nonatomic, copy) NSString *logicalURL;
@property(nonatomic, strong) NSMutableArray<NSString *> *injectionProfiles;
@property(nonatomic, assign) BOOL started;
@end

@interface ZAppDesktopHost : NSObject <NSWindowDelegate, WKNavigationDelegate>
@property(nonatomic, strong) NSMutableDictionary<NSString *, ZAppDesktopWindowRecord *> *windows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, ZAppDesktopWindowRecord *> *windowsByNativeId;
@property(nonatomic, assign) BOOL smokeMode;
@property(nonatomic, assign) int32_t result;
- (int32_t)run;
- (ZAppDesktopWindowRecord *)recordForWindow:(NSWindow *)window;
- (void)stopIfLastWindowClosed;
- (void)closeAllWindows;
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

@implementation ZAppDesktopAssetSchemeHandler

- (void)installIntoConfiguration:(WKWebViewConfiguration *)configuration {
  [configuration setURLSchemeHandler:self forURLScheme:@"zapp"];
}

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

@implementation ZAppDesktopWindowRecord
@end

@implementation ZAppDesktopBridge

+ (void)attachWindow:(NSWindow *)window
            nativeId:(int32_t)nativeId
             webView:(WKWebView *)webView
   contentController:(WKUserContentController *)contentController
             visible:(BOOL)visible {
  ZAppDesktopHost *host = prepared_host;
  if (host == nil) return;
  ZAppDesktopWindowRecord *record = host.windowsByNativeId[@(nativeId)];
  if (record == nil || record.window != nil) return;
  record.window = window;
  record.webView = webView;
  record.userContentController = contentController;
  record.windowVisible = visible;
  window.delegate = host;
}

@end

void zapp_deliver_response_from_z(
  const char *payload,
  uint64_t request_id,
  bool ok,
  int32_t window_id
) {
  ZAppDesktopHost *host = prepared_host;
  if (host == nil) return;
  ZAppDesktopWindowRecord *record = host.windowsByNativeId[@(window_id)];
  if (record == nil) return;
  NSString *text = payload == NULL
    ? @""
    : [NSString stringWithUTF8String:payload];
  if (text == nil) {
    host.result = 44;
    [record.window close];
    return;
  }
  [host deliverPayload:text
             requestId:request_id
                    ok:ok
              windowId:window_id];
}

int32_t zapp_desktop_has_injection_profile(const char *profile) {
  return zapp_webview_injection_profile_exists(profile);
}

int32_t zapp_desktop_window_configure(
  const char *window_id,
  int32_t native_id,
  const char *logical_url,
  bool visible
) {
  if (prepared_host == nil) return 1;
  NSString *identifier = window_id == NULL
    ? nil
    : [NSString stringWithUTF8String:window_id];
  NSString *logical = logical_url == NULL
    ? nil
    : [NSString stringWithUTF8String:logical_url];
  if (identifier == nil || prepared_host.windows[identifier] != nil) return 2;
  if (prepared_host.windowsByNativeId[@(native_id)] != nil) return 3;
  ZAppDesktopWindowRecord *record = [[ZAppDesktopWindowRecord alloc] init];
  record.windowId = identifier;
  record.nativeId = native_id;
  record.windowVisible = visible;
  record.logicalURL = logical.length == 0 ? @"/" : logical;
  record.injectionProfiles = [[NSMutableArray alloc] init];
  prepared_host.windows[identifier] = record;
  prepared_host.windowsByNativeId[@(native_id)] = record;
  return 0;
}

int32_t zapp_desktop_window_select_injection_profile(
  const char *window_id,
  const char *profile
) {
  ZAppDesktopHost *host = prepared_host;
  if (host == nil) return 3;
  if (!zapp_webview_injection_profile_exists(profile)) return 1;
  NSString *identifier = window_id == NULL
    ? nil
    : [NSString stringWithUTF8String:window_id];
  NSString *name = profile == NULL
    ? nil
    : [NSString stringWithUTF8String:profile];
  if (identifier == nil || name == nil) return 2;
  ZAppDesktopWindowRecord *record = host.windows[identifier];
  if (record == nil) return 4;
  if (![record.injectionProfiles containsObject:name]) {
    [record.injectionProfiles addObject:name];
  }
  return 0;
}

static NSString *zapp_desktop_style_injection(NSString *css) {
  NSError *error = nil;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[css]
                                                     options:0
                                                       error:&error];
  if (jsonData == nil || error != nil) return nil;
  NSString *json = [[NSString alloc] initWithData:jsonData
                                         encoding:NSUTF8StringEncoding];
  if (json == nil) return nil;
  return [NSString stringWithFormat:
    @"(()=>{const css=(%@)[0];const install=()=>{"
    @"const style=document.createElement('style');"
    @"style.setAttribute('data-zapp-injected-style','');"
    @"style.textContent=css;"
    @"(document.head||document.documentElement).appendChild(style)};"
    @"if(document.documentElement)install();"
    @"else document.addEventListener('DOMContentLoaded',install,{once:true})})()",
    json];
}

static BOOL zapp_desktop_install_injection_profiles(
  ZAppDesktopWindowRecord *record
) {
  size_t entryCount = zapp_webview_injection_count();
  for (NSString *selected in record.injectionProfiles) {
    const char *selectedBytes = selected.UTF8String;
    if (selectedBytes == NULL) return NO;
    for (size_t index = 0; index < entryCount; index++) {
      const char *profile = zapp_webview_injection_profile(index);
      if (profile == NULL || strcmp(profile, selectedBytes) != 0) continue;
      const unsigned char *sourceBytes = zapp_webview_injection_source(index);
      size_t sourceLength = zapp_webview_injection_source_length(index);
      if (sourceBytes == NULL) return NO;
      NSString *source = [[NSString alloc] initWithBytes:sourceBytes
                                                 length:sourceLength
                                               encoding:NSUTF8StringEncoding];
      if (source == nil) return NO;
      int32_t phase = zapp_webview_injection_phase(index);
      if (phase == 0) source = zapp_desktop_style_injection(source);
      if (source == nil) return NO;
      WKUserScriptInjectionTime injectionTime = phase == 2
        ? WKUserScriptInjectionTimeAtDocumentEnd
        : WKUserScriptInjectionTimeAtDocumentStart;
      WKUserScript *script = [[WKUserScript alloc]
        initWithSource:source
        injectionTime:injectionTime
        forMainFrameOnly:YES];
      [record.userContentController addUserScript:script];
    }
  }
  return YES;
}

NSRect zapp_desktop_make_rect(uint32_t width, uint32_t height) {
  return NSMakeRect(0.0, 0.0, (CGFloat)width, (CGFloat)height);
}

static ZAppDesktopWindowRecord *zapp_desktop_window_record(
  const char *window_id
) {
  if (prepared_host == nil || window_id == NULL) return nil;
  NSString *identifier = [NSString stringWithUTF8String:window_id];
  return identifier == nil ? nil : prepared_host.windows[identifier];
}

static ZAppDesktopWindowRecord *zapp_desktop_webview_record(
  ZAppDesktopHost *host,
  WKWebView *webView
) {
  for (ZAppDesktopWindowRecord *record in host.windows.allValues) {
    if (record.webView == webView) return record;
  }
  return nil;
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

static NSString *zapp_desktop_window_identity_script(NSString *windowId) {
  NSError *error = nil;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[windowId]
                                                     options:0
                                                       error:&error];
  if (jsonData == nil || error != nil) return nil;
  NSString *json = [[NSString alloc] initWithData:jsonData
                                          encoding:NSUTF8StringEncoding];
  if (json == nil) return nil;
  return [NSString stringWithFormat:
    @"globalThis[Symbol.for('zapp.windowId')]=(%@)[0]", json];
}

int32_t zapp_desktop_window_start(const char *window_id) {
  ZAppDesktopWindowRecord *record = zapp_desktop_window_record(window_id);
  if (record == nil) return 1;
  if (record.started) return 2;

  const char *bootstrapBytes = zapp_webview_bootstrap_script();
  NSString *bootstrapSource = bootstrapBytes == NULL
    ? nil
    : [NSString stringWithUTF8String:bootstrapBytes];
  if (bootstrapSource == nil) return 3;
  WKUserScript *bootstrap = [[WKUserScript alloc]
    initWithSource:bootstrapSource
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:YES];
  [record.userContentController addUserScript:bootstrap];

  NSString *identitySource = zapp_desktop_window_identity_script(record.windowId);
  if (identitySource == nil) return 4;
  WKUserScript *identity = [[WKUserScript alloc]
    initWithSource:identitySource
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:YES];
  [record.userContentController addUserScript:identity];

  if (!zapp_desktop_install_injection_profiles(record)) return 5;

  if (prepared_host.smokeMode) {
    WKUserScript *smoke = [[WKUserScript alloc]
      initWithSource:
        @"setTimeout(()=>document.querySelector('#cancel')?.click(),350);"
      injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
      forMainFrameOnly:YES];
    [record.userContentController addUserScript:smoke];
  }

  NSURL *initialURL = zapp_desktop_resolve_logical_url(record.logicalURL);
  if (initialURL == nil) return 6;
  record.webView.navigationDelegate = prepared_host;
  [record.webView loadRequest:[NSURLRequest requestWithURL:initialURL]];
  [record.window center];
  if (record.windowVisible) [record.window makeKeyAndOrderFront:nil];
  record.started = YES;

  if (prepared_host.smokeMode) {
    __weak ZAppDesktopHost *weakHost = prepared_host;
    __weak ZAppDesktopWindowRecord *weakRecord = record;
    dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
      dispatch_get_main_queue(),
      ^{
        ZAppDesktopHost *host = weakHost;
        ZAppDesktopWindowRecord *current = weakRecord;
        if (host == nil || current == nil || current.receivedResponse) return;
        [current.webView
          evaluateJavaScript:
            @"JSON.stringify({"
            @"ready:document.readyState,"
            @"services:typeof globalThis.__zappServices,"
            @"bridge:typeof globalThis[Symbol.for('zapp.bridge')],"
            @"windowId:globalThis[Symbol.for('zapp.windowId')]??null,"
            @"cancel:typeof document.querySelector('#cancel')?.onclick,"
            @"status:document.querySelector('#status')?.textContent??null,"
            @"body:document.body?.dataset??null"
            @"})"
          completionHandler:^(id state, NSError *stateError) {
            fprintf(
              stderr,
              "[zapp] frontend smoke timed out window=%s state=%s error=%s\n",
              current.windowId.UTF8String,
              state == nil ? "<nil>" : [[state description] UTF8String],
              stateError == nil ? "<none>" : [[stateError description] UTF8String]
            );
            host.result = 50;
            [host closeAllWindows];
          }];
      }
    );
  }
  return 0;
}

void zapp_desktop_window_discard(const char *window_id) {
  ZAppDesktopWindowRecord *record = zapp_desktop_window_record(window_id);
  if (record == nil) return;
  record.window.delegate = nil;
  record.webView.navigationDelegate = nil;
  [prepared_host.windows removeObjectForKey:record.windowId];
  [prepared_host.windowsByNativeId removeObjectForKey:@(record.nativeId)];
  [record.window close];
}

@implementation ZAppDesktopHost

- (ZAppDesktopWindowRecord *)recordForWindow:(NSWindow *)window {
  for (ZAppDesktopWindowRecord *candidate in self.windows.allValues) {
    if (candidate.window == window) return candidate;
  }
  return nil;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _windows = [[NSMutableDictionary alloc] init];
    _windowsByNativeId = [[NSMutableDictionary alloc] init];
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
  ZAppDesktopWindowRecord *record = self.windowsByNativeId[@(windowId)];
  if (record == nil) return;
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
    [record.window close];
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
  [record.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
    (void)value;
    ZAppDesktopHost *strongSelf = weakSelf;
    if (strongSelf == nil) return;
    if (error != nil) {
      strongSelf.result = 45;
      [record.window close];
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
        [record.webView
          evaluateJavaScript:
            @"JSON.stringify({"
            @"roundTrip:document.body?.dataset?.roundTrip??null,"
            @"typedError:document.body?.dataset?.typedError??null,"
            @"cancellation:document.body?.dataset?.cancellation??null,"
            @"health:document.body?.dataset?.health??null,"
            @"hmr:document.body?.dataset?.hmr??null,"
            @"inject:document.body?.dataset?.inject??null,"
            @"dynamicWindow:document.body?.dataset?.dynamicWindow??null,"
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
              && [(NSString *)state containsString:@"\"typedError\":\"ok\""]
              && [(NSString *)state containsString:@"\"cancellation\":\"ok\""]
              && [(NSString *)state containsString:@"\"health\":\"ok\""]
              && [(NSString *)state containsString:@"\"inject\":\"ready\""]
              && [(NSString *)state containsString:@"\"dynamicWindow\":\"ready\""]
              && [(NSString *)state containsString:expectedHMR];
            BOOL terminalFailure = [state isKindOfClass:[NSString class]]
              && (
                [(NSString *)state containsString:@"\"roundTrip\":\"error\""]
                || [(NSString *)state containsString:@"\"cancellation\":\"error\""]
                || [(NSString *)state containsString:@"\"health\":\"error\""]
                || [(NSString *)state containsString:@"\"inject\":\"error\""]
                || [(NSString *)state containsString:@"\"dynamicWindow\":\"error\""]
              );
            // Several legitimate requests may complete while the scripted
            // scenario is still in flight (notably frontend window creation).
            // Leave incomplete state to the per-window watchdog; only a
            // terminal DOM failure should fail the smoke eagerly.
            if (stateError == nil && !updated && !terminalFailure) return;
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
              [record.window close];
              return;
            }
            record.receivedResponse = YES;
            printf(
              "visible WebView round trip window=%d request=%llu ok=%s hmr=%s inject=ready payload=%s\n",
              windowId,
              (unsigned long long)requestId,
              ok ? "true" : "false",
              development ? "ready" : "packaged",
              payload.UTF8String
            );
            fflush(stdout);
            if (strongSelf.smokeMode) {
              BOOL allWindowsResponded = YES;
              for (
                ZAppDesktopWindowRecord *candidate
                in strongSelf.windows.allValues
              ) {
                if (!candidate.receivedResponse) {
                  allWindowsResponded = NO;
                  break;
                }
              }
              if (!allWindowsResponded) return;
              if (strongSelf.result == 41) strongSelf.result = 0;
              dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                dispatch_get_main_queue(),
                ^{
                  [strongSelf closeAllWindows];
                }
              );
            }
          }];
      }
    );
  }];
}

- (void)windowWillClose:(NSNotification *)notification {
  NSWindow *closedWindow = notification.object;
  ZAppDesktopWindowRecord *closedRecord = [self recordForWindow:closedWindow];
  if (closedRecord == nil) return;
  [self.windows removeObjectForKey:closedRecord.windowId];
  [self.windowsByNativeId removeObjectForKey:@(closedRecord.nativeId)];
  closedRecord.webView.navigationDelegate = nil;
  closedRecord.window.delegate = nil;
  zapp_window_closed_owned(
    closedRecord.windowId.UTF8String,
    closedRecord.nativeId
  );
  [self stopIfLastWindowClosed];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  ZAppDesktopWindowRecord *record = [self recordForWindow:notification.object];
  if (record == nil) return;
  zapp_window_focused_owned(record.windowId.UTF8String, record.nativeId);
}

- (void)windowDidResignKey:(NSNotification *)notification {
  ZAppDesktopWindowRecord *record = [self recordForWindow:notification.object];
  if (record == nil) return;
  zapp_window_blurred_owned(record.windowId.UTF8String, record.nativeId);
}

- (void)windowDidResize:(NSNotification *)notification {
  ZAppDesktopWindowRecord *record = [self recordForWindow:notification.object];
  if (record == nil) return;
  NSSize size = record.window.contentView.bounds.size;
  CGFloat width = size.width;
  CGFloat height = size.height;
  uint32_t nativeWidth = width <= 0.0
    ? 0
    : (width >= (CGFloat)UINT32_MAX ? UINT32_MAX : (uint32_t)width);
  uint32_t nativeHeight = height <= 0.0
    ? 0
    : (height >= (CGFloat)UINT32_MAX ? UINT32_MAX : (uint32_t)height);
  zapp_window_resized_owned(
    record.windowId.UTF8String,
    record.nativeId,
    nativeWidth,
    nativeHeight
  );
}

- (void)stopIfLastWindowClosed {
  if (self.windows.count != 0) return;
  dispatch_async(dispatch_get_main_queue(), ^{
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
  });
}

- (void)closeAllWindows {
  NSArray<ZAppDesktopWindowRecord *> *records = self.windows.allValues;
  for (ZAppDesktopWindowRecord *record in records) {
    [record.window close];
  }
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
    [zapp_desktop_webview_record(self, webView).window close];
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
    [zapp_desktop_webview_record(self, webView).window close];
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
  if (self.windows.count == 0) return 49;
  [application activate];
  [application run];
  for (ZAppDesktopWindowRecord *record in self.windows.allValues) {
    record.window.delegate = nil;
    record.webView.navigationDelegate = nil;
  }
  return self.result;
}

@end

int32_t zapp_desktop_prepare(void) {
  @autoreleasepool {
    if (prepared_host != nil) return 52;
    ZAppDesktopHost *host = [[ZAppDesktopHost alloc] init];
    prepared_host = host;
    return 0;
  }
}

void zapp_desktop_abort(void) {
  @autoreleasepool {
    ZAppDesktopHost *host = prepared_host;
    if (host == nil) return;
    NSArray<NSString *> *windowIds = host.windows.allKeys;
    for (NSString *windowId in windowIds) {
      zapp_desktop_window_discard(windowId.UTF8String);
    }
    prepared_host = nil;
  }
}

int32_t zapp_desktop_run(void) {
  @autoreleasepool {
    ZAppDesktopHost *host = prepared_host;
    if (host == nil) return 51;
    int32_t result = [host run];
    prepared_host = nil;
    return result;
  }
}
