// macOS window implementation — pure Objective-C.
// Optimized: cached numeric IDs, direct WebView dispatch (no loop), reusable JS buffer.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "window.h"

// --- Forward declarations ---
extern void darwin_webview_create(void* window_ptr, bool inspectable, const char* url_override);
extern int zapp_dispatch_event(int window_id, int event_id, int w, int h, int x, int y);

// Event IDs (mirrored from window/events.zc)
#ifndef ZAPP_EVENT_WINDOW_READY
#define ZAPP_EVENT_WINDOW_READY       0
#define ZAPP_EVENT_WINDOW_FOCUS       1
#define ZAPP_EVENT_WINDOW_BLUR        2
#define ZAPP_EVENT_WINDOW_RESIZE      3
#define ZAPP_EVENT_WINDOW_MOVE        4
#define ZAPP_EVENT_WINDOW_CLOSE       5
#define ZAPP_EVENT_WINDOW_MINIMIZE    6
#define ZAPP_EVENT_WINDOW_MAXIMIZE    7
#define ZAPP_EVENT_WINDOW_RESTORE     8
#define ZAPP_EVENT_WINDOW_FULLSCREEN  9
#define ZAPP_EVENT_WINDOW_UNFULLSCREEN 10
#endif
#ifndef ZAPP_EVENT_RESULT_CANCEL
#define ZAPP_EVENT_RESULT_CANCEL 1
#endif

// --- Direct WebView dispatch table ---
// Indexed by numeric window ID. No string lookup, no iteration.

#ifndef ZAPP_MAX_WINDOW_CALLBACKS
#define ZAPP_MAX_WINDOW_CALLBACKS 64
#endif

static WKWebView* zapp_webviews[ZAPP_MAX_WINDOW_CALLBACKS] = {0};
static NSString* zapp_window_ids[ZAPP_MAX_WINDOW_CALLBACKS] = {0};

static void zapp_register_webview(int32_t numericId, WKWebView* webview, NSString* windowId) {
    if (numericId >= 0 && numericId < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_webviews[numericId] = webview;
        zapp_window_ids[numericId] = windowId;
    }
}

// --- Event name resolution (static strings, zero alloc) ---

static const char* zapp_event_names[] = {
    "ready", "focus", "blur", "resize", "move", "close",
    "minimize", "maximize", "restore", "fullscreen", "unfullscreen"
};

static inline const char* zapp_get_event_name(int event_id) {
    if (event_id >= 0 && event_id < 11) return zapp_event_names[event_id];
    return "unknown";
}

// --- Targeted JS dispatch (Layer 2 of unified dispatcher) ---
// Fires evaluateJavaScript on THIS window's WebView only.
// Uses reusable C buffer — no NSString formatting per event.

static char zapp_js_buf[512]; // Reusable buffer for event JS

void zapp_dispatch_event_to_js(int32_t window_id, int32_t event_id, int32_t w, int32_t h, int32_t x, int32_t y) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    WKWebView* webview = zapp_webviews[window_id];
    NSString* windowId = zapp_window_ids[window_id];
    if (!webview || !windowId) return;

    const char* event_name = zapp_get_event_name(event_id);
    const char* wid = [windowId UTF8String];

    // Build JS into reusable buffer
    bool hasPayload = (event_id == ZAPP_EVENT_WINDOW_RESIZE || event_id == ZAPP_EVENT_WINDOW_MOVE ||
                       event_id == ZAPP_EVENT_WINDOW_MAXIMIZE || event_id == ZAPP_EVENT_WINDOW_RESTORE);
    if (hasPayload) {
        snprintf(zapp_js_buf, sizeof(zapp_js_buf),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&typeof b.dispatchWindowEvent==='function'){"
            "b.dispatchWindowEvent('%s','%s','{\"width\":%d,\"height\":%d,\"x\":%d,\"y\":%d}');}})();",
            wid, event_name, w, h, x, y);
    } else {
        snprintf(zapp_js_buf, sizeof(zapp_js_buf),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&typeof b.dispatchWindowEvent==='function'){"
            "b.dispatchWindowEvent('%s','%s');}})();",
            wid, event_name);
    }

    NSString* js = [[NSString alloc] initWithBytesNoCopy:zapp_js_buf
        length:strlen(zapp_js_buf)
        encoding:NSUTF8StringEncoding
        freeWhenDone:NO];
    [webview evaluateJavaScript:js completionHandler:nil];
}

