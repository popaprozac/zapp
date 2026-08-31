#pragma once

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

#include <stdbool.h>
#include <stdint.h>

int32_t zapp_macos_application_smoke_mode(void);
void zapp_macos_application_set_result(int32_t result);

bool zapp_desktop_smoke_window_received(int32_t native_id);

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
