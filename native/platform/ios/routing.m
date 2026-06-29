// iOS native routing (N3a risk gate). Drives contentNav as a UINavigationController
// routing stack: routerstate (Nim) is authoritative; zapp_ios_router_sync reconciles
// the native VC stack to match; a nav delegate routes user pops back to Nim.
//
// Architecture:
//   - routerDepth(win) = desired VC stack depth (1 = root only, N = root + routes)
//   - nav.viewControllers.count = current native depth
//   - push: want > have → push one ZappRouteVC with a fresh webview
//   - pop: want < have → pop extra VCs + brk-1 teardown on their webviews
//   - ZappRoutingNavDelegate.didShow: detect user-initiated pops (swipe/back)
//     and reflect them into routerstate (which re-syncs, but depth now matches → no-op)
//
// Gotchas addressed:
//   - Delegate composition: prev-chain + forwardingTargetForSelector: keeps N1's
//     ZappIOSToolbarNavDelegate working after we set ourselves as nav.delegate.
//   - brk-1 teardown: stopLoading + nil delegates + removeScriptMessageHandler
//     before the VC is released (reference_wkwebview_teardown recipe).
//   - Swipe-back: route VCs on contentNav inherit sidebar.m's re-arm (rearm is on
//     collapsedNav, not contentNav). contentNav has a visible bar (hidden), so iOS
//     disables interactivePopGestureRecognizer by default; re-arm it here.
//   - Loop guard: zapp_router_pop_from_native calls zapp_ios_router_sync, but by
//     then native depth == Nim depth → sync is a no-op.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// darwin_webview_create_ext is defined in ios/webview.m (same iOS link unit).
// Include the shared header rather than re-declaring `extern` — the
// ios-platform-parity lint can't parse the multi-line definition so a bare
// `extern` would trip a false "unsatisfied cross-layer extern" violation.
// (Same pattern as ios/window.m:40.)
#include "../darwin/webview.h"

// --- Nim/native externs ---
extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern UINavigationController* zapp_ios_content_nav_for_window(void* window_ptr);
extern bool zapp_window_native_routing(int32_t window_id);
extern int router_depth(int32_t win);
extern const char* router_current_url(int32_t win);
extern void zapp_router_pop_from_native(int32_t window_id);
// N3a DIAGNOSTIC (Phase-1 evidence): the iPhone split is collapsed → the live
// stack is collapsedNav, not contentNav. Log both to ground the reconcile.
extern BOOL zapp_ios_split_is_collapsed_for_window(void* window_ptr);
extern UINavigationController* zapp_ios_collapsed_nav_for_window(void* window_ptr);
// N3a per-route identity: set the route url just before create_ext mints the
// route webview → it renders its OWN fixed route (zapp.route), not the latest
// broadcast. zapp_ios_toolbar_inject_webview_safe_area gives the route webview
// the --zapp-* insets that the registered-slot metrics pass never reaches.
extern void zapp_ios_set_pending_route_url(const char* url);
extern void zapp_ios_toolbar_inject_webview_safe_area(WKWebView* wv);

// Route VC: a plain UIViewController hosting its own WKWebView.
// Tagged so reconcile can distinguish route VCs from the root contentVC
// and apply brk-1 teardown on pop.
@interface ZappRouteVC : UIViewController
@property (nonatomic, weak) WKWebView* webview;
@end
@implementation ZappRouteVC
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // N3a: route VCs aren't registered pane slots, so the toolbar metrics pass
    // never injects their --zapp-* safe-area vars (→ content under the nav).
    // Inject here, after layout, so safeAreaInsets is valid. Idempotent; re-runs
    // on rotation/resize and once the web content commits.
    if (self.webview) zapp_ios_toolbar_inject_webview_safe_area(self.webview);
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
        // Handler name is "zapp" (ios/webview.m:889).
        [wv.configuration.userContentController removeScriptMessageHandlerForName:@"zapp"];
    } @catch (__unused id e) {}
}

// One delegate per window's contentNav: detects user-initiated pops (back
// button, edge swipe) and reflects them into routerstate. Composes with N1's
// toolbar delegate by chaining `prev` + forwarding unknown selectors. Owns the
// list of pushed route VCs so it can tear down whichever ones get popped — by
// the user OR programmatically — via the unified didShow diff.
@interface ZappRoutingNavDelegate : NSObject <UINavigationControllerDelegate>
@property (nonatomic, assign) int32_t windowId;
@property (nonatomic, weak) id<UINavigationControllerDelegate> prev;
@property (nonatomic, strong) NSMutableArray<ZappRouteVC*>* pushedVCs;  // strong: hold until torn down
@end

@implementation ZappRoutingNavDelegate

