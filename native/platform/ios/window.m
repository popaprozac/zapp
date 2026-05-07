// iOS window — port of darwin/window.m. iPhone is single-window by
// design; multi-scene support (iPad) lands in Phase 4.
//
// **Deferred creation model** (mirrors Tauri Mobile / tao):
//
// The framework's startup sequence on macOS is `app.window.create()` →
// `app.run()`. NSWindow can exist before NSApp.run, so the macOS path
// allocates the real window eagerly. iOS doesn't allow this: a UIWindow
// created before UIApplicationMain has no UIWindowScene and never
// participates in event delivery; any WKWebView added to such an
// orphaned window latches its gesture recognizers onto the dead
// responder chain (first tap crashes inside
// -[UIGestureRecognizer _delayTouchesForEvent:inPhase:]).
//
// So on iOS, `darwin_window_create` returns a `ZappIOSDeferred` opaque
// handle that records intent only. Setters (set_title, show, ...) queue
// against it. After UIApplicationMain → didFinishLaunchingWithOptions
// the AppDelegate calls `zapp_ios_materialize_pending_windows()` which
// allocates the real UIWindow + UIViewController + WKWebView bound to
// the connected UIWindowScene, then replays queued actions.
//
// Most `darwin_window_*` setters are no-ops on iOS (no resizable
// frame, no titlebar, no traffic lights, no fullscreen toggle), but
// they still need to accept calls during the deferred phase so the
// caller's API contract holds.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern void darwin_webview_create(void* window_ptr, bool inspectable, bool accept_first_mouse,
                                  const char* url_override, int32_t numeric_id_pre_alloc,
                                  bool transparent_background);

#ifndef ZAPP_MAX_WINDOW_CALLBACKS
#define ZAPP_MAX_WINDOW_CALLBACKS 64
#endif

// --- Deferred-window registry ---

typedef struct ZappIOSDeferred {
    int32_t numeric_id;       // -1 until register_numeric_id
    bool inspectable;
    bool first_mouse;
    char* queued_title;       // last-set title (replayed on materialize)
    bool show_requested;      // makeKeyAndVisible queued?
    UIWindow* __unsafe_unretained real_window;     // nil until materialized
    WKWebView* __unsafe_unretained real_webview;
    // Sheet presentation options — populated by darwin_window_create
    // from WindowOptions, consumed by darwin_window_attach_modal.
    int32_t sheet_presentation;   // 0=page, 1=form, 2=fullscreen, 3=bottomSheet
    int32_t sheet_detents;        // bitmask: 1=medium, 2=large
    bool    sheet_grabber;
} ZappIOSDeferred;

#define ZAPP_MAX_DEFERRED 16
static ZappIOSDeferred* zapp_ios_deferred_list[ZAPP_MAX_DEFERRED] = {0};

// Dispatch table parallel to darwin/window.m's: numeric ID →
// (UIWindow, WKWebView, owner-string). During the deferred phase the
// `zapp_ios_windows` slot stays nil; it gets filled when the real
// UIWindow is materialized.
static UIWindow* zapp_ios_windows[ZAPP_MAX_WINDOW_CALLBACKS] = {0};
static WKWebView* zapp_ios_webviews[ZAPP_MAX_WINDOW_CALLBACKS] = {0};
static NSString* zapp_ios_window_ids[ZAPP_MAX_WINDOW_CALLBACKS] = {0};

static ZappIOSDeferred* zapp_ios_find_deferred(void* handle) {
    if (!handle) return NULL;
    for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
        if ((void*)zapp_ios_deferred_list[i] == handle) return zapp_ios_deferred_list[i];
    }
    return NULL;
}

// --- Materialization (called from AppDelegate.didFinishLaunching) ---
//
// Walks the deferred list and turns each entry into a real
// UIWindow + UIViewController + WKWebView bound to the first
// connected UIWindowScene. Replays queued setter state.

