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
extern int32_t zapp_ios_inspector_slot_for(int32_t host_slot);

// --- Per-window registry --------------------------------------------------
//
// Keyed by the host UIWindow (NSValue-wrapped pointer), mirroring darwin/
// sidebar.m's zapp_sidebars. Sidebar:* actions can arrive from EITHER pane's
// transport slot; both resolve to the same host UIWindow via
// darwin_window_get_by_numeric_id, so the host-window key catches both.

@interface ZappIOSSidebarController : NSObject <UISplitViewControllerDelegate, UIGestureRecognizerDelegate>
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
// Source of truth for the current presentation mode. Set at register time from
// the create-time config (via zapp_ios_apply_presentation) and updated by
// darwin_sidebar_set_presentation. Values: nil/"" = automatic, "tile", "overlay".
@property (nonatomic, copy) NSString* presentation;
@end

static NSMutableDictionary<NSValue*, ZappIOSSidebarController*>* zapp_ios_sidebars = nil;

// --- Shared presentation helper -------------------------------------------
//
// Applies the `preferredSplitBehavior` + `preferredDisplayMode` pair to `svc`
// from a canonical mode string ("tile", "overlay", or anything else = automatic).
// Called from three sites:
//   1. zapp_ios_sidebar_register (create path, after columns are nav-wrapped)
//   2. darwin_sidebar_set_presentation (runtime setter)
//   3. ZappIOSSplitViewController's transition/trait hooks (size-change re-apply)
//
// The pair MUST be applied together; setting one without the other produces
// undefined resolved behavior (per WWDC20 10105 and community consensus).
static void zapp_ios_apply_presentation(UISplitViewController* svc, NSString* mode) {
    if (!svc) return;
    if ([mode isEqualToString:@"overlay"]) {
        svc.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
        svc.preferredDisplayMode  = UISplitViewControllerDisplayModeSecondaryOnly;
    } else if ([mode isEqualToString:@"tile"]) {
        // WWDC canonical tile recipe: both flags, applied together.
        svc.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
        svc.preferredDisplayMode  = UISplitViewControllerDisplayModeOneBesideSecondary;
        // iOS 16+: showColumn:Primary clears any outstanding hideColumn override
        // so the primary column is forced BESIDE the secondary (true tile). Without
        // this, if the split's resolved column state is "primary hidden" (e.g. the
        // overlay/summon state), UIKit ignores preferredDisplayMode and the sidebar
        // stays an overlay regardless of the behavior/displayMode pair.
        if (@available(iOS 16.0, *)) {
            [svc showColumn:UISplitViewControllerColumnPrimary];
        }
    } else {
        // "automatic" / nil / empty — let UIKit adapt (tile-landscape,
        // overlay-portrait, collapse-compact). This is the Mail/Notes default.
        svc.preferredSplitBehavior = UISplitViewControllerSplitBehaviorAutomatic;
        svc.preferredDisplayMode  = UISplitViewControllerDisplayModeAutomatic;
    }
}

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

// Re-arm the interactive-pop (swipe-back) gesture on the combined collapsed nav.
// A hidden nav bar disables this gesture by default, so on chrome-less iPhone we
// re-enable it and route it through our delegate (which gates it to "only when
// there's something to pop"). Idempotent — safe to call repeatedly.
//
// Called from BOTH `splitViewControllerDidCollapse:` AND
// `darwin_sidebar_show_content`: on iPhone the split is often created ALREADY
// collapsed, so `splitViewControllerDidCollapse:` may never fire at launch and
// the re-arm there alone would be missed. Re-arming at navigation time (after we
// push/show the content column) guarantees the gesture is live whenever a
// content VC is actually on the stack. Lazily captures collapsedNav if it wasn't
// set by the didCollapse path.
static void zapp_ios_sidebar_rearm_pop(ZappIOSSidebarController* c) {
    if (!c) return;
    UINavigationController* nav = c.collapsedNav ?: zapp_ios_collapsed_nav(c.splitVC);
    if (!nav) return;
    c.collapsedNav = nav;
    nav.interactivePopGestureRecognizer.enabled = YES;
    nav.interactivePopGestureRecognizer.delegate = c;
}

