#pragma once

#import <AppKit/NSWindow.h>
#import <Foundation/NSData.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>
#import <WebKit/WKScriptMessage.h>
#import <WebKit/WKURLSchemeHandler.h>
#import <WebKit/WKScriptMessageHandler.h>
#import <WebKit/WKUserContentController.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>

#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

int32_t zapp_macos_application_smoke_mode(void);
void zapp_macos_application_set_result(int32_t result);

void zapp_desktop_smoke_start_window(
  WKWebView *web_view,
  WKUserContentController *content_controller,
  NSString *window_id,
  int32_t native_id
);

void zapp_desktop_smoke_observe_response(
  WKWebView *web_view,
  int32_t native_id,
  NSUInteger active_window_count,
  NSString *payload,
  uint64_t request_id,
  BOOL development,
  BOOL ok
);

@interface ZAppDesktopBridge : NSObject
@end

@interface ZAppDesktopBridge (Assets)
+ (nullable NSData *)decodeBrotliData:(NSData *)data
                       originalLength:(NSUInteger)originalLength;
@end

NS_ASSUME_NONNULL_END