void zapp_ios_materialize_pending_windows(void) {
    UIWindowScene* scene = nil;
    for (UIScene* s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene*)s; break; }
    }

    for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
        ZappIOSDeferred* d = zapp_ios_deferred_list[i];
        if (!d || d->real_window) continue;

        UIWindow* window = scene
            ? [[UIWindow alloc] initWithWindowScene:scene]
            : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        window.frame = scene ? scene.coordinateSpace.bounds : [UIScreen mainScreen].bounds;

        UIViewController* root = [[UIViewController alloc] init];
        root.view.frame = window.bounds;
        root.view.backgroundColor = [UIColor systemBackgroundColor];
        window.rootViewController = root;
        window.backgroundColor = [UIColor systemBackgroundColor];

        // Plug the materialized UIWindow into the numeric-ID dispatch
        // table BEFORE darwin_webview_create runs — its callback
        // (zapp_ios_register_webview) looks the window up there to know
        // which slot to drop the WKWebView into.
        d->real_window = window;
        if (d->numeric_id >= 0 && d->numeric_id < ZAPP_MAX_WINDOW_CALLBACKS) {
            zapp_ios_windows[d->numeric_id] = window;
            // Numeric form matches what router.zc returns to JS — keeps
            // Window.current() and Window.create() handles in lockstep.
            zapp_ios_window_ids[d->numeric_id] = [NSString stringWithFormat:@"win-%d", d->numeric_id];
        }

        // darwin_webview_create allocates the WKWebView, attaches it to
        // root.view, and registers the (window, webview) pair in
        // zapp_ios_webviews via zapp_ios_register_webview. Crucially,
        // the WKWebView is being added to a scene-bound window — its
        // gesture recognizers form against a live responder chain.
        darwin_webview_create((__bridge void*)window, d->inspectable, d->first_mouse, NULL, d->numeric_id, false);

        if (d->numeric_id >= 0 && d->numeric_id < ZAPP_MAX_WINDOW_CALLBACKS) {
            d->real_webview = zapp_ios_webviews[d->numeric_id];
            // Push the canonical "win-<numericId>" into the JS context
            // so Window.current() returns the same string format that
            // Window.create() produces. Mirrors the macOS flow.
            if (d->real_webview) {
                NSString* setIdJs = [NSString stringWithFormat:
                    @"globalThis[Symbol.for('zapp.windowId')]='win-%d';", d->numeric_id];
                [d->real_webview evaluateJavaScript:setIdJs completionHandler:nil];
            }
        }

        // Replay queued setters.
        if (d->queued_title) {
            NSString* s = [NSString stringWithUTF8String:d->queued_title];
            if (s && window.windowScene) window.windowScene.title = s;
        }
        if (d->show_requested) {
            [window makeKeyAndVisible];
        }

        NSLog(@"[native] iOS window materialized: id=%d scene=%@ window=%@ webview=%@",
              d->numeric_id, scene, window, d->real_webview);
    }
}

// --- WebView ↔ Window registration (called from webview.m) ---

void zapp_ios_register_webview(void* window_ptr, void* webview_ptr) {
    UIWindow* w = (__bridge UIWindow*)window_ptr;
    WKWebView* wv = (__bridge WKWebView*)webview_ptr;

    // First check materialized real_window slots.
    for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
        ZappIOSDeferred* d = zapp_ios_deferred_list[i];
        if (d && d->real_window == w) {
            d->real_webview = wv;
            if (d->numeric_id >= 0 && d->numeric_id < ZAPP_MAX_WINDOW_CALLBACKS) {
                zapp_ios_webviews[d->numeric_id] = wv;
            }
            return;
        }
    }
    // Fallback: dispatch table direct match.
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_ios_windows[i] == w) {
            zapp_ios_webviews[i] = wv;
            return;
        }
    }
}

void* zapp_ios_get_webview_for_window(void* window_ptr) {
    UIWindow* w = (__bridge UIWindow*)window_ptr;
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_ios_windows[i] == w) return (__bridge void*)zapp_ios_webviews[i];
    }
    return NULL;
}

