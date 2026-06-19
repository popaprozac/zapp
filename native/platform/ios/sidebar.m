// iOS native sidebar — chrome-less master-detail over UISplitViewController.
//
// T2 built the split in window.m (UISplitViewControllerStyleDoubleColumn, the
// sidebar VC as the primary column, the content VC as the secondary). This file
// owns everything after construction: the per-window registry, the control ops
// the router calls (toggle / collapse / expand / setWidth / showContent /
// showSidebar / setCollapsible / setResizable), the UISplitViewControllerDelegate
// that makes the compact (iPhone) collapse chrome-less, and the
// window:sidebar-collapsed/-expanded fan-out to both panes.
//
// === CHROME-LESS MASTER-DETAIL (the iPhone UX) ===========================
//
// On regular width (macOS-via-Catalyst is N/A here; iPad regular) the split
// shows BOTH columns side-by-side and every reveal op below is a no-op — the
// panes are always visible, exactly like macOS NSSplitViewController.
//
// On compact width (iPhone, and iPad in narrow multitasking) a .doubleColumn
// split COLLAPSES to a single navigation stack. UIKit, left alone, would (a)
// land on the *content* column and (b) show a navigation bar with a system
// "< Back" button. We want neither: land on the SIDEBAR (list-first, like
// Settings/Mail) and NO native bar (full-bleed webview; native toolbars are a
// deliberate future cycle). Two delegate/setup moves get us there:
//
//  1. LAND ON THE SIDEBAR. `splitViewController:topColumnForCollapsingToProposed
//     TopColumn:` returns UISplitViewControllerColumnPrimary, so the collapsed
//     stack's root is the sidebar.
//
//  2. HIDE THE NAV BAR. We OWN the navigation controllers: each column VC is
//     wrapped in a UINavigationController with navigationBarHidden = YES, handed
//     back to the split via setViewController:forColumn:. We do NOT set an
//     explicit compact column — an explicit compact column is shown VERBATIM on
//     collapse, so an empty one paints a blank screen and a populated one would
//     need to re-root a column VC that the primary/secondary nav already owns
//     (a VC has one parent). Instead we let UIKit build the collapsed stack: for
//     a .doubleColumn split whose columns are themselves navigation controllers,
//     UIKit COMBINES them into a single navigation controller for the compact
//     presentation (reusing one of ours, so navigationBarHidden carries over).
//     `splitViewControllerDidCollapse:` then captures that combined controller
//     (`collapsedNav`) and force-hides its bar belt-and-suspenders.
//
//  3. DRIVE THE STACK. showContent / showSidebar:
//       - iOS 16+: [split showColumn:] / [split hideColumn:] is the supported
//         way to push/pop the collapsed stack (and to slide columns on regular).
//         With our combined bar-hidden nav controller, this presents the target
//         column full-bleed with no visible bar.
//       - Fallback (pre-iOS 16, or if showColumn no-ops while collapsed): drive
//         the combined collapsed UINavigationController directly — push the
//         content VC for showContent, popToRootViewController for showSidebar.
//         Same effect, still no bar. On regular width we nudge
//         preferredDisplayMode instead.
//
// Re-parenting note: this wrapping happens in zapp_ios_sidebar_register, which
// window.m calls AFTER setViewController:forColumn: but BEFORE either pane's
// WKWebView is created. The column VCs are still empty at that point, so wrapping
// them in nav controllers never re-parents a live WKWebView (which would reset
// its content process and kill the bridge). The webviews are subsequently added
// into the SAME column VC views (now nav-controller roots), so their hierarchy
// is untouched.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <math.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);

// --- Per-window registry --------------------------------------------------
//
// Keyed by the host UIWindow (NSValue-wrapped pointer), mirroring darwin/
// sidebar.m's zapp_sidebars. Sidebar:* actions can arrive from EITHER pane's
// transport slot; both resolve to the same host UIWindow via
// darwin_window_get_by_numeric_id, so the host-window key catches both.

