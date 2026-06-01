// macOS window implementation — pure Objective-C.
// Optimized: cached numeric IDs, direct WebView dispatch (no loop), reusable JS buffer.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "window.h"

// --- Forward declarations ---
extern void darwin_webview_create(void* window_ptr, bool inspectable, bool accept_first_mouse,
                                  const char* url_override, int32_t numeric_id_pre_alloc,
                                  bool transparent_background);
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
#define ZAPP_EVENT_WINDOW_MODAL_DISMISSED 11
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
    "minimize", "maximize", "restore", "fullscreen", "unfullscreen",
    "modal-dismissed"
};

static inline const char* zapp_get_event_name(int event_id) {
    if (event_id >= 0 && event_id < 12) return zapp_event_names[event_id];
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

    // Build JS into reusable buffer. MODAL_DISMISSED gets a custom
    // payload: w carries the modal numeric ID (mapped to "win-N") and h
    // carries the NSModalResponse code, exposed as { modalId, code }.
    if (event_id == ZAPP_EVENT_WINDOW_MODAL_DISMISSED) {
        snprintf(zapp_js_buf, sizeof(zapp_js_buf),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&typeof b.dispatchWindowEvent==='function'){"
            "b.dispatchWindowEvent('%s','%s','{\"modalId\":\"win-%d\",\"code\":%d}');}})();",
            wid, event_name, w, h);
    } else {
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
// Auto-show machinery — set in darwin_window_create from WindowOptions,
// cleared by whichever ready signal fires first (bridge_ready primary,
// didFinishNavigation fallback). Once cleared, makeKeyAndOrderFront has
// already happened (or won't happen automatically).
@property (nonatomic, assign) BOOL shouldAutoShow;
@property (nonatomic, assign) BOOL fullscreenOnShow;
@end

@implementation ZappWindowDelegate
- (instancetype)init {
    self = [super init];
    if (self) {
        _numericId = -1;
        _bridgeReady = NO;
        _pendingFocusEvent = NO;
        _wasZoomed = NO;
        _shouldAutoShow = NO;
        _fullscreenOnShow = NO;
    }
    return self;
}

// Apply queued auto-show + fullscreen state. Idempotent — if shouldAutoShow
// is already cleared, this is a no-op. Called from both bridge_ready
// (early, JS bootstrap signaled) and didFinishNavigation (fallback,
// navigation completed). Whichever fires first wins.
- (void)applyAutoShowOnWindow:(NSWindow*)window {
    if (!self.shouldAutoShow || !window) return;
    self.shouldAutoShow = NO;
    [window makeKeyAndOrderFront:nil];
    if (self.fullscreenOnShow) {
        self.fullscreenOnShow = NO;
        [window toggleFullScreen:nil];
    }
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
    // Clear from dispatch table. `close()` is reversible (the window is
    // created with setReleasedWhenClosed:NO, so [window close] orders
    // out but keeps the object alive for a later show()) — we must NOT
    // tear down the WKWebView here, or show-after-close would display
    // a broken webview. Real webview teardown happens in
    // darwin_window_destroy which is the only path that actually
    // releases the NSWindow.
    if (self.numericId >= 0 && self.numericId < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_webviews[self.numericId] = nil;
        zapp_window_ids[self.numericId] = nil;
    }
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

// Reverse lookup: pointer-based JS-visible string ID → numeric ID.
// JS holds windowId as "win-<NSWindow*>" (set by webview.m bootstrap),
// but WindowManager keys by the numeric ID darwin_window_register_numeric_id
// assigns. Multi-window APIs (attachModal/detachModal, asSheetOf) need the
// numeric form to look up the WindowOptions instance, so this maps back.
int32_t darwin_window_numeric_id_for_string(const char* window_id_string) {
    if (!window_id_string || !window_id_string[0]) return -1;
    NSString* target = [NSString stringWithUTF8String:window_id_string];
    if (!target) return -1;
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_window_ids[i] && [zapp_window_ids[i] isEqualToString:target]) {
            return i;
        }
    }
    return -1;
}

// --- Get WebView by numeric ID (O(1)) ---

void* darwin_window_get_webview(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_webviews[numeric_id]) {
        return (__bridge void*)zapp_webviews[numeric_id];
    }
    return NULL;
}

