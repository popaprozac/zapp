// Experimental AppKit/WebKit oracle, never linked into Zapp. No NSWindow
// subclass: in particular, delegate-zoom tests whether composition is enough.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>

static NSRect interpolateFrame(NSRect start, NSRect target, double progress) {
    double p = fmin(1, fmax(0, progress));
    double eased = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2;
    return NSMakeRect(start.origin.x + (target.origin.x - start.origin.x) * eased,
                     start.origin.y + (target.origin.y - start.origin.y) * eased,
                     start.size.width + (target.size.width - start.size.width) * eased,
                     start.size.height + (target.size.height - start.size.height) * eased);
}

static NSDictionary *frameValue(NSRect frame) {
    return @{ @"x": @(frame.origin.x), @"y": @(frame.origin.y),
              @"width": @(frame.size.width), @"height": @(frame.size.height) };
}

// Bounded POD capture avoids allocating NSNumber/dictionary graphs on each
// display callback. Serialization happens only after the observation ends.
typedef struct {
    double t, nativeWidth, nativeHeight, domWidth, domHeight, pageTime;
    NSInteger phase;
    unsigned char source;
} ResizeSample;
static const NSUInteger maximumSamples = 8192;

@interface ResizeProbe : NSObject <NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@property NSString *mode;
@property NSWindow *window;
@property WKWebView *webView;
@property CADisplayLink *displayLink;
@property NSMutableArray<NSTimer *> *timers;
@property NSMutableData *sampleData;
@property NSMutableArray<NSDictionary *> *legs;
@property NSRect original;
@property NSRect enlarged;
@property NSRect startFrame;
@property NSRect targetFrame;
@property double animationStart;
@property double duration;
@property double epoch;
@property double domWidth;
@property double domHeight;
@property double pageTime;
@property double legStartedAt;
@property double requestedDuration;
@property NSInteger phase;
@property NSInteger resizeNotifications;
@property NSInteger displayCallbacks;
@property NSInteger callbacksAfterClose;
@property NSInteger animationWrites;
@property NSInteger skippedWrites;
@property NSInteger droppedSamples;
@property NSInteger zoomRequests;
@property NSInteger status;
@property BOOL animating;
@property BOOL ready;
@property BOOL finished;
@property BOOL closed;
@property BOOL reduceMotion;
@property BOOL matchBackground;
@property BOOL coordinateFrames;
@end

@implementation ResizeProbe
- (void)after:(double)seconds perform:(void (^)(void))operation {
    NSTimer *timer = [NSTimer timerWithTimeInterval:seconds repeats:NO
                                           block:^(__unused NSTimer *fired) { operation(); }];
    [self.timers addObject:timer];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}