void zapp_ios_eval_js_all_webviews(const char* js) {
    if (!js) return;
    NSString* script = [NSString stringWithUTF8String:js];
    if (!script) return;
    void (^run)(void) = ^{
        for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
            WKWebView* wv = zapp_ios_webviews[i];
            if (wv) [wv evaluateJavaScript:script completionHandler:nil];
        }
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

// --- Window lookup helpers (mirror darwin/window.m exports) ---

int32_t darwin_window_id_for_webview(void* webview) {
    if (!webview) return 0;
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_ios_webviews[i] == (__bridge WKWebView*)webview) return i;
    }
    return 0;
}

const char* darwin_window_id_string(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_ios_window_ids[numeric_id]) {
        return [zapp_ios_window_ids[numeric_id] UTF8String];
    }
    return NULL;
}

int32_t darwin_window_numeric_id_for_string(const char* window_id_string) {
    if (!window_id_string || !window_id_string[0]) return -1;
    NSString* target = [NSString stringWithUTF8String:window_id_string];
    if (!target) return -1;
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_ios_window_ids[i] && [zapp_ios_window_ids[i] isEqualToString:target]) return i;
    }
    return -1;
}

void* darwin_window_get_webview(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_ios_webviews[numeric_id]) {
        return (__bridge void*)zapp_ios_webviews[numeric_id];
    }
    return NULL;
}

void darwin_window_eval_js(int32_t window_id, const char* js) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    WKWebView* webview = zapp_ios_webviews[window_id];
    if (!webview || !js) return;
    NSString* script = [NSString stringWithUTF8String:js];
    if (!script) return;
    void (^run)(void) = ^{ [webview evaluateJavaScript:script completionHandler:nil]; };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

void darwin_window_set_bridge_ready(const char* window_id) { (void)window_id; }

// --- Window event dispatch to JS (called from callbacks.zc) ---
//
// Mirrors darwin/window.m's `zapp_dispatch_event_to_js`. Builds a small
// JS snippet that calls `bridge.dispatchWindowEvent(...)` and evals on
// the target webview. Reusable buffer to avoid per-event allocations.

static char zapp_ios_event_js_buf[512];

static const char* zapp_ios_event_names[] = {
    "ready", "focus", "blur", "resize", "move", "close",
    "minimize", "maximize", "restore", "fullscreen", "unfullscreen",
    "modal-dismissed"
};

static inline const char* zapp_ios_get_event_name(int event_id) {
    if (event_id >= 0 && event_id < 12) return zapp_ios_event_names[event_id];
    return "unknown";
}

void zapp_dispatch_event_to_js(int32_t window_id, int32_t event_id, int32_t w, int32_t h, int32_t x, int32_t y) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    WKWebView* webview = zapp_ios_webviews[window_id];
    NSString* windowId = zapp_ios_window_ids[window_id];
    if (!webview || !windowId) return;

    const char* event_name = zapp_ios_get_event_name(event_id);
    const char* wid = [windowId UTF8String];

    bool hasPayload = (event_id == 3 /* RESIZE */ || event_id == 4 /* MOVE */ ||
                       event_id == 7 /* MAXIMIZE */ || event_id == 8 /* RESTORE */);
    if (event_id == 11 /* MODAL_DISMISSED */) {
        snprintf(zapp_ios_event_js_buf, sizeof(zapp_ios_event_js_buf),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&typeof b.dispatchWindowEvent==='function'){"
            "b.dispatchWindowEvent('%s','%s','{\"modalId\":\"win-%d\",\"code\":%d}');}})();",
            wid, event_name, w, h);
    } else if (hasPayload) {
        snprintf(zapp_ios_event_js_buf, sizeof(zapp_ios_event_js_buf),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&typeof b.dispatchWindowEvent==='function'){"
            "b.dispatchWindowEvent('%s','%s','{\"width\":%d,\"height\":%d,\"x\":%d,\"y\":%d}');}})();",
            wid, event_name, w, h, x, y);
    } else {
        snprintf(zapp_ios_event_js_buf, sizeof(zapp_ios_event_js_buf),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&typeof b.dispatchWindowEvent==='function'){"
            "b.dispatchWindowEvent('%s','%s');}})();",
            wid, event_name);
    }

    NSString* js = [[NSString alloc] initWithBytesNoCopy:zapp_ios_event_js_buf
        length:strlen(zapp_ios_event_js_buf)
        encoding:NSUTF8StringEncoding
        freeWhenDone:NO];
    void (^run)(void) = ^{ [webview evaluateJavaScript:js completionHandler:nil]; };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