// --- Window Delegate ---
// numericId cached — zero lookup cost per event.

static const char kZappWindowDelegateKey = 0;

@interface ZappWindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, copy) NSString* ownerId;
@property (nonatomic, copy) NSString* windowId;
@property (nonatomic, assign) int32_t numericId;
@property (nonatomic, assign) BOOL bridgeReady;
@property (nonatomic, assign) BOOL pendingFocusEvent;
@property (nonatomic, assign) BOOL wasZoomed;
@end

@implementation ZappWindowDelegate
- (instancetype)init {
    self = [super init];
    if (self) {
        _numericId = -1;
        _bridgeReady = NO;
        _pendingFocusEvent = NO;
        _wasZoomed = NO;
    }
    return self;
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
    (void)sender;
    if (self.numericId >= 0) {
        int result = zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_CLOSE, 0, 0, 0, 0);
        if (result == ZAPP_EVENT_RESULT_CANCEL) return NO;
    }
    return YES;
}

- (void)windowWillClose:(NSNotification*)notification {
    (void)notification;
    // Clear from dispatch table
    if (self.numericId >= 0 && self.numericId < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_webviews[self.numericId] = nil;
        zapp_window_ids[self.numericId] = nil;
    }
    // TODO: worker cleanup via owner ID
}

- (void)windowDidBecomeKey:(NSNotification*)notification {
    (void)notification;
    if (self.numericId < 0) return;
    if (self.bridgeReady) {
        zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_FOCUS, 0, 0, 0, 0);
    } else {
        self.pendingFocusEvent = YES;
    }
}

- (void)windowDidResignKey:(NSNotification*)notification {
    (void)notification;
    if (self.numericId >= 0)
        zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_BLUR, 0, 0, 0, 0);
}

- (void)windowDidResize:(NSNotification*)notification {
    NSWindow* window = (NSWindow*)[notification object];
    if (self.numericId < 0 || !window) return;
    NSRect frame = [window frame];
    int w = (int)frame.size.width, h = (int)frame.size.height;
    int x = (int)frame.origin.x, y = (int)frame.origin.y;
    zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_RESIZE, w, h, x, y);
    BOOL isZoomed = [window isZoomed];
    if (isZoomed && !self.wasZoomed)
        zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_MAXIMIZE, w, h, x, y);
    else if (!isZoomed && self.wasZoomed)
        zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_RESTORE, w, h, x, y);
    self.wasZoomed = isZoomed;
}

- (void)windowDidMove:(NSNotification*)notification {
    NSWindow* window = (NSWindow*)[notification object];
    if (self.numericId < 0 || !window) return;
    NSRect frame = [window frame];
    zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_MOVE,
        (int)frame.size.width, (int)frame.size.height,
        (int)frame.origin.x, (int)frame.origin.y);
}

- (void)windowDidMiniaturize:(NSNotification*)notification {
    (void)notification;
    if (self.numericId >= 0)
        zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_MINIMIZE, 0, 0, 0, 0);
}

- (void)windowDidDeminiaturize:(NSNotification*)notification {
    (void)notification;
    if (self.numericId >= 0)
        zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_RESTORE, 0, 0, 0, 0);
}

- (void)windowDidEnterFullScreen:(NSNotification*)notification {
    (void)notification;
    if (self.numericId >= 0)
        zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_FULLSCREEN, 0, 0, 0, 0);
}

- (void)windowDidExitFullScreen:(NSNotification*)notification {
    (void)notification;
    if (self.numericId >= 0)
        zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_UNFULLSCREEN, 0, 0, 0, 0);
}
@end

// --- Lookup numeric ID from WebView pointer ---

int32_t darwin_window_id_for_webview(void* webview) {
    if (!webview) return 0;
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_webviews[i] == (__bridge WKWebView*)webview) return i;
    }
    return 0;
}