@interface ZappIOSSidebarController : NSObject <UISplitViewControllerDelegate>
@property (nonatomic, weak) UISplitViewController* splitVC;
@property (nonatomic, weak) UIViewController* sidebarVC;   // primary column content
@property (nonatomic, weak) UIViewController* contentVC;   // secondary column content
@property (nonatomic, strong) UINavigationController* sidebarNav;   // primary column nav (bar hidden)
@property (nonatomic, strong) UINavigationController* contentNav;   // secondary column nav (bar hidden)
@property (nonatomic, weak)   UINavigationController* collapsedNav; // the combined stack while collapsed (bar hidden)
@property (nonatomic, assign) int32_t hostWindowId;    // content webview's slot
@property (nonatomic, assign) int32_t sidebarSlotId;   // sidebar webview's slot
@property (nonatomic, assign) BOOL lastCollapsedEmit;  // last collapse state we emitted
@property (nonatomic, assign) int32_t configuredWidth; // setWidth best-effort store
@end

static NSMutableDictionary<NSValue*, ZappIOSSidebarController*>* zapp_ios_sidebars = nil;

static void zapp_ios_sidebar_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// slot -> owning UIWindow -> registry key. Works from EITHER pane's slot.
static ZappIOSSidebarController* zapp_ios_sidebar_for_slot(int32_t slot_id) {
    if (!zapp_ios_sidebars) return nil;
    void* win_ptr = darwin_window_get_by_numeric_id(slot_id);
    if (!win_ptr) return nil;
    NSValue* key = [NSValue valueWithPointer:win_ptr];
    return zapp_ios_sidebars[key];
}

// True when the split is currently in its single-column compact presentation
// (iPhone). On regular width the panes are side-by-side and reveal ops no-op.
static BOOL zapp_ios_sidebar_is_compact(ZappIOSSidebarController* c) {
    if (!c || !c.splitVC) return NO;
    return c.splitVC.isCollapsed;
}

// While collapsed, UIKit combines the column nav controllers into one stack and
// parents it under the split. Find it so we can keep its bar hidden and drive
// it on the pre-iOS-16 fallback path. `viewControllers` (classic property) holds
// the single combined controller when collapsed; childViewControllers is the
// belt-and-suspenders fallback.
static UINavigationController* zapp_ios_collapsed_nav(UISplitViewController* svc) {
    if (!svc) return nil;
    for (UIViewController* vc in svc.viewControllers) {
        if ([vc isKindOfClass:[UINavigationController class]]) return (UINavigationController*)vc;
    }
    for (UIViewController* vc in svc.childViewControllers) {
        if ([vc isKindOfClass:[UINavigationController class]]) return (UINavigationController*)vc;
    }
    return nil;
}

// --- Event fan-out (mirrors darwin/sidebar.m's zapp_sidebar_emit) ---------
//
// dispatchWindowEvent's first arg is the target window id ("win-<hostId>");
// both panes carry the host id. eventName is the bare suffix
// ("sidebar-collapsed"); bootstrap/webview.ts prepends "window:".
static void zapp_ios_sidebar_emit(ZappIOSSidebarController* c, const char* eventName) {
    if (!c || !eventName) return;
    char js[256];
    snprintf(js, sizeof(js),
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&typeof b.dispatchWindowEvent==='function'){"
        "b.dispatchWindowEvent('win-%d','%s');}})();",
        c.hostWindowId, eventName);
    darwin_window_eval_js(c.hostWindowId, js);
    if (c.sidebarSlotId >= 0 && c.sidebarSlotId != c.hostWindowId) {
        darwin_window_eval_js(c.sidebarSlotId, js);
    }
}

// Emit collapsed/expanded once per transition. "Collapsed" here means the
// CONTENT pane is the visible/top one (sidebar hidden) — the iOS analog of the
// macOS sidebar-collapsed state. Computed from the compact nav stack depth (a
// pushed content VC == collapsed) on compact, and never on regular (both
// always visible → treated as expanded).
static void zapp_ios_sidebar_sync_collapse(ZappIOSSidebarController* c, BOOL collapsed) {
    if (!c) return;
    if (collapsed == c.lastCollapsedEmit) return;
    c.lastCollapsedEmit = collapsed;
    zapp_ios_sidebar_emit(c, collapsed ? "sidebar-collapsed" : "sidebar-expanded");
}

@implementation ZappIOSSidebarController

