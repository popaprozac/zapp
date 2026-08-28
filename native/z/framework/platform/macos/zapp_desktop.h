#pragma once

#import <AppKit/NSWindow.h>
#import <Foundation/NSObject.h>
#import <WebKit/WKScriptMessage.h>
#import <WebKit/WKScriptMessageHandler.h>
#import <WebKit/WKUserContentController.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>

#include <stdint.h>

int32_t zapp_desktop_run(void);
int32_t zapp_desktop_prepare(void);
NSRect zapp_desktop_make_rect(uint32_t width, uint32_t height);

@interface ZAppDesktopRegistrationOwner : NSObject
- (instancetype)initWithContentController:(WKUserContentController *)controller;
- (void)addHandler:(id<WKScriptMessageHandler>)handler;
- (void)removeHandler;
@end

@interface ZAppDesktopBridge : NSObject
+ (void)configureWebViewConfiguration:(WKWebViewConfiguration *)configuration;
+ (void)attachWindow:(NSWindow *)window
             webView:(WKWebView *)webView
   contentController:(WKUserContentController *)contentController
             visible:(BOOL)visible;
@end

void zapp_desktop_set_logical_url(const char *logical_url);
int32_t zapp_desktop_has_injection_profile(const char *profile);
int32_t zapp_desktop_select_injection_profile(const char *profile);
void zapp_desktop_window_show(const char *window_id);
void zapp_desktop_window_hide(const char *window_id);
void zapp_desktop_window_close(const char *window_id);
void zapp_desktop_window_set_title(
  const char *window_id,
  const char *title
);