// --- Get string window ID for a numeric ID ---

const char* darwin_window_id_string(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_window_ids[numeric_id]) {
        return [zapp_window_ids[numeric_id] UTF8String];
    }
    return NULL;
}

// --- Get WebView by numeric ID (O(1)) ---

void* darwin_window_get_webview(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_webviews[numeric_id]) {
        return (__bridge void*)zapp_webviews[numeric_id];
    }
    return NULL;
}

// --- JS eval on specific window (by numeric ID, O(1) lookup) ---

void darwin_window_eval_js(int32_t window_id, const char* js) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    WKWebView* webview = zapp_webviews[window_id];
    if (!webview || !js) return;
    // Copy the source string — callers frequently pass thread-local or static
    // buffers that can be overwritten before WebKit reads them.
    // Also bounce to main thread because evaluateJavaScript: requires it.
    NSString* script = [NSString stringWithUTF8String:js];
    if (!script) return;
    if ([NSThread isMainThread]) {
        [webview evaluateJavaScript:script completionHandler:nil];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [webview evaluateJavaScript:script completionHandler:nil];
        });
    }
}

// Bridge readiness
void darwin_window_set_bridge_ready(const char* window_id) {
    if (!window_id) return;
    NSString* wid = [NSString stringWithUTF8String:window_id];
    // Find delegate by iterating — only called once per window, not hot path
    for (NSWindow* window in [NSApp windows]) {
        ZappWindowDelegate* delegate = (ZappWindowDelegate*)[window delegate];
        if ([delegate isKindOfClass:[ZappWindowDelegate class]] &&
            [delegate.windowId isEqualToString:wid]) {
            delegate.bridgeReady = YES;
            if (delegate.pendingFocusEvent) {
                delegate.pendingFocusEvent = NO;
                if (delegate.numericId >= 0)
                    zapp_dispatch_event_to_js(delegate.numericId, ZAPP_EVENT_WINDOW_FOCUS, 0, 0, 0, 0);
            }
            break;
        }
    }
}

// --- Window C API ---

void* darwin_window_create(WindowOptions* opts) {
    @autoreleasepool {
        NSUInteger styleMask = 0;
        if (!wopts_borderless(opts)) {
            styleMask |= NSWindowStyleMaskTitled;
            if (wopts_closable(opts))     styleMask |= NSWindowStyleMaskClosable;
            if (wopts_minimizable(opts))  styleMask |= NSWindowStyleMaskMiniaturizable;
            if (wopts_resizable(opts))    styleMask |= NSWindowStyleMaskResizable;
        } else {
            styleMask = NSWindowStyleMaskBorderless;
        }

        NSRect frame = NSMakeRect(wopts_x(opts), wopts_y(opts), wopts_width(opts), wopts_height(opts));
        NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
            styleMask:styleMask backing:NSBackingStoreBuffered defer:NO];
        [window setReleasedWhenClosed:NO];

        char* title = wopts_title(opts);
        NSString* titleStr = title ? [NSString stringWithUTF8String:title] : nil;
        // Defensive: stringWithUTF8String returns nil for invalid UTF-8.
        // setTitle: asserts non-nil, so fall back rather than crash.
        [window setTitle:titleStr ?: @"Zapp"];

        int32_t tbs = wopts_title_bar_style_tag(opts);
        if (tbs == 1 || tbs == 2) {
            [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullSizeContentView)];
            [window setTitleVisibility:NSWindowTitleHidden];
            [window setTitlebarAppearsTransparent:YES];
        }
        if (tbs == 2) {
#if defined(NSWindowToolbarStyleUnifiedCompact)
            if ([window respondsToSelector:@selector(setToolbarStyle:)])
                [window setToolbarStyle:NSWindowToolbarStyleUnifiedCompact];
#endif
        }

        if (wopts_transparent(opts)) {
            [window setOpaque:NO];
            [window setBackgroundColor:[NSColor clearColor]];
        }
        if (wopts_always_on_top(opts)) {
            [window setLevel:NSFloatingWindowLevel];
        }

        bool inspectable = wopts_inspectable(opts) > 0;
        extern const char* wopts_url(void* opts);
        const char* custom_url = wopts_url(opts);
        darwin_webview_create((__bridge void*)window, inspectable, custom_url);

        NSString* windowId = [NSString stringWithFormat:@"win-%p", window];
        NSString* ownerId = [NSString stringWithFormat:@"owner-%p", window];
        ZappWindowDelegate* delegate = [[ZappWindowDelegate alloc] init];
        delegate.windowId = windowId;
        delegate.ownerId = ownerId;
        // numericId set by darwin_window_register_numeric_id after creation
        objc_setAssociatedObject(window, &kZappWindowDelegateKey,
            delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [window setDelegate:delegate];

        if (wopts_fullscreen(opts)) [window toggleFullScreen:nil];
        if (wopts_visible(opts) && !wopts_hidden(opts)) [window makeKeyAndOrderFront:nil];

        return (__bridge_retained void*)window;
    }
}