// --- Event fan-out (mirrors darwin/sidebar.m's zapp_sidebar_emit) ---------
//
// dispatchWindowEvent's first arg is the target window id ("win-<hostId>");
// both panes carry the host id. eventName is the bare suffix
// ("sidebar-collapsed"); bootstrap/webview.ts prepends "window:".

// Data-carrying fan-out (mirrors ios/inspector.m's zapp_ios_inspector_emit_data):
// host + sidebar slot + inspector slot. dataJson nil => third arg `undefined`.
static void zapp_ios_sidebar_emit_data(ZappIOSSidebarController* c,
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
    if (c.sidebarSlotId >= 0 && c.sidebarSlotId != c.hostWindowId) {
        darwin_window_eval_js(c.sidebarSlotId, js);
    }
    int32_t inspectorSlot = zapp_ios_inspector_slot_for(c.hostWindowId);
    if (inspectorSlot >= 0 && inspectorSlot != c.hostWindowId && inspectorSlot != c.sidebarSlotId) {
        darwin_window_eval_js(inspectorSlot, js);
    }
}

// Name-only emit (collapse/expand) — delegates to the data-carrying form.
static void zapp_ios_sidebar_emit(ZappIOSSidebarController* c, const char* eventName) {
    zapp_ios_sidebar_emit_data(c, eventName, nil);
}

// sidebar-resized carries {"width":N} (bare top-level width) — mirrors the
// inspector resize payload + macOS sidebar-resized + bootstrap/webview.ts's
// bareWidth branch.
static void zapp_ios_sidebar_emit_resize(ZappIOSSidebarController* c, int32_t width) {
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", (int)width];
    zapp_ios_sidebar_emit_data(c, "sidebar-resized", json);
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

// --- ZappIOSSplitViewController subclass -----------------------------------
//
// Overrides the two UIKit hooks that fire on size/trait changes so the tile
// presentation pair is re-applied whenever the split enters regular width.
// This is the Mail/Notes recipe: (re)apply `preferredSplitBehavior` +
// `preferredDisplayMode` on every size transition keyed off horizontal size
// class, not orientation — multitasking can hand a landscape app a narrow width.
//
// The subclass is used instead of an observer because only the VC itself has the
// correct timing for these hooks (observers fire later in the layout cycle). It
// is declared + defined here so it can call `zapp_ios_apply_presentation` (above)
// and read the `presentation` property from the registered ZappIOSSidebarController.
@interface ZappIOSSplitViewController : UISplitViewController
@end

@implementation ZappIOSSplitViewController

// Re-apply the stored presentation pair on any size transition.
// `coordinator` runs the block inside the transition animation batch so the
// split adjusts atomically with the device rotation / multitasking resize.
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    // Resolve the stored presentation from the sidebar registry (keyed by window).
    UIWindow* win = self.view.window;
    if (!win || !zapp_ios_sidebars) return;
    NSValue* key = [NSValue valueWithPointer:(__bridge void*)win];
    ZappIOSSidebarController* c = zapp_ios_sidebars[key];
    if (!c) return;
    NSString* mode = c.presentation;
    // Only re-apply if tile is configured and we're transitioning to regular width.
    // For automatic, UIKit handles it natively. For overlay, it already works.
    // Key off the INCOMING size, not the current trait — size is authoritative
    // during rotation/multitasking (traitCollection hasn't updated yet).
    // A regular-width iPad in portrait is still regular; just check size class
    // by inference: any width above 768 pt is safely regular on modern iPads.
    // For robustness, also check the trait collection when available.
    if (![mode isEqualToString:@"tile"]) return;
    // Re-apply tile if incoming width can plausibly fit two columns. Use the
    // same heuristic Mail uses: re-apply unconditionally when regular, let
    // UIKit override to overlay/collapse if the width can't actually fit.
    UITraitCollection* tc = self.traitCollection;
    BOOL willBeRegular = (size.width >= 768.0)
        || (tc.horizontalSizeClass == UIUserInterfaceSizeClassRegular);
    if (!willBeRegular) return;
    // Run the re-apply inside the transition coordinator's animation batch so
    // the split resolves atomically with the rotation / multitasking resize
    // (WWDC10105 "Build for iPad" recipe). Fall back to a direct call if the
    // coordinator is nil (shouldn't happen in practice).
    if (coordinator) {
        NSString* modeCopy = [mode copy];
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            (void)ctx;
            zapp_ios_apply_presentation(self, modeCopy);
        } completion:nil];
    } else {
        zapp_ios_apply_presentation(self, mode);
    }
}

