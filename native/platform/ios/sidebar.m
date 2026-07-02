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
#include <stdbool.h>
#include <math.h>
#include <stdio.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
extern int32_t zapp_ios_inspector_slot_for(int32_t host_slot);

// Defined in ios/inspector.m — the single iOS-26 source for the
// inspector-expanded/-collapsed emits (and the auto-sheet Close/grabber
// affordances). Called from the splitViewController:didShowColumn:/
// didHideColumn: delegate hooks below whenever the split's Inspector column
// visibility changes, keyed by the host UIWindow (the inspector registry key).
extern void zapp_ios_inspector_column_did_show(void* window);
extern void zapp_ios_inspector_column_did_hide(void* window);

// Defined in ios/toolbar.m — applies a set toolbar to the correct nav after
// a collapse/expand transition. No-op when no toolbar has been registered.
extern void zapp_ios_toolbar_apply_for_window(void* window_ptr);

// Defined in ios/toolbar.m — applies with an explicit sidebarHidden state
// (the transition TARGET) so willChangeToDisplayMode: can drive the toggle change
// synchronously within the animation instead of one tick after.
extern void zapp_ios_toolbar_apply_for_window_hidden(void* window_ptr, BOOL sidebarHidden);

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
// Live divider-drag resize emits (#720). lastLayoutEmitWidth dedupes on the
// rounded width reported by ZappIOSPaneViewController.viewDidLayoutSubviews;
// seeded to the configured width at register so the first (launch) layout
// pass — which lands at that same width — emits nothing. layoutEmitScheduled
// coalesces the per-frame layout callbacks (a seam drag fires this every
// frame) down to at most one emit per runloop tick.
@property (nonatomic, assign) int32_t lastLayoutEmitWidth;
@property (nonatomic, assign) BOOL layoutEmitScheduled;
@property (nonatomic, assign) int32_t configuredWidth;    // configured width (setWidth + create-time)
@property (nonatomic, assign) int32_t configuredMinWidth; // configured minimumPrimaryColumnWidth
@property (nonatomic, assign) int32_t configuredMaxWidth; // configured maximumPrimaryColumnWidth
@property (nonatomic, assign) BOOL resizable;             // whether drag-resize is allowed
@property (nonatomic, assign) BOOL collapsible;           // whether the sidebar can be collapsed
// Source of truth for the current presentation mode. Set at register time from
// the create-time config (via zapp_ios_apply_presentation) and updated by
// darwin_sidebar_set_presentation. Values: nil/"" = automatic, "tile", "overlay".
@property (nonatomic, copy) NSString* presentation;
// Content-webview edge constraint management.
// Two stored constraint PAIRS (leading + trailing) — in each pair only one is
// active at a time, swapped on trait change:
//   leadingFull  → content webview leading  = contentVC.view.leadingAnchor
//   trailingFull → content webview trailing = contentVC.view.trailingAnchor
//                  (compact / iPhone — full-bleed, no pane insets)
//   leadingSafe  → content webview leading  = contentVC.view.safeAreaLayoutGuide.leadingAnchor
//   trailingSafe → content webview trailing = contentVC.view.safeAreaLayoutGuide.trailingAnchor
//                  (regular / iPad — respects the sidebar's leading and the
//                   iOS-26 Inspector column's trailing safe-area insets)
// All four are nil until zapp_ios_sidebar_set_content_webview populates them.
@property (nonatomic, weak)   WKWebView* contentWebview; // weak — sidebar doesn't own it
@property (nonatomic, strong) NSLayoutConstraint* leadingFull;   // to view.leadingAnchor
@property (nonatomic, strong) NSLayoutConstraint* leadingSafe;   // to safeAreaLayoutGuide.leadingAnchor
@property (nonatomic, strong) NSLayoutConstraint* trailingFull;  // to view.trailingAnchor
@property (nonatomic, strong) NSLayoutConstraint* trailingSafe;  // to safeAreaLayoutGuide.trailingAnchor
@end

