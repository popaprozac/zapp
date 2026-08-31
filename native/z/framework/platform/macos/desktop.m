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
extern const char *zapp_webview_injection_profile(size_t index);
extern int32_t zapp_webview_injection_phase(size_t index);
extern const unsigned char *zapp_webview_injection_source(size_t index);
extern size_t zapp_webview_injection_source_length(size_t index);
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
@property(nonatomic, assign) BOOL started;
@end

@interface ZAppDesktopHost : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, ZAppDesktopWindowRecord *> *windows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, ZAppDesktopWindowRecord *> *windowsByNativeId;
@property(nonatomic, assign) BOOL smokeMode;
@property(nonatomic, assign) int32_t result;
- (int32_t)run;
- (void)stopIfLastWindowClosed;
- (void)closeAllWindows;
- (void)deliverPayload:(NSString *)payload
             requestId:(uint64_t)requestId
                    ok:(BOOL)ok
              windowId:(int32_t)windowId;
@end

@implementation ZAppDesktopWindowRecord
@end

@implementation ZAppDesktopBridge

+ (NSUInteger)embeddedAssetCount {
  return zapp_desktop_assets_count;
}

+ (nullable NSString *)embeddedAssetPathAtIndex:(NSUInteger)index {
  if (index >= zapp_desktop_assets_count) return nil;
  return [NSString stringWithUTF8String:zapp_desktop_assets[index].path];
}

+ (nullable NSData *)embeddedAssetDataAtIndex:(NSUInteger)index {
  if (index >= zapp_desktop_assets_count) return nil;
  const ZAppDesktopAsset *asset = &zapp_desktop_assets[index];
  if (!asset->is_brotli) {
    return [NSData dataWithBytesNoCopy:(void *)asset->data
                               length:asset->length
                         freeWhenDone:NO];
  }
  if (asset->original_length == 0) return [NSData data];
  uint8_t *decoded = malloc(asset->original_length);
  if (decoded == NULL) return nil;
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
    return nil;
  }
  return [NSData dataWithBytesNoCopy:decoded length:length freeWhenDone:YES];
}

+ (nullable NSString *)webViewBootstrapScript {
  const char *source = zapp_webview_bootstrap_script();
  return source == NULL ? nil : [NSString stringWithUTF8String:source];
}

+ (nullable NSString *)webViewFrontendOrigin {
  const char *source = zapp_desktop_frontend_origin();
  return source == NULL ? nil : [NSString stringWithUTF8String:source];
}

+ (NSUInteger)webViewInjectionCount {
  return zapp_webview_injection_count();
}

+ (nullable NSString *)webViewInjectionProfileAtIndex:(NSUInteger)index {
  const char *profile = zapp_webview_injection_profile(index);
  return profile == NULL ? nil : [NSString stringWithUTF8String:profile];
}

+ (int32_t)webViewInjectionPhaseAtIndex:(NSUInteger)index {
  return zapp_webview_injection_phase(index);
}

+ (nullable NSString *)webViewInjectionSourceAtIndex:(NSUInteger)index {
  const unsigned char *source = zapp_webview_injection_source(index);
  size_t length = zapp_webview_injection_source_length(index);
  if (source == NULL) return nil;
  return [[NSString alloc] initWithBytes:source
                                  length:length
                                encoding:NSUTF8StringEncoding];
}

+ (BOOL)smokeMode {
  return prepared_host != nil && prepared_host.smokeMode;
}

+ (void)setResult:(int32_t)result {
  if (prepared_host != nil) prepared_host.result = result;
}

+ (void)failURLSchemeTask:(id<WKURLSchemeTask>)task
                   status:(NSInteger)status
                  message:(NSString *)message {
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

+ (void)attachWindow:(NSWindow *)window
            nativeId:(int32_t)nativeId
             webView:(WKWebView *)webView
   contentController:(WKUserContentController *)contentController {
  ZAppDesktopHost *host = prepared_host;
  if (host == nil) return;
  ZAppDesktopWindowRecord *record = host.windowsByNativeId[@(nativeId)];
  if (record == nil || record.window != nil) return;
  record.window = window;
  record.webView = webView;
  record.userContentController = contentController;
}

+ (void)detachWindow:(NSWindow *)window nativeId:(int32_t)nativeId {
  ZAppDesktopHost *host = prepared_host;
  if (host == nil) return;
  ZAppDesktopWindowRecord *record = host.windowsByNativeId[@(nativeId)];
  if (record == nil || record.window != window) return;
  record.window.delegate = nil;
  [host.windows removeObjectForKey:record.windowId];
  [host.windowsByNativeId removeObjectForKey:@(nativeId)];
  [host stopIfLastWindowClosed];
}

+ (uint32_t)contentWidth:(NSWindow *)window {
  CGFloat width = window.contentView.bounds.size.width;
  if (width <= 0.0) return 0;
  if (width >= (CGFloat)UINT32_MAX) return UINT32_MAX;
  return (uint32_t)width;
}

+ (uint32_t)contentHeight:(NSWindow *)window {
  CGFloat height = window.contentView.bounds.size.height;
  if (height <= 0.0) return 0;
  if (height >= (CGFloat)UINT32_MAX) return UINT32_MAX;
  return (uint32_t)height;
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

int32_t zapp_desktop_window_configure(
  const char *window_id,
  int32_t native_id
) {
  if (prepared_host == nil) return 1;
  NSString *identifier = window_id == NULL
    ? nil
    : [NSString stringWithUTF8String:window_id];
  if (identifier == nil || prepared_host.windows[identifier] != nil) return 2;
  if (prepared_host.windowsByNativeId[@(native_id)] != nil) return 3;
  ZAppDesktopWindowRecord *record = [[ZAppDesktopWindowRecord alloc] init];
  record.windowId = identifier;
  record.nativeId = native_id;
  prepared_host.windows[identifier] = record;
  prepared_host.windowsByNativeId[@(native_id)] = record;
  return 0;
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

int32_t zapp_desktop_window_start(const char *window_id) {
  ZAppDesktopWindowRecord *record = zapp_desktop_window_record(window_id);
  if (record == nil) return 1;
  if (record.started) return 2;

  if (prepared_host.smokeMode) {
    WKUserScript *smoke = [[WKUserScript alloc]
      initWithSource:
        @"setTimeout(()=>document.querySelector('#cancel')?.click(),350);"
      injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
      forMainFrameOnly:YES];
    [record.userContentController addUserScript:smoke];
  }

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
  [prepared_host.windows removeObjectForKey:record.windowId];
  [prepared_host.windowsByNativeId removeObjectForKey:@(record.nativeId)];
  [record.window close];
}

@implementation ZAppDesktopHost

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

- (int32_t)run {
  NSApplication *application = NSApplication.sharedApplication;
  [application setActivationPolicy:NSApplicationActivationPolicyRegular];
  if (self.windows.count == 0) return 49;
  [application activate];
  [application run];
  for (ZAppDesktopWindowRecord *record in self.windows.allValues) {
    record.window.delegate = nil;
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
