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
// Extended creation path (native-sidebar + popovers). container_view mounts
// the webview into a caller-provided NSView; identity_window_id (>=0) injects
// win-<that> as the JS identity while transport stays on numeric_id_pre_alloc;
// pane_role (0=main, 1=sidebar, 2=popover) sets the role marker.
// Declared in webview.h; redeclared here because window.m imports window.h,
// not webview.h.
extern void darwin_webview_create_ext(void* window_ptr, bool inspectable, bool accept_first_mouse,
                                      const char* url_override, int32_t numeric_id_pre_alloc,
                                      bool transparent_background,
                                      void* container_view, int32_t identity_window_id,
                                      int32_t pane_role, bool host_has_sidebar,
                                      bool host_has_inspector);
// Sidebar split registry (sidebar.m). register wires KVO + resize observation
// and emits sidebar-collapsed/expanded/resized into both panes; unregister
// tears the observers down. Keyed by the host NSWindow pointer.
extern void zapp_sidebar_register(void* window_ptr, void* splitVC, void* sidebarItem,
                                  int32_t host_id, int32_t sidebar_slot_id);
extern void zapp_sidebar_unregister(void* window_ptr);
// Sidebar opts accessors (window.zc). sidebarNumericId is the SECOND slot
// pre-allocated from WindowManager.next_id for the sidebar webview's transport.
extern const char* wopts_sidebar_url(void* opts);
extern const char* wopts_sidebar_material(void* opts);
extern int32_t wopts_sidebar_width(void* opts);
extern int32_t wopts_sidebar_min_width(void* opts);
extern int32_t wopts_sidebar_max_width(void* opts);
extern bool wopts_sidebar_collapsible(void* opts);
extern bool wopts_sidebar_collapsed(void* opts);
extern bool wopts_sidebar_can_resize(void* opts);
extern const char* wopts_sidebar_background_color(void* opts);
extern int32_t wopts_sidebar_numeric_id(void* opts);
extern const char* wopts_sidebar_presentation(void* opts);
// App-set window background color ("#rrggbb"); applied on opaque windows.
extern const char* wopts_background_color(void* opts);
// Inspector split registry (inspector.m). Mirrors the sidebar pattern.
extern void zapp_inspector_register(void* window_ptr, void* splitVC, void* inspectorItem,
                                    int32_t host_id, int32_t inspector_slot_id);
extern void zapp_inspector_unregister(void* window_ptr);
// Inspector opts accessors (window.zc).
extern const char* wopts_inspector_url(void* opts);
extern const char* wopts_inspector_material(void* opts);
extern int32_t wopts_inspector_width(void* opts);
extern int32_t wopts_inspector_min_width(void* opts);
extern int32_t wopts_inspector_max_width(void* opts);
extern bool wopts_inspector_collapsible(void* opts);
extern bool wopts_inspector_collapsed(void* opts);
extern bool wopts_inspector_can_resize(void* opts);
extern const char* wopts_inspector_background_color(void* opts);
extern int32_t wopts_inspector_numeric_id(void* opts);

// Runtime resize-lock ops (sidebar.m / inspector.m) — used at create time to
// honor a `resizable: false` option once the controller is registered.
extern void darwin_sidebar_set_resizable(int32_t window_id, bool resizable);
extern void darwin_inspector_set_resizable(int32_t window_id, bool resizable);
// Toolbar (toolbar.m + window.zc accessor).
extern const char* wopts_toolbar_json(void* opts);
extern void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json, int32_t window_numeric_id);
extern void zapp_toolbar_unregister(void* window_ptr);

// Native-surface pane (nativesurface.m). 1/0 gate + the view builder. cint == int.
extern int wopts_native_surface(void* opts);
extern NSView* darwin_native_surface_create(int32_t window_id);
extern int zapp_dispatch_event(int window_id, int event_id, int w, int h, int x, int y);
// Primary display height (top-left global origin flip). Defined in screen.m.
extern double zapp_primary_screen_height(void);

// SwiftUI pane host (panes.swift, macOS 14+). Wraps a populated content NSView in
// an NSHostingView; +1-retained, consumed via __bridge_transfer. Only declared
// when the swiftc tier is compiled in (native.swiftui != false + swiftc present).
#ifdef ZAPP_HAS_SWIFTUI
// Reverse state-change channel from SwiftUI (panes.swift). Scalar, main-thread,
// change-driven. Keys match panes.swift; value is the new scalar (0/1 here).
typedef void (*ZappSwiftStateCallback)(void* ctx, int32_t key, int64_t value);
enum { ZAPP_PANE_KEY_SIDEBAR_VISIBLE = 1, ZAPP_PANE_KEY_INSPECTOR_PRESENTED = 2 };

extern void* zapp_swift_panes_state_create(void* ctx, ZappSwiftStateCallback cb,
                                           bool sidebarVisible, bool inspectorPresented);
extern void zapp_swift_panes_state_release(void* state);
extern void zapp_swift_panes_set_sidebar_visible(void* state, bool visible);
extern void zapp_swift_panes_set_inspector_presented(void* state, bool presented);
extern void zapp_swift_panes_toggle_sidebar(void* state);
extern void zapp_swift_panes_toggle_inspector(void* state);
extern void* zapp_swift_panes_create(void* state, void* toolbarState, void* content, void* sidebar, void* inspector);

// Reverse string channel from SwiftUI (toolbar.swift). Sibling of
// ZappSwiftStateCallback; value is a C string (itemId / menuId). cb is wired in
// Task 4; passed NULL here.
typedef void (*ZappSwiftStringCallback)(void* ctx, int32_t key, const char* value);
extern void* zapp_swift_toolbar_state_create(void* ctx, ZappSwiftStringCallback cb);
extern void zapp_swift_toolbar_state_release(void* state);
extern void zapp_swift_module_set_string(void* state, int32_t key, const char* value);

// Reverse-emit entries (defined in sidebar.m / inspector.m — wired in Tasks 2/3).
extern void zapp_sidebar_note_swiftui_visibility(void* window_ptr, bool collapsed);
extern void zapp_inspector_note_swiftui_visibility(void* window_ptr, bool collapsed);
// SwiftUI controller register variants (defined in sidebar.m / inspector.m — Tasks 2/3).
extern void zapp_sidebar_register_swiftui(void* window_ptr, void* paneState,
                                          int32_t host_id, int32_t sidebar_slot_id,
                                          bool initial_collapsed);
extern void zapp_inspector_register_swiftui(void* window_ptr, void* paneState,
                                            int32_t host_id, int32_t inspector_slot_id,
                                            bool initial_collapsed);

// File-static reverse dispatcher: PaneState's didSet fires this with the changed
// key + new value (1=visible/0=collapsed). ctx is the host NSWindow*. The switch
// arms are added in Tasks 2 (sidebar) and 3 (inspector); a stub today emits nothing.
static void zapp_swiftui_pane_changed(void* ctx, int32_t key, int64_t value) {
    switch (key) {
        case ZAPP_PANE_KEY_SIDEBAR_VISIBLE:
            zapp_sidebar_note_swiftui_visibility(ctx, value == 0);  // value=1 visible -> collapsed=false
            break;
        case ZAPP_PANE_KEY_INSPECTOR_PRESENTED:
            zapp_inspector_note_swiftui_visibility(ctx, value == 0);  // value=1 presented -> collapsed=false
            break;
        default: break;
    }
}

