// Isolated platform oracle, never linked into Zapp. Uses the existing host only
// for window construction, bounded shutdown, and static fixture serving.
#define main feasibility_main
#include "probe.m"
#undef main

@interface DirectEndpoint : NSObject
@property NSString *identity;
@property NSString *documentToken;
@property NSUInteger generation;
@property BOOL active;
@property BOOL ready;
@property BOOL vetoClose;
@property (weak) WKWebView *view;
@property WKUserContentController *controller;
@property NSMutableDictionary<NSNumber *, NSDictionary *> *pending;
@end
@implementation DirectEndpoint
@end

@interface DirectBridgeProbe : Probe
@property NSMutableArray<DirectEndpoint *> *endpoints;
@property NSMutableArray<NSDictionary *> *observations;
@property NSUInteger dropped;
@property NSUInteger deniedFrames;
@property NSUInteger deniedOrigins;
@property NSUInteger deniedTokens;
@property BOOL ownerCloseExpected;
@property NSArray *ownerCloseAssertions;
@property BOOL finishingFixture;
@property NSUInteger cancelledCloses;
@property NSUInteger invalidationNotifications;
@end

@implementation DirectBridgeProbe
- (BOOL)isAppOrigin:(NSURL *)url {
  NSURL *owner = [NSURL URLWithString:self.url];
  return url && [url.scheme isEqual:owner.scheme] && [url.host isEqual:owner.host]
    && ((url.port == nil && owner.port == nil) || [url.port isEqual:owner.port]);
}
- (DirectEndpoint *)endpointForView:(WKWebView *)view {
  for (DirectEndpoint *endpoint in self.endpoints)
    if (view && endpoint.view == view) return endpoint;
  return nil;
}
- (DirectEndpoint *)installEndpoint:(WKWebViewConfiguration *)configuration {
  DirectEndpoint *endpoint = [DirectEndpoint new];
  endpoint.identity = [NSString stringWithFormat:@"window-%lu", (unsigned long)self.endpoints.count];
  endpoint.pending = [NSMutableDictionary dictionary];
  endpoint.active = YES;
  endpoint.controller = [WKUserContentController new];
  [endpoint.controller addScriptMessageHandler:self name:@"directProbe"];
  NSString *source = [NSString stringWithContentsOfFile:
    [self.root stringByAppendingPathComponent:@"direct-bootstrap.js"]
    encoding:NSUTF8StringEncoding error:nil];
  NSAssert(source != nil, @"missing fixture bootstrap");
  [endpoint.controller addUserScript:[[WKUserScript alloc] initWithSource:source
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
  // Preserve the supplied relationship/data store. Replace, never mutate, the
  // owner's content controller or copy its window-specific bridge registration.
  configuration.userContentController = endpoint.controller;
  [self.endpoints addObject:endpoint];
  return endpoint;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  self.windows = [NSMutableArray array];
  self.endpoints = [NSMutableArray array];
  self.observations = [NSMutableArray array];
  self.result = 2;
  WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
  configuration.preferences.javaScriptCanOpenWindowsAutomatically = YES;
  [configuration setURLSchemeHandler:self forURLScheme:@"zapp"];
  DirectEndpoint *owner = [self installEndpoint:configuration];
  self.mainView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
  owner.view = self.mainView;
  self.parent = [self host:self.mainView title:@"Direct bridge: owner" child:NO];
  [self.mainView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:self.url]]];
  [NSApp activate];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (!self.finished) [self finish:@{@"pass": @NO, @"error": @"native 20-second deadline"}];
  });
}
- (WKWebView *)webView:(WKWebView *)view
  createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
  forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
  (void)features;
  DirectEndpoint *owner = [self endpointForView:view];
  if (view != self.mainView || !owner.active || !owner.ready
      || self.ownerCloseExpected || action.targetFrame != nil) return nil;
  DirectEndpoint *endpoint = [self installEndpoint:configuration];
  WKWebView *child = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
  endpoint.view = child;
  [self host:child title:@"Direct bridge: child" child:YES];
  self.createdChildren++;
  return child;
}
- (void)invalidate:(DirectEndpoint *)endpoint closing:(BOOL)closing {
  if (!endpoint) return;
  NSString *oldToken = endpoint.documentToken;
  endpoint.generation++;
  endpoint.ready = NO;
  endpoint.documentToken = nil;
  self.dropped += endpoint.pending.count;
  [endpoint.pending removeAllObjects];
  if (closing) {
    endpoint.active = NO;
    [endpoint.controller removeScriptMessageHandlerForName:@"directProbe"];
  }
  DirectEndpoint *owner = [self endpointForView:self.mainView];
  if (oldToken && endpoint != owner && owner.active && owner.ready && !self.finishingFixture) {
    NSString *ownerToken = owner.documentToken;
    NSDictionary *event = @{@"windowId": endpoint.identity, @"token": oldToken,
      @"reason": closing ? @"native-close" : @"document-replaced"};
    NSString *script = [NSString stringWithFormat:
      @"(()=>{const b=globalThis.__directBridge;if(b?.token===(%@)[0])b.invalidateChild(%@)})()",
      [self json:@[ownerToken]], [self json:event]];
    self.invalidationNotifications++;
    // Fire-and-forget lifecycle notification, never an acknowledgement gate
    // for native closure. Ordinary service replies still target the child.
    [self.mainView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
      (void)value;
      if (error && !self.finished && owner.ready && [owner.documentToken isEqual:ownerToken])
        [self finish:@{@"pass": @NO, @"error": error.description}];
    }];
  }
}
- (void)webView:(WKWebView *)view didStartProvisionalNavigation:(WKNavigation *)navigation {
  (void)navigation;
  // This oracle conservatively invalidates the family when owner replacement
  // begins. Production must run its navigation/close cancellation preflight
  // before reaching this point and define failed-navigation behavior.
  if (view == self.mainView && [self endpointForView:view].ready)
    for (NSWindow *window in [self.windows copy])
      if (window != self.parent) [window close];
  [self invalidate:[self endpointForView:view] closing:NO];
}
- (void)evaluate:(NSString *)script in:(WKWebView *)view {
  [view evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
    (void)value;
    if (error && !self.finished)
      [self finish:@{@"pass": @NO, @"error": error.description}];
  }];
}
- (NSString *)json:(id)value {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation {
  (void)navigation;
  DirectEndpoint *endpoint = [self endpointForView:view];
  if (!endpoint.active || ![self isAppOrigin:view.URL]) return;
  endpoint.documentToken = NSUUID.UUID.UUIDString;
  endpoint.ready = YES;
  NSDictionary *binding = @{@"windowId": endpoint.identity, @"token": endpoint.documentToken};
  [self evaluate:[NSString stringWithFormat:@"globalThis.__directBridge.activate(%@);void 0", [self json:binding]] in:view];
}
- (void)reply:(NSDictionary *)value request:(NSDictionary *)request endpoint:(DirectEndpoint *)endpoint {
  // The request belongs to a particular live document, not just an NSWindow.
  // JS also checks the token, covering navigation between scheduling an eval
  // and its execution in the WebContent process.
  NSNumber *requestId = request[@"id"];
  if (!endpoint.active || !endpoint.ready || endpoint.pending[requestId] != request
      || ![request[@"token"] isEqual:endpoint.documentToken]) return;
  [endpoint.pending removeObjectForKey:requestId];
  NSDictionary *reply = @{@"id": requestId, @"token": endpoint.documentToken,
    @"windowId": endpoint.identity, @"value": value};
  [self evaluate:[NSString stringWithFormat:@"globalThis.__directBridge.accept(%@);void 0", [self json:reply]] in:endpoint.view];
}
- (void)webViewDidClose:(WKWebView *)view {
  // WebKit reports DOM close() after it succeeds. This is terminal cleanup,
  // not the cancellable native performClose:/windowShouldClose: path below.
  for (NSWindow *window in [self.windows copy])
    if (window.contentView == view) { [window close]; break; }
}
- (BOOL)windowShouldClose:(NSWindow *)window {
  // Simulates synchronous native closeRequested cancellation, NOT a JS
  // callback or browser beforeunload. Preflight the whole family before any
  // invalidation, so a child veto cannot leave its siblings half-destroyed.
  DirectEndpoint *candidate = [self endpointForView:(WKWebView *)window.contentView];
  BOOL veto = candidate.vetoClose;
  if (window == self.parent)
    for (DirectEndpoint *endpoint in self.endpoints)
      if (endpoint.active && endpoint.vetoClose) veto = YES;
  if (veto) self.cancelledCloses++;
  return !veto;
}
- (void)windowWillClose:(NSNotification *)notification {
  NSWindow *window = notification.object;
  DirectEndpoint *endpoint = [self endpointForView:(WKWebView *)window.contentView];
  [self invalidate:endpoint closing:YES];
  if (window != self.parent) self.closedChildren++;
  [self.windows removeObject:window];
  if (window == self.parent && !self.finished) {
    // Owner loss is terminal for this family. Cancellation preflight is a
    // framework integration gate; this test begins after closure is accepted.
    for (NSWindow *child in [self.windows copy]) [child close];
    BOOL noLiveEndpoints = YES;
    for (DirectEndpoint *candidate in self.endpoints)
      if (candidate.active || candidate.pending.count) noLiveEndpoints = NO;
    BOOL pass = self.ownerCloseExpected && noLiveEndpoints && self.dropped == 2;
    [self finish:@{@"pass": @(pass), @"ownerClosureInvalidatedFamily": @(noLiveEndpoints),
      @"assertions": self.ownerCloseAssertions ?: @[],
      @"error": pass ? @"" : @"owner closure did not invalidate exactly two pending requests"}];
  }
}
- (void)userContentController:(WKUserContentController *)controller
  didReceiveScriptMessage:(WKScriptMessage *)message {
  DirectEndpoint *endpoint = [self endpointForView:message.webView];
  if (!endpoint.active || endpoint.controller != controller) return;
  if (!message.frameInfo.mainFrame) { self.deniedFrames++; return; }
  if (![self isAppOrigin:message.frameInfo.request.URL] || ![self isAppOrigin:message.webView.URL]) {
    self.deniedOrigins++;
    return;
  }
  if (![message.body isKindOfClass:NSDictionary.class]) return;
  NSDictionary *body = message.body;
  if (!endpoint.ready || ![body[@"token"] isEqual:endpoint.documentToken]) {
    self.deniedTokens++;
    return;
  }
  NSNumber *requestId = body[@"id"];
  if (![requestId isKindOfClass:NSNumber.class] || endpoint.pending[requestId]) return;
  endpoint.pending[requestId] = body;
  NSString *method = body[@"method"];
  NSDictionary *arguments = body[@"args"] ?: @{};
  [self.observations addObject:@{@"windowId": endpoint.identity, @"id": requestId,
    @"method": method, @"marker": arguments[@"marker"] ?: @""}];
  if ([method isEqual:@"echo"]) {
    [self reply:@{@"sender": endpoint.identity, @"id": requestId,
      @"marker": arguments[@"marker"] ?: @""} request:body endpoint:endpoint];
  } else if ([method isEqual:@"delayed"]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      if (!self.finished) [self reply:@{@"sender": endpoint.identity, @"marker": arguments[@"marker"] ?: @""}
        request:body endpoint:endpoint];
    });
  } else if (endpoint.view == self.mainView && [method isEqual:@"stats"]) {
    [self reply:@{@"observations": self.observations.copy, @"dropped": @(self.dropped),
      @"deniedFrames": @(self.deniedFrames), @"deniedOrigins": @(self.deniedOrigins),
      @"deniedTokens": @(self.deniedTokens),
      @"previousAssertions": self.ownerCloseAssertions ?: @[],
      @"cancelledCloses": @(self.cancelledCloses),
      @"invalidationNotifications": @(self.invalidationNotifications),
      @"closedChildren": @(self.closedChildren)} request:body endpoint:endpoint];
  } else if (endpoint.view == self.mainView && [method isEqual:@"veto-close"]) {
    for (DirectEndpoint *target in self.endpoints)
      if (target.active && [target.identity isEqual:arguments[@"target"]]) target.vetoClose = [arguments[@"veto"] boolValue];
    [self reply:@{} request:body endpoint:endpoint];
  } else if (endpoint.view == self.mainView && [method isEqual:@"close-child"]) {
    for (NSWindow *window in [self.windows copy]) {
      DirectEndpoint *child = [self endpointForView:(WKWebView *)window.contentView];
      if (window != self.parent && [child.identity isEqual:arguments[@"target"]]) [window performClose:nil];
    }
    [self reply:@{} request:body endpoint:endpoint];
  } else if (endpoint.view == self.mainView && [method isEqual:@"reload-owner"]) {
    [endpoint.pending removeObjectForKey:requestId];
    self.ownerCloseAssertions = arguments[@"assertions"];
    NSURL *next = [NSURL URLWithString:[self.url stringByAppendingString:@"&phase=replaced"]];
    [self.mainView loadRequest:[NSURLRequest requestWithURL:next]];
  } else if (endpoint.view == self.mainView && [method isEqual:@"close-owner"]) {
    [endpoint.pending removeObjectForKey:requestId];
    self.ownerCloseExpected = YES;
    self.ownerCloseAssertions = arguments[@"assertions"];
    [self.parent performClose:nil];
    if (endpoint.active) {
      self.ownerCloseExpected = NO;
      endpoint.pending[requestId] = body;
      [self reply:@{@"cancelled": @YES} request:body endpoint:endpoint];
    }
  } else if (endpoint.view == self.mainView && [method isEqual:@"finish"]) {
    [endpoint.pending removeObjectForKey:requestId];
    [self finish:arguments];
  } else {
    [self finish:@{@"pass": @NO, @"error": @"unexpected fixture operation"}];
  }
}
- (void)finish:(NSDictionary *)payload {
  self.finishingFixture = YES;
  NSMutableDictionary *result = [payload mutableCopy];
  result[@"dropped"] = @(self.dropped);
  result[@"deniedFrames"] = @(self.deniedFrames);
  result[@"deniedOrigins"] = @(self.deniedOrigins);
  result[@"deniedTokens"] = @(self.deniedTokens);
  result[@"cancelledCloses"] = @(self.cancelledCloses);
  result[@"invalidationNotifications"] = @(self.invalidationNotifications);
  result[@"observations"] = self.observations ?: @[];
  for (DirectEndpoint *endpoint in self.endpoints) [self invalidate:endpoint closing:YES];
  [super finish:result];
}
- (void)webView:(WKWebView *)view startURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)view;
  NSString *name = task.request.URL.lastPathComponent;
  if (![@[@"direct-owner.html", @"direct-child.html", @"direct-app.js"] containsObject:name]) {
    [task didFailWithError:[NSError errorWithDomain:@"direct-probe" code:404 userInfo:nil]];
    return;
  }
  NSData *data = [NSData dataWithContentsOfFile:[self.root stringByAppendingPathComponent:name]];
  if (!data) { [task didFailWithError:[NSError errorWithDomain:@"direct-probe" code:404 userInfo:nil]]; return; }
  NSURLResponse *response = [[NSURLResponse alloc] initWithURL:task.request.URL
    MIMEType:[name hasSuffix:@".js"] ? @"text/javascript" : @"text/html"
    expectedContentLength:data.length textEncodingName:@"utf-8"];
  [task didReceiveResponse:response]; [task didReceiveData:data]; [task didFinish];
}
@end

int main(int argc, const char *argv[]) {
  if (argc != 3) return 64;
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    DirectBridgeProbe *probe = [DirectBridgeProbe new];
    probe.root = [NSString stringWithUTF8String:argv[1]];
    probe.url = [NSString stringWithUTF8String:argv[2]];
    NSApp.delegate = probe;
    [NSApp run];
    NSApp.delegate = nil;
    return probe.result;
  }
}
