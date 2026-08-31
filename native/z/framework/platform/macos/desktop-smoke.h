#pragma once

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

#include <stdbool.h>
#include <stdint.h>

bool zapp_desktop_smoke_window_received(int32_t native_id);

void zapp_desktop_smoke_observe_response(
  WKWebView *web_view,
  int32_t native_id,
  NSUInteger active_window_count,
  NSString *payload,
  uint64_t request_id,
  BOOL ok
);
