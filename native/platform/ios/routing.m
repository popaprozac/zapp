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
// #771 datum 3: ZappRouteNavDelegate stamps toolbar ITEMS onto the shown VC
// (zapp_ios_toolbar_stamp_vc at willShow/didShow); bar VISIBILITY stays
// willShow-owned. Defs-as-truth — the displayed VC always carries the entry's
// current UIBarButtonItem instances, so darwin_toolbar_update_item patches
// what is actually on screen.
//
// Kept verbatim: ZappRouteVC @interface/@implementation, zapp_route_vc_teardown,
// and all externs the seam still needs.

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
// Shared edge-pin helper (ios/sidebar.m, #771): Full/Safe constraint-pair
// model; route VCs are its third consumer (datum 1 — iPad-expanded inset bleed).
extern void zapp_ios_edge_pin_webview(WKWebView* wv, UIView* container,
                                      NSLayoutConstraint* __autoreleasing * outLeadingFull,
                                      NSLayoutConstraint* __autoreleasing * outLeadingSafe,
                                      NSLayoutConstraint* __autoreleasing * outTrailingFull,
                                      NSLayoutConstraint* __autoreleasing * outTrailingSafe);
extern void zapp_ios_edge_pin_update(BOOL isRegular,
                                     NSLayoutConstraint* leadingFull,
                                     NSLayoutConstraint* leadingSafe,
                                     NSLayoutConstraint* trailingFull,
                                     NSLayoutConstraint* trailingSafe,
                                     UIView* layoutView);
// Slot-restore dance: capture content webview before create_ext, restore after.
// zapp_ios_content_webview_for_slot: returns zapp_ios_webviews[slot] (window.m).
// zapp_ios_register_webview: writes a webview into the UIWindow-keyed host slot.
extern WKWebView* zapp_ios_content_webview_for_slot(int32_t slot);
extern void zapp_ios_register_webview(void* window_ptr, void* webview_ptr);
// #771 new-issue A: retarget the app-wide drag-drop webview (ios/webview.m).
extern void zapp_ios_set_drop_webview(void* webview_ptr);

// Chrome-agnostic content-VC resolution (owned-nav fork deleted in T2).
// sidebar.m: the authoritative secondary-column content VC stored at register
// time (sidebar windows), or resolved out of the split's Secondary nav for the
// hidden-Primary no-sidebar+inspector shape (G3 fallback in sidebar.m).
extern UIViewController* zapp_ios_content_vc_for_window(void* window_ptr);

// window.m slot maps (host slot -> pane slot, -1 = none). Used to stamp the
// route webview's zapp.hasSidebar / zapp.hasInspector identity to match what
// the CONTENT pane got at window creation (window.m passes d->hasSidebar /
// d->hasInspector) — a hardcoded true/false pair would misidentify the chrome
// on the no-sidebar+inspector shape now that pushes reach it (G3 fix).
extern int32_t zapp_ios_sidebar_slot_for(int32_t host_slot);
extern int32_t zapp_ios_inspector_slot_for(int32_t host_slot);

// Route VC: a plain UIViewController hosting its own WKWebView.
// Tagged so the delegate can distinguish route VCs from the root contentVC.
// Edge model (#771 datum 1): the webview is pinned via the shared Full/Safe
// constraint-pair helper (sidebar.m) — on iPad regular width UIKit expresses
// the tiled sidebar (leading) and the iOS-26 Inspector column (trailing) as
// SAFE-AREA INSETS on the full-width Secondary column, so a raw-pinned route
// webview slides under both. The pairs are stored here and swapped per
// horizontal size class, exactly like the content webview's.
@interface ZappRouteVC : UIViewController
@property (nonatomic, weak) WKWebView* webview;
@property (nonatomic, strong) NSLayoutConstraint* leadingFull;
@property (nonatomic, strong) NSLayoutConstraint* leadingSafe;
@property (nonatomic, strong) NSLayoutConstraint* trailingFull;
@property (nonatomic, strong) NSLayoutConstraint* trailingSafe;
// #771 new-issue B: set by zapp_route_vc_teardown so the explicit teardown in
// zapp_ios_pop_to_content and the viewDidDisappear: self-teardown can both
// fire in any order without double-running the brk-1 sequence.
@property (nonatomic, assign) BOOL tornDown;
@end

// Forward declaration of the teardown helper — defined below; referenced from
// viewDidDisappear: which appears before the static definition.
static void zapp_route_vc_teardown(ZappRouteVC* vc);

