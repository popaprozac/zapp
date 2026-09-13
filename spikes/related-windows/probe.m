#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

@interface Probe : NSObject <NSApplicationDelegate, NSWindowDelegate,
  WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKURLSchemeHandler>
@property NSString *root;
@property NSString *url;
@property NSMutableArray<NSWindow *> *windows;
@property NSWindow *parent;
@property WKWebView *mainView;
@property int result;
@property BOOL finished;
@property NSUInteger createdChildren;
@property NSUInteger closedChildren;
@end

@implementation Probe
- (void)log:(NSDictionary *)value {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
  fflush(stdout);
}
- (NSWindow *)host:(WKWebView *)view title:(NSString *)title child:(BOOL)child {
  NSRect rect = NSMakeRect(child ? 650 : 100, 350, 510, 350);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:rect
    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
    backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed = NO;
  window.title = title;
  window.delegate = self;
  window.contentView = view;
  view.UIDelegate = self;
  view.navigationDelegate = self;
  [self.windows addObject:window];
  [window makeKeyAndOrderFront:nil];
  return window;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  self.windows = [NSMutableArray array];
  self.result = 2;
  WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
  config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
  [config.userContentController addScriptMessageHandler:self name:@"probe"];
  [config setURLSchemeHandler:self forURLScheme:@"zapp"];
  self.mainView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
  self.parent = [self host:self.mainView title:@"Related-window probe: React owner" child:NO];
  [self.mainView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:self.url]]];
  [NSApp activate];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (!self.finished) [self finish:@{@"pass": @NO, @"error": @"native 15-second deadline"}];
  });
}
- (void)finish:(NSDictionary *)payload {
  if (self.finished) return;
  self.finished = YES;
  self.result = [payload[@"pass"] boolValue] ? 0 : 1;
  NSMutableDictionary *result = [payload mutableCopy];
  if ([payload[@"pass"] boolValue] && self.createdChildren != self.closedChildren) {
    self.result = 1;
    result[@"pass"] = @NO;
    result[@"error"] = @"JS close has not completed native window teardown";
  }
  result[@"kind"] = @"result";
  result[@"createdChildren"] = @(self.createdChildren);
  result[@"closedChildren"] = @(self.closedChildren);
  [self log:result];
  for (NSWindow *window in [self.windows copy]) {
    WKWebView *view = (WKWebView *)window.contentView;
    view.UIDelegate = nil;
    view.navigationDelegate = nil;
    [view stopLoading];
    [view.configuration.userContentController removeScriptMessageHandlerForName:@"probe"];
    window.delegate = nil;
    [window close];
  }
  [self.windows removeAllObjects];
  self.mainView = nil;
  self.parent = nil;
  [NSApp stop:nil];
  [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
    location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
    subtype:0 data1:0 data2:0] atStart:NO];
}
- (WKWebView *)webView:(WKWebView *)webView
  createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
  forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
  (void)features;
  // Critical: use WebKit's supplied configuration, not a newly constructed one.
  if (webView != self.mainView || action.targetFrame != nil) return nil;
  WKWebView *child = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
  [self host:child title:@"Related-window probe: portal target" child:YES];
  self.createdChildren += 1;
  [self log:@{@"kind": @"child-created", @"url": action.request.URL.absoluteString ?: @""}];
  // WebKit performs the requested navigation itself.
  return child;
}
- (void)webViewDidClose:(WKWebView *)view {
  for (NSWindow *window in [self.windows copy]) {
    if (window.contentView == view) {
      self.closedChildren += 1;
      [window close];
      break;
    }
  }
}
- (void)windowWillClose:(NSNotification *)notification {
  NSWindow *window = notification.object;
  [self.windows removeObject:window];
  if (window == self.parent && !self.finished)
    [self finish:@{@"pass": @NO, @"error": @"parent closed before test completed"}];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)view {
  (void)view;
  [self finish:@{@"pass": @NO, @"error": @"WebContent process terminated"}];
}
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation
  withError:(NSError *)error {
  (void)view; (void)navigation;
  [self finish:@{@"pass": @NO, @"error": error.description}];
}
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation {
  (void)navigation;
  if (view == self.mainView) return;
  // Host confirmation avoids mistaking initial about:blank for a committed
  // cross-origin document in the negative control.
  NSString *url = view.URL.absoluteString ?: @"";
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:@[url] options:0 error:nil];
  NSString *json = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
  NSString *script = [NSString stringWithFormat:@"window.__lastChildNavigation=(%@)[0]", json];
  [self.mainView evaluateJavaScript:script completionHandler:nil];
}
- (void)userContentController:(WKUserContentController *)controller
  didReceiveScriptMessage:(WKScriptMessage *)message {
  (void)controller;
  if (![message.body isKindOfClass:[NSDictionary class]]) return;
  NSDictionary *body = message.body;
  if ([body[@"kind"] isEqual:@"result"]) [self finish:body];
  else if ([body[@"kind"] isEqual:@"hide-parent"]) [self.parent orderOut:nil];
  else if ([body[@"kind"] isEqual:@"show-parent"]) [self.parent orderFront:nil];
  else [self log:body];
}
- (void)webView:(WKWebView *)view startURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)view;
  NSString *name = task.request.URL.lastPathComponent;
  if (![@[@"index.html", @"child.html", @"app.js"] containsObject:name]) {
    [task didFailWithError:[NSError errorWithDomain:@"probe" code:404 userInfo:nil]];
    return;
  }
  NSData *data = [NSData dataWithContentsOfFile:[self.root stringByAppendingPathComponent:name]];
  if (!data) {
    [task didFailWithError:[NSError errorWithDomain:@"probe" code:404 userInfo:nil]];
    return;
  }
  NSString *mime = [name hasSuffix:@".js"] ? @"text/javascript" : @"text/html";
  NSURLResponse *response = [[NSURLResponse alloc] initWithURL:task.request.URL
    MIMEType:mime expectedContentLength:data.length textEncodingName:@"utf-8"];
  [task didReceiveResponse:response];
  [task didReceiveData:data];
  [task didFinish];
}
- (void)webView:(WKWebView *)view stopURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)view; (void)task;
}
@end

int main(int argc, const char *argv[]) {
  if (argc != 3) return 64;
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    Probe *probe = [[Probe alloc] init];
    probe.root = [NSString stringWithUTF8String:argv[1]];
    probe.url = [NSString stringWithUTF8String:argv[2]];
    NSApp.delegate = probe;
    [NSApp run];
    NSApp.delegate = nil;
    return probe.result;
  }
}