// --- Window create / lifecycle ---
//
// Returns a deferred handle. Real allocation happens later in
// zapp_ios_materialize_pending_windows.

void* darwin_window_create(void* opts) {
    ZappIOSDeferred* d = (ZappIOSDeferred*)calloc(1, sizeof(ZappIOSDeferred));
    d->numeric_id = -1;
    d->inspectable = true;
    d->first_mouse = true;
    d->show_requested = true;  // create implies show on iOS
    if (opts) {
        // Capture sheet presentation options now — attach_modal reads
        // them later. Other WindowOptions fields are read at
        // materialization time in webview.m via wopts_*.
        extern int wopts_sheet_presentation(void* opts);
        extern int wopts_sheet_detents(void* opts);
        extern bool wopts_sheet_grabber(void* opts);
        d->sheet_presentation = (int32_t)wopts_sheet_presentation(opts);
        d->sheet_detents = (int32_t)wopts_sheet_detents(opts);
        d->sheet_grabber = wopts_sheet_grabber(opts);
    }
    for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
        if (!zapp_ios_deferred_list[i]) {
            zapp_ios_deferred_list[i] = d;
            return (void*)d;
        }
    }
    free(d);
    return NULL;
}

void darwin_window_destroy(void* handle) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        if (d->real_window) d->real_window.hidden = YES;
        free(d->queued_title);
        for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
            if (zapp_ios_deferred_list[i] == d) zapp_ios_deferred_list[i] = NULL;
        }
        free(d);
        return;
    }
    // Fallback: live UIWindow* (shouldn't happen on iOS now, but cheap to keep).
    UIWindow* w = (__bridge_transfer UIWindow*)handle;
    w.hidden = YES;
    (void)w;
}

void darwin_window_show(void* handle) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        if (d->real_window) [d->real_window makeKeyAndVisible];
        else d->show_requested = true;
        return;
    }
    UIWindow* w = (__bridge UIWindow*)handle;
    [w makeKeyAndVisible];
}

void darwin_window_hide(void* handle) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        if (d->real_window) d->real_window.hidden = YES;
        else d->show_requested = false;
        return;
    }
    UIWindow* w = (__bridge UIWindow*)handle;
    w.hidden = YES;
}

void darwin_window_force_close(void* handle) {
    darwin_window_hide(handle);
}

// --- Setters: most are no-ops on iOS ---

void darwin_window_set_title(void* handle, const char* title) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        free(d->queued_title);
        d->queued_title = (title && title[0]) ? strdup(title) : NULL;
        if (d->real_window && title) {
            NSString* s = [NSString stringWithUTF8String:title];
            if (s && d->real_window.windowScene) d->real_window.windowScene.title = s;
        }
        return;
    }
    UIWindow* w = (__bridge UIWindow*)handle;
    if (!title) return;
    NSString* s = [NSString stringWithUTF8String:title];
    if (s && w.windowScene) w.windowScene.title = s;
}

void darwin_window_set_size(void* handle, int32_t width, int32_t height) {
    (void)handle; (void)width; (void)height;
}
void darwin_window_set_position(void* handle, int32_t x, int32_t y) {
    (void)handle; (void)x; (void)y;
}
void darwin_window_minimize(void* handle) { (void)handle; }
void darwin_window_maximize(void* handle) { (void)handle; }
void darwin_window_set_fullscreen(void* handle, bool on) { (void)handle; (void)on; }
void darwin_window_set_always_on_top(void* handle, bool on) { (void)handle; (void)on; }