// Shared toolbar emit helpers (toolbar.m). Defined regardless of SwiftUI, but
// only referenced from the SwiftUI reverse dispatcher below.
extern void zapp_toolbar_emit_click(int32_t host_id, const char* item_id);
extern void zapp_toolbar_emit_menu_click(int32_t host_id, const char* menu_id);
// SET_ITEMS-family keys (toolbar->SwiftUI, set_string); EVT keys (SwiftUI->native).
// Must match panes.swift / toolbar.swift.
enum { ZAPP_TB_SET_ITEMS = 1, ZAPP_TB_UPDATE_ITEM = 2, ZAPP_TB_CLEAR = 3 };
enum { ZAPP_TB_EVT_CLICK = 1, ZAPP_TB_EVT_MENU_CLICK = 2 };

// Reverse dispatcher for the SwiftUI toolbar string channel. The toolbar
// module's ctx is the numeric host id boxed as a pointer (NOT the window ptr) —
// see the state-create call below. host_slot=0 -> NULL ctx -> unboxes to host 0,
// which is correct (no special-casing).
static void zapp_swiftui_toolbar_event(void* ctx, int32_t key, const char* value) {
    int32_t host = (int32_t)(intptr_t)ctx;
    switch (key) {
        case ZAPP_TB_EVT_CLICK:      zapp_toolbar_emit_click(host, value); break;
        case ZAPP_TB_EVT_MENU_CLICK: zapp_toolbar_emit_menu_click(host, value); break;
        default: break;
    }
}
#endif

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

// host slot -> sidebar slot, for window-event fan-out. -1 = no sidebar. Set in
// the sidebar construction branch; the entry is harmless to leave set after a
// close (the dispatch helpers no-op on a nil-ed slot), so we don't clear it.
static int32_t zapp_sidebar_slot_of[ZAPP_MAX_WINDOW_CALLBACKS];
static bool zapp_sidebar_slot_of_init = false;

static void zapp_set_sidebar_slot(int32_t host_slot, int32_t sidebar_slot) {
    if (!zapp_sidebar_slot_of_init) {
        for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) zapp_sidebar_slot_of[i] = -1;
        zapp_sidebar_slot_of_init = true;
    }
    if (host_slot >= 0 && host_slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_sidebar_slot_of[host_slot] = sidebar_slot;
    }
}

static int32_t zapp_sidebar_slot_for(int32_t host_slot) {
    if (!zapp_sidebar_slot_of_init) return -1;
    if (host_slot < 0 || host_slot >= ZAPP_MAX_WINDOW_CALLBACKS) return -1;
    return zapp_sidebar_slot_of[host_slot];
}

static void zapp_register_webview(int32_t numericId, WKWebView* webview, NSString* windowId) {
    if (numericId >= 0 && numericId < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_webviews[numericId] = webview;
        zapp_window_ids[numericId] = windowId;
    }
}

// Broadcast a JS snippet to every REGISTERED webview (the dispatch table).
// darwin_webview_eval_all (webview.m) used to walk [NSApp windows] checking
// each contentView — that misses any webview not mounted AS the contentView:
// both panes of a sidebar window (contentView is the NSSplitView) and
// vibrancy windows (NSVisualEffectView wrapper). The dispatch table is the
// source of truth for "panes with a live bridge", so broadcasts iterate it.
// Closed windows are absent (windowWillClose clears their slots) — same
// reversible-close contract as window events.
void zapp_registered_webviews_eval(const char* js) {
    if (!js) return;
    NSString* script = [NSString stringWithUTF8String:js];
    if (!script) return;
    void (^run)(void) = ^{
        for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
            WKWebView* wv = zapp_webviews[i];
            if (wv) [wv evaluateJavaScript:script completionHandler:nil];
        }
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

// Slot lookups for toolbar.m's chrome-metrics injection: a window's host pane
// plus (for split windows) the sidebar pane share the same chrome metrics.
WKWebView* zapp_webview_for_slot(int32_t slot) {
    if (slot < 0 || slot >= ZAPP_MAX_WINDOW_CALLBACKS) return nil;
    return zapp_webviews[slot];
}

int32_t zapp_sidebar_slot_lookup(int32_t host_slot) {
    return zapp_sidebar_slot_for(host_slot);
}

// host slot -> inspector slot, for window-event fan-out. -1 = no inspector.
static int32_t zapp_inspector_slot_of[ZAPP_MAX_WINDOW_CALLBACKS];
static bool zapp_inspector_slot_of_init = false;

static void zapp_set_inspector_slot(int32_t host_slot, int32_t inspector_slot) {
    if (!zapp_inspector_slot_of_init) {
        for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) zapp_inspector_slot_of[i] = -1;
        zapp_inspector_slot_of_init = true;
    }
    if (host_slot >= 0 && host_slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_inspector_slot_of[host_slot] = inspector_slot;
    }
}

static int32_t zapp_inspector_slot_for(int32_t host_slot) {
    if (!zapp_inspector_slot_of_init) return -1;
    if (host_slot < 0 || host_slot >= ZAPP_MAX_WINDOW_CALLBACKS) return -1;
    return zapp_inspector_slot_of[host_slot];
}

int32_t zapp_inspector_slot_lookup(int32_t host_slot) {
    return zapp_inspector_slot_for(host_slot);
}

