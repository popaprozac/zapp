#pragma once

#import <Foundation/NSObject.h>
#import <WebKit/WKScriptMessage.h>
#import <WebKit/WKScriptMessageHandler.h>
#import <WebKit/WKUserContentController.h>

#include <stdint.h>

@interface ZAppDesktopRegistrationOwner : NSObject
- (instancetype)initWithContentController:(WKUserContentController *)controller;
- (void)addHandler:(id<WKScriptMessageHandler>)handler;
- (void)removeHandler;
@end

@interface ZAppDesktopBridge : NSObject
+ (ZAppDesktopRegistrationOwner *)registrationOwner;
@end