- (void)navigationController:(UINavigationController*)nav
       didShowViewController:(UIViewController*)vc
                    animated:(BOOL)animated {
    int nativeDepth = (int)nav.viewControllers.count;
    int wantDepth = router_depth(self.windowId);
    NSLog(@"[zapp-routing] didShow win=%d nav(this).count=%d wantDepth=%d → %@",
          self.windowId, nativeDepth, wantDepth,
          (nativeDepth < wantDepth) ? @"pop_from_native()" : @"(no reflect)");
    if (nativeDepth < wantDepth) {
        // User popped via back button or edge swipe — reflect into routerstate.
        // zapp_router_pop_from_native will call zapp_ios_router_sync, but at
        // that point nativeDepth == wantDepth-1 == new wantDepth → no-op sync.
        zapp_router_pop_from_native(self.windowId);
    }

    // Unified teardown: any route VC we pushed that is no longer in the nav has
    // been popped — by the user (back/swipe, which never hits the sync pop
    // branch) OR programmatically. Tear down its webview now so it doesn't leak
    // (the VC + WKWebView would otherwise stay alive in collapsedNav). Strong
    // pushedVCs held them until this point.
    NSMutableArray<ZappRouteVC*>* gone = [NSMutableArray array];
    for (ZappRouteVC* rvc in self.pushedVCs) {
        if (![nav.viewControllers containsObject:rvc]) {
            zapp_route_vc_teardown(rvc);
            [gone addObject:rvc];
        }
    }
    if (gone.count) {
        NSLog(@"[zapp-routing]   teardown %d popped route VC(s) (pushedVCs %d→%d)",
              (int)gone.count, (int)self.pushedVCs.count, (int)(self.pushedVCs.count - gone.count));
        [self.pushedVCs removeObjectsInArray:gone];
    }

    if ([self.prev respondsToSelector:_cmd]) {
        [self.prev navigationController:nav didShowViewController:vc animated:animated];
    }
}

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.prev respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return self.prev;
}

@end

// Per-window delegate registry — keeps delegates alive and deduplicated.
static NSMutableDictionary<NSNumber*, ZappRoutingNavDelegate*>* g_routing_delegates;

// The VISIBLE navigation controller that owns the routing stack. On a COLLAPSED
// split (iPhone) the live, on-screen stack is collapsedNav — pushing onto the
// secondary-column contentNav instead makes UIKit nest contentNav INTO
// collapsedNav (a duplicate presentation that lingers, causing the sticky-route
// + extra-webview + toolbar-loss bugs). Expanded (iPad) → contentNav is visible.
static UINavigationController* zapp_routing_nav(void* win) {
    if (zapp_ios_split_is_collapsed_for_window(win)) {
        UINavigationController* c = zapp_ios_collapsed_nav_for_window(win);
        if (c) return c;   // visible combined stack
    }
    return zapp_ios_content_nav_for_window(win);
}

// N3a DIAGNOSTIC: dump a nav's VC stack (class names) so we can see exactly what
// the collapse combine retained (sticky / extra-webview investigation).
static NSString* zapp_nav_vc_dump(UINavigationController* nav) {
    if (!nav) return @"(nil)";
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (UIViewController* v in nav.viewControllers) {
        BOOL hasWeb = [v isKindOfClass:[ZappRouteVC class]]
            ? (((ZappRouteVC*)v).webview != nil)
            : NO;
        [names addObject:[NSString stringWithFormat:@"%@%@",
            NSStringFromClass([v class]), hasWeb ? @"(web)" : @""]];
    }
    return [names componentsJoinedByString:@" / "];
}

