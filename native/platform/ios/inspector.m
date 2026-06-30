// iOS native inspector — Secondary column of the UISplitViewController.
//
// Task 1 (window.m) assigns `inspectorVC` as the split's Secondary column via
// `setViewController:forColumn:UISplitViewControllerColumnSecondary` BEFORE
// calling `zapp_ios_inspector_register`. This file therefore does NOT embed
// or re-parent the VC — it stores refs and drives the column.
//
// iPad-regular (split is NOT collapsed):
//   Toggle/expand/collapse call show/hideColumn:UISplitViewControllerColumnSecondary.
//   set_width drives split.preferredSecondaryColumnWidth.
//
// iPhone-compact (split IS collapsed — UISplitViewController collapses into a
// single navigation stack):
//   expand: push a fresh lightweight inspector VC (with its own webview loading
//           the inspector URL) onto the content nav (push-mode). Tear that VC's
//           webview down on pop (brk-1 pattern from routing.m:73-82).
//   collapse: pop that VC if it is currently the top of the content nav.
//
// darwin_inspector_* symbol names are preserved (imported by router.nim:150-155).

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <stdbool.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
extern int32_t zapp_ios_sidebar_slot_for(int32_t host_slot);
extern WKWebView* zapp_ios_content_webview_for_slot(int32_t slot);

// --- Pushed inspector VC (push-mode for compact / iPhone) ------------------
//
// A lightweight, transient VC pushed onto the content nav for iPhone. The
// webview is minted via darwin_webview_create_ext so it gets the full zapp
// bridge, scheme handlers, env() safe-area injection, and identity — exactly
// mirroring how zapp_ios_push_route_vc creates route VCs (routing.m:215-272).
//
// onDismiss fires on swipe-back / tap-Back so the caller can emit
// inspector-collapsed and clear the weak pushedVC reference.

// darwin_webview_create_ext is declared in the darwin/webview.h header;
// include it here so the iOS link unit resolves the symbol.
#include "../darwin/webview.h"

// Inject safe-area vars into a webview after layout (defined in toolbar.m).
extern void zapp_ios_toolbar_inject_webview_safe_area(WKWebView* wv);

@interface ZappIOSPushedInspectorVC : UIViewController
// The WKWebView mounted by darwin_webview_create_ext (weak — the view hierarchy
// holds the strong reference; the VC just needs to reach it for teardown).
@property (nonatomic, weak) WKWebView* webview;
// Called when the VC is popped (swipe-back or Back button). The block MUST NOT
// strongly capture self to avoid a retain cycle — capture controller and ids
// by value instead (see darwin_inspector_expand's compact branch).
@property (nonatomic, copy) void (^onDismiss)(void);
// Window pointer + numeric id for darwin_webview_create_ext.
@property (nonatomic, assign) void*    windowPtr;
@property (nonatomic, assign) int32_t  windowId;
// Inspector URL to load (set lazily at push time from the live column webview).
@property (nonatomic, copy)   NSString* inspectorURL;
@end

@implementation ZappIOSPushedInspectorVC

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Mint a fully-bridged webview via the shared creation path — same pattern
    // as zapp_ios_push_route_vc (routing.m:244-254).  pane_role=3 = inspector,
    // so the bootstrap marks zapp.isInspector=true.
    if (self.windowPtr && self.windowId >= 0) {
        const char* urlCStr = self.inspectorURL ? self.inspectorURL.UTF8String : NULL;
        darwin_webview_create_ext(self.windowPtr,
            /*inspectable*/true,
            /*accept_first_mouse*/false,
            /*url_override*/urlCStr,
            /*numeric_id_pre_alloc*/self.windowId,
            /*transparent_background*/false,
            /*container_view*/(__bridge void*)self.view,
            /*identity_window_id*/self.windowId,
            /*pane_role*/3,
            /*host_has_sidebar*/true,
            /*host_has_inspector*/true);

        // Locate the webview create_ext pinned as our view's first subview.
        for (UIView* sub in self.view.subviews) {
            if ([sub isKindOfClass:[WKWebView class]]) {
                self.webview = (WKWebView*)sub;
                break;
            }
        }
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Re-inject safe-area CSS vars after each layout pass (mirrors ZappRouteVC).
    if (self.webview) zapp_ios_toolbar_inject_webview_safe_area(self.webview);
}