// Pane registration/teardown for popover.m — popover panes register OUTSIDE
// window construction (sidebar panes register inline there), and the table
// + teardown helper are static in this file.
void zapp_register_pane_webview(int32_t slot, WKWebView* wv, int32_t host_slot) {
    if (host_slot < 0 || host_slot >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    NSString* hostId = zapp_window_ids[host_slot];
    if (!hostId) hostId = [NSString stringWithFormat:@"win-%d", host_slot];
    zapp_register_webview(slot, wv, hostId);
}

void zapp_clear_pane_slot(int32_t slot) {
    if (slot < 0 || slot >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    zapp_webviews[slot] = nil;
    zapp_window_ids[slot] = nil;
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

    // Fan out to the sidebar pane: it identifies as the same host window, so
    // the SAME JS (targeting wid = win-<host>) lands its handlers there too.
    // The sidebar already receives its own collapse/resize events from
    // sidebar.m; this is for the host's resize/focus/blur/fullscreen/etc.
    int32_t sidebar_slot = zapp_sidebar_slot_for(window_id);
    if (sidebar_slot >= 0 && sidebar_slot != window_id &&
        sidebar_slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        WKWebView* sidebarWebview = zapp_webviews[sidebar_slot];
        if (sidebarWebview) {
            [sidebarWebview evaluateJavaScript:js completionHandler:nil];
        }
    }

    // Fan out to the inspector pane (same logic — inspector identifies as the
    // same host window; inspector.m handles its own collapse/resize events).
    int32_t inspector_slot = zapp_inspector_slot_for(window_id);
    if (inspector_slot >= 0 && inspector_slot != window_id &&
        inspector_slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        WKWebView* inspectorWebview = zapp_webviews[inspector_slot];
        if (inspectorWebview) {
            [inspectorWebview evaluateJavaScript:js completionHandler:nil];
        }
    }
}

// --- Window Delegate ---
// numericId cached — zero lookup cost per event.

static const char kZappWindowDelegateKey = 0;

@interface ZappWindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, copy) NSString* ownerId;
@property (nonatomic, copy) NSString* windowId;
@property (nonatomic, assign) int32_t numericId;
// Sidebar webview's transport slot, or -1 for non-sidebar windows. Set in the
// construction branch; used to fan window events into the sidebar pane and to
// clear/tear-down its dispatch slot on close/destroy.
@property (nonatomic, assign) int32_t sidebarNumericId;
// Inspector webview's transport slot, or -1 for non-inspector windows. Same
// contract as sidebarNumericId.
@property (nonatomic, assign) int32_t inspectorNumericId;
// Weak refs to the pane webviews — needed because in a split layout the
// host window's contentView is the NSSplitView, not a WKWebView, so the
// teardown path can't rederive them via [window contentView]. Weak so they
// don't keep the webviews alive past the split controller / window release.
@property (nonatomic, weak) WKWebView* mainWebview;
@property (nonatomic, weak) WKWebView* sidebarWebview;
@property (nonatomic, weak) WKWebView* inspectorWebview;
@property (nonatomic, assign) void* swiftPaneState;  // owning ref to the SwiftUI PaneState (NULL on AppKit path)
@property (nonatomic, assign) void* swiftToolbarState;  // owning ref to the SwiftUI ToolbarState (NULL on AppKit path)
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
        _sidebarNumericId = -1;
        _inspectorNumericId = -1;
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
    // Sidebar pane shares the same reversible-close contract: clear its
    // dispatch slot (no stale evals into a closed pane) but DON'T tear the
    // WKWebView down here — that's darwin_window_destroy's job.
    if (self.sidebarNumericId >= 0 && self.sidebarNumericId < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_webviews[self.sidebarNumericId] = nil;
        zapp_window_ids[self.sidebarNumericId] = nil;
    }
    // Inspector pane: same reversible-close contract as the sidebar.
    if (self.inspectorNumericId >= 0 && self.inspectorNumericId < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_webviews[self.inspectorNumericId] = nil;
        zapp_window_ids[self.inspectorNumericId] = nil;
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
    // Report position in top-left global coords, consistent with
    // darwin_window_get_position / the Screen API.
    int x = (int)frame.origin.x;
    int y = (int)(zapp_primary_screen_height() - frame.origin.y - frame.size.height);
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
    // top-left global y, consistent with get_position / the Screen API.
    int y = (int)(zapp_primary_screen_height() - frame.origin.y - frame.size.height);
    zapp_dispatch_event(self.numericId, ZAPP_EVENT_WINDOW_MOVE,
        (int)frame.size.width, (int)frame.size.height,
        (int)frame.origin.x, y);
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

// Reverse lookup: JS-visible string ID → numeric ID.
// JS holds windowId as "win-<numericId>" (set by darwin_window_register_numeric_id),
// but WindowManager keys by the numeric ID itself. Multi-window APIs
// (attachModal/detachModal, asSheetOf) need the numeric form to look up the
// WindowOptions instance, so this maps back.
int32_t darwin_window_numeric_id_for_string(const char* window_id_string) {
    if (!window_id_string || !window_id_string[0]) return -1;
    NSString* target = [NSString stringWithUTF8String:window_id_string];
    if (!target) return -1;
    // First-match-wins is intentional: a sidebar window registers BOTH its panes
    // under the same "win-<host>" id string (two slots, one logical window). The
    // host slot is always allocated + registered before the sidebar slot, so the
    // ascending scan returns the HOST — which is what every consumer (modal
    // attach, getScreen) wants.
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

// --- SwiftUI toolbar routing resolvers (callable on ALL builds) ---
//
// router.nim's toolbar:* arm forks on these regardless of swiftc tier, so both
// must compile when ZAPP_HAS_SWIFTUI is undefined — only the BODY guards the
// SwiftUI bits (returns false/NULL on the AppKit path or opted-out windows).

// True when this window renders its toolbar via SwiftUI (so the router routes
// toolbar:* to the SwiftUI module instead of NSToolbar). False on AppKit/opted-out.
bool zapp_window_uses_swiftui_toolbar(void* handle) {
#ifdef ZAPP_HAS_SWIFTUI
    if (!handle) return false;
    NSWindow* window = (__bridge NSWindow*)handle;
    ZappWindowDelegate* d = (ZappWindowDelegate*)[window delegate];
    if ([d isKindOfClass:[ZappWindowDelegate class]]) return d.swiftToolbarState != NULL;
#endif
    (void)handle; return false;
}

// The SwiftUI ToolbarState handle for this window (NULL on the AppKit path).
void* zapp_window_swiftui_toolbar_state(void* handle) {
#ifdef ZAPP_HAS_SWIFTUI
    if (!handle) return NULL;
    NSWindow* window = (__bridge NSWindow*)handle;
    ZappWindowDelegate* d = (ZappWindowDelegate*)[window delegate];
    if ([d isKindOfClass:[ZappWindowDelegate class]]) return d.swiftToolbarState;
#endif
    (void)handle; return NULL;
}

#ifndef ZAPP_HAS_SWIFTUI
// AppKit-only build (native.swiftui:false / macOS<14): router.nim's toolbar:* fork
// references this Swift @_cdecl symbol (defined in toolbar.swift) unconditionally
// at link time, even though the SwiftUI branch is never taken at runtime
// (zapp_window_uses_swiftui_toolbar returns false). Provide a no-op so the
// AppKit-only binary links. The real impl ships in toolbar.swift on the SwiftUI path.
void zapp_swift_module_set_string(void* state, int32_t key, const char* value) {
    (void)state; (void)key; (void)value;
}
#endif

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

// --- Material name → NSVisualEffectMaterial ---
// Shared by the vibrancy path (whole-window blur) and the sidebar's optional
// per-pane material override. Names mirror runtime/window.ts's Material const.
// Unknown / empty names fall back to WindowBackground.
// Parse "#rrggbb" -> r,g,b (0-255). false on malformed input. Mirrors the
// Windows sscanf parse (windows/window.c) so both platforms accept the same
// backgroundColor string.
static bool zapp_parse_hex_color(const char* hex, int* r, int* g, int* b) {
    if (!hex || hex[0] != '#' || strlen(hex) < 7) return false;
    return sscanf(hex + 1, "%2x%2x%2x", r, g, b) == 3;
}

static NSVisualEffectMaterial zapp_material_from_name(const char* name) {
    if (!name || !name[0]) return NSVisualEffectMaterialWindowBackground;
    NSString* mat = [NSString stringWithUTF8String:name];
    if (!mat) return NSVisualEffectMaterialWindowBackground;
    if      ([mat isEqualToString:@"sidebar"])               return NSVisualEffectMaterialSidebar;
    else if ([mat isEqualToString:@"headerView"])            return NSVisualEffectMaterialHeaderView;
    else if ([mat isEqualToString:@"titlebar"])              return NSVisualEffectMaterialTitlebar;
    else if ([mat isEqualToString:@"menu"])                  return NSVisualEffectMaterialMenu;
    else if ([mat isEqualToString:@"popover"])               return NSVisualEffectMaterialPopover;
    else if ([mat isEqualToString:@"hudWindow"])             return NSVisualEffectMaterialHUDWindow;
    else if ([mat isEqualToString:@"fullScreenUI"])          return NSVisualEffectMaterialFullScreenUI;
    else if ([mat isEqualToString:@"sheet"])                 return NSVisualEffectMaterialSheet;
    else if ([mat isEqualToString:@"contentBackground"])     return NSVisualEffectMaterialContentBackground;
    else if ([mat isEqualToString:@"underWindowBackground"]) return NSVisualEffectMaterialUnderWindowBackground;
    else if ([mat isEqualToString:@"underPageBackground"])   return NSVisualEffectMaterialUnderPageBackground;
    return NSVisualEffectMaterialWindowBackground;
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

        // Content rect — the SIZE is authoritative here; the on-screen origin
        // is set AFTER creation (auto-center, or the explicit top-left flip
        // below) once the full window frame height incl. title bar is known.
        // Baking the flip in here against the *content* height pushed the title
        // bar above the menu bar (which macOS then clamped), so we don't.
        NSRect frame = NSMakeRect(wopts_x(opts), 0, wopts_width(opts), wopts_height(opts));
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
        } else {
            // Explicit top-left global position. Use the full window frame
            // height (incl. title bar) so the WINDOW top — not the content
            // top — lands at y, matching darwin_window_set_position /
            // get_position. (A saved autosave frame below still wins.)
            CGFloat blY = zapp_primary_screen_height() - (CGFloat)wopts_y(opts) - window.frame.size.height;
            [window setFrameOrigin:NSMakePoint((CGFloat)wopts_x(opts), blY)];
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
        // Material enum shared by the whole-window vibrancy path and the
        // sidebar's optional per-pane material override (helper above).
        NSVisualEffectMaterial material = zapp_material_from_name(vibrancyName);

        // App-set window background color ("#rrggbb"). Opaque windows only —
        // skip when transparent or vibrancy is set (those intentionally own a
        // clear/material background). Replaces the windowBackgroundColor
        // default set at window creation; also seeds the host webview's
        // underPageBackgroundColor below. NOTE: unlike Windows (where
        // WebView2's repaint lags during live resize and flashes white),
        // WKWebView repaints fast — on macOS this is window-background
        // customization + the pre-render fill, not a resize-flash fix. The
        // page's own CSS background still paints over it.
        NSColor* bgColor = nil;
        {
            int cr, cg, cb;
            if (!wopts_transparent(opts) && !useVibrancy &&
                zapp_parse_hex_color(wopts_background_color(opts), &cr, &cg, &cb)) {
                bgColor = [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:1.0];
                [window setBackgroundColor:bgColor];
            }
        }

        const char* sidebarUrl = wopts_sidebar_url(opts);
        bool useSidebar = (sidebarUrl && sidebarUrl[0] != '\0');

        // sidebar.presentation is iOS-only (UISplitViewController split behavior).
        // AppKit's NSSplitViewController tiles/collapses and never overlays content,
        // so the value is intentionally ignored on macOS. Read for symmetry/docs.
        (void)wopts_sidebar_presentation(opts);

        // Sidebar webview's transport slot is pre-allocated by
        // WindowManager.create from the SAME id-space as the host's (window.zc).
        // -1 when no sidebar; cached on the delegate below for fan-out/teardown.
        int32_t host_slot = wopts_numeric_id_pre_alloc(opts);
        int32_t sidebar_slot = wopts_sidebar_numeric_id(opts);

        // Captured for the delegate (teardown reaches webviews through these,
        // since [window contentView] is the NSSplitView in the sidebar case).
        WKWebView* mainWebviewRef = nil;
        WKWebView* sidebarWebviewRef = nil;

        const char* inspectorUrl = wopts_inspector_url(opts);
        bool useInspector = (inspectorUrl && inspectorUrl[0] != '\0');
        int32_t inspector_slot = wopts_inspector_numeric_id(opts);

        WKWebView* inspectorWebviewRef = nil;
        void* swiftPaneState = NULL;  // SwiftUI PaneState handle (owned by the delegate; released once at teardown)
        void* swiftToolbarState = NULL;  // SwiftUI ToolbarState handle (owned by the delegate; released once at teardown)

        // Native-surface pane (macOS, SwiftUI/AppKit). Rides the same split root;
        // requesting it alone (no sidebar/inspector) still builds the split.
        bool useNativeSurface = (wopts_native_surface(opts) != 0);

        if (useSidebar || useInspector || useNativeSurface) {
            // Pane windows root on an NSSplitViewController (the split must be
            // the window's root BEFORE any webview loads — re-parenting a
            // WKWebView resets its content process and breaks the bridge). All
            // panes are born in their final containers, never re-parented.
            //
            // Chrome: default to the standard sidebar/inspector-app look (full-
            // size content, hidden title, transparent titlebar) unless titleBarStyle
            // was set explicitly. tbs==3 is Unset — "app didn't pick a style" — and
            // is the ONLY value that gets this chrome default. An explicit Default
            // (tbs==0) falls through here, leaving a standard title bar even on a
            // split window; Hidden/HiddenInset (1/2) already hid it above.
            bool useSwiftUIPanes = false;
#ifdef ZAPP_HAS_SWIFTUI
            // Sub-cycle 1: sidebar/inspector accessory'd windows use the SwiftUI pane
            // layout on macOS 14+. native-surface windows keep the AppKit split for now.
            if ((useSidebar || useInspector) && !useNativeSurface) {
                if (@available(macOS 14.0, *)) useSwiftUIPanes = true;
            }
#endif
            if (getenv("ZAPP_LOG")) {
                NSLog(@"[zapp] window panes: %s", useSwiftUIPanes ? "swiftui" : "appkit");
            }

#ifdef ZAPP_HAS_SWIFTUI
            if (useSwiftUIPanes) {
                // Task 1: content pane only (sidebar/inspector added in Tasks 2-3).
                // Build the content container (mirror the AppKit branch's content-pane
                // container construction at window.m:797-808): an NSView sized to the
                // window content frame, wrapped in a vibrancy NSVisualEffectView when
                // useVibrancy. The representable wraps the bare NSView, so we do NOT
                // need the NSViewController — just the resulting NSView* mainContainer.
                NSView* mainContainer = [[NSView alloc] initWithFrame:[window contentView].frame];
                mainContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                if (useVibrancy) {
                    NSVisualEffectView* vfx = [[NSVisualEffectView alloc] initWithFrame:mainContainer.frame];
                    vfx.material = material;
                    vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                    vfx.state = NSVisualEffectStateFollowsWindowActiveState;
                    vfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    mainContainer = vfx;
                }

                // Task 2: sidebar pane (when requested). Mirror the AppKit branch's
                // sidebar-container construction (window.m sideVC.view path: NSView sized
                // to sidebar_width × height, with the material-override vfx OR the
                // backgroundColor backdrop) — but the SwiftUI representable wraps a bare
                // NSView, so we keep ONLY the resulting NSView* sidebarContainer (no
                // NSViewController / NSSplitViewItem; the NavigationSplitView is the split).
                NSView* sidebarContainer = nil;
                if (useSidebar) {
                    sidebarContainer = [[NSView alloc] initWithFrame:
                        NSMakeRect(0, 0, (CGFloat)wopts_sidebar_width(opts), (CGFloat)wopts_height(opts))];
                    const char* sidebarMaterialName = wopts_sidebar_material(opts);
                    bool sidebarMaterialOverride = sidebarMaterialName && sidebarMaterialName[0] != '\0' &&
                                                   strcmp(sidebarMaterialName, "sidebar") != 0;
                    if (sidebarMaterialOverride) {
                        NSVisualEffectView* svfx = [[NSVisualEffectView alloc] initWithFrame:sidebarContainer.bounds];
                        svfx.material = zapp_material_from_name(sidebarMaterialName);
                        svfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                        svfx.state = NSVisualEffectStateFollowsWindowActiveState;
                        svfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                        sidebarContainer = svfx;
                    } else {
                        int cr, cg, cb;
                        const char* sbg = wopts_sidebar_background_color(opts);
                        if (sbg && sbg[0] != '\0' && zapp_parse_hex_color(sbg, &cr, &cg, &cb)) {
                            sidebarContainer.wantsLayer = YES;
                            sidebarContainer.layer.backgroundColor =
                                [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:1.0].CGColor;
                        }
                    }
                    sidebarContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                }

                // Task 3: inspector pane (when requested). Mirror the AppKit branch's
                // inspector-container construction (the inspVC.view path: NSView sized to
                // inspector_width × height, with the material-override vfx OR the
                // backgroundColor backdrop) — but the SwiftUI representable wraps a bare
                // NSView, so we keep ONLY the resulting NSView* inspectorContainer (no
                // NSViewController / NSSplitViewItem; the .inspector modifier is the split).
                NSView* inspectorContainer = nil;
                if (useInspector) {
                    inspectorContainer = [[NSView alloc] initWithFrame:
                        NSMakeRect(0, 0, (CGFloat)wopts_inspector_width(opts), (CGFloat)wopts_height(opts))];
                    const char* inspectorMaterialName = wopts_inspector_material(opts);
                    bool inspectorMaterialOverride = inspectorMaterialName && inspectorMaterialName[0] != '\0' &&
                                                     strcmp(inspectorMaterialName, "sidebar") != 0;
                    if (inspectorMaterialOverride) {
                        NSVisualEffectView* ivfx = [[NSVisualEffectView alloc] initWithFrame:inspectorContainer.bounds];
                        ivfx.material = zapp_material_from_name(inspectorMaterialName);
                        ivfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                        ivfx.state = NSVisualEffectStateFollowsWindowActiveState;
                        ivfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                        inspectorContainer = ivfx;
                    } else {
                        int cr, cg, cb;
                        const char* ibg = wopts_inspector_background_color(opts);
                        if (ibg && ibg[0] != '\0' && zapp_parse_hex_color(ibg, &cr, &cg, &cb)) {
                            inspectorContainer.wantsLayer = YES;
                            inspectorContainer.layer.backgroundColor =
                                [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:1.0].CGColor;
                        }
                    }
                    inspectorContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                }
                // Initial pane visibility for the shared PaneState: sidebar shown
                // when present; inspector shown unless created collapsed.
                bool sidebarVisible = useSidebar;
                bool inspectorPresented = useInspector && !wopts_inspector_collapsed(opts);

                // Shared, observable pane state. ctx = host NSWindow* (the registry
                // key the reverse dispatcher resolves controllers by); cb = the
                // file-static reverse dispatcher. The delegate owns this handle and
                // releases it once at teardown.
                swiftPaneState = zapp_swift_panes_state_create((__bridge void*)window,
                    zapp_swiftui_pane_changed, sidebarVisible, inspectorPresented);

                // Shared, observable toolbar state. ctx = the numeric host id boxed
                // as a pointer (the dispatcher unboxes it for window:toolbar-clicked's
                // win-<n> field); cb = the file-static reverse dispatcher (click /
                // menu-click -> native). The delegate owns this handle and releases it
                // once at teardown. The initial config toolbar is pushed below.
                swiftToolbarState = zapp_swift_toolbar_state_create((void*)(intptr_t)host_slot,
                    zapp_swiftui_toolbar_event);

                // REQUIRED for the SwiftUI pane path: NavigationSplitView only behaves
                // consistently in a HOSTED NSWindow with a full-size content view — its
                // toolbar/sidebar chrome otherwise differs under NSHostingController vs
                // the SwiftUI app lifecycle (toolbar items shifted on sidebar collapse
                // without this). `.fullSizeContentView` is the documented mitigation and
                // also gives the modern full-height sidebar. (See native-ui-strategy.md.)
                [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullSizeContentView)];
                // Parity with the AppKit branch (tbs==3 below): a sidebar window with an
                // unspecified title-bar style (Unset) gets the hidden-title unified chrome.
                // Without this the SwiftUI path shows the native window title (duplicating
                // the app's own heading). tbs 1/2 (explicit hidden/hiddenInset) were already
                // hidden up top for all windows; this covers the Unset sidebar default.
                if (tbs == 3) {
                    [window setTitleVisibility:NSWindowTitleHidden];
                    [window setTitlebarAppearsTransparent:YES];
                    // KNOWN SwiftUI LIMITATION: hiding the title collapses SwiftUI's
                    // .navigation/.primaryAction toolbar split (items pack leading) — the
                    // placement split needs the title as a layout anchor, and there is no
                    // reliable macOS-14 workaround (single-ToolbarItem+HStack+Spacer can't
                    // expand). AppKit's flexibleSpace is title-independent, so it still splits.
                    // So hidden-title SwiftUI windows get a flat (leading) toolbar. Documented.
                }
                // Toolbar-style parity: AppKit sets window.toolbarStyle from the toolbar
                // `style` (darwin_toolbar_attach), which the SwiftUI path skips. Set the
                // unified style here (tbs==2 already chose unifiedCompact up top). This
                // ALSO restores the toolbar's leading/.navigation vs trailing/.primaryAction
                // distribution — under the hidden-title transparent chrome, the default
                // (automatic) style collapsed all items to the leading edge.
                if (@available(macOS 11.0, *)) {
                    if (tbs != 2) [window setToolbarStyle:NSWindowToolbarStyleUnified];
                }

                // Install the SwiftUI host (wrapping the content container + optional
                // sidebar + optional inspector) as the window's contentView FIRST, so
                // the containers are in the window before the webviews are created into
                // them (mirrors the AppKit ordering where splitVC is root before _ext).
                NSViewController* paneVC = (__bridge_transfer NSViewController*)zapp_swift_panes_create(
                    swiftPaneState, swiftToolbarState, (__bridge void*)mainContainer,
                    (__bridge void*)sidebarContainer, (__bridge void*)inspectorContainer);
                window.contentViewController = paneVC;   // sets window.contentView = paneVC.view; window retains the VC
                // NSHostingController overrides the window's content size on assignment; restore the
                // configured size (sizingOptions=[] in panes.swift stops it re-driving on later layout).
                [window setContentSize:NSMakeSize((CGFloat)wopts_width(opts), (CGFloat)wopts_height(opts))];
                [paneVC.view layoutSubtreeIfNeeded];

                // Create the content webview INTO mainContainer (same call as the AppKit
                // path; never re-parented). pane_role=0; host_has_sidebar=useSidebar +
                // host_has_inspector=useInspector so the Window.current() handle wires the
                // sidebar + inspector panes.
                darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                          custom_url, host_slot, useVibrancy,
                                          (__bridge void*)mainContainer, -1, 0,
                                          useSidebar, useInspector);

                // Register the content webview (routing/bridge essential).
                NSString* hostWindowId = [NSString stringWithFormat:@"win-%d", host_slot];
                for (NSView* sub in mainContainer.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) {
                        mainWebviewRef = (WKWebView*)sub;
                        zapp_register_webview(host_slot, mainWebviewRef, hostWindowId);
                        break;
                    }
                }

                // Sidebar webview: own transport slot, HOST identity (win-<host>), always
                // transparent so the pane material shows through, pane_role=1 (sidebar).
                // NOTE: the SwiftUI register variant (below) wires a swiftPaneState-backed
                // controller — no splitVC/NSSplitViewItem — so darwin_sidebar_* runtime ops
                // resolve + drive the PaneState. zapp_set_sidebar_slot still runs (fan-out).
                if (useSidebar) {
                    darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                              sidebarUrl, sidebar_slot, true,
                                              (__bridge void*)sidebarContainer, host_slot, 1,
                                              useSidebar, useInspector);
                    for (NSView* sub in sidebarContainer.subviews) {
                        if ([sub isKindOfClass:[WKWebView class]]) { sidebarWebviewRef = (WKWebView*)sub; break; }
                    }
                    if (sidebarWebviewRef) zapp_register_webview(sidebar_slot, sidebarWebviewRef, hostWindowId);
                    zapp_set_sidebar_slot(host_slot, sidebar_slot);   // event fan-out
                    // Register a SwiftUI-backed controller so darwin_sidebar_* ops
                    // resolve + drive the PaneState (no splitVC/NSSplitViewItem).
                    zapp_sidebar_register_swiftui((__bridge void*)window, swiftPaneState,
                                                  host_slot, sidebar_slot, !sidebarVisible);
                }

                // Inspector webview: own transport slot, HOST identity (win-<host>), always
                // transparent so the pane material shows through, pane_role=3 (inspector).
                if (useInspector) {
                    darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                              inspectorUrl, inspector_slot, true,
                                              (__bridge void*)inspectorContainer, host_slot, 3,
                                              useSidebar, useInspector);
                    for (NSView* sub in inspectorContainer.subviews) {
                        if ([sub isKindOfClass:[WKWebView class]]) { inspectorWebviewRef = (WKWebView*)sub; break; }
                    }
                    if (inspectorWebviewRef) zapp_register_webview(inspector_slot, inspectorWebviewRef, hostWindowId);
                    zapp_set_inspector_slot(host_slot, inspector_slot);   // event fan-out
                    // Register a SwiftUI-backed controller so darwin_inspector_* ops
                    // resolve + drive the PaneState (no splitVC/NSSplitViewItem).
                    zapp_inspector_register_swiftui((__bridge void*)window, swiftPaneState,
                                                    host_slot, inspector_slot, !inspectorPresented);
                }

                // Initial config toolbar -> SwiftUI ToolbarState. On this path the
                // AppKit NSToolbar attach is skipped (it would collide with the
                // SwiftUI `.toolbar`); push the config items into the ToolbarState so
                // a config-declared toolbar renders via SwiftUI on launch. Runtime
                // setItems still routes to NSToolbar until Task 5 (the router fork).
                {
                    const char* tj0 = wopts_toolbar_json(opts);
                    if (tj0 && tj0[0]) zapp_swift_module_set_string(swiftToolbarState, ZAPP_TB_SET_ITEMS, tj0);
                }
            } else
