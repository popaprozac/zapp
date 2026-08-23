#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

#include "zapp_core.h"
#include "zapp_router.h"
#import "zapp_desktop.h"

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

extern const char *zapp_webview_bootstrap_script(void);

@class ZAppDesktopHost;

static __weak ZAppDesktopHost *active_host = nil;

static void enqueue_release(
  void *context,
  void *value,
  void (*finalize)(void *value)
) {
  (void)context;
  if (pthread_main_np() != 0) {
    finalize(value);
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    finalize(value);
  });
}

static bool is_main_thread(void *context) {
  (void)context;
  return pthread_main_np() != 0;
}

@interface ZAppDesktopHost : NSObject <NSWindowDelegate>
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, weak) WKWebView *webView;
@property(nonatomic, weak) WKUserContentController *userContentController;
@property(nonatomic, assign) BOOL receivedResponse;
@property(nonatomic, assign) int32_t result;
- (int32_t)run;
- (void)deliverPayload:(NSString *)payload
             requestId:(uint64_t)requestId
                    ok:(BOOL)ok
              windowId:(int32_t)windowId;
@end

@interface ZAppDesktopRegistrationOwner ()
@property(nonatomic, strong) WKUserContentController *contentController;
@end

@implementation ZAppDesktopRegistrationOwner

- (instancetype)initWithContentController:(WKUserContentController *)controller {
  self = [super init];
  if (self != nil) _contentController = controller;
  return self;
}

- (void)addHandler:(id<WKScriptMessageHandler>)handler {
  [self.contentController addScriptMessageHandler:handler name:@"zapp"];
}

- (void)removeHandler {
  [self.contentController removeScriptMessageHandlerForName:@"zapp"];
}

@end

@implementation ZAppDesktopBridge

+ (void)attachWindow:(NSWindow *)window
             webView:(WKWebView *)webView
   contentController:(WKUserContentController *)contentController {
  ZAppDesktopHost *host = active_host;
  if (host == nil) return;
  host.window = window;
  host.webView = webView;
  host.userContentController = contentController;
  window.delegate = host;
}

@end

void zapp_deliver_response_from_z(
  const char *payload,
  uint64_t request_id,
  bool ok,
  int32_t window_id
) {
  ZAppDesktopHost *host = active_host;
  if (host == nil) return;
  NSString *text = payload == NULL
    ? @""
    : [NSString stringWithUTF8String:payload];
  if (text == nil) {
    host.result = 44;
    [host.window close];
    return;
  }
  [host deliverPayload:text
             requestId:request_id
                    ok:ok
              windowId:window_id];
}

@implementation ZAppDesktopHost

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _receivedResponse = NO;
    _result = 41;
  }
  return self;
}

- (void)deliverPayload:(NSString *)payload
             requestId:(uint64_t)requestId
                    ok:(BOOL)ok
              windowId:(int32_t)windowId {
  NSDictionary *response = @{
    @"id": [NSString stringWithFormat:@"%llu", (unsigned long long)requestId],
    @"ok": @(ok),
    @"payload": payload,
  };
  NSError *serializationError = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:response
                                                 options:0
                                                   error:&serializationError];
  if (data == nil || serializationError != nil) {
    self.result = 43;
    [self.window close];
    return;
  }
  NSString *json = [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
  NSString *script = [NSString stringWithFormat:
    @"(()=>{const r=%@;const b=globalThis[Symbol.for('zapp.bridge')];"
    @"if(!b||typeof b._onInvokeResult!=='function'){"
    @"throw new Error('Zapp bridge is unavailable')}"
    @"b._onInvokeResult(Number(r.id),r.ok,r.payload)})()",
    json];
  __weak ZAppDesktopHost *weakSelf = self;
  [self.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
    (void)value;
    ZAppDesktopHost *strongSelf = weakSelf;
    if (strongSelf == nil) return;
    if (error != nil) {
      strongSelf.result = 45;
      [strongSelf.window close];
      return;
    }

    dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
      dispatch_get_main_queue(),
      ^{
        [strongSelf.webView
          evaluateJavaScript:
            @"JSON.stringify({"
            @"roundTrip:document.body?.dataset?.roundTrip??null,"
            @"status:document.querySelector('#status')?.textContent??null,"
            @"bridge:typeof globalThis[Symbol.for('zapp.bridge')]"
            @"})"
          completionHandler:^(id state, NSError *stateError) {
            BOOL updated = [state isKindOfClass:[NSString class]]
              && [(NSString *)state containsString:@"\"roundTrip\":\"ok\""];
            if (stateError != nil || !updated) {
              const char *stateText = state == nil
                ? "<nil>"
                : [[state description] UTF8String];
              const char *errorText = stateError == nil
                ? "<none>"
                : [[stateError description] UTF8String];
              fprintf(
                stderr,
                "WebView DOM verification failed: state=%s error=%s\n",
                stateText,
                errorText
              );
              strongSelf.result = 47;
              [strongSelf.window close];
              return;
            }
            strongSelf.receivedResponse = YES;
            strongSelf.result = 0;
            printf(
              "visible WebView round trip window=%d request=%llu ok=%s payload=%s\n",
              windowId,
              (unsigned long long)requestId,
              ok ? "true" : "false",
              payload.UTF8String
            );
            fflush(stdout);
            dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
              dispatch_get_main_queue(),
              ^{
                [strongSelf.window close];
              }
            );
          }];
      }
    );
  }];
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
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
}

