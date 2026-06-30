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
#include <stdio.h>
#include <objc/runtime.h>

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
// Slot-restore dance: capture content webview before create_ext, restore after.
// zapp_ios_content_webview_for_slot: returns zapp_ios_webviews[slot] (window.m).
// zapp_ios_register_webview: writes a webview into the UIWindow-keyed host slot.
extern WKWebView* zapp_ios_content_webview_for_slot(int32_t slot);
extern void zapp_ios_register_webview(void* window_ptr, void* webview_ptr);

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
    UINavigationController* nav = contentVC.navigationController;
    // [zapp-nav] diagnostic: log resolved contentVC + nav pointers once per call
    fprintf(stderr, "[zapp-nav] content_nav contentVC=%p nav=%p\n",
            (__bridge void*)contentVC, (__bridge void*)nav);
    fflush(stderr);
    return nav;   // LIVE nav — the fix vs N3a
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
// Forward-declare zapp_toolbar_inject_metrics so willShowViewController can
// trigger a metrics re-inject after the bar appears/disappears (same as the
// comment in toolbar.m's zapp_toolbar_inject_metrics header).
extern void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script);

@interface ZappRouteNavDelegate : NSObject <UINavigationControllerDelegate>
@property (nonatomic, assign) int32_t windowId;
// Tracks the class of the VC that was on top (the "from" VC) during the most
// recent willShowViewController: call. Set via the transition coordinator so
// didShowViewController: can guard route-depth reconciliation: a pop that reveals
// the content VC after an inspector push must NOT trigger pop_from_native because
// the inspector VC (ZappIOSPushedInspectorVC) is a pane presentation, not a route.
@property (nonatomic, assign) BOOL lastFromVCWasRouteVC;
@end
@implementation ZappRouteNavDelegate

// willShowViewController: — SINGLE source of nav-bar visibility (Fix 1).
//
// UIKit calls this on EVERY push AND pop, including user swipes, back-button taps,
// and programmatic pops. Driving visibility here (rather than scattered
// navigationBarHidden writes in toolbar.m) prevents bar-state drift.
//
// Rules:
//   • SHOWN  on the content VC (leaf of the secondary column, no route VCs on top)
//             and on any ZappRouteVC (shows the back button + per-VC toolbar items).
//   • HIDDEN on the sidebar root and any other VC that is not the content VC or a
//             route VC.
//
// The idempotency guard (only call setNavigationBarHidden: when the state actually
// needs to change) prevents redundant UIKit transitions.
- (void)navigationController:(UINavigationController*)nav
    willShowViewController:(UIViewController*)vc animated:(BOOL)animated {
    void* win = darwin_window_get_by_numeric_id(self.windowId);
    UIViewController* contentVC = win ? zapp_ios_content_vc_for_window(win) : nil;
    // Show the bar on:
    //   1. The content VC itself (the live secondary-column root).
    //   2. Any pushed ZappRouteVC (needs back button + per-VC toolbar items).
    BOOL isContent = (contentVC && vc == contentVC);
    BOOL isRoute = [vc isKindOfClass:[ZappRouteVC class]];
    BOOL showBar = isContent || isRoute;
    BOOL barHiddenBefore = nav.navigationBarHidden;

    // Inspector-pop guard: capture the "from" VC via the transition coordinator so
    // didShowViewController: can skip route-depth reconciliation when the disappearing
    // VC was not a ZappRouteVC (e.g. a ZappIOSPushedInspectorVC pane push/pop).
    // The coordinator's fromVC is the VC that was on screen before this transition.
    // Default to YES (assume route pop) so push paths are never mis-skipped; the
    // coordinator is nil for programmatic pops that bypassed UIKit animation.
    self.lastFromVCWasRouteVC = YES;
    id<UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
    if (coordinator) {
        UIViewController* fromVC = [coordinator viewControllerForKey:UITransitionContextFromViewControllerKey];
        // Only count genuine ZappRouteVC departures as route pops. Any other class
        // (ZappIOSPushedInspectorVC, sidebar root, etc.) is pane-level and must not
        // advance the route-depth reconciliation.
        self.lastFromVCWasRouteVC = (fromVC != nil && [fromVC isKindOfClass:[ZappRouteVC class]]);
    }

    // [zapp-nav] diagnostic: key signal for bar-visibility desync (Bug A)
    fprintf(stderr, "[zapp-nav] willShow win=%d vc=%p vcClass=%s contentVC=%p isContent=%d isRoute=%d showBar=%d barHiddenBefore=%d stackCount=%lu lastFromVCWasRouteVC=%d\n",
            (int)self.windowId, (__bridge void*)vc,
            class_getName([vc class]),
            (__bridge void*)contentVC,
            (int)isContent, (int)isRoute, (int)showBar, (int)barHiddenBefore,
            (unsigned long)nav.viewControllers.count, (int)self.lastFromVCWasRouteVC);
    fflush(stderr);
    if (nav.navigationBarHidden == showBar) {
        [nav setNavigationBarHidden:!showBar animated:animated];
        // Bar visibility changed — re-inject chrome metrics one tick later so the
        // nav bar has been laid out and safeAreaInsets reflect the new state.
        // add_user_script=false: the persistent WKUserScript was set by set_items;
        // this is a live update only (avoids unbounded script accumulation).
        if (win) {
            void* capturedWin = win;
            int32_t capturedSlot = self.windowId;
            dispatch_async(dispatch_get_main_queue(), ^{
                zapp_toolbar_inject_metrics(capturedWin, capturedSlot, false);
            });
        }
    }
}