// Re-apply on trait changes (multitasking mode switch: full-screen <-> split
// view on iPad). `traitCollectionDidChange:` fires after the transition; use
// the current traitCollection (already updated).
- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (!zapp_ios_sidebars) return;
    UIWindow* win = self.view.window;
    if (!win) return;
    NSValue* key = [NSValue valueWithPointer:(__bridge void*)win];
    ZappIOSSidebarController* c = zapp_ios_sidebars[key];
    if (!c) return;
    NSString* mode = c.presentation;
    if (![mode isEqualToString:@"tile"]) return;
    if (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) {
        zapp_ios_apply_presentation(self, mode);
    }
}

@end

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
        // The hidden nav bar disables UIKit's interactive-pop gesture; re-arm it
        // so chrome-less still gets edge-swipe-back. Our delegate gates it to
        // "only when there's something to pop" (avoids a no-op swipe at root).
        zapp_ios_sidebar_rearm_pop(self);
    }
    zapp_ios_sidebar_sync_collapse(self, NO);
}

- (void)splitViewControllerDidExpand:(UISplitViewController*)svc {
    (void)svc;
    // Back to side-by-side: both panes visible → expanded.
    zapp_ios_sidebar_sync_collapse(self, NO);
}

// Gate the re-armed interactive-pop gesture: only begin when the collapsed
// stack actually has something to pop (depth > 1). Avoids a no-op edge swipe
// at the root (the sidebar), where UIKit would otherwise fire it.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)g {
    UINavigationController* nav = self.collapsedNav;
    if (nav && g == nav.interactivePopGestureRecognizer) {
        return nav.viewControllers.count > 1;
    }
    return YES;
}

@end