#endif
            {
            if (tbs == 3) {
                [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullSizeContentView)];
                [window setTitleVisibility:NSWindowTitleHidden];
                [window setTitlebarAppearsTransparent:YES];
            }

            // Content pane (always present). Vibrancy wraps the MAIN pane only.
            NSViewController* contentVC = [[NSViewController alloc] init];
            contentVC.view = [[NSView alloc] initWithFrame:[window contentView].frame];
            NSView* mainContainer = contentVC.view;
            if (useVibrancy) {
                NSVisualEffectView* vfx = [[NSVisualEffectView alloc] initWithFrame:contentVC.view.frame];
                vfx.material = material;
                vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                vfx.state = NSVisualEffectStateFollowsWindowActiveState;
                vfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                contentVC.view = vfx;
                mainContainer = vfx;
            }

            NSSplitViewController* splitVC = [[NSSplitViewController alloc] init];

            // Leading sidebar pane (optional).
            NSSplitViewItem* sideItem = nil;
            NSView* sidebarContainer = nil;
            if (useSidebar) {
                NSViewController* sideVC = [[NSViewController alloc] init];
                sideVC.view = [[NSView alloc] initWithFrame:
                    NSMakeRect(0, 0, (CGFloat)wopts_sidebar_width(opts), (CGFloat)wopts_height(opts))];
                sidebarContainer = sideVC.view;
                // Sidebar material override: only when the app asked for a specific
                // material other than the default "sidebar"/empty. Default leaves
                // the .sidebar split item's own system material (liquid glass on
                // macOS 26) untouched. When overridden, install a behind-window vfx
                // as the sidebar pane's view so the webview (transparent) shows it.
                const char* sidebarMaterialName = wopts_sidebar_material(opts);
                bool sidebarMaterialOverride = sidebarMaterialName && sidebarMaterialName[0] != '\0' &&
                                               strcmp(sidebarMaterialName, "sidebar") != 0;
                if (sidebarMaterialOverride) {
                    NSVisualEffectView* svfx = [[NSVisualEffectView alloc] initWithFrame:sideVC.view.bounds];
                    svfx.material = zapp_material_from_name(sidebarMaterialName);
                    svfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                    svfx.state = NSVisualEffectStateFollowsWindowActiveState;
                    svfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    sideVC.view = svfx;
                    sidebarContainer = svfx;
                } else {
                    // No material override: a solid backgroundColor (if set) paints
                    // an opaque backdrop behind the transparent webview — the pane
                    // analog of the window backgroundColor, filling the pre-paint gap.
                    int cr, cg, cb;
                    const char* sbg = wopts_sidebar_background_color(opts);
                    if (sbg && sbg[0] != '\0' && zapp_parse_hex_color(sbg, &cr, &cg, &cb)) {
                        sideVC.view.wantsLayer = YES;
                        sideVC.view.layer.backgroundColor =
                            [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:1.0].CGColor;
                    }
                }
                sideItem = [NSSplitViewItem sidebarWithViewController:sideVC];
                sideItem.minimumThickness = (CGFloat)wopts_sidebar_min_width(opts);
                sideItem.maximumThickness = (CGFloat)wopts_sidebar_max_width(opts);
                sideItem.canCollapse = wopts_sidebar_collapsible(opts);
                [splitVC addSplitViewItem:sideItem];
            }

            // Content pane.
            NSSplitViewItem* contentItem = [NSSplitViewItem splitViewItemWithViewController:contentVC];
            [splitVC addSplitViewItem:contentItem];

            // Trailing inspector pane (optional).
            NSSplitViewItem* inspItem = nil;
            NSView* inspectorContainer = nil;
            if (useInspector) {
                NSViewController* inspVC = [[NSViewController alloc] init];
                inspVC.view = [[NSView alloc] initWithFrame:
                    NSMakeRect(0, 0, (CGFloat)wopts_inspector_width(opts), (CGFloat)wopts_height(opts))];
                inspectorContainer = inspVC.view;
                const char* inspectorMaterialName = wopts_inspector_material(opts);
                bool inspectorMaterialOverride = inspectorMaterialName && inspectorMaterialName[0] != '\0' &&
                                                 strcmp(inspectorMaterialName, "sidebar") != 0;
                if (inspectorMaterialOverride) {
                    NSVisualEffectView* ivfx = [[NSVisualEffectView alloc] initWithFrame:inspVC.view.bounds];
                    ivfx.material = zapp_material_from_name(inspectorMaterialName);
                    ivfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                    ivfx.state = NSVisualEffectStateFollowsWindowActiveState;
                    ivfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    inspVC.view = ivfx;
                    inspectorContainer = ivfx;
                } else {
                    int cr, cg, cb;
                    const char* ibg = wopts_inspector_background_color(opts);
                    if (ibg && ibg[0] != '\0' && zapp_parse_hex_color(ibg, &cr, &cg, &cb)) {
                        inspVC.view.wantsLayer = YES;
                        inspVC.view.layer.backgroundColor =
                            [NSColor colorWithSRGBRed:cr/255.0 green:cg/255.0 blue:cb/255.0 alpha:1.0].CGColor;
                    }
                }
                if (@available(macOS 11.0, *)) {
                    inspItem = [NSSplitViewItem inspectorWithViewController:inspVC];
                } else {
                    inspItem = [NSSplitViewItem splitViewItemWithViewController:inspVC];
                }
                inspItem.minimumThickness = (CGFloat)wopts_inspector_min_width(opts);
                inspItem.maximumThickness = (CGFloat)wopts_inspector_max_width(opts);
                inspItem.canCollapse = wopts_inspector_collapsible(opts);
                [splitVC addSplitViewItem:inspItem];
            }

            // Trailing native-surface pane (optional, macOS only). Resolves to a
            // SwiftUI (enhanced) or AppKit (baseline) backing in nativesurface.m;
            // it shares the host's numeric id (host_slot) so the round-trip emit
            // (zapp_native_surface_emit) lands on this window. Appended last via
            // addSplitViewItem (append-at-count is the safe NSSplitView idiom).
            if (useNativeSurface) {
                NSView* surface = darwin_native_surface_create(host_slot);
                if (surface) {
                    NSViewController* surfaceVC = [[NSViewController alloc] init];
                    surfaceVC.view = surface;
                    NSSplitViewItem* surfaceItem =
                        [NSSplitViewItem splitViewItemWithViewController:surfaceVC];
                    surfaceItem.minimumThickness = 240;
                    [splitVC addSplitViewItem:surfaceItem];
                }
            }

            window.contentViewController = splitVC;
            // Assigning a split-view controller with sidebar/inspector minimums makes
            // AppKit grow the window to fit their SUM — so the panes would be added
            // ON TOP of the configured width, launching wider than the SwiftUI path
            // (and wider than a no-panes window). Reset to the configured content size
            // so the panes lay out WITHIN it (content column shrinks), matching the
            // SwiftUI path (which does the same after its NSHostingController).
            [window setContentSize:NSMakeSize((CGFloat)wopts_width(opts), (CGFloat)wopts_height(opts))];

            // Initial geometry (controller is now the root). Sidebar divider is
            // index 0; the inspector divider is the one before the trailing item,
            // positioned from the left as (total - inspectorWidth). Collapse last
            // so KVO registry (inspector.m / sidebar.m) is wired — but register
            // happens below, so a create-time collapsed pane just starts collapsed;
            // no event is expected at create.
            if (useSidebar) {
                [splitVC.splitView setPosition:(CGFloat)wopts_sidebar_width(opts) ofDividerAtIndex:0];
                if (wopts_sidebar_collapsed(opts)) sideItem.collapsed = YES;
            }
            if (useInspector) {
                NSInteger inspDivider = (NSInteger)splitVC.splitViewItems.count - 2;
                CGFloat totalW = splitVC.splitView.bounds.size.width;
                [splitVC.splitView setPosition:(totalW - (CGFloat)wopts_inspector_width(opts))
                                ofDividerAtIndex:inspDivider];
                if (wopts_inspector_collapsed(opts)) inspItem.collapsed = YES;
            }

            // Webviews. Main → host slot, self identity, legacy transparent rule
            // (useVibrancy), pane_role=0. Sidebar → its own transport slot, HOST
            // identity (win-<host> in JS), always transparent so the pane material
            // shows through, pane_role=1 (sidebar). Inspector → its own transport
            // slot, HOST identity, always transparent, pane_role=3 (inspector).
            // has* flags drive the Window.current() handle wiring in every pane.
            darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                      custom_url, host_slot, useVibrancy,
                                      (__bridge void*)mainContainer, -1, 0,
                                      useSidebar, useInspector);
            if (useSidebar) {
                darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                          sidebarUrl, sidebar_slot, true,
                                          (__bridge void*)sidebarContainer, host_slot, 1,
                                          useSidebar, useInspector);
            }
            if (useInspector) {
                darwin_webview_create_ext((__bridge void*)window, inspectable, accept_first_mouse,
                                          inspectorUrl, inspector_slot, true,
                                          (__bridge void*)inspectorContainer, host_slot, 3,
                                          useSidebar, useInspector);
            }

            // Register all webviews in the dispatch table here. The normal
            // registration path (darwin_window_register_numeric_id) walks
            // [window contentView] which is now the NSSplitView — it can't find
            // any pane webview that way, so we register them explicitly from the
            // containers we hold. zapp_register_webview is static-in-file.
            // Note: each pane window consumes 2-3 of the ZAPP_MAX_WINDOW_CALLBACKS slots.
            NSString* hostWindowId = [NSString stringWithFormat:@"win-%d", host_slot];
            for (NSView* sub in mainContainer.subviews) {
                if ([sub isKindOfClass:[WKWebView class]]) {
                    mainWebviewRef = (WKWebView*)sub;
                    zapp_register_webview(host_slot, mainWebviewRef, hostWindowId);
                    break;
                }
            }
            if (useSidebar) {
                for (NSView* sub in sidebarContainer.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) { sidebarWebviewRef = (WKWebView*)sub; break; }
                }
                if (sidebarWebviewRef) {
                    // The sidebar's JS identity is the HOST id (win-<host>), so its
                    // window-id table entry mirrors that — transport routes by the
                    // slot index, identity by this string. (See _ext's identity note.)
                    zapp_register_webview(sidebar_slot, sidebarWebviewRef, hostWindowId);
                }
            }
            if (useInspector) {
                for (NSView* sub in inspectorContainer.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) { inspectorWebviewRef = (WKWebView*)sub; break; }
                }
                if (inspectorWebviewRef) {
                    // Inspector's JS identity is the HOST id (win-<host>), same as sidebar.
                    zapp_register_webview(inspector_slot, inspectorWebviewRef, hostWindowId);
                }
            }

            // (zapp.hasSidebar / zapp.hasInspector are injected into ALL panes as
            // document-start user scripts in darwin_webview_create_ext — a one-shot
            // eval here raced the page commit and got wiped with the throwaway context.)

            // Fan-out tables + accessory registries.
            if (useSidebar) {
                // Record host→sidebar for window-event fan-out (zapp_dispatch_event_to_js).
                zapp_set_sidebar_slot(host_slot, sidebar_slot);
                zapp_sidebar_register((__bridge void*)window, (__bridge void*)splitVC,
                                      (__bridge void*)sideItem, host_slot, sidebar_slot);
                // Honor create-time `resizable: false` — register captured the
                // configured min/max first, so a later setResizable(true) restores it.
                if (!wopts_sidebar_can_resize(opts)) darwin_sidebar_set_resizable(host_slot, false);
            }
            if (useInspector) {
                // Record host→inspector for window-event fan-out (zapp_dispatch_event_to_js).
                zapp_set_inspector_slot(host_slot, inspector_slot);
                zapp_inspector_register((__bridge void*)window, (__bridge void*)splitVC,
                                        (__bridge void*)inspItem, host_slot, inspector_slot);
                if (!wopts_inspector_can_resize(opts)) darwin_inspector_set_resizable(host_slot, false);
            }
            } // end AppKit (else) branch
        } else if (useVibrancy) {
            NSRect contentRect = [window contentView].frame;
            NSVisualEffectView* vfx = [[NSVisualEffectView alloc] initWithFrame:contentRect];
            vfx.material = material;
            vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            vfx.state = NSVisualEffectStateFollowsWindowActiveState;
            vfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [window setContentView:vfx];
        }

        if (!useSidebar && !useInspector && !useNativeSurface) {
            // Legacy single-webview path — byte-for-byte equivalent to before
            // (the vibrancy vfx, if any, was installed as contentView above).
            // A native-surface-only window took the split path above (its main
            // webview is the _ext content pane), so skip this fallback.
            darwin_webview_create((__bridge void*)window, inspectable, accept_first_mouse,
                                  custom_url, host_slot, useVibrancy);
        }

        NSString* windowId = [NSString stringWithFormat:@"win-%p", window];
        NSString* ownerId = [NSString stringWithFormat:@"owner-%p", window];
        ZappWindowDelegate* delegate = [[ZappWindowDelegate alloc] init];
        delegate.windowId = windowId;
        delegate.ownerId = ownerId;
        // numericId set by darwin_window_register_numeric_id after creation.
        // Sidebar/inspector bookkeeping for event fan-out + teardown (-1 when absent).
        delegate.sidebarNumericId = useSidebar ? sidebar_slot : -1;
        delegate.inspectorNumericId = useInspector ? inspector_slot : -1;
        delegate.mainWebview = mainWebviewRef;         // nil in the non-split path
        delegate.sidebarWebview = sidebarWebviewRef;   // nil when no sidebar
        delegate.inspectorWebview = inspectorWebviewRef; // nil when no inspector
        delegate.swiftPaneState = swiftPaneState;       // NULL unless the SwiftUI path ran
        delegate.swiftToolbarState = swiftToolbarState;  // NULL unless the SwiftUI path ran

        // Seed the host webview's underpage fill (the WebView2
        // DefaultBackgroundColor analogue) with the app-set background. Split
        // path: the main pane is mainWebviewRef. Plain opaque path: the
        // contentView IS the WKWebView (its dispatch-table registration runs
        // later, so read it directly here). bgColor is non-nil only for opaque
        // windows (see the parse above).
        if (bgColor) {
            if (@available(macOS 12.0, *)) {
                WKWebView* hostWv = mainWebviewRef;
                if (!hostWv && [[window contentView] isKindOfClass:[WKWebView class]]) {
                    hostWv = (WKWebView*)[window contentView];
                }
                if (hostWv) hostWv.underPageBackgroundColor = bgColor;
            }
        }

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

        // Native toolbar (toolbar.m). Attach AFTER split construction (the
        // tracking separator resolves the live NSSplitView through the
        // window's contentViewController) and after delegate setup.
        //
        // Sub-cycle 2b: on the SwiftUI pane path the toolbar is rendered by SwiftUI
        // `.toolbar` (panes.swift); do NOT attach an NSToolbar (it would collide).
        bool swiftUIToolbar = false;
