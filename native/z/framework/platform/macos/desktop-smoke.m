#import "desktop-smoke.h"

#include <dispatch/dispatch.h>
#include <stdio.h>

static NSMutableSet<NSNumber *> *zapp_desktop_smoke_responses(void) {
  static NSMutableSet<NSNumber *> *responses = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    responses = [[NSMutableSet alloc] init];
  });
  return responses;
}

static void zapp_desktop_smoke_close_all_windows(void) {
  for (NSWindow *window in [NSApp.windows copy]) {
    [window close];
  }
}

bool zapp_desktop_smoke_window_received(int32_t native_id) {
  return [zapp_desktop_smoke_responses() containsObject:@(native_id)];
}

void zapp_desktop_smoke_start_window(
  WKWebView *web_view,
  WKUserContentController *content_controller,
  NSString *window_id,
  int32_t native_id
) {
  WKUserScript *smoke = [[WKUserScript alloc]
    initWithSource:
      @"setTimeout(()=>document.querySelector('#cancel')?.click(),350);"
      @"setTimeout(()=>document.querySelector('#notification-status')?.click(),500);"
      @"setTimeout(()=>document.querySelector('#navigation-profile')?.click(),650);"
      @"setTimeout(()=>document.querySelector('#navigation-native')?.click(),800);"
      @"setTimeout(()=>document.querySelector('#bridge-subframe')?.click(),900);"
      @"setTimeout(()=>document.querySelector('#notification-status')?.click(),1300);"
    injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
    forMainFrameOnly:YES];
  [content_controller addUserScript:smoke];

  __weak WKWebView *weak_web_view = web_view;
  NSString *retained_window_id = [window_id copy];
  dispatch_after(
    dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
    dispatch_get_main_queue(),
    ^{
      WKWebView *current = weak_web_view;
      if (
        current == nil
        || zapp_desktop_smoke_window_received(native_id)
      ) return;
      [current
        evaluateJavaScript:
          @"JSON.stringify({"
          @"ready:document.readyState,"
          @"bridge:typeof globalThis[Symbol.for('zapp.bridge')],"
          @"windowId:globalThis[Symbol.for('zapp.windowId')]??null,"
          @"cancel:typeof document.querySelector('#cancel')?.onclick,"
          @"status:document.querySelector('#status')?.textContent??null,"
          @"body:document.body?.dataset??null"
          @"})"
        completionHandler:^(id state, NSError *state_error) {
          fprintf(
            stderr,
            "[zapp] frontend smoke timed out window=%s state=%s error=%s\n",
            retained_window_id.UTF8String,
            state == nil ? "<nil>" : [[state description] UTF8String],
            state_error == nil
              ? "<none>"
              : [[state_error description] UTF8String]
          );
          zapp_macos_application_set_result(50);
          zapp_desktop_smoke_close_all_windows();
        }];
    }
  );
}

void zapp_desktop_smoke_observe_response(
  WKWebView *web_view,
  int32_t native_id,
  NSUInteger active_window_count,
  NSString *payload,
  uint64_t request_id,
  BOOL development,
  BOOL ok
) {
  if (zapp_macos_application_smoke_mode() == 0) return;
  if (request_id == 1) {
    printf(
      "cancelled WebView response ignored request=%llu\n",
      (unsigned long long)request_id
    );
    fflush(stdout);
    return;
  }

  dispatch_after(
    dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
    dispatch_get_main_queue(),
    ^{
      [web_view
        evaluateJavaScript:
          @"JSON.stringify({"
          @"roundTrip:document.body?.dataset?.roundTrip??null,"
          @"typedError:document.body?.dataset?.typedError??null,"
          @"cancellation:document.body?.dataset?.cancellation??null,"
          @"health:document.body?.dataset?.health??null,"
          @"hmr:document.body?.dataset?.hmr??null,"
          @"inject:document.body?.dataset?.inject??null,"
          @"dynamicWindow:document.body?.dataset?.dynamicWindow??null,"
          @"notificationStatus:document.body?.dataset?.notificationStatus??null,"
          @"navigationPolicy:document.body?.dataset?.navigationPolicy??null,"
          @"status:document.querySelector('#status')?.textContent??null,"
          @"bridge:typeof globalThis[Symbol.for('zapp.bridge')]"
          @"})"
        completionHandler:^(id state, NSError *state_error) {
          NSString *expected_hmr = development
            ? @"\"hmr\":\"ready\""
            : @"\"hmr\":\"packaged\"";
          BOOL updated = [state isKindOfClass:[NSString class]]
            && [(NSString *)state containsString:@"\"roundTrip\":\"ok\""]
            && [(NSString *)state containsString:@"\"typedError\":\"ok\""]
            && [(NSString *)state containsString:@"\"cancellation\":\"ok\""]
            && [(NSString *)state containsString:@"\"health\":\"ok\""]
            && [(NSString *)state containsString:@"\"inject\":\"ready\""]
            && [(NSString *)state containsString:@"\"dynamicWindow\":\"ready\""]
            && [(NSString *)state containsString:@"\"notificationStatus\":\"ok\""]
            && [(NSString *)state containsString:@"\"navigationPolicy\":\"ok\""]
            && [(NSString *)state containsString:expected_hmr];
          BOOL terminal_failure = [state isKindOfClass:[NSString class]]
            && (
              [(NSString *)state containsString:@"\"roundTrip\":\"error\""]
              || [(NSString *)state containsString:@"\"cancellation\":\"error\""]
              || [(NSString *)state containsString:@"\"health\":\"error\""]
              || [(NSString *)state containsString:@"\"inject\":\"error\""]
              || [(NSString *)state containsString:@"\"dynamicWindow\":\"error\""]
              || [(NSString *)state containsString:@"\"notificationStatus\":\"error\""]
              || [(NSString *)state containsString:@"\"navigationPolicy\":\"error\""]
            );
          // Several legitimate requests may complete while the scripted
          // scenario is still in flight (notably frontend window creation).
          // Leave incomplete state to the per-window watchdog; only a
          // terminal DOM failure should fail the smoke eagerly.
          if (state_error == nil && !updated && !terminal_failure) return;
          if (state_error != nil || !updated) {
            const char *state_text = state == nil
              ? "<nil>"
              : [[state description] UTF8String];
            const char *error_text = state_error == nil
              ? "<none>"
              : [[state_error description] UTF8String];
            fprintf(
              stderr,
              "WebView DOM verification failed: state=%s error=%s\n",
              state_text,
              error_text
            );
            zapp_macos_application_set_result(47);
            zapp_desktop_smoke_close_all_windows();
            return;
          }
          [zapp_desktop_smoke_responses() addObject:@(native_id)];
          printf(
            "visible WebView round trip window=%d request=%llu ok=%s hmr=%s inject=ready payload=%s\n",
            native_id,
            (unsigned long long)request_id,
            ok ? "true" : "false",
            development ? "ready" : "packaged",
            payload.UTF8String
          );
          fflush(stdout);
          if (zapp_desktop_smoke_responses().count < active_window_count) return;
          zapp_macos_application_set_result(0);
          dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
            dispatch_get_main_queue(),
            ^{
              zapp_desktop_smoke_close_all_windows();
            }
          );
        }];
    }
  );
}
