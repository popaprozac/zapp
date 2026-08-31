#import "desktop-smoke.h"

#import "zapp_desktop.h"

#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

extern const char *zapp_desktop_frontend_origin(void);

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
          @"services:typeof globalThis.__zappServices,"
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
          [ZAppDesktopBridge setResult:50];
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
  BOOL ok
) {
  if (![ZAppDesktopBridge smokeMode]) return;
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
          @"status:document.querySelector('#status')?.textContent??null,"
          @"bridge:typeof globalThis[Symbol.for('zapp.bridge')]"
          @"})"
        completionHandler:^(id state, NSError *state_error) {
          const char *frontend_origin = zapp_desktop_frontend_origin();
          BOOL development = frontend_origin != NULL
            && (strncmp(frontend_origin, "http://", 7) == 0
              || strncmp(frontend_origin, "https://", 8) == 0);
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
            && [(NSString *)state containsString:expected_hmr];
          BOOL terminal_failure = [state isKindOfClass:[NSString class]]
            && (
              [(NSString *)state containsString:@"\"roundTrip\":\"error\""]
              || [(NSString *)state containsString:@"\"cancellation\":\"error\""]
              || [(NSString *)state containsString:@"\"health\":\"error\""]
              || [(NSString *)state containsString:@"\"inject\":\"error\""]
              || [(NSString *)state containsString:@"\"dynamicWindow\":\"error\""]
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
            [ZAppDesktopBridge setResult:47];
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
          [ZAppDesktopBridge setResult:0];
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
