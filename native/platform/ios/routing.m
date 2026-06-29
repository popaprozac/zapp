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

// Route VC: a plain UIViewController hosting its own WKWebView.
// Tagged so reconcile can distinguish route VCs from the root contentVC
// and apply brk-1 teardown on pop.
@interface ZappRouteVC : UIViewController
@property (nonatomic, weak) WKWebView* webview;
@end
@implementation ZappRouteVC @end

// One delegate per window's contentNav: detects user-initiated pops (back
// button, edge swipe) and reflects them into routerstate. Composes with N1's
// toolbar delegate by chaining `prev` + forwarding unknown selectors.
@interface ZappRoutingNavDelegate : NSObject <UINavigationControllerDelegate>
@property (nonatomic, assign) int32_t windowId;
@property (nonatomic, weak) id<UINavigationControllerDelegate> prev;
@end

@implementation ZappRoutingNavDelegate

- (void)navigationController:(UINavigationController*)nav
       didShowViewController:(UIViewController*)vc
                    animated:(BOOL)animated {
    int nativeDepth = (int)nav.viewControllers.count;
    int wantDepth = router_depth(self.windowId);
    if (nativeDepth < wantDepth) {
        // User popped via back button or edge swipe — reflect into routerstate.
        // zapp_router_pop_from_native will call zapp_ios_router_sync, but at
        // that point nativeDepth == wantDepth-1 == new wantDepth → no-op sync.
        zapp_router_pop_from_native(self.windowId);
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

void zapp_ios_router_sync(int32_t windowId) {
    if (!zapp_window_native_routing(windowId)) return;   // opt-in only

    void* win = darwin_window_get_by_numeric_id(windowId);
    if (!win) return;

    UINavigationController* nav = zapp_ios_content_nav_for_window(win);
    if (!nav) return;   // no-sidebar window: contentNav not available yet; deferred

    // Install our delegate once per window. Chain any pre-existing delegate
    // (e.g. N1's ZappIOSToolbarNavDelegate) so it keeps receiving callbacks.
    if (!g_routing_delegates) {
        g_routing_delegates = [NSMutableDictionary dictionary];
    }
    if (!g_routing_delegates[@(windowId)]) {
        ZappRoutingNavDelegate* d = [ZappRoutingNavDelegate new];
        d.windowId = windowId;
        d.prev = nav.delegate;   // chain N1's toolbar delegate
        nav.delegate = d;
        g_routing_delegates[@(windowId)] = d;
    }

    // Re-arm the interactive-pop gesture on contentNav (hidden bar disables it
    // by default). Idempotent — safe to call on every sync.
    if (nav.interactivePopGestureRecognizer) {
        nav.interactivePopGestureRecognizer.enabled = YES;
    }

    int want = router_depth(windowId);   // desired total VCs (root + routes)
    int have = (int)nav.viewControllers.count;

    if (have < want) {
        // Push one route VC for the new top entry.
        const char* urlC = router_current_url(windowId);
        NSString* url = (urlC && urlC[0]) ? [NSString stringWithUTF8String:urlC] : @"/";
        (void)url;  // N3a: route webview receives the URL via ROUTE_CHANGED broadcast
                    // (the app's router.current() drives the content). Per-route URL
                    // injection into the webview load is deferred to N3b.

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

        [nav pushViewController:vc animated:YES];

    } else if (have > want) {
        // Pop extra route VCs (programmatic router.pop / router.popToRoot).
        // Tear down each popped webview to avoid the brk-1 crash
        // (reference_wkwebview_teardown recipe).
        while ((int)nav.viewControllers.count > want) {
            UIViewController* top = nav.topViewController;
            [nav popViewControllerAnimated:YES];
            if ([top isKindOfClass:[ZappRouteVC class]]) {
                WKWebView* wv = ((ZappRouteVC*)top).webview;
                if (wv) {
                    [wv stopLoading];
                    wv.navigationDelegate = nil;
                    wv.UIDelegate = nil;
                    @try {
                        // Remove the bridge message handler. Handler name is "zapp"
                        // (ios/webview.m:889 — [ucc addScriptMessageHandler:handler name:@"zapp"]).
                        [wv.configuration.userContentController
                            removeScriptMessageHandlerForName:@"zapp"];
                    } @catch (__unused id e) {}
                }
            }
        }
    }
}