// Detect swipe-back / tap-Back (user-initiated pop) and fire onDismiss so JS
// hears inspector-collapsed.  Use viewWillDisappear: (not viewDidDisappear:)
// so the event fires before the animation completes, consistent with how the
// programmatic collapse path emits synchronously.
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController && self.onDismiss) {
        self.onDismiss();
    }
}

- (void)dealloc {
    // brk-1 teardown (reference_wkwebview_teardown): stop + nil delegates +
    // remove the "zapp" script-message handler registered by darwin_webview_create_ext.
    WKWebView* wv = _webview;
    if (wv) {
        [wv stopLoading];
        wv.navigationDelegate = nil;
        wv.UIDelegate = nil;
        @try {
            [wv.configuration.userContentController removeScriptMessageHandlerForName:@"zapp"];
        } @catch (__unused id e) {}
    }
}

@end

// --- Per-window registry --------------------------------------------------
//
// Keyed by the host UIWindow (NSValue-wrapped pointer), mirroring sidebar.m's
// zapp_ios_sidebars. Inspector:* control ops can arrive from ANY pane's
// transport slot; all resolve to the same host UIWindow via
// darwin_window_get_by_numeric_id, so the host-window key catches them all.

@interface ZappIOSInspectorController : NSObject <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, weak)   UIViewController* inspectorVC;   // Secondary-column VC (owned by split)
@property (nonatomic, weak)   UIViewController* contentVC;     // content pane VC (Primary/Supplementary)
@property (nonatomic, assign) int32_t hostWindowId;           // content/host webview slot
@property (nonatomic, assign) int32_t inspectorSlotId;        // inspector webview slot
@property (nonatomic, assign) int32_t width;                   // configured (expanded) width
@property (nonatomic, copy)   NSString* inspectorURL;          // captured URL for compact push
// compact push-mode: the currently pushed transient inspector VC (weak — nav owns it).
@property (nonatomic, weak)   ZappIOSPushedInspectorVC* pushedVC;
@end

// Forward-declared so the delegate callbacks can call the emit helper.
static void zapp_ios_inspector_emit(ZappIOSInspectorController* c, const char* eventName);

@implementation ZappIOSInspectorController
@end

static NSMutableDictionary<NSValue*, ZappIOSInspectorController*>* zapp_ios_inspectors = nil;

static void zapp_ios_inspector_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// slot -> owning UIWindow -> registry key. Works from ANY pane's slot (content,
// sidebar, or inspector) since they all share the host UIWindow.
static ZappIOSInspectorController* zapp_ios_inspector_for_slot(int32_t slot_id) {
    if (!zapp_ios_inspectors) return nil;
    void* win_ptr = darwin_window_get_by_numeric_id(slot_id);
    if (!win_ptr) return nil;
    NSValue* key = [NSValue valueWithPointer:win_ptr];
    return zapp_ios_inspectors[key];
}