// --- Registry API consumed by window.m ------------------------------------
//
// window.m calls this after building the split AND after setting the preferred
// min/max/width values, BEFORE the pane webviews are created. We wrap the column
// VCs in bar-hidden navigation controllers, install the delegate, store the
// presentation mode, and apply the presentation pair (behavior + displayMode)
// AFTER the final (nav-wrapped) columns are in place — per the WWDC 10105 rule.
// This is the STRONG definition that window.m declares extern.
void zapp_ios_sidebar_register(void* window, void* split, void* sidebarVC,
                               void* contentVC, int32_t host_id, int32_t sidebar_id,
                               const char* presentation) {
    if (!window || !split) return;
    // Capture the presentation C-string before the async block (the caller's
    // buffer may be freed by the time the block runs if the deferred struct is
    // torn down; copy to an NSString which is ARC-retained safely).
    NSString* presMode = (presentation && presentation[0])
        ? [NSString stringWithUTF8String:presentation] : @"";
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
        // Store the presentation as source of truth so the transition hook can
        // re-apply it without reading stale config from the deferred struct.
        c.presentation = presMode;

        // OWN the navigation controllers so we control the bar. The column VCs
        // are still empty (no webview yet), so this never re-parents a live
        // WKWebView. Each column becomes a bar-hidden nav controller root.
        UINavigationController* sbNav = [[UINavigationController alloc] initWithRootViewController:sbVC];
        sbNav.navigationBarHidden = YES;
        UINavigationController* ctNav = [[UINavigationController alloc] initWithRootViewController:ctVC];
        ctNav.navigationBarHidden = YES;
        c.sidebarNav = sbNav;
        c.contentNav = ctNav;

        // Re-install the nav-wrapped columns. This REPLACES the bare VCs that
        // window.m set before calling us. The preferred min/max/width values
        // window.m set are preserved on the split (they're not column-VC-scoped).
        [svc setViewController:sbNav forColumn:UISplitViewControllerColumnPrimary];
        [svc setViewController:ctNav forColumn:UISplitViewControllerColumnSecondary];

        // NO explicit compact column. An explicit compact column is presented
        // VERBATIM on collapse (an empty one = blank screen); a populated one
        // would need to re-root a column VC the primary/secondary nav already
        // owns. Instead we let UIKit COMBINE the two bar-hidden column nav
        // controllers into one collapsed stack — `splitViewControllerDidCollapse:`
        // captures it (collapsedNav) and re-asserts the hidden bar.

        svc.delegate = c;

        // Apply the presentation PAIR (behavior + displayMode) NOW, AFTER the
        // final nav-wrapped columns are in place. This is the WWDC 10105 rule:
        // set displayMode + splitBehavior together, after columns exist. Applying
        // before the nav-wrap (as window.m did) means the pair is set on bare VCs
        // that are immediately replaced, losing the resolved behavior.
        zapp_ios_apply_presentation(svc, presMode);

        NSValue* key = [NSValue valueWithPointer:window];
        zapp_ios_sidebars[key] = c;

        NSLog(@"[native] iOS sidebar registered: host=%d sidebar=%d split=%@ presentation=%@",
              host_id, sidebar_id, svc, presMode.length ? presMode : @"automatic");
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
            if (compact) {
                [c.splitVC showColumn:UISplitViewControllerColumnSecondary];
                // The split may have been created already-collapsed on iPhone, so
                // splitViewControllerDidCollapse: (which normally re-arms the
                // swipe-back gesture) may never have fired. Re-arm defensively now
                // that a content VC is on the stack.
                zapp_ios_sidebar_rearm_pop(c);
            } else {
                [c.splitVC hideColumn:UISplitViewControllerColumnPrimary];
            }
        } else if (compact) {
            UINavigationController* nav = c.collapsedNav ?: zapp_ios_collapsed_nav(c.splitVC);
            if (nav && c.contentVC && nav.topViewController != c.contentVC)
                [nav pushViewController:c.contentVC animated:YES];
            zapp_ios_sidebar_rearm_pop(c);  // defensive re-arm (see above)
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
        if (!c || !c.splitVC) return;
        BOOL sidebarVisible;
        if (c.splitVC.isCollapsed) {
            // compact (iPhone): no system tap-out dismiss; tracked state is
            // authoritative (lastCollapsedEmit YES == sidebar hidden).
            sidebarVisible = !c.lastCollapsedEmit;
        } else {
            // regular (iPad): the overlay can be dismissed by the system
            // (tap-out), so read the LIVE displayMode, not the cached flag —
            // otherwise lastCollapsedEmit goes stale and toggle needs two taps.
            sidebarVisible = (c.splitVC.displayMode != UISplitViewControllerDisplayModeSecondaryOnly);
        }
        // The show_* ops re-dispatch to main (already on it here — they run
        // inline since [NSThread isMainThread] is true).
        if (sidebarVisible) darwin_sidebar_show_content(window_id);  // hide it
        else darwin_sidebar_show_sidebar(window_id);                 // show it
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
            // Force a relayout so the width re-applies immediately — without
            // this, a native overlay-reveal gesture that changed displayMode can
            // leave the split ignoring the new preferred width until the next
            // system layout pass.
            [c.splitVC.view setNeedsLayout];
            [c.splitVC.view layoutIfNeeded];
            zapp_ios_sidebar_emit_resize(c, width);
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

// Runtime sidebar presentation switch (A2). mode: "automatic" | "tile" | "overlay".
// Applies via the shared zapp_ios_apply_presentation helper so the create path,
// this setter, and the transition hook all use exactly the same pair. Stores the
// new mode on the controller so the transition hook re-applies it on rotation /
// multitasking changes without reading stale config.
void darwin_sidebar_set_presentation(int32_t window_id, const char* mode) {
    NSString* presMode = (mode && mode[0]) ? [NSString stringWithUTF8String:mode] : @"";
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        // Update the stored presentation so ZappIOSSplitViewController's
        // transition/trait hooks re-apply the correct pair on size changes.
        c.presentation = presMode;
        zapp_ios_apply_presentation(c.splitVC, presMode);
        [c.splitVC.view setNeedsLayout];
        [c.splitVC.view layoutIfNeeded];
    });
}