#ifdef ZAPP_HAS_SWIFTUI
        swiftUIToolbar = (delegate.swiftPaneState != NULL);
#endif
        const char* toolbarJson = wopts_toolbar_json(opts);
        if (!swiftUIToolbar && toolbarJson && toolbarJson[0]) {
            darwin_toolbar_attach((__bridge void*)window, toolbarJson, host_slot);
            // Initial chrome-metrics injection, one runloop tick later: the
            // titlebar band picks the toolbar up in the next layout pass, and
            // by then both panes are registered in the dispatch table (the
            // create call chain completes before the tick runs). Subsequent
            // updates — the user can switch Icon/Text display modes from the
            // toolbar's context menu at runtime — re-inject via the
            // controller's contentLayoutRect KVO (toolbar.m).
            extern void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script);
            NSWindow* toolbarWindow = window;
            dispatch_async(dispatch_get_main_queue(), ^{
                zapp_toolbar_inject_metrics((__bridge void*)toolbarWindow, host_slot, true);
            });
        }

        return (__bridge_retained void*)window;
    }
}

// Tear a single WKWebView down (alpha.29 ProcessThrottler brk#1 hardening):
// stop pending loads → remove the script message handler (drops WebKit's strong
// ref to ZappMsgHandler + captured blocks) → nil delegates (final in-flight
// callbacks become no-ops instead of retaining the webview through destruction).
// No-op on nil. Used for the main webview and (in the split case) both panes.
static void zapp_teardown_webview(WKWebView* wv) {
    if (!wv) return;
    [wv stopLoading];
    WKUserContentController* ucc = wv.configuration.userContentController;
    @try {
        [ucc removeScriptMessageHandlerForName:@"zapp"];
    } @catch (NSException* ex) { (void)ex; }
    [wv setNavigationDelegate:nil];
    [wv setUIDelegate:nil];
}