// --- Event fan-out (mirrors darwin/sidebar.m's zapp_pane_emit) ------------
//
// dispatchWindowEvent's first arg is the target window id ("win-<hostId>");
// both panes carry the host id. eventName is the bare suffix
// ("inspector-collapsed" / "inspector-resized"); bootstrap/webview.ts prepends
// "window:". dataJson is the optional 3rd arg — nil emits `undefined`, otherwise
// a single-quoted JSON literal (mirroring macOS's zapp_pane_emit), which the
// runtime parses for the bare-`width` resize payload. Eval'd to BOTH the host
// slot AND (when distinct) the inspector slot.
static void zapp_ios_inspector_emit_data(ZappIOSInspectorController* c,
                                         const char* eventName, NSString* dataJson) {
    if (!c || !eventName) return;
    NSString* dataArg = @"undefined";
    if (dataJson) {
        NSString* esc = [dataJson stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        dataArg = [NSString stringWithFormat:@"'%@'", esc];
    }
    NSString* event = [NSString stringWithUTF8String:eventName];
    char js[256];
    snprintf(js, sizeof(js),
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&typeof b.dispatchWindowEvent==='function'){"
        "b.dispatchWindowEvent('win-%d','%s',%s);}})();",
        c.hostWindowId, event.UTF8String, dataArg.UTF8String);
    darwin_window_eval_js(c.hostWindowId, js);
    if (c.inspectorSlotId >= 0 && c.inspectorSlotId != c.hostWindowId) {
        darwin_window_eval_js(c.inspectorSlotId, js);
    }
    int32_t sidebarSlot = zapp_ios_sidebar_slot_for(c.hostWindowId);
    if (sidebarSlot >= 0 && sidebarSlot != c.hostWindowId && sidebarSlot != c.inspectorSlotId) {
        darwin_window_eval_js(sidebarSlot, js);
    }
}

// Name-only emit (no payload) — collapse/expand transitions.
static void zapp_ios_inspector_emit(ZappIOSInspectorController* c, const char* eventName) {
    zapp_ios_inspector_emit_data(c, eventName, nil);
}

// inspector-resized carries a bare width under the top-level `width` key
// ({"width":N}), matching darwin/inspector.m's resize payload + the
// bareWidth branch in bootstrap/webview.ts's dispatchWindowEvent.
static void zapp_ios_inspector_emit_resize(ZappIOSInspectorController* c, int32_t width) {
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", (int)width];
    zapp_ios_inspector_emit_data(c, "inspector-resized", json);
}

// --- Registry API consumed by window.m ------------------------------------
//
// window.m calls this AFTER the inspector VC has been assigned as the split's
// Secondary column (Task 1). This function:
//   • stores inspectorVC (weak), contentVC (weak), ids, width.
//   • captures the inspector URL from the inspector slot webview for compact push.
//   • does NOT addChildViewController: — the split owns inspectorVC.
//   • does NOT re-constrain the content webview — it keeps its edge-pin from
//     darwin_webview_create_ext.
//   • registers the controller in the registry so darwin_inspector_* can find it.
void zapp_ios_inspector_register(void* window, void* inspectorVC, void* contentVC,
                                 void* contentWebview, int32_t host_id,
                                 int32_t inspector_id, int32_t width, bool collapsed) {
    if (!window || !inspectorVC || !contentVC) return;
    zapp_ios_inspector_on_main(^{
        if (!zapp_ios_inspectors) zapp_ios_inspectors = [NSMutableDictionary dictionary];

        UIViewController* ivc = (__bridge UIViewController*)inspectorVC;
        UIViewController* cvc = (__bridge UIViewController*)contentVC;
        if (!ivc || !cvc) return;

        ZappIOSInspectorController* c = [[ZappIOSInspectorController alloc] init];
        c.inspectorVC  = ivc;
        c.contentVC    = cvc;
        c.hostWindowId = host_id;
        c.inspectorSlotId = inspector_id;
        c.width        = (width > 0 ? width : 280);

        // Capture the inspector URL now for compact push-mode. The inspector
        // webview has been registered in the inspector_id slot by the time
        // window.m calls us (see the re-slot dance above the call site).
        WKWebView* inspWv = zapp_ios_content_webview_for_slot(inspector_id);
        if (inspWv && inspWv.URL) {
            c.inspectorURL = inspWv.URL.absoluteString;
        }

        // iPad initial display mode:  if collapsed-by-default, hide the Secondary
        // column so it starts invisible.  The split's preferredDisplayMode was set
        // to TwoBesideSecondary by window.m; override to OneBesideSecondary when
        // the config says collapsed=true.
        UISplitViewController* split = cvc.splitViewController;
        if (split && !split.isCollapsed && collapsed) {
            [split hideColumn:UISplitViewControllerColumnSecondary];
        }

        NSValue* key = [NSValue valueWithPointer:window];
        zapp_ios_inspectors[key] = c;

        NSLog(@"[native] iOS inspector registered (column model): host=%d inspector=%d width=%d collapsed=%d url=%@",
              host_id, inspector_id, c.width, (int)collapsed, c.inspectorURL ?: @"(none)");
    });
}

void zapp_ios_inspector_unregister(void* window) {
    if (!window) return;
    zapp_ios_inspector_on_main(^{
        if (!zapp_ios_inspectors) return;
        NSValue* key = [NSValue valueWithPointer:window];
        [zapp_ios_inspectors removeObjectForKey:key];
    });
}

// --- Control ops (router entry points) ------------------------------------
//
// All keyed by a transport slot (host OR inspector pane);
// zapp_ios_inspector_for_slot resolves either to the host record.

// Show the inspector.
//   iPad-regular (not collapsed): showColumn:Secondary.
//   iPhone-compact (collapsed):   push a fresh ZappIOSPushedInspectorVC onto
//                                 the content nav (push-mode).
void darwin_inspector_expand(int32_t window_id) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;

        UISplitViewController* split = c.contentVC.splitViewController;
        if (!split) return;

        if (split.isCollapsed) {
            // iPhone-compact: push a fresh inspector VC.
            UINavigationController* nav = c.contentVC.navigationController;
            if (!nav) return;
            // Guard: already pushed (weak ref still alive).
            if (c.pushedVC) return;

            ZappIOSPushedInspectorVC* pushVC = [[ZappIOSPushedInspectorVC alloc] init];

            // Fetch the inspector URL lazily from the live column webview at push
            // time.  The column webview may not have loaded at register time, so
            // c.inspectorURL can be nil; reading it here ensures we get the real URL.
            WKWebView* liveInspWv = zapp_ios_content_webview_for_slot(c.inspectorSlotId);
            NSString* liveURL = (liveInspWv && liveInspWv.URL)
                                    ? liveInspWv.URL.absoluteString
                                    : c.inspectorURL;
            pushVC.inspectorURL = liveURL;

            // Wire up bridge creation params (Fix #2).
            void* winPtr = darwin_window_get_by_numeric_id(c.hostWindowId);
            pushVC.windowPtr = winPtr;
            pushVC.windowId  = c.inspectorSlotId;

            pushVC.title = @"Inspector";

            // Fix #1: emit inspector-collapsed when the user swipes back or taps
            // Back.  Capture controller fields by value to avoid a retain cycle
            // (the block must not strongly capture pushVC / the VC itself).
            int32_t hostId      = c.hostWindowId;
            int32_t inspId      = c.inspectorSlotId;
            int32_t sidebarId   = zapp_ios_sidebar_slot_for(hostId);
            __weak ZappIOSPushedInspectorVC* weakPushVC = pushVC;
            ZappIOSInspectorController* __weak weakC = c;
            pushVC.onDismiss = ^{
                // Emit inspector-collapsed to host + inspector + sidebar slots.
                // Call JS inline using the captured by-value ids (no strong
                // reference to any ObjC object that could form a retain cycle).
                char js[256];
                snprintf(js, sizeof(js),
                    "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
                    "if(b&&typeof b.dispatchWindowEvent==='function'){"
                    "b.dispatchWindowEvent('win-%d','inspector-collapsed',undefined);}})();",
                    hostId);
                darwin_window_eval_js(hostId, js);
                if (inspId >= 0 && inspId != hostId)
                    darwin_window_eval_js(inspId, js);
                if (sidebarId >= 0 && sidebarId != hostId && sidebarId != inspId)
                    darwin_window_eval_js(sidebarId, js);
                // Clear the pushedVC reference on the controller (if still alive).
                ZappIOSInspectorController* strongC = weakC;
                if (strongC && strongC.pushedVC == weakPushVC) {
                    strongC.pushedVC = nil;
                }
            };

            c.pushedVC = pushVC;
            [nav pushViewController:pushVC animated:YES];
        } else {
            // iPad-regular: show the Secondary column.
            [split showColumn:UISplitViewControllerColumnSecondary];
        }
        zapp_ios_inspector_emit(c, "inspector-expanded");
    });
}

