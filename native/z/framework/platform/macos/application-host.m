#import <AppKit/AppKit.h>

#import "zapp_desktop.h"

#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

#ifndef ZAPP_DESKTOP_SMOKE_SUPPORT
#define ZAPP_DESKTOP_SMOKE_SUPPORT 0
#endif

NS_ASSUME_NONNULL_BEGIN

@implementation ZAppDesktopBridge

+ (BOOL)smokeMode {
  return zapp_macos_application_smoke_mode() != 0;
}

+ (void)setResult:(int32_t)result {
  zapp_macos_application_set_result(result);
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

bool zapp_desktop_requested_smoke_mode(void) {
#if ZAPP_DESKTOP_SMOKE_SUPPORT
  const char *smoke = getenv("ZAPP_Z_DESKTOP_SMOKE");
  return smoke != NULL && strcmp(smoke, "1") == 0;
#else
  return false;
#endif
}

NS_ASSUME_NONNULL_END