void darwin_window_get_size(void* handle, int32_t* out_w, int32_t* out_h) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    UIWindow* w = d ? d->real_window : (__bridge UIWindow*)handle;
    if (!w) {
        // Pre-materialization: report screen bounds as a best-effort.
        CGRect bounds = [UIScreen mainScreen].bounds;
        if (out_w) *out_w = (int32_t)bounds.size.width;
        if (out_h) *out_h = (int32_t)bounds.size.height;
        return;
    }
    if (out_w) *out_w = (int32_t)w.bounds.size.width;
    if (out_h) *out_h = (int32_t)w.bounds.size.height;
}

void darwin_window_get_position(void* handle, int32_t* out_x, int32_t* out_y) {
    (void)handle;
    if (out_x) *out_x = 0;
    if (out_y) *out_y = 0;  // no concept of position on iOS
}

void darwin_window_register_numeric_id(void* handle, int32_t numeric_id) {
    if (numeric_id < 0 || numeric_id >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        d->numeric_id = numeric_id;
        // Slot stays nil in zapp_ios_windows until materialization;
        // pre-id_string will return NULL which is fine — no JS code is
        // running yet to ask for it.
        return;
    }
    UIWindow* w = (__bridge UIWindow*)handle;
    zapp_ios_windows[numeric_id] = w;
    zapp_ios_window_ids[numeric_id] = [NSString stringWithFormat:@"win-%d", numeric_id];
}

// --- Modal sheets — UIViewController presentation ---
//
// iOS doesn't have a direct NSWindow.beginSheet equivalent. The closest
// match is `presentViewController:animated:completion:` — slides up
// from the bottom, blocks interaction with the presenting controller
// until dismissed, and supports the iOS 13+ swipe-down-to-dismiss
// gesture. We map `Window.create({ asSheetOf: parent })` to this
// presentation by stealing the modal UIWindow's rootViewController and
// presenting it on the parent's rootViewController.
//
// On dismissal we fire the same `WINDOW_MODAL_DISMISSED` (event id 12)
// that macOS does, so JS bridge listeners ported from macOS just work.

// Helper: resolve either a deferred handle or a live UIWindow* into
// a UIWindow*. Returns nil if neither is materialized.
static UIWindow* zapp_ios_resolve_window(void* handle) {
    if (!handle) return nil;
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) return d->real_window;
    return (__bridge UIWindow*)handle;
}

// Modal stack — supports presenting a sheet from inside another sheet
// (the wedge audience does this: tap a row in a bottom sheet, push a
// detail page sheet on top). UIKit's pattern is to walk the
// `presentedViewController` chain to find the topmost VC, then present
// from there. We mirror that with a stack of (vc, parentId, modalId)
// so the dismissal observer knows which entry to fire WINDOW_MODAL_
// DISMISSED for.
typedef struct {
    UIViewController* __weak vc;
    int32_t parent_id;
    int32_t modal_id;
} ZappIOSModalStackEntry;

#define ZAPP_IOS_MODAL_STACK_MAX 8
static ZappIOSModalStackEntry zapp_ios_modal_stack[ZAPP_IOS_MODAL_STACK_MAX] = {0};
static int zapp_ios_modal_stack_count = 0;

// Find the topmost currently-presented VC (the one to present new
// modals from). Returns rootVC if nothing is currently presented.
static UIViewController* zapp_ios_topmost_presented(UIViewController* rootVC) {
    UIViewController* vc = rootVC;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

@interface ZappIOSModalDismissObserver : NSObject <UIAdaptivePresentationControllerDelegate>
@end

@implementation ZappIOSModalDismissObserver
- (void)presentationControllerDidDismiss:(UIPresentationController*)pc {
    UIViewController* dismissedVC = pc.presentedViewController;
    extern int zapp_dispatch_event(int window_id, int event_id, int w, int h, int x, int y);
    // Find this VC in the stack and remove it (anywhere — the user
    // could dismiss a non-top sheet via swipe-down on a stack with
    // adaptive presentation).
    for (int i = zapp_ios_modal_stack_count - 1; i >= 0; i--) {
        if (zapp_ios_modal_stack[i].vc == dismissedVC) {
            // ZAPP_EVENT_WINDOW_MODAL_DISMISSED == 12 (matches darwin path)
            zapp_dispatch_event(zapp_ios_modal_stack[i].parent_id, 12,
                                (int)zapp_ios_modal_stack[i].modal_id, 0, 0, 0);
            // Compact the stack.
            for (int j = i; j < zapp_ios_modal_stack_count - 1; j++) {
                zapp_ios_modal_stack[j] = zapp_ios_modal_stack[j + 1];
            }
            zapp_ios_modal_stack_count--;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].vc = nil;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].parent_id = -1;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].modal_id = -1;
            return;
        }
    }
}
@end

