#import <AppKit/AppKit.h>

#import "zapp_desktop.h"

#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef ZAPP_DESKTOP_SMOKE_SUPPORT
#define ZAPP_DESKTOP_SMOKE_SUPPORT 0
#endif

NS_ASSUME_NONNULL_BEGIN

@class ZAppDesktopHost;
static ZAppDesktopHost *prepared_host = nil;

@interface ZAppDesktopHost : NSObject
@property(nonatomic, assign) BOOL smokeMode;
@property(nonatomic, assign) int32_t result;
- (int32_t)run;
@end

@implementation ZAppDesktopBridge

+ (BOOL)smokeMode {
  return prepared_host != nil && prepared_host.smokeMode;
}

+ (void)setResult:(int32_t)result {
  if (prepared_host != nil) prepared_host.result = result;
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

@end

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

NS_ASSUME_NONNULL_END
