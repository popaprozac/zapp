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

@implementation ZAppDesktopBridge (WebView)

+ (void)evaluateJavaScript:(NSString *)script
                 inWebView:(WKWebView *)webView
                 forWindow:(NSWindow *)window
                  nativeId:(int32_t)nativeId
                   payload:(NSString *)payload
                 requestId:(uint64_t)requestId
         activeWindowCount:(NSUInteger)activeWindowCount
               development:(BOOL)development
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
      development,
      ok
    );
#else
    (void)nativeId;
    (void)payload;
    (void)requestId;
    (void)activeWindowCount;
    (void)development;
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