// LAND ON THE SIDEBAR: when the split collapses to a single column on compact,
// make the SIDEBAR (primary) the top of the stack — list-first.
- (UISplitViewControllerColumn)splitViewController:(UISplitViewController*)svc
        topColumnForCollapsingToProposedTopColumn:(UISplitViewControllerColumn)proposedTopColumn {
    (void)svc; (void)proposedTopColumn;
    return UISplitViewControllerColumnPrimary;
}

// On collapse (entered compact): the stack roots at the sidebar → expanded
// (sidebar visible). Capture the combined nav controller UIKit built and force
// its bar hidden in case UIKit re-installed one while building the stack.
- (void)splitViewControllerDidCollapse:(UISplitViewController*)svc {
    UINavigationController* nav = zapp_ios_collapsed_nav(svc);
    if (nav) {
        nav.navigationBarHidden = YES;
        self.collapsedNav = nav;
    }
    zapp_ios_sidebar_sync_collapse(self, NO);
}

- (void)splitViewControllerDidExpand:(UISplitViewController*)svc {
    (void)svc;
    // Back to side-by-side: both panes visible → expanded.
    zapp_ios_sidebar_sync_collapse(self, NO);
}

@end

// --- Registry API consumed by window.m ------------------------------------
//
// window.m calls this after building the split (columns set, BEFORE the pane
// webviews are created). We wrap the column VCs in bar-hidden navigation
// controllers, install the delegate, and provide an explicit bar-hidden compact
// column so the collapsed iPhone stack is chrome-less by construction. This is
// the STRONG definition that overrides window.m's __attribute__((weak)) shim.
void zapp_ios_sidebar_register(void* window, void* split, void* sidebarVC,
                               void* contentVC, int32_t host_id, int32_t sidebar_id) {
    if (!window || !split) return;
    zapp_ios_sidebar_on_main(^{
        if (!zapp_ios_sidebars) zapp_ios_sidebars = [NSMutableDictionary dictionary];

        UISplitViewController* svc = (__bridge UISplitViewController*)split;
        UIViewController* sbVC = (__bridge UIViewController*)sidebarVC;
        UIViewController* ctVC = (__bridge UIViewController*)contentVC;
        if (!svc || !sbVC || !ctVC) return;

        ZappIOSSidebarController* c = [[ZappIOSSidebarController alloc] init];
        c.splitVC = svc;
        c.sidebarVC = sbVC;
        c.contentVC = ctVC;
        c.hostWindowId = host_id;
        c.sidebarSlotId = sidebar_id;
        c.lastCollapsedEmit = NO;   // we land on the sidebar → start "expanded"

        // OWN the navigation controllers so we control the bar. The column VCs
        // are still empty (no webview yet), so this never re-parents a live
        // WKWebView. Each column becomes a bar-hidden nav controller root.
        UINavigationController* sbNav = [[UINavigationController alloc] initWithRootViewController:sbVC];
        sbNav.navigationBarHidden = YES;
        UINavigationController* ctNav = [[UINavigationController alloc] initWithRootViewController:ctVC];
        ctNav.navigationBarHidden = YES;
        c.sidebarNav = sbNav;
        c.contentNav = ctNav;

        [svc setViewController:sbNav forColumn:UISplitViewControllerColumnPrimary];
        [svc setViewController:ctNav forColumn:UISplitViewControllerColumnSecondary];

        // NO explicit compact column. An explicit compact column is presented
        // VERBATIM on collapse (an empty one = blank screen); a populated one
        // would need to re-root a column VC the primary/secondary nav already
        // owns. Instead we let UIKit COMBINE the two bar-hidden column nav
        // controllers into one collapsed stack — `splitViewControllerDidCollapse:`
        // captures it (collapsedNav) and re-asserts the hidden bar.

        svc.delegate = c;

        NSValue* key = [NSValue valueWithPointer:window];
        zapp_ios_sidebars[key] = c;

        NSLog(@"[native] iOS sidebar registered: host=%d sidebar=%d split=%@",
              host_id, sidebar_id, svc);
    });
}

void zapp_ios_sidebar_unregister(void* window) {
    if (!window) return;
    zapp_ios_sidebar_on_main(^{
        if (!zapp_ios_sidebars) return;
        NSValue* key = [NSValue valueWithPointer:window];
        ZappIOSSidebarController* c = zapp_ios_sidebars[key];
        if (!c) return;
        if (c.splitVC && c.splitVC.delegate == c) c.splitVC.delegate = nil;
        [zapp_ios_sidebars removeObjectForKey:key];
    });
}