void zapp_ios_router_sync(int32_t windowId) {
    if (!zapp_window_native_routing(windowId)) return;   // opt-in only

    void* win = darwin_window_get_by_numeric_id(windowId);
    if (!win) return;

    UINavigationController* nav = zapp_routing_nav(win);   // visible nav (collapsedNav when collapsed)
    if (!nav) return;   // no-sidebar window: nav not available yet; deferred

    // --- N3a DIAGNOSTIC (Phase-1 evidence) ---
    {
        BOOL collapsed = zapp_ios_split_is_collapsed_for_window(win);
        UINavigationController* cont = zapp_ios_content_nav_for_window(win);
        UINavigationController* coll = zapp_ios_collapsed_nav_for_window(win);
        const char* urlDbg = router_current_url(windowId);
        NSLog(@"[zapp-routing] SYNC win=%d collapsed=%d routingNav.count=%d (contentNav=%d collapsedNav=%d) want(routerDepth)=%d url=%s",
              windowId, collapsed,
              (int)nav.viewControllers.count,
              (int)(cont ? cont.viewControllers.count : -1),
              (int)(coll ? coll.viewControllers.count : -1),
              router_depth(windowId),
              urlDbg ? urlDbg : "(null)");
        NSLog(@"[zapp-routing]   routingNav VCs: [%@]", zapp_nav_vc_dump(nav));
    }

    // Install our delegate once per window. Chain any pre-existing delegate
    // (e.g. N1's ZappIOSToolbarNavDelegate) so it keeps receiving callbacks.
    if (!g_routing_delegates) {
        g_routing_delegates = [NSMutableDictionary dictionary];
    }
    ZappRoutingNavDelegate* d = g_routing_delegates[@(windowId)];
    if (!d) {
        d = [ZappRoutingNavDelegate new];
        d.windowId = windowId;
        d.pushedVCs = [NSMutableArray array];
        g_routing_delegates[@(windowId)] = d;
    }
    // Self-healing install on the CURRENT visible nav. We share collapsedNav with
    // N1's ZappIOSToolbarNavDelegate, whose reapply may re-set the delegate and
    // drop us — so re-chain whenever we're not the active delegate (chaining
    // whatever is there now, e.g. N1). Idempotent when already installed.
    if (nav.delegate != d) {
        d.prev = nav.delegate;   // chain the current delegate (e.g. N1's toolbar)
        nav.delegate = d;
    }

    // Re-arm the interactive-pop gesture on contentNav (hidden bar disables it
    // by default). Idempotent — safe to call on every sync.
    if (nav.interactivePopGestureRecognizer) {
        nav.interactivePopGestureRecognizer.enabled = YES;
    }

    int want = router_depth(windowId);   // desired total VCs (root + routes)
    int have = (int)nav.viewControllers.count;

    if (have < want) {
        NSLog(@"[zapp-routing]   PUSH branch: have=%d < want=%d → push 1 ZappRouteVC onto contentNav", have, want);
        // Push one route VC for the new top entry.
        const char* urlC = router_current_url(windowId);
        NSString* url = (urlC && urlC[0]) ? [NSString stringWithUTF8String:urlC] : @"/";
        // N3a per-route identity: the route webview renders THIS url (zapp.route),
        // not the latest broadcast. create_ext consumes the pending url once.
        // [url UTF8String] is valid for this autorelease pool → stable across the
        // synchronous create_ext call (the Nim cstring is not held past here).
        zapp_ios_set_pending_route_url([url UTF8String]);

        ZappRouteVC* vc = [ZappRouteVC new];
        vc.view.backgroundColor = UIColor.systemBackgroundColor;

        // Mint a new webview into vc.view via the existing create path.
        // identity_window_id = host windowId so the route webview reports the
        // host window's id to the bridge (ROUTE_CHANGED + all t:4 ops target host).
        // pane_role 0 (main). container_view = vc.view → create_ext pins it.
        darwin_webview_create_ext(win,
            /*inspectable*/true,
            /*accept_first_mouse*/false,
            /*url_override*/NULL,
            /*numeric_id_pre_alloc*/-1,
            /*transparent_background*/false,
            /*container_view*/(__bridge void*)vc.view,
            /*identity_window_id*/windowId,
            /*pane_role*/0,
            /*host_has_sidebar*/false,
            /*host_has_inspector*/false);

        // Locate the webview that create_ext pinned as vc.view's first subview.
        // darwin_webview_create_ext with container_view does: [host addSubview:webview]
        // (ios/webview.m:966), so subviews.firstObject is the WKWebView.
        for (UIView* sub in vc.view.subviews) {
            if ([sub isKindOfClass:[WKWebView class]]) {
                vc.webview = (WKWebView*)sub;
                break;
            }
        }

        // Track for unified teardown (the delegate tears it down when popped,
        // whether by the user or programmatically).
        [g_routing_delegates[@(windowId)].pushedVCs addObject:vc];

        [nav pushViewController:vc animated:YES];
        {
            UINavigationController* coll = zapp_ios_collapsed_nav_for_window(win);
            NSLog(@"[zapp-routing]   after PUSH: contentNav.count=%d collapsedNav.count=%d",
                  (int)nav.viewControllers.count, (int)(coll ? coll.viewControllers.count : -1));
        }

    } else if (have > want) {
        NSLog(@"[zapp-routing]   POP branch: have=%d > want=%d → pop %d VC(s)", have, want, have - want);
        // Pop extra route VCs (programmatic router.pop / router.popToRoot). Each
        // pop fires the delegate's didShowViewController, which tears down the
        // popped route VC's webview via the pushedVCs diff (unified with the
        // user-pop path — no inline teardown needed here).
        while ((int)nav.viewControllers.count > want) {
            [nav popViewControllerAnimated:YES];
            // Teardown of the popped route VC happens in the delegate's
            // didShowViewController (pushedVCs diff) — unified user/programmatic path.
        }
    } else {
        NSLog(@"[zapp-routing]   NOOP: have==want==%d (no native push/pop)", have);
    }
}
