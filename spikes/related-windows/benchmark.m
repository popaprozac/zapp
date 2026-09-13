// Reuse the isolated feasibility host, not any production Zapp source.
#define main feasibility_main
#include "probe.m"
#undef main

@interface Benchmark : Probe
@property WKWebView *childView;
@property NSMutableArray<NSNumber *> *nativeCreationMs;
@property NSUInteger relayCount;
@property NSUInteger relayBytes;
@end

@implementation Benchmark
- (WKWebViewConfiguration *)freshConfiguration {
  WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
  config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
  [config.userContentController addScriptMessageHandler:self name:@"probe"];
  [config setURLSchemeHandler:self forURLScheme:@"zapp"];
  return config;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  self.windows = [NSMutableArray array];
  self.nativeCreationMs = [NSMutableArray array];
  self.result = 2;
  self.mainView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:[self freshConfiguration]];
  self.parent = [self host:self.mainView title:@"Benchmark owner" child:NO];
  [self.mainView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:self.url]]];
  [NSApp activate];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (!self.finished) [self finish:@{@"pass": @NO, @"error": @"native 30-second deadline"}];
  });
}
- (WKWebView *)newChild:(WKWebViewConfiguration *)config {
  double start = NSProcessInfo.processInfo.systemUptime;
  WKWebView *child = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
  [self host:child title:@"Benchmark inspector" child:YES];
  self.childView = child;
  self.createdChildren += 1;
  [self.nativeCreationMs addObject:@((NSProcessInfo.processInfo.systemUptime - start) * 1000)];
  return child;
}
- (WKWebView *)webView:(WKWebView *)view
  createWebViewWithConfiguration:(WKWebViewConfiguration *)config
  forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
  (void)features;
  if (view != self.mainView || action.targetFrame != nil || self.childView) return nil;
  return [self newChild:config];
}
- (void)deliver:(NSString *)function payload:(id)payload to:(WKWebView *)view {
  if (!view) {
    [self finish:@{@"pass": @NO, @"error": @"relay target disappeared"}];
    return;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  NSString *script = [NSString stringWithFormat:@"window.%@(%@);void 0", function, json];
  [view evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
    (void)value;
    if (error && !self.finished) [self finish:@{@"pass": @NO, @"error": error.description}];
  }];
}
- (void)userContentController:(WKUserContentController *)controller
  didReceiveScriptMessage:(WKScriptMessage *)message {
  (void)controller;
  NSDictionary *body = message.body;
  if ([message.body isKindOfClass:NSString.class]) {
    body = [NSJSONSerialization JSONObjectWithData:[message.body dataUsingEncoding:NSUTF8StringEncoding]
      options:0 error:nil];
  }
  if (![body isKindOfClass:NSDictionary.class]) return;
  NSString *kind = body[@"kind"];
  if ([kind isEqual:@"open-independent"]) {
    WKWebView *child = [self newChild:[self freshConfiguration]];
    [child loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:body[@"url"]]]];
  } else if ([kind isEqual:@"relay"]) {
    self.relayCount += 1;
    self.relayBytes += [message.body lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    [self deliver:@"__applyUpdate" payload:body[@"payload"] to:self.childView];
  } else if ([kind isEqual:@"ack"]) {
    [self deliver:@"__receive" payload:body[@"payload"] to:self.mainView];
  } else if ([kind isEqual:@"ready"]) {
    [self deliver:@"__childReady" payload:body[@"payload"] to:self.mainView];
  } else if ([kind isEqual:@"close-child"]) {
    WKWebView *child = self.childView;
    child.UIDelegate = nil;
    child.navigationDelegate = nil;
    [child stopLoading];
    [self webViewDidClose:child];
    self.childView = nil;
    [self deliver:@"__closed" payload:@{} to:self.mainView];
  } else if ([kind isEqual:@"result"]) {
    [self finish:body];
  } else if ([kind isEqual:@"failure"]) {
    [self finish:@{@"pass": @NO, @"error": body[@"error"] ?: @"JS error"}];
  }
}
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation {
  (void)view; (void)navigation;
}
- (void)finish:(NSDictionary *)payload {
  NSMutableDictionary *result = [payload mutableCopy];
  result[@"nativeCreationMs"] = self.nativeCreationMs ?: @[];
  result[@"relayCount"] = @(self.relayCount);
  result[@"relayBytes"] = @(self.relayBytes);
  [super finish:result];
  self.childView = nil;
}
- (void)webView:(WKWebView *)view startURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)view;
  NSString *name = task.request.URL.lastPathComponent;
  if (![@[@"bench-owner.html", @"bench-independent.html", @"bench-related.html",
          @"bench.js", @"related-child.js", @"bench.css"] containsObject:name]) {
    [task didFailWithError:[NSError errorWithDomain:@"benchmark" code:404 userInfo:nil]];
    return;
  }
  NSData *data = [NSData dataWithContentsOfFile:[self.root stringByAppendingPathComponent:name]];
  NSString *mime = [name hasSuffix:@".js"] ? @"text/javascript" :
    ([name hasSuffix:@".css"] ? @"text/css" : @"text/html");
  NSURLResponse *response = [[NSURLResponse alloc] initWithURL:task.request.URL
    MIMEType:mime expectedContentLength:data.length textEncodingName:@"utf-8"];
  [task didReceiveResponse:response];
  [task didReceiveData:data];
  [task didFinish];
}
@end

int main(int argc, const char *argv[]) {
  if (argc != 3) return 64;
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    Benchmark *probe = [[Benchmark alloc] init];
    probe.root = [NSString stringWithUTF8String:argv[1]];
    probe.url = [NSString stringWithUTF8String:argv[2]];
    NSApp.delegate = probe;
    [NSApp run];
    NSApp.delegate = nil;
    return probe.result;
  }
}
