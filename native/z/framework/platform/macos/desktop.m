#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

#include "zapp_router.h"
#import "zapp_desktop.h"

#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const char *zapp_webview_bootstrap_script(void);

@class ZAppDesktopHost;

static __weak ZAppDesktopHost *active_host = nil;
static ZAppDesktopHost *prepared_host = nil;

@interface ZAppDesktopHost : NSObject <NSWindowDelegate>
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, weak) WKWebView *webView;
@property(nonatomic, weak) WKUserContentController *userContentController;
@property(nonatomic, assign) BOOL receivedResponse;
@property(nonatomic, assign) BOOL smokeMode;
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
    const char *smoke = getenv("ZAPP_Z_DESKTOP_SMOKE");
    _smokeMode = smoke != NULL && strcmp(smoke, "1") == 0;
    _result = _smokeMode ? 41 : 0;
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
            if (strongSelf.smokeMode) {
              dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                dispatch_get_main_queue(),
                ^{
                  [strongSelf.window close];
                }
              );
            }
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

  NSString *automaticInvocation = self.smokeMode
    ? @"setTimeout(()=>button.click(),350);"
    : @"";
  NSString *html = [NSString stringWithFormat:
    @"<!doctype html>"
    @"<html><head><meta charset=\"utf-8\">"
    @"<style>"
    @":root{color-scheme:light dark;font-family:-apple-system,sans-serif}"
    @"body{display:grid;place-content:center;min-height:100vh;margin:0}"
    @"main{width:min(560px,calc(100vw - 64px))}"
    @"button{font:inherit;padding:10px 16px}"
    @"pre{min-height:72px;padding:14px;border-radius:10px;background:rgba(128,128,128,.14)}"
    @"</style></head><body><main>"
    @"<h1>Zapp is calling a Z service</h1>"
    @"<p>This button calls the generated NotesService binding.</p>"
    @"<button id=\"ping\">Create a note in Z</button>"
    @"<pre id=\"status\">Waiting for the bridge…</pre>"
    @"</main><script>"
    @"const button=document.querySelector('#ping');"
    @"const status=document.querySelector('#status');"
    @"const services=globalThis.__zappServices;"
    @"button.addEventListener('click',async()=>{"
    @"status.textContent='Routing…';"
    @"try{"
    @"const note=await services.notes.create({title:'WebView note'});"
    @"status.textContent=`Created note ${note.id}\\n${note.title}`;"
    @"document.body.dataset.roundTrip='ok';"
    @"}catch(error){"
    @"status.textContent=`Failure\\n${String(error)}`;"
    @"document.body.dataset.roundTrip='error';"
    @"}"
    @"});"
    @"%@"
    @"</script></body></html>",
    automaticInvocation];
  [self.webView loadHTMLString:html baseURL:nil];

  [self.window center];
  [self.window makeKeyAndOrderFront:nil];
  active_host = self;
  [application activate];
  if (self.smokeMode) {
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
  }
  [application run];
  active_host = nil;

  self.window.delegate = nil;
  return self.smokeMode
    ? (self.receivedResponse ? 0 : self.result)
    : self.result;
}

@end

int32_t zapp_desktop_prepare(void) {
  @autoreleasepool {
    if (prepared_host != nil) return 52;
    ZAppDesktopHost *host = [[ZAppDesktopHost alloc] init];
    prepared_host = host;
    active_host = host;
    return 0;
  }
}

int32_t zapp_desktop_run(void) {
  @autoreleasepool {
    ZAppDesktopHost *host = prepared_host;
    if (host == nil) return 51;
    int32_t result = [host run];
    active_host = nil;
    prepared_host = nil;
    return result;
  }
}