// --- Get NSWindow by numeric ID ---
//
// We don't keep a separate NSWindow dispatch table — the WKWebView is
// always the window's contentView, so `webview.window` is the canonical
// path. Used by features that take a runtime WindowHandle.id (notably
// `tray.attachWindow`).
void* darwin_window_get_by_numeric_id(int32_t numeric_id) {
    if (numeric_id < 0 || numeric_id >= ZAPP_MAX_WINDOW_CALLBACKS) return NULL;
    WKWebView* wv = zapp_webviews[numeric_id];
    if (!wv) return NULL;
    NSWindow* w = wv.window;
    if (!w) return NULL;
    return (__bridge void*)w;
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
            // Primary auto-show path — bridge bootstrap signaled. Earliest
            // reliable "first frame is going to render" moment we have.
            // didFinishNavigation in the nav delegate is the fallback if
            // bootstrap doesn't fire (rare).
            [delegate applyAutoShowOnWindow:window];
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

        // Paint the host dark-or-light correctly before the WKWebView
        // shows up. windowBackgroundColor is a dynamic NSColor that
        // tracks the system's effective appearance without us having to
        // observe NSAppearance changes ourselves. Without this the
        // brand-new NSWindow flashes its default (often white) backing
        // before the webview's first paint replaces it.
        [window setBackgroundColor:[NSColor windowBackgroundColor]];

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

        // Traffic lights (close / minimize / zoom). 0=Enabled, 1=Disabled,
        // 2=Hidden. Per-button enabled/hidden overrides the style-mask
        // defaults so apps can express "close greyed, zoom hidden, minimize
        // clickable" without reshuffling the style mask.
        {
            int close_tag = wopts_traffic_light_close_tag(opts);
            int min_tag = wopts_traffic_light_minimize_tag(opts);
            int zoom_tag = wopts_traffic_light_zoom_tag(opts);
            NSButton* closeBtn = [window standardWindowButton:NSWindowCloseButton];
            NSButton* minBtn = [window standardWindowButton:NSWindowMiniaturizeButton];
            NSButton* zoomBtn = [window standardWindowButton:NSWindowZoomButton];
            if (closeBtn) {
                closeBtn.hidden = (close_tag == 2);
                closeBtn.enabled = (close_tag == 0);
            }
            if (minBtn) {
                minBtn.hidden = (min_tag == 2);
                minBtn.enabled = (min_tag == 0);
            }
            if (zoomBtn) {
                zoomBtn.hidden = (zoom_tag == 2);
                zoomBtn.enabled = (zoom_tag == 0);
            }
        }

        // Center on the active screen if requested. Done before
        // setFrameAutosaveName: so a saved frame still wins on restore;
        // autoCenter is only the first-launch fallback.
        if (wopts_auto_center(opts)) {
            [window center];
        }

        // Frame autosave — AppKit persists frame to NSUserDefaults under
        // this name and restores on subsequent launches. Empty string
        // means no autosave.
        const char* autosave_name = wopts_frame_autosave_name(opts);
        if (autosave_name && autosave_name[0] != '\0') {
            NSString* nsName = [NSString stringWithUTF8String:autosave_name];
            if (nsName) [window setFrameAutosaveName:nsName];
        }

        bool inspectable = wopts_inspectable(opts) > 0;
        bool accept_first_mouse = wopts_accept_first_mouse(opts);
        extern const char* wopts_url(void* opts);
        const char* custom_url = wopts_url(opts);
        // Vibrancy (G12) — install the NSVisualEffectView as the
        // window's contentView BEFORE creating the webview. The
        // webview detects the vfx-as-host and mounts itself as a
        // subview, so it's born in the final view tree and never
        // re-parented. Re-parenting WKWebView after its first
        // loadRequest resets the content process and breaks the
        // bridge bootstrap (the await greet() at module top would
        // time out — observed in dev).
        const char* vibrancyName = wopts_vibrancy(opts);
        bool useVibrancy = (vibrancyName && vibrancyName[0] != '\0');
        if (useVibrancy) {
            NSString* mat = [NSString stringWithUTF8String:vibrancyName];
            NSVisualEffectMaterial material = NSVisualEffectMaterialWindowBackground;
            if      ([mat isEqualToString:@"sidebar"])               material = NSVisualEffectMaterialSidebar;
            else if ([mat isEqualToString:@"headerView"])            material = NSVisualEffectMaterialHeaderView;
            else if ([mat isEqualToString:@"titlebar"])              material = NSVisualEffectMaterialTitlebar;
            else if ([mat isEqualToString:@"menu"])                  material = NSVisualEffectMaterialMenu;
            else if ([mat isEqualToString:@"popover"])               material = NSVisualEffectMaterialPopover;
            else if ([mat isEqualToString:@"hudWindow"])             material = NSVisualEffectMaterialHUDWindow;
            else if ([mat isEqualToString:@"fullScreenUI"])          material = NSVisualEffectMaterialFullScreenUI;
            else if ([mat isEqualToString:@"sheet"])                 material = NSVisualEffectMaterialSheet;
            else if ([mat isEqualToString:@"contentBackground"])     material = NSVisualEffectMaterialContentBackground;
            else if ([mat isEqualToString:@"underWindowBackground"]) material = NSVisualEffectMaterialUnderWindowBackground;
            else if ([mat isEqualToString:@"underPageBackground"])   material = NSVisualEffectMaterialUnderPageBackground;

            NSRect contentRect = [window contentView].frame;
            NSVisualEffectView* vfx = [[NSVisualEffectView alloc] initWithFrame:contentRect];
            vfx.material = material;
            vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            vfx.state = NSVisualEffectStateFollowsWindowActiveState;
            vfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [window setContentView:vfx];
        }

        darwin_webview_create((__bridge void*)window, inspectable, accept_first_mouse,
                              custom_url, wopts_numeric_id_pre_alloc(opts), useVibrancy);

        NSString* windowId = [NSString stringWithFormat:@"win-%p", window];
        NSString* ownerId = [NSString stringWithFormat:@"owner-%p", window];
        ZappWindowDelegate* delegate = [[ZappWindowDelegate alloc] init];
        delegate.windowId = windowId;
        delegate.ownerId = ownerId;
        // numericId set by darwin_window_register_numeric_id after creation

        // Visibility model: visible:true is cosmetic — apps say "show me
        // when ready", not "show me right now even if blank". The window
        // is fully created either way; we just defer makeKeyAndOrderFront
        // until the bridge bootstrap or navigation completes (whichever
        // first), eliminating the white flash and the need for apps to
        // wire `on(READY, () => show())` themselves.
        //
        // visible:false means "create but don't auto-show" — the app must
        // call show() explicitly. Same with fullscreen — toggleFullScreen
        // requires the window to be on screen, so it queues until first
        // show.
        delegate.shouldAutoShow = (wopts_visible(opts) && !wopts_hidden(opts));
        delegate.fullscreenOnShow = wopts_fullscreen(opts);

        objc_setAssociatedObject(window, &kZappWindowDelegateKey,
            delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [window setDelegate:delegate];

        return (__bridge_retained void*)window;
    }
}

