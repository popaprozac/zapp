#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <compression.h>

#import "zapp_desktop.h"

#ifndef ZAPP_DESKTOP_SMOKE_SUPPORT
#define ZAPP_DESKTOP_SMOKE_SUPPORT 0
#endif

#if ZAPP_DESKTOP_SMOKE_SUPPORT
#import "desktop-smoke.h"
#endif

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
static ZAppDesktopHost *prepared_host = nil;

@interface ZAppDesktopHost : NSObject
@property(nonatomic, assign) BOOL smokeMode;
@property(nonatomic, assign) int32_t result;
- (int32_t)run;
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

+ (void)evaluateJavaScript:(NSString *)script
                 inWebView:(WKWebView *)webView
                 forWindow:(NSWindow *)window
                  nativeId:(int32_t)nativeId
                   payload:(NSString *)payload
                 requestId:(uint64_t)requestId
         activeWindowCount:(NSUInteger)activeWindowCount
                        ok:(BOOL)ok {
  [webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
    (void)value;
    if (error != nil) {
      [ZAppDesktopBridge setResult:45];
      [window close];
      return;
    }
#if ZAPP_DESKTOP_SMOKE_SUPPORT
    zapp_desktop_smoke_observe_response(
      webView,
      nativeId,
      activeWindowCount,
      payload,
      requestId,
      ok
    );
#else
    (void)nativeId;
    (void)payload;
    (void)requestId;
    (void)activeWindowCount;
    (void)ok;
#endif
  }];
}

+ (void)startWindowSmokeSupport:(NSString *)windowId
                       nativeId:(int32_t)nativeId
                        webView:(WKWebView *)webView
              contentController:(WKUserContentController *)contentController {
#if ZAPP_DESKTOP_SMOKE_SUPPORT
  if (![self smokeMode]) return;
  zapp_desktop_smoke_start_window(
    webView,
    contentController,
    windowId,
    nativeId
  );
#else
  (void)windowId;
  (void)nativeId;
  (void)webView;
  (void)contentController;
#endif
}

+ (void)stopRunLoop {
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

NSRect zapp_desktop_make_rect(uint32_t width, uint32_t height) {
  return NSMakeRect(0.0, 0.0, (CGFloat)width, (CGFloat)height);
}

@implementation ZAppDesktopHost

- (instancetype)init {
  self = [super init];
  if (self != nil) {
#if ZAPP_DESKTOP_SMOKE_SUPPORT
    const char *smoke = getenv("ZAPP_Z_DESKTOP_SMOKE");
    _smokeMode = smoke != NULL && strcmp(smoke, "1") == 0;
    _result = _smokeMode ? 41 : 0;
#else
    _smokeMode = NO;
    _result = 0;
#endif
  }
  return self;
}

- (int32_t)run {
  NSApplication *application = NSApplication.sharedApplication;
  [application setActivationPolicy:NSApplicationActivationPolicyRegular];
  [application activate];
  [application run];
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
    if (prepared_host == nil) return;
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
