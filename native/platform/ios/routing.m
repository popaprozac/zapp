// iOS native routing — idiomatic UIKit seam (R1' RISK GATE, Task 1+2).
//
// Drives the LIVE content-nav (contentVC.navigationController) directly:
//   push → [nav pushViewController:vc animated:YES]
//   pop  → [nav popViewControllerAnimated:YES]
//   popToRoot → [nav popToViewController:contentVC animated:NO]
//
// The chrome-agnostic live-nav resolver (`zapp_route_content_nav`) resolves
// contentVC.navigationController for both iPhone (collapsed split) and iPad
// (expanded split). Owned-nav fork deleted in T2; single split path.
//
// Deleted from N3a: old push/pop baseline math, router sync, old delegate chain.
// Deleted in T2: owned-nav fork, iphonenav.m externs, toolbar-apply call in old delegate.
// The ZappRouteNavDelegate does not apply toolbar items.
//
// Kept verbatim: ZappRouteVC @interface/@implementation + viewDidLayoutSubviews,
// zapp_route_vc_teardown, and all externs the seam still needs.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// darwin_webview_create_ext is defined in ios/webview.m (same iOS link unit).
#include "../darwin/webview.h"

// --- Nim/native externs ---
extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern bool zapp_window_native_routing(int32_t window_id);
extern int router_depth(int32_t win);
extern void zapp_router_pop_from_native(int32_t window_id);
// Per-route identity: set the route url just before create_ext mints the route
// webview → it renders its OWN fixed route (zapp.route), not the latest broadcast.
extern void zapp_ios_set_pending_route_url(const char* url);
// Inject --zapp-* safe-area vars into a route VC's webview after layout.
extern void zapp_ios_toolbar_inject_webview_safe_area(WKWebView* wv);

// Chrome-agnostic content-VC resolution (owned-nav fork deleted in T2).
// sidebar.m: the authoritative secondary-column content VC stored at register time.
extern UIViewController* zapp_ios_content_vc_for_window(void* window_ptr);

// Route VC: a plain UIViewController hosting its own WKWebView.
// Tagged so the delegate can distinguish route VCs from the root contentVC.
@interface ZappRouteVC : UIViewController
@property (nonatomic, weak) WKWebView* webview;
@end

// Forward declaration of the teardown helper — defined below; referenced from
// viewDidDisappear: which appears before the static definition.
static void zapp_route_vc_teardown(ZappRouteVC* vc);

@implementation ZappRouteVC
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Route VCs aren't registered pane slots, so the toolbar metrics pass never
    // injects their --zapp-* safe-area vars (content under the nav). Inject
    // here, after layout, so safeAreaInsets is valid. Idempotent.
    if (self.webview) zapp_ios_toolbar_inject_webview_safe_area(self.webview);
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Self-teardown: brk-1 (stopLoading + nil delegates + remove "zapp" handler)
    // when this VC is popped (back button / swipe / programmatic pop).
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        zapp_route_vc_teardown(self);
    }
}
@end

// brk-1 teardown for a popped route VC's webview (reference_wkwebview_teardown):
// stopLoading + nil delegates + remove the bridge script-message handler before
// the VC/webview is released. Safe to call once per VC.
static void zapp_route_vc_teardown(ZappRouteVC* vc) {
    WKWebView* wv = vc.webview;
    if (!wv) return;
    [wv stopLoading];
    wv.navigationDelegate = nil;
    wv.UIDelegate = nil;
    @try {
        [wv.configuration.userContentController removeScriptMessageHandlerForName:@"zapp"];
    } @catch (__unused id e) {}
}

// --- Chrome-agnostic live-nav resolver ------------------------------------
//
// Returns the UINavigationController that the content VC currently lives in.
// On both iPhone and iPad: contentVC is the root of contentNav (sidebar.m).
// The owned-nav fork was deleted in T2; split path is the single chrome.
static UINavigationController* zapp_route_content_nav(void* win) {
    UIViewController* contentVC = zapp_ios_content_vc_for_window(win);
    return contentVC.navigationController;   // LIVE nav — the fix vs N3a
}

// --- Single clean nav delegate --------------------------------------------
//
// One ZappRouteNavDelegate per content nav, installed once. didShow detects
// a user-initiated pop (native route-VC depth < routerstate depth) and
// reflects it into Nim. Route VCs self-teardown via viewDidDisappear: so
// no external pushedVCs list is needed.
//
// Distinguishing programmatic vs user pop:
//   Programmatic: routerstate mutated FIRST → by didShow the depths match → no-op.
//   User back/swipe: VC popped first → didShow sees native < router → pop_from_native.
//
// This delegate lives on contentVC.navigationController (the live nav).
// After T2 it is the sole delegate on that nav (no toolbar delegate conflicts).
@interface ZappRouteNavDelegate : NSObject <UINavigationControllerDelegate>
@property (nonatomic, assign) int32_t windowId;
@end
@implementation ZappRouteNavDelegate
- (void)navigationController:(UINavigationController*)nav
       didShowViewController:(UIViewController*)vc animated:(BOOL)animated {
    (void)vc; (void)animated;
    // Count only ZappRouteVC instances so the sidebar root on collapsed iPhone
    // doesn't skew the delta.
    int nativeRouteDepth = 0;
    for (UIViewController* v in nav.viewControllers)
        if ([v isKindOfClass:[ZappRouteVC class]]) nativeRouteDepth++;
    // routerstate depth 1 = content VC (0 route VCs on top of it).
    int wantRouteDepth = (int)router_depth(self.windowId) - 1;
    if (wantRouteDepth < 0) wantRouteDepth = 0;
    if (nativeRouteDepth < wantRouteDepth) {
        // User popped via back button or edge swipe — reflect into routerstate.
        // zapp_router_pop_from_native pops routerstate + emits ROUTE_CHANGED.
        // It does NOT call any native op (loop broken).
        zapp_router_pop_from_native(self.windowId);
    }
}
@end