// Hide the inspector.
//   iPad-regular: hideColumn:Secondary.
//   iPhone-compact: pop if the top VC is the pushed inspector.
void darwin_inspector_collapse(int32_t window_id) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;

        UISplitViewController* split = c.contentVC.splitViewController;
        if (!split) return;

        if (split.isCollapsed) {
            // iPhone-compact: pop if the pushed VC is still on top.
            // Guard (Minor #4): only pop + nil + emit when there is actually a
            // pushed inspector VC on top, so a no-op collapse doesn't fire a
            // spurious inspector-collapsed event.
            UINavigationController* nav = c.contentVC.navigationController;
            if (c.pushedVC && nav &&
                [nav.topViewController isKindOfClass:[ZappIOSPushedInspectorVC class]]) {
                [nav popViewControllerAnimated:YES];
                c.pushedVC = nil;
                zapp_ios_inspector_emit(c, "inspector-collapsed");
            }
            // No pushedVC → nothing to collapse; skip emit.
        } else {
            // iPad-regular: hide the Secondary column.
            [split hideColumn:UISplitViewControllerColumnSecondary];
            zapp_ios_inspector_emit(c, "inspector-collapsed");
        }
    });
}

// Toggle from live state. Branches on the split's collapse state:
//   • compact (isCollapsed=YES): delegate to expand (push-mode).
//   • regular: check actual displayMode for a real toggle — never trust a cache.
void darwin_inspector_toggle(int32_t window_id) {
    zapp_ios_inspector_on_main(^{
        // Fetch the controller inside the main-thread block: the registry
        // dictionary is not thread-safe (Minor #3 fix).
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;

        UISplitViewController* split = c.contentVC.splitViewController;
        if (!split) return;

        if (split.isCollapsed) {
            // Compact (iPhone): push path.
            darwin_inspector_expand(window_id);
            return;
        }

        // Regular (iPad): real toggle based on actual displayMode.
        BOOL visible = (split.displayMode == UISplitViewControllerDisplayModeTwoBesideSecondary
                     || split.displayMode == UISplitViewControllerDisplayModeSecondaryOnly);
        if (visible) {
            [split hideColumn:UISplitViewControllerColumnSecondary];
            zapp_ios_inspector_emit(c, "inspector-collapsed");
        } else {
            [split showColumn:UISplitViewControllerColumnSecondary];
            zapp_ios_inspector_emit(c, "inspector-expanded");
        }
    });
}

// Set the (expanded) inspector width.
//   iPad-regular: drives split.preferredSecondaryColumnWidth.
//   iPhone-compact: full-width sheet/push — width is n/a (documented no-op there).
// Emits inspector-resized for state parity with the runtime InspectorHandle.
void darwin_inspector_set_width(int32_t window_id, int32_t width) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        c.width = width;

        UISplitViewController* split = c.contentVC.splitViewController;
        if (split && !split.isCollapsed) {
            split.preferredSecondaryColumnWidth = width;
        }
        // compact: push fills full width — width is n/a (documented no-op there).
        zapp_ios_inspector_emit_resize(c, width);
    });
}

// User-collapsible gating is an NSSplitViewItem affordance; the iOS inspector is
// driven explicitly (show/hideColumn: / push-pop), so there's no equivalent knob.
// No-op for router parity (documented).
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) {
    (void)window_id; (void)can_collapse;
}

// Divider-drag resize isn't a UIKit affordance (Secondary column width is set
// programmatically; the compact push is full-width). No-op for router parity
// (documented).
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) {
    (void)window_id; (void)resizable;
}
