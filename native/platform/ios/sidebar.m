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
@property (nonatomic, assign) int32_t configuredWidth;    // configured width (setWidth + create-time)
@property (nonatomic, assign) int32_t configuredMinWidth; // configured minimumPrimaryColumnWidth
@property (nonatomic, assign) int32_t configuredMaxWidth; // configured maximumPrimaryColumnWidth
@property (nonatomic, assign) BOOL resizable;             // whether drag-resize is allowed
@property (nonatomic, assign) BOOL collapsible;           // whether the sidebar can be collapsed
// Source of truth for the current presentation mode. Set at register time from
// the create-time config (via zapp_ios_apply_presentation) and updated by
// darwin_sidebar_set_presentation. Values: nil/"" = automatic, "tile", "overlay".
@property (nonatomic, copy) NSString* presentation;
// Content-webview leading constraint management.
// Two stored constraints — only one active at a time, swapped on trait change:
//   leadingFull → content webview leading = contentVC.view.leadingAnchor
//                 (compact / iPhone — full-bleed, no sidebar inset)
//   leadingSafe → content webview leading = contentVC.view.safeAreaLayoutGuide.leadingAnchor
//                 (regular / iPad tile — respects the 310pt sidebar safe-area inset)
// Both are nil until zapp_ios_sidebar_set_content_webview (or
// zapp_ios_sidebar_register_leading_constraints from inspector.m) populates them.
@property (nonatomic, weak)   WKWebView* contentWebview; // weak — sidebar doesn't own it
@property (nonatomic, strong) NSLayoutConstraint* leadingFull;  // to view.leadingAnchor
@property (nonatomic, strong) NSLayoutConstraint* leadingSafe;  // to safeAreaLayoutGuide.leadingAnchor
@end

// Forward declaration — defined later (Content-webview leading constraint
// management section) but called from the ZappIOSSplitViewController trait/
// transition overrides above its definition.
static void zapp_ios_update_content_leading(ZappIOSSidebarController* c);

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