// Public wrapper for popover.m (the helper itself stays static/local).
void zapp_teardown_pane_webview(WKWebView* wv) {
    zapp_teardown_webview(wv);
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
        zapp_teardown_webview((WKWebView*)content);
    }

    // Split windows (sidebar / inspector / both): the contentView is the
    // NSSplitView, so pane webviews are not reachable via [window contentView].
    // Tear all panes down via the delegate's stored refs (same alpha.29
    // hardening), and drop the split registries (KVO + resize observers). The
    // delegate is still the window's delegate here (release happens at [window
    // close] below).
    ZappWindowDelegate* delegate = (ZappWindowDelegate*)[window delegate];
    if ([delegate isKindOfClass:[ZappWindowDelegate class]]) {
        bool hasSplit = (delegate.sidebarNumericId >= 0 || delegate.inspectorNumericId >= 0);
        if (hasSplit) {
            zapp_teardown_webview(delegate.mainWebview);
        }
        if (delegate.sidebarNumericId >= 0) {
            zapp_teardown_webview(delegate.sidebarWebview);
            zapp_sidebar_unregister(handle);
        }
        if (delegate.inspectorNumericId >= 0) {
            zapp_teardown_webview(delegate.inspectorWebview);
            zapp_inspector_unregister(handle);
        }
#ifdef ZAPP_HAS_SWIFTUI
        if (delegate.swiftPaneState) {
            zapp_swift_panes_state_release(delegate.swiftPaneState);
            delegate.swiftPaneState = NULL;
        }
        if (delegate.swiftToolbarState) {
            zapp_swift_toolbar_state_release(delegate.swiftToolbarState);
            delegate.swiftToolbarState = NULL;
        }
#endif
    }
    zapp_toolbar_unregister(handle);
    extern void zapp_popover_unregister_window(void* window_ptr);
    zapp_popover_unregister_window(handle);

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
    // x,y are top-left global; setFrameOrigin wants bottom-left.
    NSWindow* w = (__bridge NSWindow*)handle;
    CGFloat blY = zapp_primary_screen_height() - (CGFloat)y - w.frame.size.height;
    [w setFrameOrigin:NSMakePoint((CGFloat)x, blY)];
}