- (void)record:(NSString *)source {
    NSSize content = self.webView.bounds.size;
    if (self.sampleData.length / sizeof(ResizeSample) >= maximumSamples) {
        self.droppedSamples += 1;
        return;
    }
    ResizeSample sample = {
        .t = CACurrentMediaTime() - self.epoch, .phase = self.phase,
        .source = [source isEqualToString:@"display"] ? 0 : [source isEqualToString:@"resize"] ? 1 : 2,
        .nativeWidth = content.width, .nativeHeight = content.height,
        .domWidth = self.domWidth, .domHeight = self.domHeight, .pageTime = self.pageTime,
    };
    [self.sampleData appendBytes:&sample length:sizeof(sample)];
}
- (NSArray *)serializedSamples {
    NSMutableArray *result = [NSMutableArray new];
    const ResizeSample *samples = self.sampleData.bytes;
    for (NSUInteger i = 0; i < self.sampleData.length / sizeof(ResizeSample); i += 1) {
        ResizeSample sample = samples[i];
        [result addObject:@{
            @"t": @(sample.t), @"phase": @(sample.phase),
            @"source": sample.source == 0 ? @"display" : sample.source == 1 ? @"resize" : @"dom",
            @"nativeWidth": @(sample.nativeWidth), @"nativeHeight": @(sample.nativeHeight),
            @"domWidth": @(sample.domWidth), @"domHeight": @(sample.domHeight), @"pageTime": @(sample.pageTime),
        }];
    }
    return result;
}
- (void)cancelAnimation {
    self.animating = NO;
}
- (void)startAnimation:(NSRect)target {
    // Retarget from the currently visible geometry, not the old destination.
    [self cancelAnimation];
    self.startFrame = self.window.frame;
    self.targetFrame = target;
    self.duration = [self.window animationResizeTime:target];
    self.animationStart = CACurrentMediaTime();
    if (self.reduceMotion || self.duration <= 0) {
        [self.window setFrame:target display:YES animate:NO];
        return;
    }
    self.animating = YES;
}
- (void)display:(CADisplayLink *)link {
    if (self.closed) self.callbacksAfterClose += 1;
    if (self.finished || self.closed) return;
    self.displayCallbacks += 1;
    if (self.animating) {
        double progress = (link.targetTimestamp - self.animationStart) / self.duration;
        NSRect frame = interpolateFrame(self.startFrame, self.targetFrame, progress);
        if (self.coordinateFrames) {
            // Alignment operates in window coordinates, not screen coordinates.
            // Keep the exact requested endpoint; AppKit applies its constraints.
            if (progress < 1) {
                NSRect local = [self.window convertRectFromScreen:frame];
                local = [self.window backingAlignedRect:local options:NSAlignAllEdgesNearest];
                frame = [self.window convertRectToScreen:local];
            }
            if (!NSEqualRects(frame, self.window.frame)) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                [self.window setFrame:frame display:NO animate:NO];
                [CATransaction commit];
                self.animationWrites += 1;
            } else self.skippedWrites += 1;
        } else {
            [self.window setFrame:frame display:YES animate:NO];
            self.animationWrites += 1;
        }
        if (progress >= 1) self.animating = NO;
    }
    [self record:@"display"];
}
- (BOOL)windowShouldZoom:(NSWindow *)window toFrame:(NSRect)newFrame {
    (void)window;
    self.zoomRequests += 1;
    if (![self.mode isEqualToString:@"delegate-zoom"] &&
        ![self.mode isEqualToString:@"interrupted-zoom"]) return YES;
    // Deliberately do NOT track/replace AppKit's restore frame. We are testing
    // whether the delegate alone preserves the native standard/user pair.
    [self startAnimation:newFrame];
    return NO;
}
- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    self.resizeNotifications += 1;
    [self record:@"resize"];
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    self.closed = YES;
    [self cancelAnimation];
    [self.displayLink invalidate];
    self.displayLink = nil;
    if (![self.mode isEqualToString:@"close-size"] && !self.finished) {
        [self finish:@"window closed before the probe completed"];
    }
}
- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;
    if (self.finished || self.closed) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = message.body;
    if ([body[@"error"] isKindOfClass:[NSString class]]) { [self finish:body[@"error"]]; return; }
    if (![body[@"width"] isKindOfClass:[NSNumber class]] ||
        ![body[@"height"] isKindOfClass:[NSNumber class]]) return;
    self.domWidth = [body[@"width"] doubleValue];
    self.domHeight = [body[@"height"] doubleValue];
    if ([body[@"pageTime"] isKindOfClass:[NSNumber class]]) self.pageTime = [body[@"pageTime"] doubleValue];
    [self record:@"dom"];
    if (!self.ready) {
        self.ready = YES;
        __weak ResizeProbe *weakSelf = self;
        [self after:0.2 perform:^{ [weakSelf beginLeg]; }];
    }
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView; (void)navigation;
    [self finish:error.localizedDescription];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    (void)webView;
    [self finish:@"WebKit content process terminated"];
}
- (void)beginLeg {
    if (self.finished) return;
    self.phase += 1;
    NSRect target = self.phase == 1 ? self.enlarged : self.original;
    self.legStartedAt = CACurrentMediaTime() - self.epoch;
    self.requestedDuration = self.reduceMotion ? 0 : [self.window animationResizeTime:target];
    __weak ResizeProbe *weakSelf = self;
    // Allow geometry/IPC to settle before inspecting the result. This is not
    // a performance assertion; display and DOM histories are reported below.
    [self after:1.0 perform:^{ [weakSelf endLeg]; }];
    if ([self.mode hasSuffix:@"zoom"]) {
        [self.window zoom:nil];
        if ([self.mode isEqualToString:@"interrupted-zoom"]) {
            [self after:fmax(0.01, self.duration / 2) perform:^{ [weakSelf.window zoom:nil]; }];
        }
    } else if ([self.mode isEqualToString:@"appkit-size"]) {
        [self.window setFrame:target display:YES animate:!self.reduceMotion];
    } else {
        [self startAnimation:target];
        if (self.phase == 1 && [self.mode isEqualToString:@"retarget-size"]) {
            [self after:fmax(0.01, self.duration / 2) perform:^{
                ResizeProbe *probe = weakSelf;
                if (probe && !probe.finished) [probe startAnimation:probe.original];
            }];
        }
        if (self.phase == 1 && [self.mode isEqualToString:@"close-size"]) {
            [self after:fmax(0.01, self.duration / 2) perform:^{ [weakSelf.window close]; }];
        }
    }
}
- (void)endLeg {
    if (self.finished) return;
    [self.legs addObject:@{
        @"phase": @(self.phase), @"frame": frameValue(self.window.frame),
        @"startedAt": @(self.legStartedAt), @"duration": @(self.requestedDuration),
        @"isZoomed": @(self.window.isZoomed), @"animating": @(self.animating),
        @"closed": @(self.closed), @"displayCallbacks": @(self.displayCallbacks),
        @"animationWrites": @(self.animationWrites), @"resizeNotifications": @(self.resizeNotifications),
        @"skippedWrites": @(self.skippedWrites),
    }];
    if (self.phase == 1 && ![self.mode isEqualToString:@"close-size"] &&
        ![self.mode isEqualToString:@"retarget-size"] &&
        ![self.mode isEqualToString:@"interrupted-zoom"]) {
        __weak ResizeProbe *weakSelf = self;
        [self after:0.2 perform:^{ [weakSelf beginLeg]; }];
    } else {
        [self finish:nil];
    }
}
- (void)finish:(NSString *)error {
    if (self.finished) return;
    self.finished = YES;
    self.status = error ? 1 : 0;
    [self cancelAnimation];
    [self.displayLink invalidate];
    self.displayLink = nil;
    for (NSTimer *timer in self.timers) [timer invalidate];
    NSUInteger activeTimers = 0;
    for (NSTimer *timer in self.timers) if (timer.valid) activeTimers += 1;
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"probe"];
    NSDictionary *report = @{
        @"instrumentationVersion": @2, @"droppedSamples": @(self.droppedSamples),
        @"mode": self.mode, @"error": error ?: (id)[NSNull null],
        @"matchBackground": @(self.matchBackground), @"coordinateFrames": @(self.coordinateFrames),
        @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"maximumFramesPerSecond": @(self.window.screen.maximumFramesPerSecond),
        @"backingScaleFactor": @(self.window.backingScaleFactor),
        @"reduceMotion": @(self.reduceMotion), @"original": frameValue(self.original),
        @"enlarged": frameValue(self.enlarged), @"final": frameValue(self.window.frame),
        @"zoomRequests": @(self.zoomRequests), @"closed": @(self.closed),
        @"callbacksAfterClose": @(self.callbacksAfterClose),
        @"activeTimersAfterFinish": @(activeTimers),
        @"animationStopped": @((BOOL)(!self.animating && self.displayLink == nil)),
        @"legs": self.legs, @"samples": [self serializedSamples],
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout); }
    self.window.delegate = nil;
    self.webView.navigationDelegate = nil;
    [self.webView stopLoading];
    [self.window close];
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
}
- (void)begin {
    self.timers = [NSMutableArray new];
    self.sampleData = [NSMutableData dataWithCapacity:maximumSamples * sizeof(ResizeSample)];
    self.legs = [NSMutableArray new];
    self.epoch = CACurrentMediaTime();
    self.reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    self.matchBackground = [self.mode isEqualToString:@"background-size"] || [self.mode isEqualToString:@"combined-size"];
    self.coordinateFrames = [self.mode isEqualToString:@"coordinated-size"] || [self.mode isEqualToString:@"combined-size"];
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    if (screen.size.width < 400 || screen.size.height < 300) { self.status = 2; return; }
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, screen.size.width * 0.45,
        screen.size.height * 0.45) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed = NO;
    self.window.title = [@"Zapp resize probe: " stringByAppendingString:self.mode];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    [configuration.userContentController addScriptMessageHandler:self name:@"probe"];
    self.webView = [[WKWebView alloc] initWithFrame:self.window.contentView.bounds configuration:configuration];
    self.window.contentView = self.webView;
    self.webView.navigationDelegate = self;
    if (self.matchBackground) {
        // Same #15212b as the page, no CSS changes. This is a visual control,
        // not a claim that matching the underlay makes WebKit paint sooner.
        NSColor *background = [NSColor colorWithSRGBRed:21.0/255 green:33.0/255 blue:43.0/255 alpha:1];
        self.window.backgroundColor = background;
        self.webView.underPageBackgroundColor = background;
    }
    [self.window center];
    self.original = self.window.frame;
    self.enlarged = NSMakeRect(screen.origin.x + screen.size.width * 0.075,
        screen.origin.y + screen.size.height * 0.075, screen.size.width * 0.85, screen.size.height * 0.85);
    self.window.delegate = self;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activate];
    self.displayLink = [self.window displayLinkWithTarget:self selector:@selector(display:)];
    float maximum = (float)self.window.screen.maximumFramesPerSecond;
    if (maximum > 0) self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(fminf(60, maximum), maximum, maximum);
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSString *html = @"<!doctype html><meta name='viewport' content='width=device-width, initial-scale=1'>"
        "<style>html{background:#15212b;color:#eef;font:18px system-ui}body{margin:0;padding:20px}"
        "#grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:12px}"
        ".card{background:#2c4a60;border:1px solid #73b2c6;border-radius:12px;padding:20px}"
        "#edge{position:fixed;bottom:0;right:0;padding:12px;background:#baeeae;color:#14251d}</style>"
        "<h1>Live viewport / responsive layout</h1><p id='size'></p><div id='grid'></div><div id='edge'>Bottom right</div>"
        "<script>addEventListener('error',e=>webkit.messageHandlers.probe.postMessage({error:e.message}));"
        "document.getElementById('grid').innerHTML=Array.from({length:18},(_,i)=>'<div class=card>Note '+(i+1)+'</div>').join('');"
        "let previous='',heartbeat=0;function tick(){const key=innerWidth+','+innerHeight;"
        "if(key!==previous||++heartbeat%30===0){previous=key;document.getElementById('size').textContent=innerWidth+' × '+innerHeight;"
        "webkit.messageHandlers.probe.postMessage({width:innerWidth,height:innerHeight,pageTime:performance.now()});}requestAnimationFrame(tick)}"
        "requestAnimationFrame(tick)</script>";
    [self.webView loadHTMLString:html baseURL:nil];
    __weak ResizeProbe *weakSelf = self;
    [self after:25 perform:^{ [weakSelf finish:@"WebView/display probe exceeded its deadline"]; }];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        ResizeProbe *probe = [ResizeProbe new];
        probe.mode = [NSString stringWithUTF8String:argv[1]];
        [probe begin];
        if (probe.status == 0) [NSApp run];
        return (int)probe.status;
    }
}
