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

bool zapp_desktop_requested_smoke_mode(void);
int32_t zapp_macos_application_smoke_mode(void);
void zapp_macos_application_set_result(int32_t result);

@interface ZAppDesktopBridge : NSObject
+ (BOOL)smokeMode;
+ (void)setResult:(int32_t)result;
+ (void)stopRunLoop;
@end

@interface ZAppDesktopBridge (Assets)
+ (nullable NSData *)decodeBrotliData:(NSData *)data
                       originalLength:(NSUInteger)originalLength;
@end

@interface ZAppDesktopBridge (WebView)
+ (void)observeResponseInWebView:(WKWebView *)webView
                       nativeId:(int32_t)nativeId
                        payload:(NSString *)payload
                      requestId:(uint64_t)requestId
              activeWindowCount:(NSUInteger)activeWindowCount
                    development:(BOOL)development
                             ok:(BOOL)ok;
+ (void)startWindowSmokeSupport:(NSString *)windowId
                       nativeId:(int32_t)nativeId
                        webView:(WKWebView *)webView
              contentController:(WKUserContentController *)contentController;
@end

NS_ASSUME_NONNULL_END
