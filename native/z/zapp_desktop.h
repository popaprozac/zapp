#pragma once

#import <AppKit/NSWindow.h>
#import <Foundation/NSObject.h>
#import <WebKit/WKScriptMessage.h>
#import <WebKit/WKScriptMessageHandler.h>
#import <WebKit/WKUserContentController.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>

#include <stdint.h>

@interface ZAppDesktopRegistrationOwner : NSObject
- (instancetype)initWithContentController:(WKUserContentController *)controller;
- (void)addHandler:(id<WKScriptMessageHandler>)handler;
- (void)removeHandler;
@end

@interface ZAppDesktopBridge : NSObject
+ (void)attachWindow:(NSWindow *)window
             webView:(WKWebView *)webView
   contentController:(WKUserContentController *)contentController;
@end