void darwin_window_minimize(void* handle) {
    [(__bridge NSWindow*)handle miniaturize:nil];
}

void darwin_window_focus(void* handle) {
    if (!handle) return;
    NSWindow* window = (__bridge NSWindow*)handle;
    void (^run)(void) = ^{
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];  // raise the APP over others
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

void darwin_window_maximize(void* handle) {
    NSWindow* w = (__bridge NSWindow*)handle;
    if (![w isZoomed]) [w zoom:nil];
}

// Toggle zoom (standard / zoomed) — NSWindow zoom: toggles each call, so this
// is the title-bar double-click behavior. Unlike darwin_window_maximize (which
// only ever maximizes), this restores when already zoomed.
void darwin_window_zoom(void* handle) {
    NSWindow* w = (__bridge NSWindow*)handle;
    [w zoom:nil];
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
    *out_y = (int32_t)(zapp_primary_screen_height() - frame.origin.y - frame.size.height);
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

    // Cache numericId on delegate for O(1) event dispatch. Also migrate
    // delegate.windowId off the construction-time pointer form ("win-%p") to
    // the canonical numeric form: darwin_window_set_bridge_ready matches the
    // router's wid ("win-%d") against delegate.windowId, and with the stale
    // pointer form it never matched — bridgeReady stayed NO, so every FOCUS
    // event was parked in pendingFocusEvent forever (blur is ungated, which
    // is why windows blurred but never focused).
    ZappWindowDelegate* delegate = (ZappWindowDelegate*)[w delegate];
    if ([delegate isKindOfClass:[ZappWindowDelegate class]]) {
        delegate.numericId = numeric_id;
        delegate.windowId = windowId;
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
