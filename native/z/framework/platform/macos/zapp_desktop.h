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

int32_t zapp_desktop_run(void);
int32_t zapp_desktop_prepare(void);
void zapp_desktop_abort(void);
NSRect zapp_desktop_make_rect(uint32_t width, uint32_t height);

@interface ZAppDesktopBridge : NSObject
+ (BOOL)smokeMode;
+ (void)setResult:(int32_t)result;
+ (void)stopRunLoop;
@end

@interface ZAppDesktopBridge (Assets)
+ (NSUInteger)embeddedAssetCount;
+ (nullable NSString *)embeddedAssetPathAtIndex:(NSUInteger)index;
+ (nullable NSData *)embeddedAssetDataAtIndex:(NSUInteger)index;
@end

@interface ZAppDesktopBridge (WebView)
+ (nullable NSString *)webViewBootstrapScript;
+ (nullable NSString *)webViewFrontendOrigin;
+ (NSUInteger)webViewInjectionCount;
+ (nullable NSString *)webViewInjectionProfileAtIndex:(NSUInteger)index;
+ (int32_t)webViewInjectionPhaseAtIndex:(NSUInteger)index;
+ (nullable NSString *)webViewInjectionSourceAtIndex:(NSUInteger)index;
+ (void)evaluateJavaScript:(NSString *)script
                 inWebView:(WKWebView *)webView
                 forWindow:(NSWindow *)window
                  nativeId:(int32_t)nativeId
                   payload:(NSString *)payload
                 requestId:(uint64_t)requestId
         activeWindowCount:(NSUInteger)activeWindowCount
                        ok:(BOOL)ok;
+ (void)startWindowSmokeSupport:(NSString *)windowId
                       nativeId:(int32_t)nativeId
                        webView:(WKWebView *)webView
              contentController:(WKUserContentController *)contentController;
@end

@interface ZAppDesktopBridge (Window)
+ (void)failURLSchemeTask:(id<WKURLSchemeTask>)task
                   status:(NSInteger)status
                  message:(NSString *)message;
+ (uint32_t)contentWidth:(NSWindow *)window;
+ (uint32_t)contentHeight:(NSWindow *)window;
@end

NS_ASSUME_NONNULL_END