- (int32_t)run {
  NSApplication *application = NSApplication.sharedApplication;
  [application setActivationPolicy:NSApplicationActivationPolicyRegular];

  if (
    self.window == nil
    || self.webView == nil
    || self.userContentController == nil
  ) {
    self.result = 49;
    return self.result;
  }

  const char *bootstrapBytes = zapp_webview_bootstrap_script();
  NSString *bootstrapSource = bootstrapBytes == NULL
    ? nil
    : [NSString stringWithUTF8String:bootstrapBytes];
  if (bootstrapSource == nil) {
    self.result = 48;
    return self.result;
  }
  WKUserScript *bootstrap = [[WKUserScript alloc]
    initWithSource:bootstrapSource
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:NO];
  [self.userContentController addUserScript:bootstrap];

  NSString *html =
    @"<!doctype html>"
    @"<html><head><meta charset=\"utf-8\">"
    @"<style>"
    @":root{color-scheme:light dark;font-family:-apple-system,sans-serif}"
    @"body{display:grid;place-content:center;min-height:100vh;margin:0}"
    @"main{width:min(560px,calc(100vw - 64px))}"
    @"button{font:inherit;padding:10px 16px}"
    @"pre{min-height:72px;padding:14px;border-radius:10px;background:rgba(128,128,128,.14)}"
    @"</style></head><body><main>"
    @"<h1>Zapp is routing through Z</h1>"
    @"<p>This button sends a typed WebKit message through the Z core.</p>"
    @"<button id=\"ping\">Send WebView → Z → WebView</button>"
    @"<pre id=\"status\">Waiting for the bridge…</pre>"
    @"</main><script>"
    @"const button=document.querySelector('#ping');"
    @"const status=document.querySelector('#status');"
    @"const bridge=globalThis[Symbol.for('zapp.bridge')];"
    @"button.addEventListener('click',async()=>{"
    @"status.textContent='Routing…';"
    @"try{"
    @"const payload=await bridge.invoke('__zapp:ping',{message:'héllo from WebKit'});"
    @"status.textContent=`Success\\n${payload.message}`;"
    @"document.body.dataset.roundTrip='ok';"
    @"}catch(error){"
    @"status.textContent=`Failure\\n${String(error)}`;"
    @"document.body.dataset.roundTrip='error';"
    @"}"
    @"});"
    @"setTimeout(()=>button.click(),350);"
    @"</script></body></html>";
  [self.webView loadHTMLString:html baseURL:nil];

  [self.window center];
  [self.window makeKeyAndOrderFront:nil];
  active_host = self;
  [application activate];
  __weak ZAppDesktopHost *weakSelf = self;
  dispatch_after(
    dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
    dispatch_get_main_queue(),
    ^{
      ZAppDesktopHost *strongSelf = weakSelf;
      if (strongSelf != nil && !strongSelf.receivedResponse) {
        strongSelf.result = 50;
        [strongSelf.window close];
      }
    }
  );
  [application run];
  active_host = nil;

  self.window.delegate = nil;
  return self.receivedResponse ? 0 : self.result;
}

@end

int main(void) {
  @autoreleasepool {
    ZAppDesktopHost *host = [[ZAppDesktopHost alloc] init];
    active_host = host;

    const zapp_core_runtime_config config = {
      .context = NULL,
      .enqueue_release = enqueue_release,
      .is_main_thread = is_main_thread,
    };
    if (zapp_core_runtime_initialize(&config) != ZAPP_CORE_RUNTIME_OK) {
      fputs("could not initialize the embedded Z runtime\n", stderr);
      return 2;
    }

    int32_t result = [host run];
    zapp_core_runtime_status shutdown = zapp_core_runtime_shutdown();
    if (shutdown != ZAPP_CORE_RUNTIME_OK) {
      fputs("could not shut down the embedded Z runtime\n", stderr);
      if (result == 0) result = 46;
    }
    active_host = nil;
    return result;
  }
}