static ZappIOSModalDismissObserver* zapp_ios_modal_observer = nil;

void darwin_window_attach_modal(void* parent_handle, void* modal_handle) {
    if (!parent_handle || !modal_handle || parent_handle == modal_handle) return;

    // On iOS, post-UIApplicationMain Window.create allocates a deferred
    // handle but doesn't materialize a real UIWindow until something
    // (like this modal-attach call) drives the materialization. Run
    // the queue drain now so the modal's UIWindow + rootViewController
    // + WKWebView all exist before we present.
    extern void zapp_ios_materialize_pending_windows(void);
    zapp_ios_materialize_pending_windows();

    UIWindow* parent = zapp_ios_resolve_window(parent_handle);
    UIWindow* modal  = zapp_ios_resolve_window(modal_handle);
    if (!parent || !modal) return;

    // The modal's UIWindow.rootViewController is intact (we steal it
    // below at present time). The parent's may not be — if the parent
    // is itself a currently-presented modal, we cleared its UIWindow's
    // rootViewController when we presented it earlier. Resolve via:
    //   - modal-stack lookup if parent is a known modal (its real VC
    //     is the stack entry's vc, currently presented in the chain);
    //   - else the parent UIWindow's intact rootViewController (the
    //     normal "root window of the app" case).
    UIViewController* modalVC = modal.rootViewController;
    if (!modalVC) return;
    if (modalVC.presentingViewController) return;  // already presented

    UIViewController* parentRootVC = nil;
    ZappIOSDeferred* parentDef0 = zapp_ios_find_deferred(parent_handle);
    int32_t parentNumericId = parentDef0 ? parentDef0->numeric_id : -1;
    for (int i = 0; i < zapp_ios_modal_stack_count; i++) {
        if (zapp_ios_modal_stack[i].modal_id == parentNumericId) {
            parentRootVC = zapp_ios_modal_stack[i].vc;
            break;
        }
    }
    if (!parentRootVC) parentRootVC = parent.rootViewController;
    if (!parentRootVC) return;

    // For nested modals: present from the topmost currently-presented
    // VC in the chain rooted at parentRootVC. UIKit refuses to present
    // from a VC whose view isn't currently visible.
    UIViewController* parentVC = zapp_ios_topmost_presented(parentRootVC);

    // Capture numeric IDs for the dismissal callback before we tear
    // the modal UIWindow down.
    ZappIOSDeferred* modalDef = zapp_ios_find_deferred(modal_handle);
    int32_t parentId = parentNumericId;
    int32_t modalId  = modalDef  ? modalDef->numeric_id  : -1;

    // Capture sheet presentation options before the dispatch_async
    // (modalDef may not be safe to read on the main queue if it's
    // freed in some edge case).
    int32_t sheetPres = modalDef ? modalDef->sheet_presentation : 0;
    int32_t sheetDetents = modalDef ? modalDef->sheet_detents : 0;
    bool sheetGrabber = modalDef ? modalDef->sheet_grabber : false;

    void (^run)(void) = ^{
        // Hold the VC strong before clearing rootViewController
        // (which would otherwise dealloc it — UIWindow.rootViewController
        // is the only strong ref).
        UIViewController* vcStrong = modalVC;
        modal.rootViewController = nil;
        modal.hidden = YES;

        // Map sheet presentation enum:
        //   0 = page (PageSheet) — default
        //   1 = form (FormSheet) — smaller centered card on iPad
        //   2 = fullscreen (FullScreen) — take-over modal
        //   3 = bottomSheet (UISheetPresentationController) — drawer
        switch (sheetPres) {
            case 1: vcStrong.modalPresentationStyle = UIModalPresentationFormSheet; break;
            case 2: vcStrong.modalPresentationStyle = UIModalPresentationFullScreen; break;
            case 3:
            case 0:
            default: vcStrong.modalPresentationStyle = UIModalPresentationPageSheet; break;
        }

        // Bottom sheet — UISheetPresentationController gives detents,
        // grabber, and mid-screen positioning (iOS 15+). PageSheet
        // also exposes the same controller via `sheetPresentationController`,
        // so the grabber + detent options on a regular pageSheet work.
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController* sheet = vcStrong.sheetPresentationController;
            if (sheet) {
                NSMutableArray<UISheetPresentationControllerDetent*>* detents = [NSMutableArray array];
                // Bit 0 = medium, bit 1 = large, bit 2 = small (custom,
                // iOS 16+; degrades to no entry on iOS 15).
                if (sheetDetents & 4) {
                    if (@available(iOS 16.0, *)) {
                        UISheetPresentationControllerDetent* small =
                            [UISheetPresentationControllerDetent
                                customDetentWithIdentifier:@"zapp.small"
                                resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> ctx) {
                                    return ctx.maximumDetentValue * 0.25;
                                }];
                        if (small) [detents addObject:small];
                    }
                }
                if (sheetDetents & 1) [detents addObject:[UISheetPresentationControllerDetent mediumDetent]];
                if (sheetDetents & 2) [detents addObject:[UISheetPresentationControllerDetent largeDetent]];
                // bottomSheet with no explicit detents → both available
                // (medium + large with swipe between). Page/form sheets
                // with no detents → keep system default (large only).
                if (detents.count == 0 && sheetPres == 3) {
                    [detents addObject:[UISheetPresentationControllerDetent mediumDetent]];
                    [detents addObject:[UISheetPresentationControllerDetent largeDetent]];
                }
                if (detents.count > 0) {
                    sheet.detents = detents;
                }
                sheet.prefersGrabberVisible = sheetGrabber;
            }
        }

        if (!zapp_ios_modal_observer) {
            zapp_ios_modal_observer = [[ZappIOSModalDismissObserver alloc] init];
        }
        vcStrong.presentationController.delegate = zapp_ios_modal_observer;

        // Push to the modal stack so the dismissal observer can
        // route WINDOW_MODAL_DISMISSED to the right (parent, modal).
        if (zapp_ios_modal_stack_count < ZAPP_IOS_MODAL_STACK_MAX) {
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].vc = vcStrong;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].parent_id = parentId;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].modal_id = modalId;
            zapp_ios_modal_stack_count++;
        }

        [parentVC presentViewController:vcStrong animated:YES completion:nil];
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

void darwin_window_detach_modal(void* parent_handle, void* modal_handle) {
    (void)parent_handle;  // iOS dismisses via the modal's presenting controller, parent is implicit
    if (!modal_handle) return;
    ZappIOSDeferred* modalDef = zapp_ios_find_deferred(modal_handle);
    int32_t modalId = modalDef ? modalDef->numeric_id : -1;
    void (^run)(void) = ^{
        // Find the right VC in the stack by modal ID, since the modal's
        // UIWindow.rootViewController got cleared when we presented
        // (vcStrong is the only retainer left, held weakly in the stack).
        UIViewController* vc = nil;
        for (int i = zapp_ios_modal_stack_count - 1; i >= 0; i--) {
            if (zapp_ios_modal_stack[i].modal_id == modalId) {
                vc = zapp_ios_modal_stack[i].vc;
                break;
            }
        }
        if (vc.presentingViewController) {
            [vc dismissViewControllerAnimated:YES completion:nil];
        }
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}
