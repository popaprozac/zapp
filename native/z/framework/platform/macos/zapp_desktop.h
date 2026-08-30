#pragma once

#import <AppKit/NSWindow.h>
#import <Foundation/NSObject.h>
#import <WebKit/WKScriptMessage.h>
#import <WebKit/WKURLSchemeHandler.h>
#import <WebKit/WKScriptMessageHandler.h>
#import <WebKit/WKUserContentController.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>

#include <stdbool.h>
#include <stdint.h>

int32_t zapp_desktop_run(void);
int32_t zapp_desktop_prepare(void);
void zapp_desktop_abort(void);
NSRect zapp_desktop_make_rect(uint32_t width, uint32_t height);

@interface ZAppDesktopAssetSchemeHandler : NSObject <WKURLSchemeHandler>
- (void)installIntoConfiguration:(WKWebViewConfiguration *)configuration;
@end

@interface ZAppDesktopBridge : NSObject
+ (void)attachWindow:(NSWindow *)window
            nativeId:(int32_t)nativeId
             webView:(WKWebView *)webView
   contentController:(WKUserContentController *)contentController
             visible:(BOOL)visible;
@end

int32_t zapp_desktop_has_injection_profile(const char *profile);
int32_t zapp_desktop_window_configure(
  const char *window_id,
  int32_t native_id,
  const char *logical_url,
  bool visible
);
int32_t zapp_desktop_window_select_injection_profile(
  const char *window_id,
  const char *profile
);
int32_t zapp_desktop_window_start(const char *window_id);
void zapp_desktop_window_discard(const char *window_id);