// window_ptr -> content UINavigationController (for the toolbar to reach
// contentVC.navigationItem). Returns nil for no-sidebar windows.
// Declared extern in ios/toolbar.m.
UINavigationController* zapp_ios_content_nav_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_sidebars) return nil;
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappIOSSidebarController* c = zapp_ios_sidebars[key];
    return c ? c.contentNav : nil;
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
    // Re-apply the tile presentation pair if configured. For automatic/overlay,
    // UIKit handles the split natively.
    // Key off the INCOMING size, not the current trait — size is authoritative
    // during rotation/multitasking (traitCollection hasn't updated yet).
    // A regular-width iPad in portrait is still regular; just check size class
    // by inference: any width above 768 pt is safely regular on modern iPads.
    // For robustness, also check the trait collection when available.
    UITraitCollection* tc = self.traitCollection;
    BOOL willBeRegular = (size.width >= 768.0)
        || (tc.horizontalSizeClass == UIUserInterfaceSizeClassRegular);
    // Run the re-apply + leading-constraint update inside the transition
    // coordinator's animation batch so the split resolves atomically with the
    // rotation / multitasking resize (WWDC10105 "Build for iPad" recipe).
    // The completion block fires after traitCollection is final — update the
    // content webview's leading constraint (safeArea vs full-bleed) there.
    if (coordinator) {
        BOOL applyTile = [mode isEqualToString:@"tile"] && willBeRegular;
        NSString* modeCopy = applyTile ? [mode copy] : nil;
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            (void)ctx;
            if (modeCopy) zapp_ios_apply_presentation(self, modeCopy);
        } completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            (void)ctx;
            // traitCollection is final after the transition — update leading.
            zapp_ios_update_content_leading(c);
        }];
    } else {
        if ([mode isEqualToString:@"tile"] && willBeRegular) {
            zapp_ios_apply_presentation(self, mode);
        }
        zapp_ios_update_content_leading(c);
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
    if ([mode isEqualToString:@"tile"] &&
        self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) {
        zapp_ios_apply_presentation(self, mode);
    }
    // Always update the content webview's leading constraint — the horizontal
    // size class may have changed (e.g. multitasking → full-screen or vice-versa).
    zapp_ios_update_content_leading(c);
    // App-level THEME_CHANGED (deduped in the helper — safe to call on any
    // trait change; only a real light/dark switch dispatches).
    extern void zapp_ios_dispatch_theme_if_changed(void);
    zapp_ios_dispatch_theme_if_changed();
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
                               const char* presentation,
                               int32_t width, int32_t minWidth, int32_t maxWidth,
                               bool resizable, bool collapsible) {
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
        // Store configured width/min/max and resizable so setWidth and
        // setResizable can reference them without the deferred struct.
        c.configuredWidth    = width;
        c.configuredMinWidth = minWidth;
        c.configuredMaxWidth = maxWidth;
        c.resizable          = (BOOL)resizable;
        c.collapsible        = (BOOL)collapsible;

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

        // Fix 2 (create-time): if resizable==false, lock the divider by clamping
        // min==max==width so the user cannot drag-resize the column at launch.
        if (!resizable && width > 0) {
            svc.minimumPrimaryColumnWidth = (CGFloat)width;
            svc.maximumPrimaryColumnWidth = (CGFloat)width;
        }

        // collapsible:false — disable the native swipe-in gesture from launch
        // (macOS parity: collapsible gates only the native affordance). The
        // programmatic API (toggle/collapse/expand) and an app-rendered toggle
        // button still work — the dev owns their UI.
        if (!collapsible) {
            svc.presentsWithGesture = NO;
        }

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

// --- Content-webview leading constraint management ------------------------
//
// On iPad regular width (tile mode) the secondary column's safe-area leading
// inset is the sidebar's width (e.g. 310 pt). Without this fix the content
// webview's leading edge was anchored to the container's leading edge (which
// is the window edge), so the webview slid UNDER the sidebar.
//
// Fix: maintain two stored leading constraints on the sidebar controller and
// swap the active one based on horizontalSizeClass:
//   - Regular (iPad tile) → safeAreaLayoutGuide.leadingAnchor (respects sidebar inset)
//   - Compact (iPhone)    → view.leadingAnchor (full-bleed, no inset)
//
// This helper is called from:
//   1. zapp_ios_sidebar_set_content_webview (initial setup, no-inspector path)
//   2. zapp_ios_sidebar_register_leading_constraints (inspector.m handoff)
//   3. ZappIOSSplitViewController traitCollectionDidChange: (trait changes)
//   4. ZappIOSSplitViewController viewWillTransitionToSize: completion (rotation/multitasking)

static void zapp_ios_update_content_leading(ZappIOSSidebarController* c) {
    if (!c || !c.leadingFull || !c.leadingSafe) return;
    if (!c.splitVC) return;
    BOOL isRegular = (c.splitVC.traitCollection.horizontalSizeClass
                      == UIUserInterfaceSizeClassRegular);
    if (isRegular) {
        c.leadingFull.active = NO;
        c.leadingSafe.active = YES;
    } else {
        c.leadingSafe.active = NO;
        c.leadingFull.active = YES;
    }
    // Force layout so the change takes effect immediately.
    [c.contentVC.view setNeedsLayout];
    [c.contentVC.view layoutIfNeeded];
}

// Called from window.m immediately after the content webview is created (no-
// inspector window). Converts the webview from autoresizingMask to explicit
// Auto Layout, pins top/bottom/trailing to the container view, and stores the
// two conditional leading constraints. The correct one is activated right away.
//
// When an inspector is ALSO present, inspector.m calls darwin_webview_create_ext
// for the content webview BEFORE zapp_ios_inspector_register runs, so this
// function runs first (autoresizingMask → AutoLayout conversion + top/bottom/
// trailing pinning). Inspector.m then hands its own leading constraints to
// zapp_ios_sidebar_register_leading_constraints, which replaces the ones set
// here with the inspector-trailing-aware ones.
void zapp_ios_sidebar_set_content_webview(void* window, void* webview_ptr) {
    if (!window || !webview_ptr) return;
    zapp_ios_sidebar_on_main(^{
        if (!zapp_ios_sidebars) return;
        NSValue* key = [NSValue valueWithPointer:window];
        ZappIOSSidebarController* c = zapp_ios_sidebars[key];
        if (!c || !c.contentVC) return;

        WKWebView* wv = (__bridge WKWebView*)webview_ptr;
        UIView* container = c.contentVC.view;

        c.contentWebview = wv;

        // Switch from autoresizingMask (set by webview.m) to explicit Auto Layout.
        wv.translatesAutoresizingMaskIntoConstraints = NO;

        // Build both leading constraints — only one will be active at a time.
        NSLayoutConstraint* full =
            [wv.leadingAnchor constraintEqualToAnchor:container.leadingAnchor];
        NSLayoutConstraint* safe =
            [wv.leadingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor];

        // Pin top / bottom / trailing to the container edges (not safe-area).
        // Top and bottom must stay full-frame: on iPhone the entire content VC
        // is the visible surface and we don't want top/bottom insets.
        // Trailing stays at view.trailingAnchor — inspector.m will later
        // replace this constraint if an inspector is registered.
        [NSLayoutConstraint activateConstraints:@[
            [wv.topAnchor constraintEqualToAnchor:container.topAnchor],
            [wv.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
            [wv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        ]];

        c.leadingFull = full;
        c.leadingSafe = safe;

        // Activate the correct leading constraint for the current trait.
        zapp_ios_update_content_leading(c);
    });
}

// Called from inspector.m (zapp_ios_inspector_register) after it builds its
// own leading constraints. Inspector.m creates the full/safe pair with the
// trailing already anchored to the inspector pane's leading — it hands the
// pair here so the sidebar controller can swap them on trait changes.
// The caller is responsible for having already deactivated any previous
// leading constraints and activated the initial correct one.
void zapp_ios_sidebar_register_leading_constraints(void* window,
                                                   void* fullConstraint,
                                                   void* safeConstraint) {
    if (!window || !fullConstraint || !safeConstraint) return;
    zapp_ios_sidebar_on_main(^{
        if (!zapp_ios_sidebars) return;
        NSValue* key = [NSValue valueWithPointer:window];
        ZappIOSSidebarController* c = zapp_ios_sidebars[key];
        if (!c) return;
        c.leadingFull = (__bridge NSLayoutConstraint*)fullConstraint;
        c.leadingSafe = (__bridge NSLayoutConstraint*)safeConstraint;
        // The caller already activated the initial correct one; no update needed.
    });
}

// --- Control ops (router entry points) ------------------------------------
//
// All keyed by a transport slot (host OR sidebar pane); zapp_ios_sidebar_for_slot
// resolves either to the host record.

// Reveal the CONTENT (hide the sidebar). compact(iPhone): existing nav move.
// regular(iPad) overlay: dismiss the flyout. regular(iPad) tile/automatic: NO-OP —
// when the split is showing both columns side-by-side (tiled), the content is
// ALREADY visible; collapsing the sidebar here would break the tiled layout on
// every route change that calls showContent().
//
// Guard: only collapse when compact (iPhone / narrow multitasking) OR the
// configured presentation is "overlay". "automatic" on a regular-width iPad
// also tiles the sidebar (Mail/Notes behaviour), so do NOT gate on presentation
// alone — gate on "compact OR overlay" so automatic-tiled is correctly a no-op.
void darwin_sidebar_show_content(int32_t window_id) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        BOOL compact  = zapp_ios_sidebar_is_compact(c);
        BOOL isOverlay = [c.presentation isEqualToString:@"overlay"];
        // On regular width with a tiled sidebar (automatic or tile presentation),
        // showContent is a no-op — the content is always visible beside the sidebar.
        if (!compact && !isOverlay) {
            // Both panes are side-by-side; content is already visible. No collapse.
            return;
        }
        if (@available(iOS 16.0, *)) {
            if (compact) {
                [c.splitVC showColumn:UISplitViewControllerColumnSecondary];
                // The split may have been created already-collapsed on iPhone, so
                // splitViewControllerDidCollapse: (which normally re-arms the
                // swipe-back gesture) may never have fired. Re-arm defensively now
                // that a content VC is on the stack.
                zapp_ios_sidebar_rearm_pop(c);
            } else {
                // overlay on regular: dismiss the flyout
                [c.splitVC hideColumn:UISplitViewControllerColumnPrimary];
            }
        } else if (compact) {
            UINavigationController* nav = c.collapsedNav ?: zapp_ios_collapsed_nav(c.splitVC);
            if (nav && c.contentVC && nav.topViewController != c.contentVC)
                [nav pushViewController:c.contentVC animated:YES];
            zapp_ios_sidebar_rearm_pop(c);  // defensive re-arm (see above)
        } else {
            // overlay on pre-iOS16 regular: collapse via displayMode
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

// Toggle which column is shown. On compact (iPhone): push/pop via show_* helpers
// (existing behaviour). On regular/tiled (iPad): bypass show_content's no-op
// guard and operate DIRECTLY on the primary column — this is the explicit user
// affordance (toolbar toggle) and MUST collapse/expand a tiled sidebar.
// collapsible:false only gates the NATIVE edge-swipe gesture (presentsWithGesture);
// the programmatic toggle (API + app ☰ button) still works — matching macOS parity.
void darwin_sidebar_toggle(int32_t window_id) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;

        if (c.splitVC.isCollapsed) {
            // COMPACT (iPhone): keep existing push/pop behaviour via the
            // show_* helpers. lastCollapsedEmit YES == sidebar hidden.
            BOOL sidebarVisible = !c.lastCollapsedEmit;
            if (sidebarVisible) darwin_sidebar_show_content(window_id);
            else                darwin_sidebar_show_sidebar(window_id);
            return;
        }

        // REGULAR (iPad) — direct primary-column collapse/expand, bypassing the
        // show_content no-op guard that protects route-navigation from collapsing
        // a tiled sidebar. Toggle is the *explicit* affordance and MUST act.
        //
        // Detect current shown state from the LIVE displayMode:
        //   SecondaryOnly → sidebar is hidden (collapsed away).
        //   Anything else → sidebar is visible (tiled beside content, or overlay).
        BOOL sidebarHidden = (c.splitVC.displayMode == UISplitViewControllerDisplayModeSecondaryOnly);

        if (!sidebarHidden) {
            // Sidebar currently visible → COLLAPSE it (hide primary column).
            if (@available(iOS 16.0, *)) {
                [c.splitVC hideColumn:UISplitViewControllerColumnPrimary];
            } else {
                c.splitVC.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
            }
            zapp_ios_sidebar_sync_collapse(c, YES);
        } else {
            // Sidebar currently hidden → EXPAND it (show primary column).
            //
            // For overlay presentation: showColumn:Primary summons the flyout
            // directly. Do NOT call zapp_ios_apply_presentation after this —
            // the overlay helper sets preferredDisplayMode=SecondaryOnly, which
            // would immediately re-hide the column we just summoned.
            //
            // For tile/automatic: showColumn:Primary then re-apply the stored
            // presentation pair so the column returns to side-by-side mode
            // (not just a transient show). The tile path also calls
            // showColumn:Primary internally to clear any outstanding hideColumn
            // override, making the explicit call here redundant but harmless.
            if (@available(iOS 16.0, *)) {
                [c.splitVC showColumn:UISplitViewControllerColumnPrimary];
            } else {
                c.splitVC.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
            }
            // Only re-apply the presentation pair for tile/automatic; for
            // overlay, showColumn:Primary alone summons the flyout and re-
            // applying would undo it.
            if (![c.presentation isEqualToString:@"overlay"]) {
                zapp_ios_apply_presentation(c.splitVC, c.presentation);
            }
            zapp_ios_sidebar_sync_collapse(c, NO);
        }
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

// Set the sidebar width programmatically.
//
// OWNERSHIP MODEL (verified on-device via instrumentation, iOS 26):
//
// UISplitViewController stores a PRIVATE "user-drag" column width once the user
// drags the divider on a regular-width iPad. That private cache overrides
// preferredPrimaryColumnWidth on every layout while min/max are flexible, and
// there is NO public API to clear it: it is NOT preferredPrimaryColumnWidthFraction
// (instrumentation showed that property stays at its automatic sentinel through a
// drag), and toggling displayMode / splitBehavior does not evict it either. The
// only things that beat the pin are (a) locking min==max (which disables dragging)
// or (b) detaching the column VC (which resets the WKWebView content process and
// kills the JS bridge — unacceptable). So setWidth follows an ownership model:
//
//   resizable:false — APP-OWNED width. We lock min==max==width, which is
//     authoritative (no drag possible, no pin can form). setWidth always works.
//   resizable:true  — USER-OWNED width. setWidth sets the initial/preferred width
//     and applies until the user manually drags; after a drag the user's width is
//     sticky and setWidth is a no-op (UIKit exposes no safe override). Documented
//     in docs/api-reference.md.
//   compact (iPhone) — single-column; no drag pin. preferredPrimaryColumnWidth
//     takes effect when the split expands to regular width.
void darwin_sidebar_set_width(int32_t window_id, int32_t width) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;

        // Always store the configured width. Emit happens per-branch below
        // (resizable:ON+regular uses the clamped value; all others use width).
        c.configuredWidth = (int32_t)width;

        if (width <= 0) {
            zapp_ios_sidebar_emit_resize(c, width);
            return;
        }

        if (!c.resizable) {
            // Resizable:OFF — lock the column by clamping min==max==width.
            // This is the authoritative "frozen" path: no drag is possible so
            // no drag pin can form; clamping is sufficient and correct.
            c.splitVC.preferredPrimaryColumnWidth = (CGFloat)width;
            c.splitVC.minimumPrimaryColumnWidth = (CGFloat)width;
            c.splitVC.maximumPrimaryColumnWidth = (CGFloat)width;
            [c.splitVC.view setNeedsLayout];
            [c.splitVC.view layoutIfNeeded];
            // Leave min==max==width — column stays locked (no restore needed).
            zapp_ios_sidebar_emit_resize(c, width);
        } else {
            // Resizable:ON — USER-OWNED width. Set the preferred width: it applies
            // before any user drag (and on compact, once the split expands to
            // regular width). After a manual divider drag, UIKit's private drag-pin
            // overrides this on every layout and there is no safe public way to
            // clear it (see the header comment), so this is a harmless no-op once
            // the user has dragged.
            c.splitVC.preferredPrimaryColumnWidth = (CGFloat)width;
            [c.splitVC.view setNeedsLayout];
            [c.splitVC.view layoutIfNeeded];
            zapp_ios_sidebar_emit_resize(c, width);
        }
    });
}

// Enable or disable sidebar collapsing (macOS parity: gates only the native
// affordance, not the programmatic API). When can_collapse==false:
//   • presentsWithGesture is set to NO so the native swipe-in gesture is disabled.
//   • darwin_sidebar_toggle / collapse / expand STILL work — the app's own
//     toggle button calls those and the dev owns their UI.
// When can_collapse==true, presentsWithGesture is restored to YES.
void darwin_sidebar_set_collapsible(int32_t window_id, bool can_collapse) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        c.collapsible = (BOOL)can_collapse;
        c.splitVC.presentsWithGesture = (BOOL)can_collapse;
    });
}

