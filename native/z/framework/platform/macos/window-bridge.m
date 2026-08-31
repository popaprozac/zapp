#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

#import "zapp_desktop.h"

#include <stdint.h>
NS_ASSUME_NONNULL_BEGIN

@implementation ZAppDesktopBridge (Window)

+ (uint32_t)contentWidth:(NSWindow *)window {
  CGFloat width = window.contentView.bounds.size.width;
  if (width <= 0.0) return 0;
  if (width >= (CGFloat)UINT32_MAX) return UINT32_MAX;
  return (uint32_t)width;
}

+ (uint32_t)contentHeight:(NSWindow *)window {
  CGFloat height = window.contentView.bounds.size.height;
  if (height <= 0.0) return 0;
  if (height >= (CGFloat)UINT32_MAX) return UINT32_MAX;
  return (uint32_t)height;
}

@end

NSRect zapp_desktop_make_rect(uint32_t width, uint32_t height) {
  return NSMakeRect(0.0, 0.0, (CGFloat)width, (CGFloat)height);
}

NS_ASSUME_NONNULL_END