void darwin_window_destroy(void* handle) {
    NSWindow* window = (__bridge_transfer NSWindow*)handle;

    // Explicit WKWebView teardown before the NSWindow is released at the
    // end of this function. Without this, in-flight IPC replies from the
    // web content process can land on a webview that's mid-release —
    // their captured ProcessThrottlerActivity derefs to zero during the
    // reply handler's destructor and triggers WebKit's prepare-to-suspend
    // path on a process proxy that's already past that state. That's the
    // EXC_BREAKPOINT brk 1 in WebKit::ProcessThrottler::sendPrepareToSuspendIPC
    // on macOS 26.x, especially with rapid create/destroy from workers.
    //
    // Order: stop pending loads → remove script handler (drops WebKit's
    // strong ref to ZappMsgHandler and its captured blocks) → nil
    // delegates (final in-flight callbacks become no-ops instead of
    // retaining the webview through its destruction).
    //
    // Only runs here — not in windowWillClose: — because [window close]
    // with setReleasedWhenClosed:NO is reversible via show(); only this
    // function (which does __bridge_transfer to actually release) is the
    // terminal point.
    NSView* content = [window contentView];
    if ([content isKindOfClass:[WKWebView class]]) {
        WKWebView* wv = (WKWebView*)content;
        [wv stopLoading];
        WKUserContentController* ucc = wv.configuration.userContentController;
        @try {
            [ucc removeScriptMessageHandlerForName:@"zapp"];
        } @catch (NSException* ex) { (void)ex; }
        [wv setNavigationDelegate:nil];
        [wv setUIDelegate:nil];
    }

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

// --- Modal sheets ---
//
// beginSheet: shows the modal anchored to parent's titlebar and blocks
// interaction with parent only (not the rest of the app). When the modal
// closes via [modal close] or its close button, NSWindow auto-dismisses
// the sheet and fires the completion handler — no explicit cleanup
// required for that path.
//
// Both helpers main-thread-bounce per alpha.31 — modal attach is
// frequently driven by webview/worker callbacks that arrive off-thread.

void darwin_window_attach_modal(void* parent_handle, void* modal_handle) {
    if (!parent_handle || !modal_handle) return;
    NSWindow* parent = (__bridge NSWindow*)parent_handle;
    NSWindow* modal = (__bridge NSWindow*)modal_handle;
    if (parent == modal) return;  // self-attach is meaningless
    void (^run)(void) = ^{
        // Already attached to this parent? No-op (NSWindow asserts otherwise).
        if ([parent attachedSheet] == modal) return;
        // Attached to a different parent? Detach first to avoid the
        // "sheet already running" assertion.
        NSWindow* currentSheetParent = [modal sheetParent];
        if (currentSheetParent && currentSheetParent != parent) {
            [currentSheetParent endSheet:modal returnCode:NSModalResponseAbort];
        }
        // beginSheet silently fails to wrap a window that's already
        // visible standalone — orderOut first so the modal appears as a
        // sheet rather than as the free-floating window the user already
        // saw. Use Window.create({ asSheetOf: parent }) for an atomic
        // create-and-attach that avoids this transient flash entirely.
        if ([modal isVisible] && ![modal sheetParent]) {
            [modal orderOut:nil];
        }
        // Escape-to-dismiss. macOS HIG says a sheet with a Cancel
        // button should bind ⎋ to it, but a webview-content sheet has
        // no Cancel button — so install a local key monitor scoped to
        // the modal window that ends the sheet on Escape (keycode 53).
        // Mirrors the iOS UIKeyCommand behavior so apps get the same
        // "press Escape to close" UX on both platforms. Monitor is
        // associated with the modal so it auto-releases when modal
        // dies.
        // __unsafe_unretained (not __weak) — window.m is built without ARC.
        // Monitor's lifetime is bounded by modal's lifetime, so the captured
        // pointers can't outlive their targets in practice.
        __unsafe_unretained NSWindow* weakModal = modal;
        __unsafe_unretained NSWindow* weakParent = parent;
        id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
            handler:^NSEvent*(NSEvent* event) {
                if (event.keyCode != 53 /* kVK_Escape */) return event;
                NSWindow* m = weakModal;
                NSWindow* p = weakParent;
                if (!m || !p || event.window != m) return event;
                if ([p attachedSheet] != m) return event;
                [p endSheet:m returnCode:NSModalResponseCancel];
                return nil;  // swallow
            }];
        objc_setAssociatedObject(modal, "zapp_modal_esc_monitor",
            monitor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [parent beginSheet:modal completionHandler:^(NSModalResponse code) {
            // Tear down the Escape monitor when the sheet dismisses
            // (regardless of how — Escape, programmatic, or close
            // button). NSEvent monitors are global to the app, so
            // leaving them around would respond to keystrokes in
            // unrelated windows.
            id mon = objc_getAssociatedObject(modal, "zapp_modal_esc_monitor");
            if (mon) {
                [NSEvent removeMonitor:mon];
                objc_setAssociatedObject(modal, "zapp_modal_esc_monitor",
                    nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            // Notify the parent window's JS that the sheet dismissed,
            // including the response code (default NSModalResponseStop
            // when modal closes itself; user-supplied if a future
            // setModalResult API lands). Look up parent's numeric ID
            // via the cached delegate.
            ZappWindowDelegate* delegate = (ZappWindowDelegate*)[parent delegate];
            if (![delegate isKindOfClass:[ZappWindowDelegate class]]) return;
            int32_t parent_id = delegate.numericId;
            if (parent_id < 0) return;
            ZappWindowDelegate* modal_delegate = (ZappWindowDelegate*)[modal delegate];
            int32_t modal_id = -1;
            if ([modal_delegate isKindOfClass:[ZappWindowDelegate class]]) {
                modal_id = modal_delegate.numericId;
            }
            // Pass modal_id via `w` and code via `h` — zapp_dispatch_event_to_js
            // recognizes MODAL_DISMISSED and formats { modalId, code } in JSON.
            extern int zapp_dispatch_event(int window_id, int event_id, int w, int h, int x, int y);
            zapp_dispatch_event(parent_id, ZAPP_EVENT_WINDOW_MODAL_DISMISSED, (int)modal_id, (int)code, 0, 0);
        }];
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

void darwin_window_detach_modal(void* parent_handle, void* modal_handle) {
    if (!parent_handle || !modal_handle) return;
    NSWindow* parent = (__bridge NSWindow*)parent_handle;
    NSWindow* modal = (__bridge NSWindow*)modal_handle;
    void (^run)(void) = ^{
        if ([modal sheetParent] == parent) {
            [parent endSheet:modal returnCode:NSModalResponseStop];
        }
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
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
    // Single canonical format for window IDs visible to JS:
    // "win-<numericId>". This matches what the router serializes back
    // to JS from `__window:create` (`router.zc` `"win-%d"`), so the
    // reverse lookup `darwin_window_numeric_id_for_string` actually
    // resolves Window.current() and Window.create() handles. The
    // pointer-based form was a footgun — the two paths diverged.
    NSString* windowId = [NSString stringWithFormat:@"win-%d", numeric_id];

    // Cache numericId on delegate for O(1) event dispatch
    ZappWindowDelegate* delegate = (ZappWindowDelegate*)[w delegate];
    if ([delegate isKindOfClass:[ZappWindowDelegate class]]) {
        delegate.numericId = numeric_id;
    }

    // Register WebView in direct dispatch table.
    //
    // The contentView is the WKWebView in the default path, but for
    // windows with `vibrancy: ...` set it's an NSVisualEffectView
    // wrapping the WKWebView as a subview. Walk one level down to
    // find it. Without this, the webview never enters the dispatch
    // table → ZappMsgHandler can't resolve window_id from
    // msg.webView → invoke responses can't be routed back → JS
    // bridge calls (e.g. `await Services.invoke("greet", ...)` at
    // module top) hang and timeout.
    NSView* content = [w contentView];
    WKWebView* wv = nil;
    if ([content isKindOfClass:[WKWebView class]]) {
        wv = (WKWebView*)content;
    } else {
        for (NSView* sub in content.subviews) {
            if ([sub isKindOfClass:[WKWebView class]]) { wv = (WKWebView*)sub; break; }
        }
    }
    if (wv) {
        zapp_register_webview(numeric_id, wv, windowId);

        // Set the in-page Symbol.for('zapp.windowId') to the same
        // numeric form. WKWebView queues evaluateJavaScript: until the
        // JS context exists, so this lands before any user-script can
        // observe the global. We set it via globalThis assignment so
        // it persists across user-script runs at document-start.
        NSString* setIdJs = [NSString stringWithFormat:
            @"globalThis[Symbol.for('zapp.windowId')]='%@';", windowId];
        [wv evaluateJavaScript:setIdJs completionHandler:nil];
    }
}