// Forward declaration — defined later (Content-webview edge constraint
// management section) but called from the ZappIOSSplitViewController trait/
// transition overrides above its definition.
static void zapp_ios_update_content_edges(ZappIOSSidebarController* c);

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
//
// Always doubleColumn now (no tripleColumn) — content is the permanent
// Secondary column; the iOS-26 Inspector column is a separate, orthogonal
// column that this helper does NOT govern (see ios/inspector.m).
//
// #721: the pair assignment is wrapped in a UIView animation block so UIKit
// animates the tile<->overlay column transition instead of snapping cold
// (the human smoke: "overlay = instant disappear, no animation"). The
// iOS16+ showColumn:Primary tile-recipe call below stays OUTSIDE that block,
// exactly where it sat before this change — showColumn:/hideColumn: are
// already animated by UIKit itself, so nesting that call inside our block
// too would double-animate the same transition.
static void zapp_ios_apply_presentation(UISplitViewController* svc, NSString* mode) {
    if (!svc) return;
    BOOL isTile = [mode isEqualToString:@"tile"];
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        if ([mode isEqualToString:@"overlay"]) {
            svc.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
            svc.preferredDisplayMode  = UISplitViewControllerDisplayModeSecondaryOnly;
        } else if (isTile) {
            // WWDC canonical tile recipe: both flags, applied together.
            svc.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
            svc.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        } else {
            // "automatic" / nil / empty — let UIKit adapt (tile-landscape,
            // overlay-portrait, collapse-compact). This is the Mail/Notes default.
            svc.preferredSplitBehavior = UISplitViewControllerSplitBehaviorAutomatic;
            svc.preferredDisplayMode = UISplitViewControllerDisplayModeAutomatic;
        }
        [svc.view layoutIfNeeded];
    } completion:nil];
    if (isTile) {
        // iOS 16+: showColumn:Primary clears any outstanding hideColumn override
        // so the primary column is forced BESIDE the secondary (true tile). Without
        // this, if the split's resolved column state is "primary hidden" (e.g. the
        // overlay/summon state), UIKit ignores preferredDisplayMode and the sidebar
        // stays an overlay regardless of the behavior/displayMode pair. Kept OUTSIDE
        // the animation block above (#721) — see the header comment.
        if (@available(iOS 16.0, *)) {
            [svc showColumn:UISplitViewControllerColumnPrimary];
        }
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

// window_ptr -> the content UIViewController stored at registration time.
// Returns the authoritative contentVC (not inferred from nav stack), so the
// toolbar can target contentVC.navigationItem even when UIKit has orphaned
// contentNav in the combined collapsed stack. Nil for no-sidebar/unregistered.
// Declared extern in ios/toolbar.m.
UIViewController* zapp_ios_content_vc_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_sidebars) return nil;
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappIOSSidebarController* c = zapp_ios_sidebars[key];
    return c ? c.contentVC : nil;
}

// window_ptr -> the combined collapsed UINavigationController captured by
// splitViewControllerDidCollapse:. Nil when not yet collapsed or no sidebar.
// Declared extern in ios/toolbar.m.
UINavigationController* zapp_ios_collapsed_nav_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_sidebars) return nil;
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappIOSSidebarController* c = zapp_ios_sidebars[key];
    return c ? c.collapsedNav : nil;
}

// Returns YES when the split is currently collapsed to a single column
// (c.splitVC.isCollapsed). NO when expanded or no sidebar.
// Declared extern in ios/toolbar.m.
BOOL zapp_ios_split_is_collapsed_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_sidebars) return NO;
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappIOSSidebarController* c = zapp_ios_sidebars[key];
    return c ? c.splitVC.isCollapsed : NO;
}

// Returns YES when the sidebar is HIDDEN on iPad (displayMode == SecondaryOnly).
// Returns NO for: collapsed (iPhone), no sidebar, sidebar visible.
// On iPad, hiding the sidebar is a displayMode change — the split is never
// isCollapsed on regular width. This distinguishes "visible" from "hidden" on
// the expanded path so the toolbar can include/omit the manual toggle correctly.
// Declared extern in ios/toolbar.m.
BOOL zapp_ios_sidebar_is_hidden_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_sidebars) return NO;
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappIOSSidebarController* c = zapp_ios_sidebars[key];
    if (!c || !c.splitVC) return NO;
    // Never collapsed on iPad regular width; isCollapsed == YES means compact/iPhone,
    // where "hidden" has no meaning (the sidebar is the nav root, not a column).
    if (c.splitVC.isCollapsed) return NO;
    return c.splitVC.displayMode == UISplitViewControllerDisplayModeSecondaryOnly;
}

