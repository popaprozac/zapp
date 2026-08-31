#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

#import "zapp_desktop.h"

#ifndef ZAPP_DESKTOP_SMOKE_SUPPORT
#define ZAPP_DESKTOP_SMOKE_SUPPORT 0
#endif

#if ZAPP_DESKTOP_SMOKE_SUPPORT
#import "desktop-smoke.h"
#endif

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

extern const char *zapp_webview_bootstrap_script(void);
extern const char *zapp_desktop_frontend_origin(void);
extern size_t zapp_webview_injection_count(void);
extern const char *zapp_webview_injection_profile(size_t index);
extern int32_t zapp_webview_injection_phase(size_t index);
extern const unsigned char *zapp_webview_injection_source(size_t index);
extern size_t zapp_webview_injection_source_length(size_t index);

@implementation ZAppDesktopBridge (WebView)

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

@end

NS_ASSUME_NONNULL_END