// Lock or unlock the divider drag. When resizable==false, clamp
// minimumPrimaryColumnWidth == maximumPrimaryColumnWidth == configured width so
// the user cannot drag-resize the sidebar column. When resizable==true, restore
// the configured min/max so the user can drag freely within those bounds.
void darwin_sidebar_set_resizable(int32_t window_id, bool resizable) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        c.resizable = (BOOL)resizable;
        if (!resizable) {
            // Lock: clamp both ends to the LIVE current column width so the
            // sidebar freezes at whatever width it currently shows — including
            // any width the user reached by dragging the divider (a drag never
            // updates configuredWidth, so clamping to configuredWidth would snap
            // the sidebar to a stale value).
            //
            // Read the live width from the sidebarNav's view bounds (the actual
            // primary-column container laid out to the column width). Fall back
            // to configuredWidth (pre-layout / zero-bounds), then to
            // preferredPrimaryColumnWidth as a last resort.
            CGFloat liveWidth = c.sidebarNav.view.bounds.size.width;
            CGFloat lockWidth = (liveWidth > 0.0)
                ? liveWidth
                : ((c.configuredWidth > 0)
                    ? (CGFloat)c.configuredWidth
                    : c.splitVC.preferredPrimaryColumnWidth);
            // Guard: never clamp to 0 (would collapse the column to nothing if
            // called before first layout with no configured width).
            if (lockWidth > 0.0) {
                c.splitVC.minimumPrimaryColumnWidth = lockWidth;
                c.splitVC.maximumPrimaryColumnWidth = lockWidth;
            }
        } else {
            // Restore configured min/max (0 means "use system default").
            c.splitVC.minimumPrimaryColumnWidth = (c.configuredMinWidth > 0)
                ? (CGFloat)c.configuredMinWidth : 0.0;
            c.splitVC.maximumPrimaryColumnWidth = (c.configuredMaxWidth > 0)
                ? (CGFloat)c.configuredMaxWidth : CGFLOAT_MAX;
        }
    });
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