// T2 (double-toggle race fix): live read of the split's CURRENT displayMode —
// NOT a transition target. Returns true only when displayMode ==
// SecondaryOnly (sidebar hidden); false when no controller/split is
// registered. Unlike zapp_ios_sidebar_is_hidden_for_window, this omits the
// isCollapsed gate: its only caller (zapp_ios_toolbar_apply_for_window_hidden's
// expanded path, ios/toolbar.m) has already established collapsed == NO
// before calling, so the extra branch would be dead weight here.
//
// This is the single source of truth the toolbar's expanded path reads AT
// APPLY TIME to decide whether to include the manual toggleSidebar button —
// replacing a caller-supplied `sidebarHidden` BOOL that could be a stale
// transition TARGET (from willChangeToDisplayMode:, fired before the mode
// change commits) and let both Zapp's toggle and UIKit's system reveal
// button render simultaneously, or neither, under overlapping transitions.
// Declared extern in ios/toolbar.m.
bool zapp_ios_split_display_mode_is_secondary_only(void* window_ptr) {
    if (!window_ptr || !zapp_ios_sidebars) return false;
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappIOSSidebarController* c = zapp_ios_sidebars[key];
    if (!c || !c.splitVC) return false;
    return c.splitVC.displayMode == UISplitViewControllerDisplayModeSecondaryOnly;
}

// Toolbar affordance query: is the sidebar user-collapsible? Live read taken
// at toolbar-apply time (same pattern as the displayMode read above) — drives
// the ENABLED state of Zapp's manual toggleSidebar bar button (ios/toolbar.m).
// macOS parity: AppKit auto-greys its system NSToolbarToggleSidebarItem when
// NSSplitViewItem.canCollapse == NO (darwin/sidebar.m revalidates on
// set_collapsible); UIKit has no validation pass, so the toolbar reads this
// helper and sets `enabled` manually. Returns true when no sidebar is
// registered for the window — a sidebar-less window has no toggle to gate
// anyway (the TS runtime drops toggleSidebar items for windows without a
// sidebar, runtime/window.ts), so the default is a harmless "nothing to
// disable". Declared extern in ios/toolbar.m.
bool zapp_ios_sidebar_is_collapsible_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_sidebars) return true;
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappIOSSidebarController* c = zapp_ios_sidebars[key];
    return c ? (bool)c.collapsible : true;
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