// --- Control ops (router entry points) ------------------------------------
//
// All keyed by a transport slot (host OR sidebar pane); zapp_ios_sidebar_for_slot
// resolves either to the host record.

// Reveal the CONTENT (hide the sidebar). compact(iPhone): existing nav move.
// regular(iPad): tile → collapse the sidebar to full content width; overlay →
// dismiss the flyout. (hideColumn:Primary adapts to the split's behavior.)
void darwin_sidebar_show_content(int32_t window_id) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        BOOL compact = zapp_ios_sidebar_is_compact(c);
        if (@available(iOS 16.0, *)) {
            if (compact) [c.splitVC showColumn:UISplitViewControllerColumnSecondary];
            else [c.splitVC hideColumn:UISplitViewControllerColumnPrimary];
        } else if (compact) {
            UINavigationController* nav = c.collapsedNav ?: zapp_ios_collapsed_nav(c.splitVC);
            if (nav && c.contentVC && nav.topViewController != c.contentVC)
                [nav pushViewController:c.contentVC animated:YES];
        } else {
            c.splitVC.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        }
        zapp_ios_sidebar_sync_collapse(c, YES);  // content visible == collapsed
    });
}

// Reveal the SIDEBAR. compact(iPhone): existing pop-to-sidebar.
// regular(iPad): tile → slide the sidebar in beside content; overlay → float
// the flyout in. showColumn:Primary works on both compact and regular.
void darwin_sidebar_show_sidebar(int32_t window_id) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        BOOL compact = zapp_ios_sidebar_is_compact(c);
        if (@available(iOS 16.0, *)) {
            [c.splitVC showColumn:UISplitViewControllerColumnPrimary];
        } else if (compact) {
            UINavigationController* nav = c.collapsedNav ?: zapp_ios_collapsed_nav(c.splitVC);
            if (nav && nav.viewControllers.count > 1)
                [nav popToRootViewControllerAnimated:YES];
        } else {
            c.splitVC.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        }
        zapp_ios_sidebar_sync_collapse(c, NO);  // sidebar visible == expanded
    });
}

// Toggle which column is shown on compact (sidebar <-> content). No-op on
// regular (both always visible). Mapped onto the show/hide reveal primitives.
void darwin_sidebar_toggle(int32_t window_id) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c) return;
        // c.lastCollapsedEmit tracks "content visible" (collapsed). Flip it.
        // The show_* ops re-dispatch to main (already on it here — they run
        // inline since [NSThread isMainThread] is true).
        if (c.lastCollapsedEmit) darwin_sidebar_show_sidebar(window_id);
        else darwin_sidebar_show_content(window_id);
    });
}

// collapse() == hide the sidebar (reveal the content) — the macOS "sidebar
// collapsed" semantics, mapped to the compact reveal.
void darwin_sidebar_collapse(int32_t window_id) {
    darwin_sidebar_show_content(window_id);
}

// expand() == reveal the sidebar.
void darwin_sidebar_expand(int32_t window_id) {
    darwin_sidebar_show_sidebar(window_id);
}

// Best-effort sidebar width: the PRIMARY column width in .doubleColumn style.
// iOS clamps to its own min/max; only meaningful on regular width (compact is a
// full-screen stack). Stored so a later layout/regular transition can apply it.
void darwin_sidebar_set_width(int32_t window_id, int32_t width) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        c.configuredWidth = width;
        if (width > 0) {
            c.splitVC.preferredPrimaryColumnWidth = (CGFloat)width;
        }
    });
}

// User-collapsible gating is an NSSplitViewItem affordance; the iOS split's
// collapse is width-driven (system-owned), so there's no equivalent knob.
// Stored intent / no-op for router parity (documented).
void darwin_sidebar_set_collapsible(int32_t window_id, bool can_collapse) {
    (void)window_id; (void)can_collapse;
}

// Divider-drag resize isn't a UISplitViewController affordance (column widths
// are system-managed within preferredPrimaryColumnWidth bounds). No-op for
// router parity (documented).
void darwin_sidebar_set_resizable(int32_t window_id, bool resizable) {
    (void)window_id; (void)resizable;
}