@implementation ZappRouteVC
- (void)zapp_updateEdges {
    if (!self.leadingFull || !self.leadingSafe) return;
    if (!self.trailingFull || !self.trailingSafe) return;
    BOOL isRegular = (self.traitCollection.horizontalSizeClass
                      == UIUserInterfaceSizeClassRegular);
    zapp_ios_edge_pin_update(isRegular, self.leadingFull, self.leadingSafe,
                             self.trailingFull, self.trailingSafe, self.view);
}
- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self zapp_updateEdges];
}
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil
                                     completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            (void)ctx;
            [self zapp_updateEdges];
        }];
    } else {
        [self zapp_updateEdges];
    }
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
    if (vc.tornDown) return;
    vc.tornDown = YES;
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
// #771 datum 3: stamp the window's toolbar defs onto the VC being shown
// (defined in ios/toolbar.m).
extern void zapp_ios_toolbar_stamp_vc(void* window_ptr, UIViewController* vc);

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

    // #771 datum 3 (structural): stamp the window's toolbar defs onto the VC
    // being shown. UIKit mutates viewControllers before this delegate fires,
    // so the incoming VC gets the CURRENT item instances during the
    // transition — and the revealed content VC gets them back after a pop
    // (this is what killed the old generation mismatch: a pop used to reveal
    // a bar holding instances that updateItem no longer patched).
    if (showBar && win) zapp_ios_toolbar_stamp_vc(win, vc);
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

    // #771 datum 3: re-stamp after the transition settles — covers cancelled
    // interactive swipes (willShow fired for a VC that never landed; didShow
    // always reports the real top) and guarantees the displayed bar holds the
    // instances darwin_toolbar_update_item patches.
    void* winPtr = darwin_window_get_by_numeric_id(self.windowId);
    if (winPtr) {
        UIViewController* shownContentVC = zapp_ios_content_vc_for_window(winPtr);
        BOOL shownIsContent = (shownContentVC && vc == shownContentVC);
        BOOL shownIsRoute = [vc isKindOfClass:[ZappRouteVC class]];
        if (shownIsContent || shownIsRoute)
            zapp_ios_toolbar_stamp_vc(winPtr, vc);

        // #771 new-issue A: system drag-drop targets the webview of the VC
        // now on screen — the route VC's own webview after a push, the
        // window's content webview after a pop to content.
        WKWebView* dropWv = nil;
        if (shownIsRoute)        dropWv = ((ZappRouteVC*)vc).webview;
        else if (shownIsContent) dropWv = zapp_ios_content_webview_for_slot(self.windowId);
        if (dropWv) zapp_ios_set_drop_webview((__bridge void*)dropWv);
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
    // Args match the content-pane call in window.m:
    //   inspectable=true, accept_first_mouse=false, url_override=NULL
    //   (route url is consumed via pending-url, not url_override),
    //   numeric_id_pre_alloc = windowId (bridge targets the host window),
    //   transparent_background=false, container_view=vc.view,
    //   identity_window_id = windowId, pane_role=0 (main),
    //   host_has_sidebar / host_has_inspector = the window's REAL pane shape
    //   (window.m slot maps; -1 = none) so the route webview's zapp.hasSidebar /
    //   zapp.hasInspector identity matches the content pane's — hardcoding
    //   true/false here would misidentify the no-sidebar+inspector shape.
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
        /*host_has_sidebar*/(zapp_ios_sidebar_slot_for(windowId) >= 0),
        /*host_has_inspector*/(zapp_ios_inspector_slot_for(windowId) >= 0));

    // Locate the webview that create_ext pinned as vc.view's first subview.
    for (UIView* sub in vc.view.subviews) {
        if ([sub isKindOfClass:[WKWebView class]]) {
            vc.webview = (WKWebView*)sub;
            break;
        }
    }

    // #771 datum 1: convert the create_ext frame+autoresizing mount to the
    // shared edge-pin model so the route webview honors the tiled-sidebar
    // (leading) and inspector-column (trailing) safe-area insets on iPad
    // regular width, and stays full-bleed on compact.
    if (vc.webview) {
        NSLayoutConstraint *lf = nil, *ls = nil, *tf = nil, *ts = nil;
        zapp_ios_edge_pin_webview(vc.webview, vc.view, &lf, &ls, &tf, &ts);
        vc.leadingFull  = lf;
        vc.leadingSafe  = ls;
        vc.trailingFull = tf;
        vc.trailingSafe = ts;
        [vc zapp_updateEdges];
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

    // Toolbar items are stamped by the nav delegate (zapp_ios_toolbar_stamp_vc
    // at willShow/didShow) — defs-as-truth, displayed-VC stamping. Nothing to
    // do at push time.

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
    if (containsContent) {
        // #771 new-issue B: popToViewController: removes COVERED route VCs
        // (depth ≥ 2) without a moving-from-parent viewDidDisappear:, so their
        // self-teardown never runs — "zapp" handlers stay registered, zombie
        // bridges accumulate. Collect every route VC above the content VC
        // first, pop, then tear each down explicitly (idempotent via the
        // tornDown flag — the topmost VC's own viewDidDisappear: may also fire).
        NSMutableArray<ZappRouteVC*>* covered = [NSMutableArray array];
        NSUInteger contentIdx = [nav.viewControllers indexOfObject:contentVC];
        for (NSUInteger i = contentIdx + 1; i < nav.viewControllers.count; i++) {
            UIViewController* v = nav.viewControllers[i];
            if ([v isKindOfClass:[ZappRouteVC class]])
                [covered addObject:(ZappRouteVC*)v];
        }
        [nav popToViewController:contentVC animated:NO];
        for (ZappRouteVC* v in covered) zapp_route_vc_teardown(v);
    }
}