// Live divider-drag resize emits (#720). viewDidLayoutSubviews fires per
// frame during a seam drag (probe-proven); this coalesces to at most one
// emit per runloop tick and dedupes on the rounded width. Guards: no split /
// collapsed(compact) / hidden pane / width<=1 (collapse-expand transitions)
// emit nothing — this reports regular-width divider geometry only. Called
// from window.m's ZappIOSPaneViewController.viewDidLayoutSubviews (paneRole 1).
void zapp_ios_sidebar_note_layout_width(void* window_ptr, CGFloat width) {
    if (!window_ptr || !zapp_ios_sidebars) return;
    ZappIOSSidebarController* c = zapp_ios_sidebars[[NSValue valueWithPointer:window_ptr]];
    if (!c || !c.splitVC || c.splitVC.isCollapsed) return;
    // Hidden-pane guard (iPad-regular, sidebar hidden via displayMode
    // SecondaryOnly): the primary column still lays out off-screen at its
    // last width, which would otherwise read as a phantom resize. Plain
    // iOS-14 API — no availability gate needed at Zapp's 15.0 minimum.
    if (c.splitVC.displayMode == UISplitViewControllerDisplayModeSecondaryOnly) return;
    int32_t w = (int32_t)lround(width);
    // M1: unconfigured sidebar (registered with width<=0, seeded to the -2
    // sentinel below) — absorb the FIRST observed REAL layout width (w>1) as
    // the seed instead of treating it as a real resize, so landing at UIKit's
    // default column width doesn't fire a spurious launch emit. A degenerate
    // 0/1-width first layout must NOT be absorbed — it falls through to the
    // w<=1 guard below and leaves the sentinel in place, so the next real
    // width is still absorbed as the seed instead of firing a launch emit.
    if (c.lastLayoutEmitWidth == -2 && w > 1) {
        c.lastLayoutEmitWidth = w;
        return;
    }
    if (w <= 1 || w == c.lastLayoutEmitWidth) return;
    c.lastLayoutEmitWidth = w;
    if (c.layoutEmitScheduled) return;
    c.layoutEmitScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        c.layoutEmitScheduled = NO;
        zapp_ios_sidebar_emit_resize(c, c.lastLayoutEmitWidth);
    });
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
    // Run the re-apply + edge-constraint update inside the transition
    // coordinator's animation batch so the split resolves atomically with the
    // rotation / multitasking resize (WWDC10105 "Build for iPad" recipe).
    // The completion block fires after traitCollection is final — update the
    // content webview's leading/trailing constraints (safeArea vs full-bleed)
    // there.
    if (coordinator) {
        BOOL applyTile = [mode isEqualToString:@"tile"] && willBeRegular;
        NSString* modeCopy = applyTile ? [mode copy] : nil;
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            (void)ctx;
            if (modeCopy) zapp_ios_apply_presentation(self, modeCopy);
        } completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            (void)ctx;
            // traitCollection is final after the transition — update edges.
            zapp_ios_update_content_edges(c);
        }];
    } else {
        if ([mode isEqualToString:@"tile"] && willBeRegular) {
            zapp_ios_apply_presentation(self, mode);
        }
        zapp_ios_update_content_edges(c);
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
    // Always update the content webview's edge constraints — the horizontal
    // size class may have changed (e.g. multitasking → full-screen or vice-versa).
    zapp_ios_update_content_edges(c);
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
// (sidebar visible). Capture the combined nav controller UIKit built.
// If no toolbar has been registered, force its bar hidden (chrome-less default).
// If a toolbar IS registered, call zapp_ios_toolbar_apply_for_window —
// it will show the bar on collapsedNav only when the content VC is on top.
- (void)splitViewControllerDidCollapse:(UISplitViewController*)svc {
    UINavigationController* nav = zapp_ios_collapsed_nav(svc);
    if (nav) {
        self.collapsedNav = nav;
        // The hidden nav bar disables UIKit's interactive-pop gesture; re-arm it
        // so chrome-less still gets edge-swipe-back. Our delegate gates it to
        // "only when there's something to pop" (avoids a no-op swipe at root).
        zapp_ios_sidebar_rearm_pop(self);
    }
    // Install the route-nav delegate on the collapsed nav so that
    // willShowViewController: fires when UIKit shows the content VC (e.g. via
    // showColumn:Supplementary). Without this, the delegate only installs on the
    // first route push, so the content toolbar bar would be invisible until then.
    if (nav) {
        extern void zapp_ios_route_install_nav_delegate(UINavigationController* nav, int32_t windowId);
        zapp_ios_route_install_nav_delegate(nav, (int32_t)self.hostWindowId);
        // Explicitly show the collapsed nav's bar so the content toolbar is
        // visible from launch on iPhone without waiting for a route push.
        // UIKit combines the two column nav controllers into one collapsed stack
        // whose bar starts hidden (inherited from sidebarNav's hidden=YES); the
        // willShowViewController: delegate is the ongoing authority for per-route
        // transitions but does NOT fire for the already-visible content VC at
        // initial collapse, so we prime the bar here. The delegate's idempotency
        // guard means a later willShow call on the same state is a no-op.
        [nav setNavigationBarHidden:NO animated:NO];
    }
    // [zapp-nav] diagnostic: log didCollapse — captures the combined nav pointer
    fprintf(stderr, "[zapp-nav] didCollapse win=%d collapsedNav=%p stack=%lu\n",
            (int)self.hostWindowId, (__bridge void*)nav,
            nav ? (unsigned long)nav.viewControllers.count : 0UL);
    fflush(stderr);
    zapp_ios_sidebar_sync_collapse(self, NO);
    // Re-apply any registered toolbar to the now-captured collapsedNav.
    // Must happen AFTER self.collapsedNav is set so the toolbar can reach it.
    void* winPtr = (__bridge void*)self.splitVC.view.window;
    if (winPtr) zapp_ios_toolbar_apply_for_window(winPtr);
}

- (void)splitViewControllerDidExpand:(UISplitViewController*)svc {
    (void)svc;
    // Back to side-by-side: both panes visible → expanded.
    zapp_ios_sidebar_sync_collapse(self, NO);
    // Re-apply any registered toolbar to contentNav now that the split is
    // expanded. Also removes the nav delegate from the old collapsedNav.
    void* winPtr = (__bridge void*)self.splitVC.view.window;
    if (winPtr) zapp_ios_toolbar_apply_for_window(winPtr);
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

// Re-apply the toolbar when the split's displayMode changes (iPad only).
// The toolbar's expanded path must include our manual toggleSidebar when the
// sidebar is VISIBLE (displayMode != SecondaryOnly) and OMIT it when the
// sidebar is HIDDEN (displayMode == SecondaryOnly — UIKit shows its own system
// button at that point). Without this hook, the toolbar never updates after the
// user shows/hides the sidebar via our button, the system button, or a gesture.
//
// TWO applies, for two different jobs (T2 double-toggle race fix):
//   1. SYNCHRONOUS pre-settle apply, passing `displayMode` as a (now
//      advisory-only) hint. UIKit calls this delegate BEFORE it commits the
//      change, so splitVC.displayMode is still the OUTGOING value at this
//      point — the toolbar's live read (zapp_ios_split_display_mode_is_
//      secondary_only, ios/toolbar.m) would just reproduce the pre-transition
//      toggle here. Calling synchronously (already on the main thread) means
//      whatever the toolbar renders rides the SAME animation as the sidebar
//      show/hide, avoiding the "wonky snap" a delayed apply produces.
//   2. SETTLED re-apply, hopped one tick via dispatch_async. By the time this
//      runs, splitVC.displayMode has committed to the target, so the
//      toolbar's live read resolves to the correct final state. This is the
//      actual race fix: under overlapping transitions (rapid toggle, rotation
//      mid-toggle) a stale `displayMode`/target value could leave BOTH
//      toggles visible or NEITHER once things settled; because the decision
//      is now made from live state at APPLY time (not the target captured at
//      SCHEDULE time), whichever settled re-apply runs last always reads
//      whatever is CURRENTLY true and self-corrects, regardless of dispatch
//      ordering between overlapping transitions.
//
// NOTE: do NOT emit sidebar-visibility events from here. The imperative toggle
// path (darwin_sidebar_toggle / show_content / show_sidebar) owns those emits
// via zapp_ios_sidebar_sync_collapse — emitting here would double-fire.
- (void)splitViewController:(UISplitViewController*)svc
    willChangeToDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    (void)svc;
    // Resolve the window pointer that zapp_ios_toolbar_apply_for_window_hidden
    // expects.
    void* winPtr = darwin_window_get_by_numeric_id(self.hostWindowId);
    if (!winPtr) return;
    // Compute the target hidden state from the incoming displayMode parameter.
    // SecondaryOnly means the primary (sidebar) column will be hidden after the
    // transition. This value is now advisory only (pre-settle hint) — the
    // expanded toolbar path re-derives the real answer from live state; see
    // the header comment above and zapp_ios_toolbar_apply_for_window_hidden.
    BOOL targetHidden = (displayMode == UISplitViewControllerDisplayModeSecondaryOnly);
    // 1. Pre-settle apply — synchronous, rides the same animation batch.
    zapp_ios_toolbar_apply_for_window_hidden(winPtr, targetHidden);
    // 2. Settled re-apply — one runloop tick later, once displayMode has
    // actually committed, re-derive the toggle from LIVE state. Captures the
    // numeric host id (not the raw pointer) so the lookup is re-resolved
    // fresh at the later tick rather than trusting a possibly-stale pointer.
    int32_t hostWindowId = self.hostWindowId;
    dispatch_async(dispatch_get_main_queue(), ^{
        void* settledWinPtr = darwin_window_get_by_numeric_id(hostWindowId);
        if (settledWinPtr) zapp_ios_toolbar_apply_for_window(settledWinPtr);
    });
}

// iOS 26+: column-level visibility notifications (both delegate methods are
// API_AVAILABLE(ios(26.0)); UIKit never calls them on earlier OSes). The
// Inspector column can show/hide WITHOUT any darwin_inspector_* call — UIKit
// itself dismisses the auto-presented iPhone sheet on swipe — so these hooks
// (not the imperative entry points in ios/inspector.m) are the single source
// of the inspector-expanded/-collapsed emits on the 26+ path. Forward to
// ios/inspector.m keyed by the host UIWindow (darwin_window_get_by_numeric_id
// on the host slot — exactly the pointer the inspector registry is keyed by).
// Non-Inspector columns are ignored: sidebar visibility emits stay owned by
// the imperative sidebar paths (see the willChangeToDisplayMode: note above).
// UISplitViewControllerColumnInspector is itself ios(26.0)-only, so the
// comparison lives inside the @available guard.
- (void)splitViewController:(UISplitViewController*)svc
              didShowColumn:(UISplitViewControllerColumn)column {
    (void)svc;
    if (@available(iOS 26.0, *)) {
        if (column != UISplitViewControllerColumnInspector) return;
        void* winPtr = darwin_window_get_by_numeric_id(self.hostWindowId);
        if (winPtr) zapp_ios_inspector_column_did_show(winPtr);
    }
}

- (void)splitViewController:(UISplitViewController*)svc
              didHideColumn:(UISplitViewControllerColumn)column {
    (void)svc;
    if (@available(iOS 26.0, *)) {
        if (column != UISplitViewControllerColumnInspector) return;
        void* winPtr = darwin_window_get_by_numeric_id(self.hostWindowId);
        if (winPtr) zapp_ios_inspector_column_did_hide(winPtr);
    }
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
        // #720: seed the live-resize dedupe to the configured width so the
        // first (launch) viewDidLayoutSubviews pass — which lands at that same
        // width — does not fire a spurious resize event. M1: when the app
        // omits a sidebar width (width<=0) there's no configured value to
        // seed against — use the -2 sentinel so the note-layout helper
        // absorbs the first observed width instead of comparing against a
        // bogus 0/negative value.
        c.lastLayoutEmitWidth  = (width > 0) ? width : -2;
        c.layoutEmitScheduled  = NO;

        // OWN the navigation controllers so we control the bar. The column VCs
        // are still empty (no webview yet), so this never re-parents a live
        // WKWebView. Sidebar nav: bar hidden (no toolbar). Content nav: bar visible
        // so the toolbar renders at launch without waiting for a route push.
        UINavigationController* sbNav = [[UINavigationController alloc] initWithRootViewController:sbVC];
        sbNav.navigationBarHidden = YES;
        UINavigationController* ctNav = [[UINavigationController alloc] initWithRootViewController:ctVC];
        // Content nav starts bar-VISIBLE: the content pane always carries a toolbar,
        // so its nav bar must be shown at launch (iPad) and whenever content is on
        // top (iPhone/collapsed). ZappRouteNavDelegate's willShowViewController: is
        // the ongoing authority; NO here is the correct initial state for iPad where
        // no VC push fires before the bar is needed.
        ctNav.navigationBarHidden = NO;
        c.sidebarNav = sbNav;
        c.contentNav = ctNav;

        // Re-install the nav-wrapped columns. This REPLACES the bare VCs that
        // window.m set before calling us. The preferred min/max/width values
        // window.m set are preserved on the split (they're not column-VC-scoped).
        // Primary(sidebar) + Secondary(content) only — doubleColumn, always. The
        // iOS-26 Inspector column (if any) is attached separately by window.m's
        // inspector pane block, AFTER this call — it nav-wraps and owns that
        // column itself (see ios/inspector.m), not this function.
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

        // [zapp-nav] diagnostic: register_contentVC — use this pointer to match other log lines
        fprintf(stderr, "[zapp-nav] register_contentVC win=%d contentVC=%p sidebarVC=%p contentNav=%p\n",
                (int)host_id, (__bridge void*)ctVC, (__bridge void*)sbVC, (__bridge void*)ctNav);
        fflush(stderr);
        fprintf(stderr, "[native] iOS sidebar registered: host=%d sidebar=%d presentation=%s\n",
                (int)host_id, (int)sidebar_id,
                presMode.length ? presMode.UTF8String : "automatic");
        fflush(stderr);
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

// --- Content-webview edge constraint management ----------------------------
//
// On iPad regular width UIKit does NOT resize the Secondary column's view for
// tiled siblings — the view stays the full split width and UIKit expresses the
// neighbors as SAFE-AREA INSETS on it: the tiled sidebar as a leading inset
// (e.g. 310 pt) and the iOS-26 Inspector column as a trailing inset (e.g.
// 280 pt). A webview pinned to the raw view edges therefore slides UNDER the
// sidebar (leading) and bleeds UNDER the inspector (trailing).
//
// Fix: maintain two stored constraint pairs (leading + trailing) on the
// sidebar controller and swap the active one in each pair based on
// horizontalSizeClass:
//   - Regular (iPad)   → safeAreaLayoutGuide anchors (track sidebar/inspector insets)
//   - Compact (iPhone) → raw view anchors (full-bleed — device notches create
//                        edge safe insets in landscape that must NOT inset content)
//
// This helper is called from:
//   1. zapp_ios_sidebar_set_content_webview (initial setup)
//   2. ZappIOSSplitViewController traitCollectionDidChange: (trait changes)
//   3. ZappIOSSplitViewController viewWillTransitionToSize: completion (rotation/multitasking)

static void zapp_ios_update_content_edges(ZappIOSSidebarController* c) {
    if (!c || !c.leadingFull || !c.leadingSafe) return;
    if (!c.trailingFull || !c.trailingSafe) return;
    if (!c.splitVC) return;
    BOOL isRegular = (c.splitVC.traitCollection.horizontalSizeClass
                      == UIUserInterfaceSizeClassRegular);
    if (isRegular) {
        c.leadingFull.active = NO;
        c.trailingFull.active = NO;
        c.leadingSafe.active = YES;
        c.trailingSafe.active = YES;
    } else {
        c.leadingSafe.active = NO;
        c.trailingSafe.active = NO;
        c.leadingFull.active = YES;
        c.trailingFull.active = YES;
    }
    // Force layout so the change takes effect immediately.
    [c.contentVC.view setNeedsLayout];
    [c.contentVC.view layoutIfNeeded];
}

// Called from window.m immediately after the content webview is created, for
// every sidebar window (with or without an inspector pane). Converts the
// webview from autoresizingMask to explicit Auto Layout, pins top/bottom to
// the container view, and stores the conditional leading + trailing constraint
// pairs. The correct one in each pair is activated right away.
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

        // Build both edge-constraint pairs — in each pair only one will be
        // active at a time (swapped per size class by
        // zapp_ios_update_content_edges).
        //
        // Why pairs on BOTH horizontal edges: the Secondary column's view stays
        // the full split width; UIKit expresses the tiled sidebar (leading) and
        // the iOS-26 Inspector column (trailing) as safe-area insets on it. The
        // webview tracks those insets via the *Safe constraints on regular
        // width, and uses the raw edges (*Full) on compact for full-bleed
        // content (notch insets must not shrink it).
        NSLayoutConstraint* leadingFull =
            [wv.leadingAnchor constraintEqualToAnchor:container.leadingAnchor];
        NSLayoutConstraint* leadingSafe =
            [wv.leadingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor];
        NSLayoutConstraint* trailingFull =
            [wv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor];
        NSLayoutConstraint* trailingSafe =
            [wv.trailingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor];

        // Pin top / bottom to the container edges (not safe-area). Top and
        // bottom must stay full-frame: on iPhone the entire content VC is the
        // visible surface and we don't want top/bottom insets.
        [NSLayoutConstraint activateConstraints:@[
            [wv.topAnchor constraintEqualToAnchor:container.topAnchor],
            [wv.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        ]];

        c.leadingFull = leadingFull;
        c.leadingSafe = leadingSafe;
        c.trailingFull = trailingFull;
        c.trailingSafe = trailingSafe;

        // Activate the correct leading + trailing constraints for the current
        // trait.
        zapp_ios_update_content_edges(c);
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
        // [zapp-nav] diagnostic: show_content entry — key for lateral section switch (Bug B)
        fprintf(stderr, "[zapp-nav] show_content win=%d contentVC=%p method=%s\n",
                (int)c.hostWindowId, (__bridge void*)c.contentVC,
                compact ? "showColumn(compact)" : (isOverlay ? "hideColumn(overlay)" : "noOp(tile)"));
        fflush(stderr);
        // On regular width with a tiled sidebar (automatic or tile presentation),
        // showContent is a no-op — the content is always visible beside the sidebar.
        if (!compact && !isOverlay) {
            // Both panes are side-by-side; content is already visible. No collapse.
            return;
        }
        if (@available(iOS 16.0, *)) {
            if (compact) {
                // Pop to root FIRST if the content nav has been drilled into a detail
                // view. This prevents the stale-view bug (sticky route / Bug B) where
                // a section-select on a drilled nav leaves the user on the old detail.
                // Mirror the spike (SidebarViewController.m:61-63).
                if (c.contentNav && c.contentNav.viewControllers.count > 1) {
                    [c.contentNav popToRootViewControllerAnimated:NO];
                }
                // Show the content column (always Secondary — doubleColumn only).
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
            // seed BEFORE layoutIfNeeded — the synchronous layout pass drives the
            // note-layout hook, which must see this width as already-emitted
            c.lastLayoutEmitWidth = width;
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
            // seed BEFORE layoutIfNeeded — the synchronous layout pass drives the
            // note-layout hook, which must see this width as already-emitted
            c.lastLayoutEmitWidth = width;
            [c.splitVC.view setNeedsLayout];
            [c.splitVC.view layoutIfNeeded];
            zapp_ios_sidebar_emit_resize(c, width);
        }
    });
}

// Enable or disable sidebar collapsing (macOS parity: gates only the native
// affordances, not the programmatic API). When can_collapse==false:
//   • presentsWithGesture is set to NO so the native swipe-in gesture is disabled.
//   • Zapp's toolbar toggleSidebar button renders DISABLED — the toolbar apply
//     paths (ios/toolbar.m) read zapp_ios_sidebar_is_collapsible_for_window at
//     apply time, mirroring macOS where AppKit auto-greys the system toggle
//     against NSSplitViewItem.canCollapse.
//   • darwin_sidebar_toggle / collapse / expand STILL work — those are the
//     programmatic API and the dev owns their UI.
// When can_collapse==true, presentsWithGesture is restored and the toggle
// re-enables.
//
// presentsWithGesture=NO side-effects (E2-smoked; SDK-documented, by design):
//   • iPad, sidebar tiled+visible: displayMode stays OneBesideSecondary — the
//     sidebar STAYS OPEN. No side-effect collapse.
//   • iPhone (compact) with the sidebar currently presented: removing the
//     gesture also dismisses the presented primary — UISplitViewController
//     behavior, not fought here.
void darwin_sidebar_set_collapsible(int32_t window_id, bool can_collapse) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        c.collapsible = (BOOL)can_collapse;
        c.splitVC.presentsWithGesture = (BOOL)can_collapse;
        // Re-apply the toolbar so the toggleSidebar button greys/un-greys
        // immediately. Same two-step as willChangeToDisplayMode: (above):
        // a synchronous apply now, plus a settled re-apply one runloop tick
        // later in case the gesture change moved the presentation (the iPhone
        // dismiss-presented-primary case). Capture the numeric host id so the
        // settled lookup re-resolves fresh rather than trusting a stale pointer.
        void* winPtr = darwin_window_get_by_numeric_id(c.hostWindowId);
        if (winPtr) zapp_ios_toolbar_apply_for_window(winPtr);
        int32_t hostWindowId = c.hostWindowId;
        dispatch_async(dispatch_get_main_queue(), ^{
            void* settledWinPtr = darwin_window_get_by_numeric_id(hostWindowId);
            if (settledWinPtr) zapp_ios_toolbar_apply_for_window(settledWinPtr);
        });
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