void darwin_window_destroy(void* handle) {
    NSWindow* window = (__bridge_transfer NSWindow*)handle;
    [window close];
    (void)window;
}

void darwin_window_show(void* handle) {
    [(__bridge NSWindow*)handle makeKeyAndOrderFront:nil];
}

void darwin_window_hide(void* handle) {
    [(__bridge NSWindow*)handle orderOut:nil];
}

void darwin_window_force_close(void* handle) {
    [(__bridge NSWindow*)handle close];
}

void darwin_window_set_title(void* handle, const char* title) {
    if (!title) return;
    NSString* str = [NSString stringWithUTF8String:title];
    if (!str) return;  // invalid UTF-8 / garbage pointer
    [(__bridge NSWindow*)handle setTitle:str];
}

void darwin_window_set_size(void* handle, int32_t width, int32_t height) {
    NSWindow* w = (__bridge NSWindow*)handle;
    NSRect frame = [w frame];
    frame.size = NSMakeSize(width, height);
    [w setFrame:frame display:YES animate:YES];
}

void darwin_window_set_position(void* handle, int32_t x, int32_t y) {
    [(__bridge NSWindow*)handle setFrameOrigin:NSMakePoint(x, y)];
}

void darwin_window_minimize(void* handle) {
    [(__bridge NSWindow*)handle miniaturize:nil];
}

void darwin_window_maximize(void* handle) {
    NSWindow* w = (__bridge NSWindow*)handle;
    if (![w isZoomed]) [w zoom:nil];
}

void darwin_window_set_fullscreen(void* handle, bool on) {
    NSWindow* w = (__bridge NSWindow*)handle;
    bool isFS = (([w styleMask] & NSWindowStyleMaskFullScreen) != 0);
    if (on != isFS) [w toggleFullScreen:nil];
}

void darwin_window_set_always_on_top(void* handle, bool on) {
    [(__bridge NSWindow*)handle setLevel:on ? NSFloatingWindowLevel : NSNormalWindowLevel];
}

void darwin_window_get_size(void* handle, int32_t* out_w, int32_t* out_h) {
    NSRect frame = [(__bridge NSWindow*)handle frame];
    *out_w = (int32_t)frame.size.width;
    *out_h = (int32_t)frame.size.height;
}

void darwin_window_get_position(void* handle, int32_t* out_x, int32_t* out_y) {
    NSRect frame = [(__bridge NSWindow*)handle frame];
    *out_x = (int32_t)frame.origin.x;
    *out_y = (int32_t)frame.origin.y;
}

void darwin_window_register_numeric_id(void* handle, int32_t numeric_id) {
    NSWindow* w = (__bridge NSWindow*)handle;
    NSString* windowId = [NSString stringWithFormat:@"win-%p", w];

    // Cache numericId on delegate for O(1) event dispatch
    ZappWindowDelegate* delegate = (ZappWindowDelegate*)[w delegate];
    if ([delegate isKindOfClass:[ZappWindowDelegate class]]) {
        delegate.numericId = numeric_id;
    }

    // Register WebView in direct dispatch table
    NSView* content = [w contentView];
    if ([content isKindOfClass:[WKWebView class]]) {
        zapp_register_webview(numeric_id, (WKWebView*)content, windowId);
    }
}