// Per-window delegate registry — keeps delegates alive and deduplicated.
static NSMutableDictionary<NSNumber*, ZappRouteNavDelegate*>* g_route_delegates;

// Install the route delegate on nav (once per window; re-assert if UIKit reset it).
static void zapp_route_install_delegate(UINavigationController* nav, int32_t windowId) {
    if (!g_route_delegates) g_route_delegates = [NSMutableDictionary dictionary];
    ZappRouteNavDelegate* d = g_route_delegates[@(windowId)];
    if (!d) {
        d = [ZappRouteNavDelegate new];
        d.windowId = windowId;
        g_route_delegates[@(windowId)] = d;
    }
    if (nav.delegate != d) nav.delegate = d;   // single owner; re-assert if UIKit reset it
}

// --- Push seam ------------------------------------------------------------

void zapp_ios_push_route_vc(int32_t windowId, const char* url) {
    if (!zapp_window_native_routing(windowId)) return;   // opt-in gate (retired in R3')
    void* win = darwin_window_get_by_numeric_id(windowId);
    if (!win) return;
    UINavigationController* nav = zapp_route_content_nav(win);
    if (!nav) return;   // nav not available yet → deferred
    zapp_route_install_delegate(nav, windowId);

    ZappRouteVC* vc = [ZappRouteVC new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;

    // N3a per-route identity: set the pending url before create_ext mints the
    // route webview so it renders its own fixed route, not the latest broadcast.
    zapp_ios_set_pending_route_url(url);

    // Mint a webview into vc.view via the shared create path.
    // Args match the content-pane call in window.m:534-537:
    //   inspectable=true, accept_first_mouse=false, url_override=NULL
    //   (route url is consumed via pending-url, not url_override),
    //   numeric_id_pre_alloc = windowId (bridge targets the host window),
    //   transparent_background=false, container_view=vc.view,
    //   identity_window_id = windowId, pane_role=0 (main),
    //   host_has_sidebar=true, host_has_inspector=false.
    // Note: url_override=NULL — the route url was set via set_pending_route_url
    // above and is consumed once at doc-start.
    darwin_webview_create_ext(win,
        /*inspectable*/true,
        /*accept_first_mouse*/false,
        /*url_override*/NULL,
        /*numeric_id_pre_alloc*/windowId,
        /*transparent_background*/false,
        /*container_view*/(__bridge void*)vc.view,
        /*identity_window_id*/windowId,
        /*pane_role*/0,
        /*host_has_sidebar*/true,
        /*host_has_inspector*/false);

    // Locate the webview that create_ext pinned as vc.view's first subview.
    for (UIView* sub in vc.view.subviews) {
        if ([sub isKindOfClass:[WKWebView class]]) {
            vc.webview = (WKWebView*)sub;
            break;
        }
    }

    // Don't force-stamp toolbar items at push time. The app sets items via
    // toolbar:setItems → darwin_toolbar_set_items → zapp_ios_toolbar_apply_to_nav,
    // which targets nav.topViewController. After this push, the route VC becomes
    // topViewController → the next setItems call will reach it automatically.
    // Stamping at push would apply stale items from the content VC, not the
    // route-specific items.

    [nav pushViewController:vc animated:YES];
}

// --- Pop ops --------------------------------------------------------------

void zapp_ios_pop_route_vc(int32_t windowId) {
    void* win = darwin_window_get_by_numeric_id(windowId);
    if (!win) return;
    UINavigationController* nav = zapp_route_content_nav(win);
    if (!nav) return;
    if ([nav.topViewController isKindOfClass:[ZappRouteVC class]])
        [nav popViewControllerAnimated:YES];
}

void zapp_ios_pop_to_content(int32_t windowId) {
    void* win = darwin_window_get_by_numeric_id(windowId);
    if (!win) return;
    UIViewController* contentVC = zapp_ios_content_vc_for_window(win);
    if (!contentVC) return;
    UINavigationController* nav = contentVC.navigationController;
    if (!nav) return;
    if ([nav.viewControllers containsObject:contentVC])
        [nav popToViewController:contentVC animated:NO];
}