- (void)navigationController:(UINavigationController*)nav
       didShowViewController:(UIViewController*)vc animated:(BOOL)animated {
    (void)animated;
    // Count only ZappRouteVC instances so the sidebar root on collapsed iPhone
    // doesn't skew the delta.
    int nativeRouteDepth = 0;
    for (UIViewController* v in nav.viewControllers)
        if ([v isKindOfClass:[ZappRouteVC class]]) nativeRouteDepth++;
    // routerstate depth 1 = content VC (0 route VCs on top of it).
    int wantRouteDepth = (int)router_depth(self.windowId) - 1;
    if (wantRouteDepth < 0) wantRouteDepth = 0;
    // Inspector-pop guard: only reconcile route depth when the VC that just
    // disappeared was a ZappRouteVC. Pane-level pushes/pops (e.g. the
    // ZappIOSPushedInspectorVC compact inspector) must be invisible to
    // route-depth reconciliation — they are NOT router navigations, so popping
    // them must never trigger pop_from_native (which would reset the route to /).
    // lastFromVCWasRouteVC is set in willShowViewController: via the transition
    // coordinator; it defaults to YES so programmatic/coordinator-less pops are
    // not accidentally suppressed.
    BOOL fromVCWasRoute = self.lastFromVCWasRouteVC;
    // [zapp-nav] diagnostic: depth-delta check (Bug B sticky-route: native popped but routerstate stuck)
    BOOL willPopFromNative = fromVCWasRoute && (nativeRouteDepth < wantRouteDepth);
    fprintf(stderr, "[zapp-nav] didShow win=%d vc=%p vcClass=%s nativeRouteDepth=%d wantRouteDepth=%d fromVCWasRoute=%d willPopFromNative=%d\n",
            (int)self.windowId, (__bridge void*)vc,
            class_getName([vc class]),
            nativeRouteDepth, wantRouteDepth, (int)fromVCWasRoute, (int)willPopFromNative);
    fflush(stderr);
    if (willPopFromNative) {
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

// Public entry point so sidebar.m can install the delegate on the collapsed
// nav at didCollapse time — before any route push, so willShowViewController:
// fires when UIKit shows the content VC (e.g. via showColumn:Supplementary).
// Must be called on the main thread. Idempotent.
void zapp_ios_route_install_nav_delegate(UINavigationController* nav, int32_t windowId) {
    if (!nav || windowId <= 0) return;
    zapp_route_install_delegate(nav, windowId);
}

// --- Push seam ------------------------------------------------------------

void zapp_ios_push_route_vc(int32_t windowId, const char* url) {
    if (!zapp_window_native_routing(windowId)) return;   // opt-in gate (retired in R3')
    void* win = darwin_window_get_by_numeric_id(windowId);
    if (!win) return;
    UINavigationController* nav = zapp_route_content_nav(win);
    // [zapp-nav] diagnostic: push entry — shows whether nav resolved
    fprintf(stderr, "[zapp-nav] push_route_vc win=%d url=%s navResolved=%p\n",
            (int)windowId, url ? url : "(null)", (__bridge void*)nav);
    fflush(stderr);
    if (!nav) return;   // nav not available yet → deferred
    zapp_route_install_delegate(nav, windowId);

    ZappRouteVC* vc = [ZappRouteVC new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;

    // N3a per-route identity: set the pending url before create_ext mints the
    // route webview so it renders its own fixed route, not the latest broadcast.
    zapp_ios_set_pending_route_url(url);

    // Slot-restore dance (fixes sticky-route / Bug B):
    // darwin_webview_create_ext ends by calling zapp_ios_register_webview, which
    // writes the newly minted route webview into zapp_ios_webviews[windowId] —
    // evicting the content webview from its host slot.  After that eviction,
    // zapp_ios_eval_js_all_webviews (used for ROUTE_CHANGED broadcasts) no longer
    // reaches the content webview, so lateral section nav can't re-render and the
    // route appears sticky.  Capture the current content webview BEFORE create_ext
    // so we can restore it to the slot afterwards.  Mirrors the same fix applied to
    // ZappIOSPushedInspectorVC.viewDidLoad in inspector.m:114-115.
    WKWebView* savedContentWebview = zapp_ios_content_webview_for_slot(windowId);

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

    // Restore the content webview to the host slot (slot-restore dance).
    // create_ext has now clobbered zapp_ios_webviews[windowId] with the route
    // webview.  Put the content webview back so ROUTE_CHANGED broadcasts via
    // zapp_ios_eval_js_all_webviews continue reaching the content pane.
    // The route webview is slot-less: its bridge (Back button, one-time render via
    // zapp.route identity) works without a slot; it intentionally ignores
    // ROUTE_CHANGED anyway.
    if (savedContentWebview && savedContentWebview != vc.webview) {
        zapp_ios_register_webview(win, (__bridge void*)savedContentWebview);
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
    BOOL topIsRouteVC = [nav.topViewController isKindOfClass:[ZappRouteVC class]];
    // [zapp-nav] diagnostic: pop entry — shows whether top is actually a route VC
    fprintf(stderr, "[zapp-nav] pop_route_vc win=%d topIsRouteVC=%d\n",
            (int)windowId, (int)topIsRouteVC);
    fflush(stderr);
    if (topIsRouteVC)
        [nav popViewControllerAnimated:YES];
}

void zapp_ios_pop_to_content(int32_t windowId) {
    void* win = darwin_window_get_by_numeric_id(windowId);
    if (!win) return;
    UIViewController* contentVC = zapp_ios_content_vc_for_window(win);
    if (!contentVC) return;
    UINavigationController* nav = contentVC.navigationController;
    if (!nav) return;
    BOOL containsContent = [nav.viewControllers containsObject:contentVC];
    // [zapp-nav] diagnostic: pop_to_content — key for lateral section switch (Bug B)
    fprintf(stderr, "[zapp-nav] pop_to_content win=%d contentVC=%p stackBefore=%lu containsContent=%d\n",
            (int)windowId, (__bridge void*)contentVC,
            (unsigned long)nav.viewControllers.count, (int)containsContent);
    fflush(stderr);
    if (containsContent)
        [nav popToViewController:contentVC animated:NO];
}
