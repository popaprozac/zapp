// iOS window — port of darwin/window.m. iPhone is single-window by
// design; multi-scene support (iPad) lands in Phase 4.
//
// **Deferred creation model** (mirrors Tauri Mobile / tao):
//
// The framework's startup sequence on macOS is `app.window.create()` →
// `app.run()`. NSWindow can exist before NSApp.run, so the macOS path
// allocates the real window eagerly. iOS doesn't allow this: a UIWindow
// created before UIApplicationMain has no UIWindowScene and never
// participates in event delivery; any WKWebView added to such an
// orphaned window latches its gesture recognizers onto the dead
// responder chain (first tap crashes inside
// -[UIGestureRecognizer _delayTouchesForEvent:inPhase:]).
//
// So on iOS, `darwin_window_create` returns a `ZappIOSDeferred` opaque
// handle that records intent only. Setters (set_title, show, ...) queue
// against it. After UIApplicationMain → didFinishLaunchingWithOptions
// the AppDelegate calls `zapp_ios_materialize_pending_windows()` which
// allocates the real UIWindow + UIViewController + WKWebView bound to
// the connected UIWindowScene, then replays queued actions.
//
// Most `darwin_window_*` setters are no-ops on iOS (no resizable
// frame, no titlebar, no traffic lights, no fullscreen toggle), but
// they still need to accept calls during the deferred phase so the
// caller's API contract holds.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <objc/runtime.h>

// darwin_webview_create + darwin_webview_create_ext (defined in ios/webview.m,
// same iOS link unit). Pulled in via the shared cross-platform header rather
// than re-declared `extern` here: the ios-platform-parity lint can't parse the
// _ext definition's inline-comment'd param list, so a bare `extern` of it would
// trip a false "unsatisfied cross-layer extern" — the header include sidesteps
// that (the lint only scans for the literal `extern` keyword in .m files).
#include "../darwin/webview.h"

#ifndef ZAPP_MAX_WINDOW_CALLBACKS
#define ZAPP_MAX_WINDOW_CALLBACKS 64
#endif

// --- Deferred-window registry ---

typedef struct ZappIOSDeferred {
    int32_t numeric_id;       // -1 until register_numeric_id
    bool inspectable;
    bool first_mouse;
    char* queued_title;       // last-set title (replayed on materialize)
    char* url;                // content webview url override (e.g. "#sheet=settings"); strdup'd; freed in destroy. NULL = default initial url.
    bool show_requested;      // makeKeyAndVisible queued?
    UIWindow* __unsafe_unretained real_window;     // nil until materialized
    WKWebView* __unsafe_unretained real_webview;
    // Sheet presentation options — populated by darwin_window_create
    // from WindowOptions, consumed by darwin_window_attach_modal.
    int32_t sheet_presentation;   // 0=page, 1=form, 2=fullscreen, 3=bottomSheet
    int32_t sheet_detents;        // bitmask: 1=medium, 2=large
    bool    sheet_grabber;
    // App-set window background ("#rrggbb"), parsed at create, applied at
    // materialize. iOS is full-screen / no live resize, so this is the
    // launch/pre-render fill + brand customization (vs. Windows' resize flash,
    // where WebView2 repaint lag exposes a white gap).
    bool    has_bg;
    int     bg_r, bg_g, bg_b;
    // Create-time sidebar opts (read from wopts_sidebar_* in
    // darwin_window_create, consumed at materialize). Mirrors the macOS
    // create-time sidebar reads in darwin/window.m. hasSidebar gates the
    // UISplitViewController path; sidebarUrl is strdup'd to survive until
    // materialize, like queued_title. Inspector is a separate future task.
    bool    hasSidebar;
    char*   sidebarUrl;          // strdup'd; freed in destroy
    int32_t sidebarNumericId;    // sidebar webview's transport slot
    bool    sidebarCollapsed;
    int32_t sidebarWidth;
    char*   sidebarPresentation;  // strdup'd; freed in destroy. "" / NULL = automatic; "tile"; "overlay"
    int32_t sidebarMinWidth;
    int32_t sidebarMaxWidth;
    bool    sidebarCollapsible;
    bool    sidebarResizable;
    // Optional sidebar pane backdrop ("#rrggbb"); paints behind the
    // transparent sidebar webview (the pane analog of the window bg).
    bool    sidebar_has_bg;
    int     sidebar_bg_r, sidebar_bg_g, sidebar_bg_b;
    // Create-time inspector opts (read from wopts_inspector_* in
    // darwin_window_create, consumed at materialize). Mirrors the sidebar
    // fields above. hasInspector gates the trailing-pane materialize path;
    // inspectorUrl is strdup'd to survive until materialize (freed in destroy).
    // On iPad-regular the inspector is a trailing pane in the content VC; on
    // iPhone-compact it is merely held (the sheet presentation + show/hide
    // control ops are a separate next task).
    bool    hasInspector;
    char*   inspectorUrl;        // strdup'd; freed in destroy
    int32_t inspectorNumericId;  // inspector webview's transport slot
    int32_t inspectorWidth;
    bool    inspectorCollapsed;
    int32_t inspectorMinWidth;
    int32_t inspectorMaxWidth;
    bool    inspectorCollapsible;
    bool    inspectorResizable;
    // Optional inspector pane backdrop ("#rrggbb"); paints behind the
    // transparent inspector webview (the pane analog of the window bg).
    // Mirrors sidebar_has_bg above.
    bool    inspector_has_bg;
    int     inspector_bg_r, inspector_bg_g, inspector_bg_b;
} ZappIOSDeferred;

#define ZAPP_MAX_DEFERRED 16
static ZappIOSDeferred* zapp_ios_deferred_list[ZAPP_MAX_DEFERRED] = {0};

// Dispatch table parallel to darwin/window.m's: numeric ID →
// (UIWindow, WKWebView, owner-string). During the deferred phase the
// `zapp_ios_windows` slot stays nil; it gets filled when the real
// UIWindow is materialized.
static UIWindow* zapp_ios_windows[ZAPP_MAX_WINDOW_CALLBACKS] = {0};
static WKWebView* zapp_ios_webviews[ZAPP_MAX_WINDOW_CALLBACKS] = {0};
static NSString* zapp_ios_window_ids[ZAPP_MAX_WINDOW_CALLBACKS] = {0};

// Public getter: content webview for a numeric window slot. Used by
// ios/panel.m to capture the host webview for coord-space conversion in
// set_bounds (fix #737: panel mispositions when host webview is inset by
// a sidebar).
WKWebView* zapp_ios_content_webview_for_slot(int32_t slot) {
    if (slot < 0 || slot >= ZAPP_MAX_WINDOW_CALLBACKS) return nil;
    return zapp_ios_webviews[slot];
}

// host slot -> sidebar transport slot, for window-event fan-out (mirrors
// darwin/window.m's zapp_sidebar_slot_of). -1 = no sidebar. Initialized
// lazily so a 0-filled table doesn't read as "host 0 -> sidebar 0".
static int32_t zapp_ios_sidebar_slot_of[ZAPP_MAX_WINDOW_CALLBACKS];
static bool zapp_ios_sidebar_slot_of_init = false;

static void zapp_ios_set_sidebar_slot(int32_t host_slot, int32_t sidebar_slot) {
    if (!zapp_ios_sidebar_slot_of_init) {
        for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) zapp_ios_sidebar_slot_of[i] = -1;
        zapp_ios_sidebar_slot_of_init = true;
    }
    if (host_slot >= 0 && host_slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_ios_sidebar_slot_of[host_slot] = sidebar_slot;
    }
}

int32_t zapp_ios_sidebar_slot_for(int32_t host_slot) {
    if (!zapp_ios_sidebar_slot_of_init) return -1;
    if (host_slot < 0 || host_slot >= ZAPP_MAX_WINDOW_CALLBACKS) return -1;
    return zapp_ios_sidebar_slot_of[host_slot];
}

// Host slot -> inspector slot (mirror of zapp_ios_sidebar_slot_of). -1 = none.
static int32_t zapp_ios_inspector_slot_of[ZAPP_MAX_WINDOW_CALLBACKS];
static bool zapp_ios_inspector_slot_of_init = false;

void zapp_ios_set_inspector_slot(int32_t host_slot, int32_t inspector_slot) {
    if (!zapp_ios_inspector_slot_of_init) {
        for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) zapp_ios_inspector_slot_of[i] = -1;
        zapp_ios_inspector_slot_of_init = true;
    }
    if (host_slot >= 0 && host_slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_ios_inspector_slot_of[host_slot] = inspector_slot;
    }
}

int32_t zapp_ios_inspector_slot_for(int32_t host_slot) {
    if (!zapp_ios_inspector_slot_of_init) return -1;
    if (host_slot < 0 || host_slot >= ZAPP_MAX_WINDOW_CALLBACKS) return -1;
    return zapp_ios_inspector_slot_of[host_slot];
}

// Register a webview directly into a specific transport slot + window-id
// string (mirrors darwin/window.m's zapp_register_webview). The pane path
// needs this because zapp_ios_register_webview routes by UIWindow — both
// panes share one UIWindow, so the second create would otherwise clobber
// the first's slot. The pane's JS identity (windowId) is the HOST id.
static void zapp_ios_register_webview_slot(int32_t slot, WKWebView* webview, NSString* windowId) {
    if (slot >= 0 && slot < ZAPP_MAX_WINDOW_CALLBACKS) {
        zapp_ios_webviews[slot] = webview;
        zapp_ios_window_ids[slot] = windowId;
    }
}

// ZappIOSSplitViewController is defined in ios/sidebar.m. Both TUs are in the
// same link unit (same xcbuild target) so the runtime class is always present.
// We use it instead of UISplitViewController directly so that
// viewWillTransitionToSize: and traitCollectionDidChange: can re-apply the
// stored presentation pair on rotation / multitasking changes (the Mail recipe).
// Declaring the @interface here (matching the definition in sidebar.m, which
// the linker provides) lets the compiler resolve initWithStyle: correctly.
@interface ZappIOSSplitViewController : UISplitViewController
@end

// ── ZappIOSPaneViewController ────────────────────────────────────────────────
//
// Minimal UIViewController subclass shared by ALL pane view controllers (content
// VC in sidebar windows, inspector VC, and the lone root VC in no-sidebar windows).
//
// Overrides -viewSafeAreaInsetsDidChange to re-inject chrome metrics into EVERY
// pane webview for the owning window. UIKit fires this callback:
//   • After the initial layout (so the nav bar height is known by then).
//   • On every subsequent change: rotation, bar show/hide, sheet present/dismiss,
//     multitasking resize.
//
// This fixes the T4 "too-early inject" root cause:
//   • iPad content: -set_items defers one tick but the floating UINavigationBar
//     hasn't laid out yet → safeAreaInsets.top too small → content obscured.
//     viewSafeAreaInsetsDidChange fires AFTER layout settles → correct value.
//   • iPad sidebar: same mechanism (sidebar VC's safe area mirrors the content VC's).
//   • iPhone inspector sheet: inspector VC gets its own safe-area change when the
//     sheet appears → inject fires with the correct bar-present inset.
//   • Rotation / multitasking resize: automatically re-injects the new insets.
//
// The re-inject calls zapp_toolbar_inject_metrics(windowPtr, hostSlot, false)
// — add_user_script=false because the WKUserScript was already added on the
// first set_items call. Multiple rapid safe-area change callbacks are safe:
// inject_metrics only evaluates JS (setProperty on documentElement.style), which
// is idempotent and has no layout side-effects, so no feedback loop can form.
//
// Guard: windowPtr==NULL || hostSlot<0 means this VC is not yet wired (e.g. the
// no-sidebar plain root VC before materialize sets the id). The override is a
// no-op until both fields are populated.

// Forward declaration — defined in ios/toolbar.m (same link unit).
extern void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot,
                                         bool add_user_script);

@interface ZappIOSPaneViewController : UIViewController
@property (nonatomic, assign) void* windowPtr;  // host UIWindow* (not retained; window outlives VCs)
@property (nonatomic, assign) int32_t hostSlot; // numeric window id (content slot)
@property (nonatomic, assign) int paneRole;     // 0 content, 1 sidebar, 3 inspector
@end

@implementation ZappIOSPaneViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _windowPtr = NULL;
        _hostSlot  = -1;
        _paneRole  = 0;
    }
    return self;
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    // Guard: skip until the VC is wired to a window (materialize sets these).
    if (!_windowPtr || _hostSlot < 0) return;
    // add_user_script=false: the persistent WKUserScript was already installed at
    // set_items time; this is a live CSS-var update only. Safe to call repeatedly —
    // inject_metrics only evaluates JS setProperty (no layout side-effects).
    zapp_toolbar_inject_metrics(_windowPtr, _hostSlot, false);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Re-inject toolbar metrics once per appearance (sheet present, tab return,
    // etc.) to cover the inspector sheet's initial present, where
    // viewSafeAreaInsetsDidChange fires before the sheet's geometry settles.
    // One-tick defer so the sheet's final geometry / safeAreaInsets are settled.
    // Guard: skip until the VC is wired to a window (materialize sets these).
    if (!_windowPtr || _hostSlot < 0) return;
    void* winPtr = _windowPtr;
    int32_t slot = _hostSlot;
    dispatch_async(dispatch_get_main_queue(), ^{
        zapp_toolbar_inject_metrics(winPtr, slot, false);
    });
}

// T7: Re-inject chrome metrics AFTER the rotation transition completes.
// viewSafeAreaInsetsDidChange fires DURING the transition with intermediate
// insets; the coordinator completion block runs after the animation finishes
// and safeAreaInsets reflect the final orientation — that value wins.
// Capture scalars/void* into locals (not self) so the block is MRC-safe and
// avoids any inadvertent self-retain under non-ARC translation units.
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    if (!_windowPtr || _hostSlot < 0) return;
    void* wp = _windowPtr;
    int32_t hs = _hostSlot;
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil
                                     completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx){
            (void)ctx;
            // Post-rotation: safeAreaInsets now reflect the new orientation. Re-measure.
            zapp_toolbar_inject_metrics(wp, hs, false);
        }];
    } else {
        // No animated coordinator (e.g. non-animated size change): one-tick defer.
        dispatch_async(dispatch_get_main_queue(), ^{
            zapp_toolbar_inject_metrics(wp, hs, false);
        });
    }
}

// Live divider-drag resize emits (#720). viewDidLayoutSubviews fires once per
// frame while the user drags the sidebar/inspector column seam (probe-proven),
// so this is the earliest per-frame hook available on the pane VC itself —
// unlike viewSafeAreaInsetsDidChange above (insets-only, fires on chrome
// changes, not divider geometry). Gated on paneRole so the content pane (role
// 0 — including the plain no-sidebar/no-inspector root VC, which has no
// sidebar/inspector column to report) never calls either note-layout helper.
// Guard requires ONLY _windowPtr (not _hostSlot, unlike the metrics hooks
// above): the sidebar VC is wired with windowPtr but deliberately left at its
// -init default hostSlot=-1 (see the sidebar VC construction below) so the
// pre-existing metrics hooks keep their current no-op behavior for that pane.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_windowPtr || _paneRole == 0) return;
    CGFloat w = self.view.bounds.size.width;
    extern void zapp_ios_sidebar_note_layout_width(void*, CGFloat);
    extern void zapp_ios_inspector_note_layout_width(void*, CGFloat);
    if (_paneRole == 1) zapp_ios_sidebar_note_layout_width(_windowPtr, w);
    else if (_paneRole == 3) zapp_ios_inspector_note_layout_width(_windowPtr, w);
}

@end

// Root VC for the no-sidebar window. Inherits ZappIOSPaneViewController so that
// -viewSafeAreaInsetsDidChange re-injects metrics when the nav bar settles.
// Adds -traitCollectionDidChange: for THEME_CHANGED dispatch (the sidebar path
// gets this from ZappIOSSplitViewController's override; the plain path needs its own).
@interface ZappIOSRootViewController : ZappIOSPaneViewController
@end
@implementation ZappIOSRootViewController
- (void)traitCollectionDidChange:(UITraitCollection*)previous {
    [super traitCollectionDidChange:previous];
    extern void zapp_ios_dispatch_theme_if_changed(void);
    zapp_ios_dispatch_theme_if_changed();
}
@end

// ── ZappIOSHiddenPrimarySplitViewController (E3: no-sidebar + inspector) ─────
//
// A no-sidebar window WITH an inspector needs a UISplitViewController for the
// iOS-26 Inspector column to attach to (the column is split-scoped API). The
// recipe is the spike-proven hidden-Primary doubleColumn split
// (spikes/ios-splitview-reference/src/AppDelegate.m, SPLITREF_NO_SIDEBAR
// variant, G1 human-smoked on iPad + iPhone):
//   • Primary   = an EMPTY plain UIViewController (clear background, never
//                 nav-wrapped, no content) held permanently hidden.
//   • Secondary = the content pane (nav-wrapped, bar visible — the content
//                 pane carries the native toolbar, same stance as the sidebar
//                 shape's contentNav. toolbar.m and routing.m reach this
//                 shape's nav via sidebar.m's Secondary-column fallback
//                 resolver, G3 fix).
//   • preferredDisplayMode SecondaryOnly + presentsWithGesture NO +
//     showsSecondaryOnlyButton NO ⇒ no user affordance can ever summon the
//     Primary.
//
// This subclass is BOTH the split and its UISplitViewControllerDelegate
// (materialize sets self.delegate = self). Why not reuse sidebar.m's
// ZappIOSSidebarController: that delegate assumes a REAL sidebar — it
// collapses to Primary, emits sidebar-collapsed/-expanded, re-applies
// toolbars, and registers the window in the sidebar registry (which toolbar/
// routing nav resolution keys off) — installing it here would activate every
// sidebar path for a pane that doesn't exist. And why window.m rather than
// inspector.m: window.m owns split construction for every window shape (and
// already defines the shape-specific VC subclasses above); inspector.m stays
// shape-agnostic — it reaches whatever split contentVC lives in via
// .splitViewController and runs unchanged for both shapes.
//
// RETENTION: this object is the window's rootViewController, so the UIWindow
// strongly retains it for the window's lifetime; UIKit's weak `delegate`
// back-reference points at self. No registry entry and no unregister path is
// needed (unlike ZappIOSSidebarController, a separate object that must be
// dictionary-retained).
//
// Delegate duties for this shape:
//   1. topColumnForCollapsingToProposedTopColumn → Secondary: there is no
//      sidebar, so compact width MUST land on content (spike commit fdec309).
//   2. splitViewControllerDidCollapse / viewDidAppear → prune the empty
//      Primary out of the combined collapsed stack. UIKit collapses
//      "Secondary on top" by stacking it ABOVE the Primary root — the G1
//      smoke showed the collapsed nav as [emptyPrimary, content], which grows
//      a stray native Back button that pops to a blank screen. Filtering the
//      empty Primary out makes the collapsed stack content-only: nothing
//      beneath to pop to, by button OR gesture (with the bar visible — G3
//      fix — UIKit's interactive-pop is armed, but it no-ops at depth 1;
//      pushed route VCs on top pop normally). Expansion is unaffected: on
//      compact→regular UIKit restores columns from its own column registry
//      (setViewController:forColumn:), not from the collapsed stack, and the
//      sticky SecondaryOnly mode keeps the Primary hidden regardless.
//   3. didShowColumn:/didHideColumn: (iOS 26) → forward Inspector-column
//      visibility to ios/inspector.m's emit hooks. For sidebar windows this
//      forwarding lives on ZappIOSSidebarController (the split delegate for
//      that shape); this shape has no sidebar controller, so the split
//      forwards its own.
//   4. Content-webview edge model (FU-1 parity) — see
//      zapp_ios_pin_content_webview_no_sidebar below.

// Defined in ios/inspector.m — the single iOS-26 source for the
// inspector-expanded/-collapsed emits (same externs sidebar.m declares).
extern void zapp_ios_inspector_column_did_show(void* window);
extern void zapp_ios_inspector_column_did_hide(void* window);
// Defined later in this file (numeric-ID dispatch table).
extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);

@interface ZappIOSHiddenPrimarySplitViewController : UISplitViewController <UISplitViewControllerDelegate>
// The empty Primary column VC. Strong so the collapsed-stack prune can still
// recognize it while UIKit shuffles ownership during collapse transitions.
@property (nonatomic, strong) UIViewController* emptyPrimaryVC;
@property (nonatomic, assign) int32_t hostWindowId;   // content/host webview slot
// Content-webview edge constraints — mirror of ZappIOSSidebarController's four
// stored constraints (see zapp_ios_pin_content_webview_no_sidebar below). All
// nil until the pin helper populates them.
@property (nonatomic, weak)   UIView* contentContainer;          // contentVC.view
@property (nonatomic, strong) NSLayoutConstraint* leadingFull;   // to view.leadingAnchor
@property (nonatomic, strong) NSLayoutConstraint* leadingSafe;   // to safeAreaLayoutGuide.leadingAnchor
@property (nonatomic, strong) NSLayoutConstraint* trailingFull;  // to view.trailingAnchor
@property (nonatomic, strong) NSLayoutConstraint* trailingSafe;  // to safeAreaLayoutGuide.trailingAnchor
- (void)zapp_updateContentEdges;
@end

@implementation ZappIOSHiddenPrimarySplitViewController

// Make the collapsed stack CONTENT-ONLY. UIKit's collapse honors our
// topColumnForCollapsing→Secondary by putting content on TOP, but it roots
// the combined nav at the (empty, hidden) Primary underneath — which grows a
// stray native Back button that pops to a blank screen (observed in the G1
// smoke on iPhone). Remove the empty Primary from every nav stack the split
// built for the compact presentation. Idempotent and cheap when the stack is
// already content-only.
- (void)zapp_pruneEmptyPrimaryFromCollapsedStack {
    if (!self.isCollapsed || !self.emptyPrimaryVC) return;
    // Find the combined collapsed nav(s) the same way sidebar.m's
    // zapp_ios_collapsed_nav does: `viewControllers` holds the single combined
    // controller while collapsed; childViewControllers is belt-and-suspenders.
    NSMutableArray<UINavigationController*>* navs = [NSMutableArray array];
    for (UIViewController* vc in self.viewControllers) {
        if ([vc isKindOfClass:[UINavigationController class]] &&
            ![navs containsObject:(UINavigationController*)vc]) {
            [navs addObject:(UINavigationController*)vc];
        }
    }
    for (UIViewController* vc in self.childViewControllers) {
        if ([vc isKindOfClass:[UINavigationController class]] &&
            ![navs containsObject:(UINavigationController*)vc]) {
            [navs addObject:(UINavigationController*)vc];
        }
    }
    for (UINavigationController* nav in navs) {
        if (![nav.viewControllers containsObject:self.emptyPrimaryVC]) continue;
        NSMutableArray<UIViewController*>* stack = [nav.viewControllers mutableCopy];
        [stack removeObject:self.emptyPrimaryVC];
        // Never leave an empty stack (would blank the window); with the empty
        // Primary removed the content root is always still present.
        if (stack.count > 0) [nav setViewControllers:stack animated:NO];
    }
}

// There is no sidebar: compact width must land on the CONTENT column, and the
// Inspector column auto-sheets on top of it (spike commit fdec309's
// SPLITREF_NO_SIDEBAR branch — the framework-port semantic it documented).
- (UISplitViewControllerColumn)splitViewController:(UISplitViewController*)svc
        topColumnForCollapsingToProposedTopColumn:(UISplitViewControllerColumn)proposedTopColumn {
    (void)svc; (void)proposedTopColumn;
    return UISplitViewControllerColumnSecondary;
}

- (void)splitViewControllerDidCollapse:(UISplitViewController*)svc {
    (void)svc;
    [self zapp_pruneEmptyPrimaryFromCollapsedStack];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // On iPhone the split is created ALREADY collapsed, so
    // splitViewControllerDidCollapse: may never fire at launch (the same UIKit
    // quirk sidebar.m documents for its swipe-back re-arm). Prune here too.
    [self zapp_pruneEmptyPrimaryFromCollapsedStack];
}

// iOS 26+ column-level visibility notifications (both delegate methods are
// API_AVAILABLE(ios(26.0)); UIKit never calls them on earlier OSes). Forward
// Inspector-column changes to ios/inspector.m's emit hooks, keyed by the host
// UIWindow — mirrors ZappIOSSidebarController's implementation verbatim.
// Resolve the window via darwin_window_get_by_numeric_id, NOT self.view.window:
// the launch-time deferred show/hideColumn in zapp_ios_inspector_register can
// run before a `visible:false` window ever attaches its root view.
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

// Swap the active edge-constraint pair per horizontal size class — the exact
// logic of sidebar.m's zapp_ios_update_content_edges, on this shape's own
// stored constraints. Regular (iPad): safeAreaLayoutGuide anchors, tracking
// the iOS-26 Inspector column's trailing safe-area inset. Compact (iPhone):
// raw view anchors, full-bleed (notch insets must not shrink content).
- (void)zapp_updateContentEdges {
    if (!self.leadingFull || !self.leadingSafe) return;
    if (!self.trailingFull || !self.trailingSafe) return;
    BOOL isRegular = (self.traitCollection.horizontalSizeClass
                      == UIUserInterfaceSizeClassRegular);
    if (isRegular) {
        self.leadingFull.active = NO;
        self.trailingFull.active = NO;
        self.leadingSafe.active = YES;
        self.trailingSafe.active = YES;
    } else {
        self.leadingSafe.active = NO;
        self.trailingSafe.active = NO;
        self.leadingFull.active = YES;
        self.trailingFull.active = YES;
    }
    [self.contentContainer setNeedsLayout];
    [self.contentContainer layoutIfNeeded];
}

// Same two re-switch triggers ZappIOSSplitViewController (sidebar.m) uses for
// the sidebar shape's edge model: trait changes and size transitions (edge
// update in the coordinator's completion, after traitCollection is final).
// No presentation re-apply here — unlike the sidebar tile pair, SecondaryOnly
// is a sticky preferredDisplayMode that survives rotation/multitasking.
- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self zapp_updateContentEdges];
    // App-level THEME_CHANGED (deduped in the helper). The sidebar shape gets
    // this from ZappIOSSplitViewController, the plain shape from
    // ZappIOSRootViewController; this split owns it for the hidden-Primary
    // shape (its contentVC is a plain ZappIOSPaneViewController).
    extern void zapp_ios_dispatch_theme_if_changed(void);
    zapp_ios_dispatch_theme_if_changed();
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil
                                     completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            (void)ctx;
            [self zapp_updateContentEdges];
        }];
    } else {
        [self zapp_updateContentEdges];
    }
}

@end

// ── Content-webview edge pinning for the hidden-Primary shape ────────────────
//
// Mirrors sidebar.m's zapp_ios_sidebar_set_content_webview +
// zapp_ios_update_content_edges (the FU-1 trailing-safe fix) WITHOUT a sidebar
// registry entry. Why the mirror is needed at all: on iPad regular width UIKit
// does NOT resize the Secondary column's view for tiled siblings — the view
// stays the full split width and the iOS-26 Inspector column is expressed as a
// TRAILING safe-area inset on it, so a webview pinned to the raw view edges
// bleeds UNDER the inspector. The pin: convert the webview from
// autoresizingMask (set by webview.m) to explicit Auto Layout, keep top/bottom
// full-frame, and store leading+trailing constraint PAIRS on the split —
// safe-area anchors on regular (leading kept symmetric with sidebar.m's model;
// it resolves to the raw edge when nothing insets it), raw anchors on compact.
// -zapp_updateContentEdges (above) swaps the active pair at the same three
// trigger points sidebar.m uses: initial setup here, trait changes, and
// size-transition completions.
//
// Why a window.m helper instead of reusing sidebar.m's function: that function
// is coupled to the ZappIOSSidebarController registry (keyed lookup, weak
// contentVC), and registering a phantom sidebar controller for a window with
// NO sidebar would activate every sidebar code path (toolbar/routing nav
// resolution, collapse-to-Primary, sidebar emits) for a pane that doesn't
// exist. Mirroring ~25 lines is the cheaper coupling.
static void zapp_ios_pin_content_webview_no_sidebar(
        ZappIOSHiddenPrimarySplitViewController* split,
        WKWebView* wv, UIView* container) {
    if (!split || !wv || !container) return;

    wv.translatesAutoresizingMaskIntoConstraints = NO;

    NSLayoutConstraint* leadingFull =
        [wv.leadingAnchor constraintEqualToAnchor:container.leadingAnchor];
    NSLayoutConstraint* leadingSafe =
        [wv.leadingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor];
    NSLayoutConstraint* trailingFull =
        [wv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor];
    NSLayoutConstraint* trailingSafe =
        [wv.trailingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor];

    // Top / bottom stay full-frame (not safe-area) — same rationale as
    // sidebar.m: the pane is the visible surface; no top/bottom insets.
    [NSLayoutConstraint activateConstraints:@[
        [wv.topAnchor constraintEqualToAnchor:container.topAnchor],
        [wv.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    split.contentContainer = container;
    split.leadingFull  = leadingFull;
    split.leadingSafe  = leadingSafe;
    split.trailingFull = trailingFull;
    split.trailingSafe = trailingSafe;

    // Activate the correct pair for the current trait.
    [split zapp_updateContentEdges];
}

// Implemented in ios/sidebar.m (T3 — chrome-less master-detail). Materialize
// calls it after setting min/max/preferred column widths but BEFORE creating
// pane webviews. sidebar.m nav-wraps the columns, installs the delegate, stores
// the presentation mode, and applies the behavior+displayMode pair in its final
// correct order (after nav-wrapped columns are set). `presentation` is the raw
// config string: "tile", "overlay", or NULL/"" for automatic.
extern void zapp_ios_sidebar_register(void* window, void* split, void* sidebarVC,
                                      void* contentVC, int32_t host_id, int32_t sidebar_id,
                                      const char* presentation,
                                      int32_t width, int32_t minWidth, int32_t maxWidth,
                                      bool resizable, bool collapsible);

// Implemented in ios/inspector.m. Materialize calls it AFTER both the content
// and (optional) sidebar panes are built AND the persistent inspector nav has
// been attached to the split's iOS-26 Inspector column (when available — see
// the inspector pane block below), handing it the inspector nav + the content
// VC + the content webview + the host/inspector ids + the configured width
// and collapsed intent. inspector.m strongly retains the nav so it survives
// on <26, when it is never attached to any split column, for on-demand modal
// sheet presentation instead.
extern void zapp_ios_inspector_register(void* window, void* inspectorNav,
                                        void* contentVC, void* contentWebview,
                                        int32_t host_id, int32_t inspector_id,
                                        int32_t width, int32_t min_width, int32_t max_width,
                                        bool collapsed, bool collapsible, bool resizable);

static ZappIOSDeferred* zapp_ios_find_deferred(void* handle) {
    if (!handle) return NULL;
    for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
        if ((void*)zapp_ios_deferred_list[i] == handle) return zapp_ios_deferred_list[i];
    }
    return NULL;
}

// --- Materialization (called from AppDelegate.didFinishLaunching) ---
//
// Walks the deferred list and turns each entry into a real
// UIWindow + UIViewController + WKWebView bound to the first
// connected UIWindowScene. Replays queued setter state.

void zapp_ios_materialize_pending_windows(void) {
    UIWindowScene* scene = nil;
    for (UIScene* s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene*)s; break; }
    }

    for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
        ZappIOSDeferred* d = zapp_ios_deferred_list[i];
        if (!d || d->real_window) continue;

        UIWindow* window = scene
            ? [[UIWindow alloc] initWithWindowScene:scene]
            : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        window.frame = scene ? scene.coordinateSpace.bounds : [UIScreen mainScreen].bounds;

        // App-set background ("#rrggbb") or the adaptive system default. Fills
        // the launch / pre-render gap; the page's CSS background paints over it.
        UIColor* bgColor = d->has_bg
            ? [UIColor colorWithRed:d->bg_r/255.0 green:d->bg_g/255.0 blue:d->bg_b/255.0 alpha:1.0]
            : [UIColor systemBackgroundColor];

        // The view controller holding the content webview — the lone root VC
        // (no sidebar, no inspector) or the split's Secondary column (sidebar
        // windows AND no-sidebar+inspector windows, which get a hidden-Primary
        // split — E3). The sidebar VC is the split's primary column; nil when
        // there's no sidebar.
        UIViewController* contentVC = nil;
        UIViewController* sidebarVC = nil;
        // The split itself (nil only for plain no-sidebar/no-inspector
        // windows). Hoisted to function scope so the inspector pane block
        // below can attach the persistent inspector nav to
        // UISplitViewControllerColumnInspector (iOS 26+) without re-deriving
        // it from window.rootViewController.
        UISplitViewController* split = nil;
        // Inspector column VC (UISplitViewControllerColumnInspector, iOS 26+
        // only — orthogonal to the doubleColumn base style, so no tripleColumn
        // is ever used). Created below in the inspector pane block, AFTER the
        // content (+ optional sidebar) panes exist so the webview is born in
        // its final container. Persistent for the window's lifetime: on 26+ it
        // becomes the split's Inspector column; on <26 it is retained by
        // inspector.m's registry for on-demand modal-sheet presentation.
        ZappIOSPaneViewController* inspectorVC = nil;
        // The CONTENT webview, captured canonically. d->real_webview is NOT
        // reliable past the pane-create dance: each darwin_webview_create_ext
        // ends with zapp_ios_register_webview (auto-register by UIWindow), which
        // overwrites d->real_webview with the LAST-created pane (sidebar, then
        // inspector). We restore the canonical content webview after the panes
        // are built so the inspector capture + re-slot + downstream consumers
        // all get the content webview, not a pane.
        WKWebView* canonicalContentWebview = nil;

        if (d->hasSidebar) {
            // Sidebar window: root on a ZappIOSSplitViewController (our
            // UISplitViewController subclass that re-applies the presentation
            // pair on rotation / multitasking size changes). The split MUST be
            // the window's rootViewController BEFORE either pane webview is
            // created — re-parenting a WKWebView resets its content process and
            // kills the bridge, so every pane is born in its final container.
            // (Mirrors the darwin/window.m create-ordering note.)
            //
            // Always doubleColumn — Primary=sidebar, Secondary=content (the
            // PERMANENT canvas). The iOS-26 Inspector column (attached in the
            // inspector pane block below, after the content + inspector VCs
            // exist) is orthogonal to the base style; it does NOT require
            // tripleColumn. Mirrors the spike (spikes/ios-splitview-reference).
            split = [[ZappIOSSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
            // ZappIOSPaneViewController (not a bare UIViewController) so
            // viewDidLayoutSubviews can note live divider-drag width changes
            // (#720) via the paneRole=1 branch. windowPtr is wired below,
            // alongside contentVC's; hostSlot is deliberately left at its
            // -init default (-1) — see the wiring block below for why.
            sidebarVC = [[ZappIOSPaneViewController alloc] init];   // primary column
            ((ZappIOSPaneViewController*)sidebarVC).paneRole = 1;
            // content VC: ZappIOSPaneViewController so viewSafeAreaInsetsDidChange
            // re-injects toolbar metrics after UIKit lays out the floating nav bar.
            // windowPtr + hostSlot are wired below after d->real_window is set.
            contentVC = [[ZappIOSPaneViewController alloc] init]; // secondary column — the permanent content canvas

            contentVC.view.backgroundColor = bgColor;
            // Sidebar pane backdrop: explicit "#rrggbb" if the app set one,
            // else the adaptive system background (the pane analog of the
            // window bg, filling the pre-paint gap behind the webview).
            sidebarVC.view.backgroundColor = d->sidebar_has_bg
                ? [UIColor colorWithRed:d->sidebar_bg_r/255.0 green:d->sidebar_bg_g/255.0
                                   blue:d->sidebar_bg_b/255.0 alpha:1.0]
                : [UIColor systemBackgroundColor];

            // Set the column VCs on the bare split first. zapp_ios_sidebar_register
            // (called below, after min/max/width) will nav-wrap these and re-set
            // them, then apply the presentation pair AFTER the final columns are
            // in place — the correct ordering per WWDC20 10105.
            //
            // Content is ALWAYS Secondary now (doubleColumn — no Supplementary).
            [split setViewController:sidebarVC forColumn:UISplitViewControllerColumnPrimary];
            [split setViewController:contentVC forColumn:UISplitViewControllerColumnSecondary];
            // Set column min/max BEFORE preferred so the preferred value lands
            // inside the allowed range. Without min/max, iOS caps
            // preferredPrimaryColumnWidth at ~320 pt by default — any configured
            // width above that (e.g. maxWidth:500) is silently clamped.
            // These are split-level (not column-VC-scoped) so they survive the
            // nav-wrap re-set in zapp_ios_sidebar_register below.
            if (d->sidebarMinWidth > 0) {
                split.minimumPrimaryColumnWidth = (CGFloat)d->sidebarMinWidth;
            }
            if (d->sidebarMaxWidth > 0) {
                split.maximumPrimaryColumnWidth = (CGFloat)d->sidebarMaxWidth;
            }
            if (d->sidebarWidth > 0) {
                // Sidebar = the PRIMARY column, so its width is
                // preferredPrimaryColumnWidth. Governed by the min/max set above.
                split.preferredPrimaryColumnWidth = (CGFloat)d->sidebarWidth;
            }
            // Presentation (preferredSplitBehavior + preferredDisplayMode) is
            // intentionally NOT set here. zapp_ios_sidebar_register applies the
            // pair AFTER it nav-wraps the columns — that is the correct ordering
            // (set both together, after final columns exist, per WWDC20 10105).
            // Left-edge swipe reveals the sidebar (esp. in overlay, where the
            // flyout starts hidden). This is the system default, but set it
            // explicitly/intentionally so the reveal affordance is guaranteed.
            split.presentsWithGesture = YES;
            split.view.backgroundColor = bgColor;

            window.rootViewController = split;   // BEFORE any webview creation
        } else if (d->hasInspector) {
            // E3: no-sidebar window WITH an inspector — hidden-Primary split
            // so the iOS-26 Inspector column has a split to attach to. Full
            // recipe + rationale on ZappIOSHiddenPrimarySplitViewController
            // above. Same re-parenting rule as the sidebar path: the split
            // MUST be the window's rootViewController BEFORE the content
            // webview is created.
            ZappIOSHiddenPrimarySplitViewController* hpSplit =
                [[ZappIOSHiddenPrimarySplitViewController alloc]
                    initWithStyle:UISplitViewControllerStyleDoubleColumn];
            hpSplit.hostWindowId = d->numeric_id;
            split = hpSplit;

            // Primary: empty plain VC — clear background, never nav-wrapped,
            // no content. Held permanently hidden (SecondaryOnly below);
            // retained on the subclass so the collapsed-stack prune can
            // recognize it (see the class comment's Back-button note).
            UIViewController* emptyPrimary = [[UIViewController alloc] init];
            emptyPrimary.view.backgroundColor = [UIColor clearColor];
            hpSplit.emptyPrimaryVC = emptyPrimary;

            // Secondary: the SAME ZappIOSPaneViewController content pane the
            // sidebar path uses (windowPtr/hostSlot wired below; webview
            // mounted by the shared split content-mount block below).
            contentVC = [[ZappIOSPaneViewController alloc] init];
            contentVC.view.backgroundColor = bgColor;

            // Nav-wrap the content NOW, while the column VC is still empty —
            // never re-parents a live WKWebView (the ordering rule
            // zapp_ios_sidebar_register documents). Bar VISIBLE (G3 fix,
            // mirroring the sidebar shape's contentNav in
            // zapp_ios_sidebar_register): the content pane carries the native
            // toolbar, and toolbar.m/routing.m now reach this shape's nav via
            // sidebar.m's Secondary-column fallback resolver — so the bar must
            // be shown at launch or set toolbar items render invisibly.
            // ZappRouteNavDelegate's willShowViewController: (routing.m) is
            // the ongoing authority once route pushes install it. A visible
            // bar re-arms UIKit's interactive-pop gesture, but the
            // no-Back-button guarantee still holds at the nav root: the
            // collapsed-stack prune below leaves nothing beneath the content
            // VC to pop to (button or edge swipe both no-op at depth 1); a
            // pushed route VC on TOP gets the normal back affordance, which is
            // desired nav behavior.
            UINavigationController* contentNav =
                [[UINavigationController alloc] initWithRootViewController:contentVC];
            contentNav.navigationBarHidden = NO;

            [hpSplit setViewController:emptyPrimary forColumn:UISplitViewControllerColumnPrimary];
            [hpSplit setViewController:contentNav forColumn:UISplitViewControllerColumnSecondary];

            // The spike recipe, applied immediately after construction:
            // permanently hide the Primary and remove every affordance that
            // could summon it. behavior+displayMode are set as a PAIR (the
            // WWDC 10105 rule) and match the smoked spike configuration
            // exactly: Tile keeps the iOS-26 Inspector column TILED beside
            // content on iPad regular (content takes a trailing safe-area
            // inset — the edge model the pin helper tracks) instead of an
            // adaptive overlay. Both are sticky preferred values — no
            // per-rotation re-apply needed (unlike the sidebar path, whose
            // tile recipe includes a showColumn:Primary that must re-run).
            hpSplit.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
            hpSplit.preferredDisplayMode   = UISplitViewControllerDisplayModeSecondaryOnly;
            hpSplit.presentsWithGesture    = NO;
            if (@available(iOS 14.0, *)) {
                hpSplit.showsSecondaryOnlyButton = NO;
            }
            // Self-delegate: collapse-to-Secondary + collapsed-stack prune +
            // Inspector-column emit forwarding. No zapp_ios_sidebar_register
            // for this shape (there is no sidebar), so the split — not a
            // ZappIOSSidebarController — must own the delegate.
            hpSplit.delegate = hpSplit;
            hpSplit.view.backgroundColor = bgColor;

            window.rootViewController = hpSplit;   // BEFORE any webview creation
        } else {
            // Single-pane window (no sidebar, no inspector): lone root VC
            // hosting the content webview.
            UIViewController* root = [[ZappIOSRootViewController alloc] init];
            root.view.frame = window.bounds;
            root.view.backgroundColor = bgColor;
            contentVC = root;
            window.rootViewController = root;
        }
        window.backgroundColor = bgColor;

        // Plug the materialized UIWindow into the numeric-ID dispatch
        // table BEFORE darwin_webview_create runs — its callback
        // (zapp_ios_register_webview) looks the window up there to know
        // which slot to drop the WKWebView into.
        d->real_window = window;
        if (d->numeric_id >= 0 && d->numeric_id < ZAPP_MAX_WINDOW_CALLBACKS) {
            zapp_ios_windows[d->numeric_id] = window;
            // Numeric form matches what router.zc returns to JS — keeps
            // Window.current() and Window.create() handles in lockstep.
            zapp_ios_window_ids[d->numeric_id] = [NSString stringWithFormat:@"win-%d", d->numeric_id];
        }

        // Wire the numeric id and window pointer into every ZappIOSPaneViewController
        // so that viewSafeAreaInsetsDidChange can re-inject toolbar metrics once
        // UIKit has finished laying out the floating nav bar. contentVC is either a
        // ZappIOSPaneViewController (sidebar path) or a ZappIOSRootViewController
        // (no-sidebar path, which also subclasses ZappIOSPaneViewController). In
        // both cases the cast is safe because both classes respond to the properties.
        if (d->numeric_id >= 0 && [contentVC isKindOfClass:[ZappIOSPaneViewController class]]) {
            ((ZappIOSPaneViewController*)contentVC).windowPtr = (__bridge void*)window;
            ((ZappIOSPaneViewController*)contentVC).hostSlot  = d->numeric_id;
        }

        // Sidebar VC (#720): wire windowPtr ONLY — hostSlot stays -1 (its -init
        // default). The sidebar pane does not participate in the pre-existing
        // metrics hooks (viewSafeAreaInsetsDidChange / viewDidAppear /
        // viewWillTransitionToSize:) today: those are already covered end-to-end
        // by contentVC's hostSlot-gated firing, since zapp_toolbar_inject_metrics
        // re-injects into ALL THREE panes (content, sidebar, inspector) off the
        // HOST slot in one call. Setting hostSlot here would newly arm those
        // hooks on the sidebar VC too — a behavior change this task doesn't ask
        // for. windowPtr alone is sufficient to arm the NEW viewDidLayoutSubviews
        // resize hook above, which is paneRole-gated and windowPtr-only.
        if (sidebarVC && [sidebarVC isKindOfClass:[ZappIOSPaneViewController class]]) {
            ((ZappIOSPaneViewController*)sidebarVC).windowPtr = (__bridge void*)window;
        }

        // Hand the split + columns + ids to the sidebar manager (ios/sidebar.m).
        // It runs SYNCHRONOUSLY on this (main) thread, wrapping the still-empty
        // column VCs in bar-hidden navigation controllers + installing the
        // collapse delegate, all BEFORE the pane webviews are created below — so
        // the webviews are born inside their final (nav-wrapped) containers and
        // never re-parent. (zapp_ios_sidebar_register declared at file scope.)
        // Hand the split + columns + ids to the sidebar manager (ios/sidebar.m).
        // It runs SYNCHRONOUSLY on this (main) thread, wrapping the still-empty
        // column VCs in bar-hidden navigation controllers + installing the
        // collapse delegate, all BEFORE the pane webviews are created below — so
        // the webviews are born inside their final (nav-wrapped) containers and
        // never re-parent. (zapp_ios_sidebar_register declared at file scope.)
        if (d->hasSidebar) {
            // Pass the presentation string so sidebar_register can apply the
            // behavior+displayMode pair AFTER nav-wrapping and store it for
            // the transition hook's re-apply on rotation/multitasking changes.
            zapp_ios_sidebar_register((__bridge void*)window,
                                      (__bridge void*)window.rootViewController,
                                      (__bridge void*)sidebarVC,
                                      (__bridge void*)contentVC,
                                      d->numeric_id, d->sidebarNumericId,
                                      d->sidebarPresentation,
                                      d->sidebarWidth, d->sidebarMinWidth,
                                      d->sidebarMaxWidth, d->sidebarResizable,
                                      d->sidebarCollapsible);
        }

        if (split) {
            // Content pane → host slot, host identity, pane_role 0. Shared by
            // BOTH split shapes (sidebar and hidden-Primary): created into
            // contentVC.view (the split's Secondary column), which is now
            // attached to the window. Mirrors the macOS content-pane call
            // (which passes useSidebar/useInspector) — host_has_sidebar
            // reflects the shape; host_has_inspector injects zapp.hasInspector
            // so Window.current().inspector (and the kitchen-sink toggle) is
            // wired. Identity=d->numeric_id bakes the document-start
            // zapp.windowId user script, so no post-create eval is needed
            // (unlike the plain no-split path below).
            darwin_webview_create_ext((__bridge void*)window, d->inspectable, d->first_mouse,
                                      d->url, d->numeric_id, false,
                                      (__bridge void*)contentVC.view, d->numeric_id, 0,
                                      /*host_has_sidebar*/d->hasSidebar, /*host_has_inspector*/d->hasInspector);
            // _ext auto-registers by UIWindow → the content webview landed in
            // the host slot. Capture it before a later pane create clobbers it.
            WKWebView* contentWebview = (d->numeric_id >= 0 && d->numeric_id < ZAPP_MAX_WINDOW_CALLBACKS)
                ? zapp_ios_webviews[d->numeric_id] : nil;
            d->real_webview = contentWebview;
            canonicalContentWebview = contentWebview;  // captured BEFORE any pane _ext clobbers d->real_webview

            // Underpage fill on the content pane — ALWAYS (bgColor is the
            // brand bg if set, else the adaptive systemBackgroundColor).
            // Filling the pre-paint / overscroll gap means a presenting sheet
            // slides up already colored instead of flashing WebKit's default
            // white (esp. visible in dark mode). CSS paints over it.
            if (@available(iOS 15.0, *)) {
                if (contentWebview) contentWebview.underPageBackgroundColor = bgColor;
            }

            if (d->hasSidebar) {
                // Sidebar pane → its OWN transport slot, HOST identity (win-<host>
                // in JS), always-transparent intent, pane_role 1 (sets isSidebar),
                // host_has_sidebar=true. Created into sidebarVC.view (the primary
                // column). Mirrors the macOS sidebar-pane call.
                darwin_webview_create_ext((__bridge void*)window, d->inspectable, d->first_mouse,
                                          d->sidebarUrl, d->sidebarNumericId, true,
                                          (__bridge void*)sidebarVC.view, d->numeric_id, 1,
                                          /*host_has_sidebar*/true, /*host_has_inspector*/d->hasInspector);

                // _ext registered the sidebar webview by UIWindow → it overwrote
                // the HOST slot (both panes share one UIWindow). Pull the sidebar
                // webview out of its container and register BOTH panes into their
                // correct transport slots, with the sidebar's JS-visible window-id
                // mirroring the host (its identity is the host id; transport routes
                // by slot). Then restore the content webview to the host slot.
                NSString* hostWindowId = [NSString stringWithFormat:@"win-%d", d->numeric_id];
                WKWebView* sidebarWebview = nil;
                for (UIView* sub in sidebarVC.view.subviews) {
                    if ([sub isKindOfClass:[WKWebView class]]) { sidebarWebview = (WKWebView*)sub; break; }
                }
                if (sidebarWebview) {
                    zapp_ios_register_webview_slot(d->sidebarNumericId, sidebarWebview, hostWindowId);
                }
                if (contentWebview) {
                    zapp_ios_register_webview_slot(d->numeric_id, contentWebview, hostWindowId);
                }
                // Record host→sidebar for window-event fan-out (zapp_dispatch_event_to_js).
                zapp_ios_set_sidebar_slot(d->numeric_id, d->sidebarNumericId);

                // Register the content webview with the sidebar manager so it can
                // apply the safeArea-conditional leading constraint (iPad regular =
                // safeAreaLayoutGuide.leading; iPhone compact = view.leading). This
                // converts the webview from autoresizingMask to explicit Auto Layout
                // and pins top/bottom/trailing to the container. Runs for every
                // sidebar window, with or without an inspector pane — the inspector
                // pane no longer touches content layout.
                // Forward-declared at file scope; defined in ios/sidebar.m.
                extern void zapp_ios_sidebar_set_content_webview(void* window, void* webview);
                if (contentWebview) {
                    zapp_ios_sidebar_set_content_webview((__bridge void*)window,
                                                         (__bridge void*)contentWebview);
                }

                // Underpage fill on the sidebar pane (the content pane's is set
                // in the shared block above).
                if (@available(iOS 15.0, *)) {
                    if (sidebarWebview) sidebarWebview.underPageBackgroundColor = bgColor;
                }
                // (windowId / isSidebar / hasSidebar are injected as document-start
                // user scripts inside darwin_webview_create_ext — a one-shot eval
                // here would race the page commit, as the macOS path notes.)
            } else {
                // Hidden-Primary shape: no sidebar pane, so the content
                // webview still owns the host slot (the inspector block below
                // does its own re-slot + restore). Pin its edges with the
                // sidebar-equivalent model — this window has no sidebar
                // registry entry, so zapp_ios_sidebar_set_content_webview
                // (registry-keyed) cannot apply; the static helper above
                // mirrors it 1:1, storing the constraint pairs on the split.
                if ([split isKindOfClass:[ZappIOSHiddenPrimarySplitViewController class]]) {
                    zapp_ios_pin_content_webview_no_sidebar(
                        (ZappIOSHiddenPrimarySplitViewController*)split,
                        contentWebview, contentVC.view);
                }
            }
        } else {
            // Plain path (no split — i.e. no sidebar AND no inspector; a
            // no-sidebar window WITH an inspector takes the hidden-Primary
            // split path above). _ext (container=NULL → adds to the
            // scene-bound window's root view, same as the legacy
            // darwin_webview_create) so the gesture recognizers form against
            // a live responder chain. host_has_inspector=d->hasInspector is
            // kept for signature parity — it is always false on this branch.
            darwin_webview_create_ext((__bridge void*)window, d->inspectable, d->first_mouse,
                                      d->url, d->numeric_id, false,
                                      /*container*/NULL, /*identity*/-1, /*pane_role*/0,
                                      /*host_has_sidebar*/false, /*host_has_inspector*/d->hasInspector);

            if (d->numeric_id >= 0 && d->numeric_id < ZAPP_MAX_WINDOW_CALLBACKS) {
                d->real_webview = zapp_ios_webviews[d->numeric_id];
                canonicalContentWebview = d->real_webview;  // no-sidebar: real_webview IS the content webview
                // Push the canonical "win-<numericId>" into the JS context
                // so Window.current() returns the same string format that
                // Window.create() produces. Mirrors the macOS flow.
                if (d->real_webview) {
                    NSString* setIdJs = [NSString stringWithFormat:
                        @"globalThis[Symbol.for('zapp.windowId')]='win-%d';", d->numeric_id];
                    [d->real_webview evaluateJavaScript:setIdJs completionHandler:nil];
                    // Seed the webview's underpage fill (WebView2 DefaultBackground
                    // analogue) — ALWAYS: brand bg if set, else the adaptive system
                    // background. Fills the pre-paint gap so a presenting sheet
                    // slides up already colored instead of flashing white + popping
                    // content in once the load commits.
                    if (@available(iOS 15.0, *)) {
                        d->real_webview.underPageBackgroundColor = bgColor;
                    }
                }
            }
        }

        // --- Inspector VC (persistent; iOS-26 dedicated Inspector column) ----
        //
        // Built AFTER the content (+ optional sidebar) panes so contentVC and
        // d->real_webview are set in BOTH branches above. The inspector webview
        // is born in its OWN persistent VC and never re-parented (re-parenting a
        // live WKWebView resets its content process and kills the bridge).
        //
        // Use the CANONICAL content webview, NOT d->real_webview: in the sidebar
        // branch the sidebar pane's darwin_webview_create_ext ended with
        // zapp_ios_register_webview, which overwrote d->real_webview (and the host
        // slot, since restored) with the SIDEBAR webview. Capturing d->real_webview
        // here would hand the inspector block the sidebar webview — crashing the
        // iPad content re-constrain (sidebar webview lives in sidebarVC.view, no
        // common ancestor with contentVC.view) and routing the host content slot
        // to the sidebar webview (greet times out). Restore the canonical content
        // webview as real_webview too, so downstream consumers are correct.
        if (canonicalContentWebview) d->real_webview = canonicalContentWebview;
        WKWebView* contentWebviewForInspector = canonicalContentWebview;
        if (d->hasInspector) {
            // Always create + nav-wrap the persistent inspector VC here — it is
            // NOT created in the split-construction block any more (the
            // doubleColumn split built above has no inspector-shaped column to
            // place it in ahead of time). Nav-wrapping gives it its own bar/
            // title and lets it host the Close button on the <26 modal-sheet
            // fallback (see ios/inspector.m).
            inspectorVC = [[ZappIOSPaneViewController alloc] init];
            inspectorVC.windowPtr = (__bridge void*)window;
            inspectorVC.hostSlot  = d->numeric_id;
            inspectorVC.paneRole  = 3;  // #720: arms the viewDidLayoutSubviews resize-note hook
            // Inspector pane backdrop: explicit "#rrggbb" if the app set one,
            // else the adaptive system background (mirrors the sidebar pane
            // backdrop above).
            inspectorVC.view.backgroundColor = d->inspector_has_bg
                ? [UIColor colorWithRed:d->inspector_bg_r/255.0 green:d->inspector_bg_g/255.0
                                   blue:d->inspector_bg_b/255.0 alpha:1.0]
                : [UIColor systemBackgroundColor];
            UINavigationController* inspectorNav =
                [[UINavigationController alloc] initWithRootViewController:inspectorVC];

            // Create the inspector webview INTO inspectorVC.view (pane_role 3),
            // host identity, transparent, host_has_inspector=true.
            darwin_webview_create_ext((__bridge void*)window, d->inspectable, d->first_mouse,
                                      d->inspectorUrl, d->inspectorNumericId, true,
                                      (__bridge void*)inspectorVC.view, d->numeric_id, 3,
                                      /*host_has_sidebar*/d->hasSidebar, /*host_has_inspector*/true);

            // Re-slot dance (mirror the sidebar): _ext registers the new webview
            // by UIWindow, which clobbered the host slot (all panes share one
            // UIWindow). Find the inspector webview, register it in ITS slot,
            // then restore the content webview to the host slot.
            NSString* hostWindowId2 = [NSString stringWithFormat:@"win-%d", d->numeric_id];
            WKWebView* inspectorWebview = nil;
            for (UIView* sub in inspectorVC.view.subviews) {
                if ([sub isKindOfClass:[WKWebView class]]) { inspectorWebview = (WKWebView*)sub; break; }
            }
            if (inspectorWebview) {
                zapp_ios_register_webview_slot(d->inspectorNumericId, inspectorWebview, hostWindowId2);
            }
            if (contentWebviewForInspector) {
                zapp_ios_register_webview_slot(d->numeric_id, contentWebviewForInspector, hostWindowId2);
            }

            // Underpage fill on the inspector pane when the app set a window bg
            // (mirrors the sidebar/content underpage fill above).
            if (d->has_bg && inspectorWebview) {
                if (@available(iOS 15.0, *)) {
                    inspectorWebview.underPageBackgroundColor = bgColor;
                }
            }

            // iOS 26+: attach to the split's dedicated Inspector column — a
            // sibling of Primary/Secondary, orthogonal to the doubleColumn base
            // style (no tripleColumn needed). A split now exists for EVERY
            // inspector window: sidebar windows ride ZappIOSSplitViewController,
            // no-sidebar windows the hidden-Primary
            // ZappIOSHiddenPrimarySplitViewController (E3) — so this attach is
            // reachable for both shapes. Below iOS 26 this attach is skipped
            // (the Inspector-column API doesn't exist) even though the split
            // does; zapp_ios_inspector_register's own @available branching
            // then keeps the <26 modal-sheet fallback — its 26-only block is
            // the ONLY place the register touches the split, so an unattached
            // split on <26 is inert for the inspector.
            if (@available(iOS 26.0, *)) {
                if (split) {
                    [split setViewController:inspectorNav forColumn:UISplitViewControllerColumnInspector];
                }
            }

            // Hand off to the inspector manager (ios/inspector.m): it strongly
            // retains inspectorNav (so it survives on <26, when it is never
            // attached to any split column, for on-demand modal presentation)
            // and drives show/hideColumn:Inspector (26+) or a modal sheet (<26).
            zapp_ios_inspector_register((__bridge void*)window,
                                        (__bridge void*)inspectorNav,
                                        (__bridge void*)contentVC,
                                        (__bridge void*)contentWebviewForInspector,
                                        d->numeric_id, d->inspectorNumericId,
                                        d->inspectorWidth, d->inspectorMinWidth,
                                        d->inspectorMaxWidth, d->inspectorCollapsed,
                                        d->inspectorCollapsible, d->inspectorResizable);
            // Record host→inspector for pane-event fan-out (#713).
            zapp_ios_set_inspector_slot(d->numeric_id, d->inspectorNumericId);
        }

        // Replay queued setters.
        if (d->queued_title) {
            NSString* s = [NSString stringWithUTF8String:d->queued_title];
            if (s && window.windowScene) window.windowScene.title = s;
        }
        if (d->show_requested) {
            [window makeKeyAndVisible];
        }

        NSLog(@"[native] iOS window materialized: id=%d scene=%@ window=%@ webview=%@",
              d->numeric_id, scene, window, d->real_webview);
    }
}

// --- WebView ↔ Window registration (called from webview.m) ---

void zapp_ios_register_webview(void* window_ptr, void* webview_ptr) {
    UIWindow* w = (__bridge UIWindow*)window_ptr;
    WKWebView* wv = (__bridge WKWebView*)webview_ptr;

    // First check materialized real_window slots.
    for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
        ZappIOSDeferred* d = zapp_ios_deferred_list[i];
        if (d && d->real_window == w) {
            d->real_webview = wv;
            if (d->numeric_id >= 0 && d->numeric_id < ZAPP_MAX_WINDOW_CALLBACKS) {
                zapp_ios_webviews[d->numeric_id] = wv;
            }
            return;
        }
    }
    // Fallback: dispatch table direct match.
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_ios_windows[i] == w) {
            zapp_ios_webviews[i] = wv;
            return;
        }
    }
}

void* zapp_ios_get_webview_for_window(void* window_ptr) {
    UIWindow* w = (__bridge UIWindow*)window_ptr;
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_ios_windows[i] == w) return (__bridge void*)zapp_ios_webviews[i];
    }
    return NULL;
}

void zapp_ios_eval_js_all_webviews(const char* js) {
    if (!js) return;
    NSString* script = [NSString stringWithUTF8String:js];
    if (!script) return;
    void (^run)(void) = ^{
        for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
            WKWebView* wv = zapp_ios_webviews[i];
            if (wv) [wv evaluateJavaScript:script completionHandler:nil];
        }
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

// --- Window lookup helpers (mirror darwin/window.m exports) ---

int32_t darwin_window_id_for_webview(void* webview) {
    if (!webview) return 0;
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_ios_webviews[i] == (__bridge WKWebView*)webview) return i;
    }
    return 0;
}

const char* darwin_window_id_string(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_ios_window_ids[numeric_id]) {
        return [zapp_ios_window_ids[numeric_id] UTF8String];
    }
    return NULL;
}

// --- Enumerate all live window id strings as a JSON array ---
// Same signature as darwin/window.m's darwin_windows_list_json so both
// platforms compile and link. Returns a heap-dup'd JSON array; caller frees.
const char* darwin_windows_list_json(void) {
    NSMutableArray<NSString*>* seen = [NSMutableArray array];
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        NSString* wid = zapp_ios_window_ids[i];
        if (!wid) continue;
        if ([seen containsObject:wid]) continue;
        [seen addObject:wid];
    }
    NSMutableString* json = [NSMutableString stringWithString:@"["];
    BOOL first = YES;
    for (NSString* wid in seen) {
        if (!first) [json appendString:@","];
        [json appendFormat:@"\"%@\"", wid];
        first = NO;
    }
    [json appendString:@"]"];
    return strdup([json UTF8String]);
}

int32_t darwin_window_numeric_id_for_string(const char* window_id_string) {
    if (!window_id_string || !window_id_string[0]) return -1;
    NSString* target = [NSString stringWithUTF8String:window_id_string];
    if (!target) return -1;
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        if (zapp_ios_window_ids[i] && [zapp_ios_window_ids[i] isEqualToString:target]) return i;
    }
    return -1;
}

void* darwin_window_get_webview(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_ios_webviews[numeric_id]) {
        return (__bridge void*)zapp_ios_webviews[numeric_id];
    }
    return NULL;
}

// Look up the UIWindow for a numeric window id (mirrors macOS
// darwin_window_get_by_numeric_id, which returns the NSWindow). panel.m uses
// this to reach the owner window's rootViewController.view as the host view
// for a child WKWebView.
void* darwin_window_get_by_numeric_id(int32_t numeric_id) {
    if (numeric_id >= 0 && numeric_id < ZAPP_MAX_WINDOW_CALLBACKS && zapp_ios_windows[numeric_id]) {
        return (__bridge void*)zapp_ios_windows[numeric_id];
    }
    return NULL;
}

void darwin_window_eval_js(int32_t window_id, const char* js) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    WKWebView* webview = zapp_ios_webviews[window_id];
    if (!webview || !js) return;
    NSString* script = [NSString stringWithUTF8String:js];
    if (!script) return;
    void (^run)(void) = ^{ [webview evaluateJavaScript:script completionHandler:nil]; };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

void darwin_window_set_bridge_ready(const char* window_id) { (void)window_id; }

// --- Window event dispatch to JS (called from callbacks.zc) ---
//
// Mirrors darwin/window.m's `zapp_dispatch_event_to_js`. Builds a small
// JS snippet that calls `bridge.dispatchWindowEvent(...)` and evals on
// the target webview. Reusable buffer to avoid per-event allocations.

static char zapp_ios_event_js_buf[512];

static const char* zapp_ios_event_names[] = {
    "ready", "focus", "blur", "resize", "move", "close",
    "minimize", "maximize", "restore", "fullscreen", "unfullscreen",
    "modal-dismissed"
};

static inline const char* zapp_ios_get_event_name(int event_id) {
    if (event_id >= 0 && event_id < 12) return zapp_ios_event_names[event_id];
    return "unknown";
}

void zapp_dispatch_event_to_js(int32_t window_id, int32_t event_id, int32_t w, int32_t h, int32_t x, int32_t y) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    WKWebView* webview = zapp_ios_webviews[window_id];
    NSString* windowId = zapp_ios_window_ids[window_id];
    if (!webview || !windowId) return;

    const char* event_name = zapp_ios_get_event_name(event_id);
    const char* wid = [windowId UTF8String];

    bool hasPayload = (event_id == 3 /* RESIZE */ || event_id == 4 /* MOVE */ ||
                       event_id == 7 /* MAXIMIZE */ || event_id == 8 /* RESTORE */);
    if (event_id == 11 /* MODAL_DISMISSED */) {
        snprintf(zapp_ios_event_js_buf, sizeof(zapp_ios_event_js_buf),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&typeof b.dispatchWindowEvent==='function'){"
            "b.dispatchWindowEvent('%s','%s','{\"modalId\":\"win-%d\",\"code\":%d}');}})();",
            wid, event_name, w, h);
    } else if (hasPayload) {
        snprintf(zapp_ios_event_js_buf, sizeof(zapp_ios_event_js_buf),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&typeof b.dispatchWindowEvent==='function'){"
            "b.dispatchWindowEvent('%s','%s','{\"width\":%d,\"height\":%d,\"x\":%d,\"y\":%d}');}})();",
            wid, event_name, w, h, x, y);
    } else {
        snprintf(zapp_ios_event_js_buf, sizeof(zapp_ios_event_js_buf),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&typeof b.dispatchWindowEvent==='function'){"
            "b.dispatchWindowEvent('%s','%s');}})();",
            wid, event_name);
    }

    NSString* js = [[NSString alloc] initWithBytesNoCopy:zapp_ios_event_js_buf
        length:strlen(zapp_ios_event_js_buf)
        encoding:NSUTF8StringEncoding
        freeWhenDone:NO];

    // Fan out to the sidebar pane: it identifies as the same host window, so
    // the SAME JS (targeting wid = win-<host>) lands its handlers there too.
    // Mirrors darwin/window.m's sidebar fan-out. (T3 wires the sidebar's own
    // collapse/resize events; this carries the host's resize/focus/blur/etc.)
    int32_t sidebar_slot = zapp_ios_sidebar_slot_for(window_id);
    WKWebView* sidebarWebview = (sidebar_slot >= 0 && sidebar_slot != window_id &&
                                 sidebar_slot < ZAPP_MAX_WINDOW_CALLBACKS)
        ? zapp_ios_webviews[sidebar_slot] : nil;
    int32_t inspector_slot = zapp_ios_inspector_slot_for(window_id);
    WKWebView* inspectorWebview = (inspector_slot >= 0 && inspector_slot != window_id &&
                                   inspector_slot < ZAPP_MAX_WINDOW_CALLBACKS)
        ? zapp_ios_webviews[inspector_slot] : nil;

    void (^run)(void) = ^{
        [webview evaluateJavaScript:js completionHandler:nil];
        if (sidebarWebview) [sidebarWebview evaluateJavaScript:js completionHandler:nil];
        if (inspectorWebview) [inspectorWebview evaluateJavaScript:js completionHandler:nil];
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

// --- Window create / lifecycle ---
//
// Returns a deferred handle. Real allocation happens later in
// zapp_ios_materialize_pending_windows.

void* darwin_window_create(void* opts) {
    ZappIOSDeferred* d = (ZappIOSDeferred*)calloc(1, sizeof(ZappIOSDeferred));
    d->numeric_id = -1;
    d->inspectable = true;
    d->first_mouse = true;
    d->show_requested = true;  // create implies show on iOS
    if (opts) {
        // Capture sheet presentation options now — attach_modal reads
        // them later. Other WindowOptions fields are read at
        // materialization time in webview.m via wopts_*.
        extern int wopts_sheet_presentation(void* opts);
        extern int wopts_sheet_detents(void* opts);
        extern bool wopts_sheet_grabber(void* opts);
        d->sheet_presentation = (int32_t)wopts_sheet_presentation(opts);
        d->sheet_detents = (int32_t)wopts_sheet_detents(opts);
        d->sheet_grabber = wopts_sheet_grabber(opts);
        // App-set background color ("#rrggbb") — parsed now, applied at
        // materialize (same string + parse as macOS / Windows).
        extern const char* wopts_background_color(void* opts);
        const char* bg = wopts_background_color(opts);
        if (bg && bg[0] == '#' && strlen(bg) >= 7 &&
            sscanf(bg + 1, "%2x%2x%2x", &d->bg_r, &d->bg_g, &d->bg_b) == 3) {
            d->has_bg = true;
        }

        // Create-time sidebar opts — read from the SAME wopts_sidebar_*
        // accessors macOS uses (darwin/window.m). hasSidebar gates the
        // UISplitViewController materialize path. The url is strdup'd to
        // survive until materialize (the WindowOptions is only pinned across
        // this call). Inspector panes are a separate future task on iOS.
        extern const char* wopts_sidebar_url(void* opts);
        extern int32_t wopts_sidebar_numeric_id(void* opts);
        extern int32_t wopts_sidebar_width(void* opts);
        extern int32_t wopts_sidebar_min_width(void* opts);
        extern int32_t wopts_sidebar_max_width(void* opts);
        extern bool wopts_sidebar_collapsible(void* opts);
        extern bool wopts_sidebar_collapsed(void* opts);
        extern bool wopts_sidebar_can_resize(void* opts);
        extern const char* wopts_sidebar_background_color(void* opts);
        extern const char* wopts_sidebar_presentation(void* opts);
        const char* sbUrl = wopts_sidebar_url(opts);
        if (sbUrl && sbUrl[0] != '\0') {
            d->hasSidebar = true;
            d->sidebarUrl = strdup(sbUrl);
            d->sidebarNumericId = wopts_sidebar_numeric_id(opts);
            d->sidebarWidth = wopts_sidebar_width(opts);
            const char* _sbPres = wopts_sidebar_presentation(opts);
            d->sidebarPresentation = (_sbPres && _sbPres[0]) ? strdup(_sbPres) : NULL;
            d->sidebarMinWidth = wopts_sidebar_min_width(opts);
            d->sidebarMaxWidth = wopts_sidebar_max_width(opts);
            d->sidebarCollapsible = wopts_sidebar_collapsible(opts);
            d->sidebarCollapsed = wopts_sidebar_collapsed(opts);
            d->sidebarResizable = wopts_sidebar_can_resize(opts);
            const char* sbg = wopts_sidebar_background_color(opts);
            if (sbg && sbg[0] == '#' && strlen(sbg) >= 7 &&
                sscanf(sbg + 1, "%2x%2x%2x",
                       &d->sidebar_bg_r, &d->sidebar_bg_g, &d->sidebar_bg_b) == 3) {
                d->sidebar_has_bg = true;
            }
        }

        // Create-time inspector opts — read from the SAME wopts_inspector_*
        // accessors macOS uses (darwin/window.m). hasInspector gates the
        // trailing-pane materialize path. The url is strdup'd to survive until
        // materialize (the WindowOptions is only pinned across this call).
        extern const char* wopts_inspector_url(void* opts);
        extern int32_t wopts_inspector_numeric_id(void* opts);
        extern int32_t wopts_inspector_width(void* opts);
        extern bool wopts_inspector_collapsed(void* opts);
        extern int32_t wopts_inspector_min_width(void* opts);
        extern int32_t wopts_inspector_max_width(void* opts);
        extern bool wopts_inspector_collapsible(void* opts);
        extern bool wopts_inspector_can_resize(void* opts);
        extern const char* wopts_inspector_background_color(void* opts);
        const char* _insUrl = wopts_inspector_url(opts);
        d->hasInspector = (_insUrl && _insUrl[0]);
        d->inspectorUrl = d->hasInspector ? strdup(_insUrl) : NULL;
        d->inspectorNumericId = wopts_inspector_numeric_id(opts);
        d->inspectorWidth = wopts_inspector_width(opts);
        d->inspectorCollapsed = wopts_inspector_collapsed(opts);
        d->inspectorMinWidth   = wopts_inspector_min_width(opts);
        d->inspectorMaxWidth   = wopts_inspector_max_width(opts);
        d->inspectorCollapsible = wopts_inspector_collapsible(opts);
        d->inspectorResizable  = wopts_inspector_can_resize(opts);
        const char* ibg = wopts_inspector_background_color(opts);
        if (ibg && ibg[0] == '#' && strlen(ibg) >= 7 &&
            sscanf(ibg + 1, "%2x%2x%2x",
                   &d->inspector_bg_r, &d->inspector_bg_g, &d->inspector_bg_b) == 3) {
            d->inspector_has_bg = true;
        }
        extern int wopts_inspectable(void* opts);
        d->inspectable = wopts_inspectable(opts) > 0;

        // Content webview url override (macOS parity: darwin/window.m reads
        // wopts_url and passes it as url_override). strdup to survive until
        // materialize (like queued_title / sidebarUrl). NULL/empty -> default
        // initial url. This is what makes a sheet opened with url:"#sheet=foo"
        // load the requested route instead of the default page.
        extern const char* wopts_url(void* opts);
        const char* _contentUrl = wopts_url(opts);
        d->url = (_contentUrl && _contentUrl[0]) ? strdup(_contentUrl) : NULL;
    }
    for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
        if (!zapp_ios_deferred_list[i]) {
            zapp_ios_deferred_list[i] = d;
            return (void*)d;
        }
    }
    free(d);
    return NULL;
}

void darwin_window_destroy(void* handle) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        if (d->real_window) d->real_window.hidden = YES;
        free(d->queued_title);
        free(d->url);
        free(d->sidebarUrl);
        free(d->sidebarPresentation);
        free(d->inspectorUrl);
        for (int i = 0; i < ZAPP_MAX_DEFERRED; i++) {
            if (zapp_ios_deferred_list[i] == d) zapp_ios_deferred_list[i] = NULL;
        }
        free(d);
        return;
    }
    // Fallback: live UIWindow* (shouldn't happen on iOS now, but cheap to keep).
    UIWindow* w = (__bridge_transfer UIWindow*)handle;
    w.hidden = YES;
    (void)w;
}

void darwin_window_show(void* handle) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        if (d->real_window) [d->real_window makeKeyAndVisible];
        else d->show_requested = true;
        return;
    }
    UIWindow* w = (__bridge UIWindow*)handle;
    [w makeKeyAndVisible];
}

void darwin_window_hide(void* handle) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        if (d->real_window) d->real_window.hidden = YES;
        else d->show_requested = false;
        return;
    }
    UIWindow* w = (__bridge UIWindow*)handle;
    w.hidden = YES;
}

void darwin_window_force_close(void* handle) {
    darwin_window_hide(handle);
}

// --- Setters: most are no-ops on iOS ---

void darwin_window_set_title(void* handle, const char* title) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        free(d->queued_title);
        d->queued_title = (title && title[0]) ? strdup(title) : NULL;
        if (d->real_window && title) {
            NSString* s = [NSString stringWithUTF8String:title];
            if (s && d->real_window.windowScene) d->real_window.windowScene.title = s;
        }
        return;
    }
    UIWindow* w = (__bridge UIWindow*)handle;
    if (!title) return;
    NSString* s = [NSString stringWithUTF8String:title];
    if (s && w.windowScene) w.windowScene.title = s;
}

void darwin_window_set_size(void* handle, int32_t width, int32_t height) {
    (void)handle; (void)width; (void)height;
}
void darwin_window_set_position(void* handle, int32_t x, int32_t y) {
    (void)handle; (void)x; (void)y;
}
void darwin_window_minimize(void* handle) { (void)handle; }
void darwin_window_maximize(void* handle) { (void)handle; }
void darwin_window_zoom(void* handle) { (void)handle; }  // no window zoom on iOS
void darwin_window_focus(void* handle) { (void)handle; }
void darwin_window_set_fullscreen(void* handle, bool on) { (void)handle; (void)on; }
void darwin_window_set_always_on_top(void* handle, bool on) { (void)handle; (void)on; }

void darwin_window_get_size(void* handle, int32_t* out_w, int32_t* out_h) {
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    UIWindow* w = d ? d->real_window : (__bridge UIWindow*)handle;
    if (!w) {
        // Pre-materialization: report screen bounds as a best-effort.
        CGRect bounds = [UIScreen mainScreen].bounds;
        if (out_w) *out_w = (int32_t)bounds.size.width;
        if (out_h) *out_h = (int32_t)bounds.size.height;
        return;
    }
    if (out_w) *out_w = (int32_t)w.bounds.size.width;
    if (out_h) *out_h = (int32_t)w.bounds.size.height;
}

void darwin_window_get_position(void* handle, int32_t* out_x, int32_t* out_y) {
    (void)handle;
    if (out_x) *out_x = 0;
    if (out_y) *out_y = 0;  // no concept of position on iOS
}

void darwin_window_register_numeric_id(void* handle, int32_t numeric_id) {
    if (numeric_id < 0 || numeric_id >= ZAPP_MAX_WINDOW_CALLBACKS) return;
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) {
        d->numeric_id = numeric_id;
        // Slot stays nil in zapp_ios_windows until materialization;
        // pre-id_string will return NULL which is fine — no JS code is
        // running yet to ask for it.
        return;
    }
    UIWindow* w = (__bridge UIWindow*)handle;
    zapp_ios_windows[numeric_id] = w;
    zapp_ios_window_ids[numeric_id] = [NSString stringWithFormat:@"win-%d", numeric_id];
}

// --- Modal sheets — UIViewController presentation ---
//
// iOS doesn't have a direct NSWindow.beginSheet equivalent. The closest
// match is `presentViewController:animated:completion:` — slides up
// from the bottom, blocks interaction with the presenting controller
// until dismissed, and supports the iOS 13+ swipe-down-to-dismiss
// gesture. We map `Window.create({ asSheetOf: parent })` to this
// presentation by stealing the modal UIWindow's rootViewController and
// presenting it on the parent's rootViewController.
//
// On dismissal we fire the same `WINDOW_MODAL_DISMISSED` (event id 12)
// that macOS does, so JS bridge listeners ported from macOS just work.

// Helper: resolve either a deferred handle or a live UIWindow* into
// a UIWindow*. Returns nil if neither is materialized.
static UIWindow* zapp_ios_resolve_window(void* handle) {
    if (!handle) return nil;
    ZappIOSDeferred* d = zapp_ios_find_deferred(handle);
    if (d) return d->real_window;
    return (__bridge UIWindow*)handle;
}

// Modal stack — supports presenting a sheet from inside another sheet
// (the wedge audience does this: tap a row in a bottom sheet, push a
// detail page sheet on top). UIKit's pattern is to walk the
// `presentedViewController` chain to find the topmost VC, then present
// from there. We mirror that with a stack of (vc, parentId, modalId)
// so the dismissal observer knows which entry to fire WINDOW_MODAL_
// DISMISSED for.
typedef struct {
    UIViewController* __weak vc;
    int32_t parent_id;
    int32_t modal_id;
} ZappIOSModalStackEntry;

#define ZAPP_IOS_MODAL_STACK_MAX 8
static ZappIOSModalStackEntry zapp_ios_modal_stack[ZAPP_IOS_MODAL_STACK_MAX] = {0};
static int zapp_ios_modal_stack_count = 0;

// Find the topmost currently-presented VC (the one to present new
// modals from). Returns rootVC if nothing is currently presented.
static UIViewController* zapp_ios_topmost_presented(UIViewController* rootVC) {
    UIViewController* vc = rootVC;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

// Add a runtime method to UIViewController that dismisses the
// receiver — UIKeyCommand for Escape uses this as its action selector
// so iPad keyboard users (and iPhone with a hardware keyboard) can
// close any presented sheet with one keystroke. Registered once at
// +load; idempotent across multiple attach_modal invocations.
@interface ZappIOSModalEscapeFix : NSObject
@end
@implementation ZappIOSModalEscapeFix
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        IMP imp = imp_implementationWithBlock(^(id self_) {
            [(UIViewController*)self_ dismissViewControllerAnimated:YES completion:nil];
        });
        class_addMethod([UIViewController class],
                        NSSelectorFromString(@"__zapp_dismiss_modal_via_escape"),
                        imp, "v@:");
    });
}
@end

@interface ZappIOSModalDismissObserver : NSObject <UIAdaptivePresentationControllerDelegate>
@end

@implementation ZappIOSModalDismissObserver
- (void)presentationControllerDidDismiss:(UIPresentationController*)pc {
    UIViewController* dismissedVC = pc.presentedViewController;
    extern int zapp_dispatch_event(int window_id, int event_id, int w, int h, int x, int y);
    // Find this VC in the stack and remove it (anywhere — the user
    // could dismiss a non-top sheet via swipe-down on a stack with
    // adaptive presentation).
    for (int i = zapp_ios_modal_stack_count - 1; i >= 0; i--) {
        if (zapp_ios_modal_stack[i].vc == dismissedVC) {
            // ZAPP_EVENT_WINDOW_MODAL_DISMISSED == 12 (matches darwin path)
            zapp_dispatch_event(zapp_ios_modal_stack[i].parent_id, 12,
                                (int)zapp_ios_modal_stack[i].modal_id, 0, 0, 0);
            // Compact the stack.
            for (int j = i; j < zapp_ios_modal_stack_count - 1; j++) {
                zapp_ios_modal_stack[j] = zapp_ios_modal_stack[j + 1];
            }
            zapp_ios_modal_stack_count--;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].vc = nil;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].parent_id = -1;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].modal_id = -1;
            return;
        }
    }
}
@end

static ZappIOSModalDismissObserver* zapp_ios_modal_observer = nil;

void darwin_window_attach_modal(void* parent_handle, void* modal_handle) {
    if (!parent_handle || !modal_handle || parent_handle == modal_handle) return;

    // On iOS, post-UIApplicationMain Window.create allocates a deferred
    // handle but doesn't materialize a real UIWindow until something
    // (like this modal-attach call) drives the materialization. Run
    // the queue drain now so the modal's UIWindow + rootViewController
    // + WKWebView all exist before we present.
    extern void zapp_ios_materialize_pending_windows(void);
    zapp_ios_materialize_pending_windows();

    UIWindow* parent = zapp_ios_resolve_window(parent_handle);
    UIWindow* modal  = zapp_ios_resolve_window(modal_handle);
    if (!parent || !modal) return;

    // The modal's UIWindow.rootViewController is intact (we steal it
    // below at present time). The parent's may not be — if the parent
    // is itself a currently-presented modal, we cleared its UIWindow's
    // rootViewController when we presented it earlier. Resolve via:
    //   - modal-stack lookup if parent is a known modal (its real VC
    //     is the stack entry's vc, currently presented in the chain);
    //   - else the parent UIWindow's intact rootViewController (the
    //     normal "root window of the app" case).
    UIViewController* modalVC = modal.rootViewController;
    if (!modalVC) return;
    if (modalVC.presentingViewController) return;  // already presented

    UIViewController* parentRootVC = nil;
    ZappIOSDeferred* parentDef0 = zapp_ios_find_deferred(parent_handle);
    int32_t parentNumericId = parentDef0 ? parentDef0->numeric_id : -1;
    for (int i = 0; i < zapp_ios_modal_stack_count; i++) {
        if (zapp_ios_modal_stack[i].modal_id == parentNumericId) {
            parentRootVC = zapp_ios_modal_stack[i].vc;
            break;
        }
    }
    if (!parentRootVC) parentRootVC = parent.rootViewController;
    if (!parentRootVC) return;

    // For nested modals: present from the topmost currently-presented
    // VC in the chain rooted at parentRootVC. UIKit refuses to present
    // from a VC whose view isn't currently visible.
    UIViewController* parentVC = zapp_ios_topmost_presented(parentRootVC);

    // Capture numeric IDs for the dismissal callback before we tear
    // the modal UIWindow down.
    ZappIOSDeferred* modalDef = zapp_ios_find_deferred(modal_handle);
    int32_t parentId = parentNumericId;
    int32_t modalId  = modalDef  ? modalDef->numeric_id  : -1;

    // Capture sheet presentation options before the dispatch_async
    // (modalDef may not be safe to read on the main queue if it's
    // freed in some edge case).
    int32_t sheetPres = modalDef ? modalDef->sheet_presentation : 0;
    int32_t sheetDetents = modalDef ? modalDef->sheet_detents : 0;
    bool sheetGrabber = modalDef ? modalDef->sheet_grabber : false;
    // Sheet card fill — paint the presented VC's view with the window bg so the
    // sheet slides up already colored (the webview's underPageBackgroundColor,
    // set at materialize, fills the content area; this backs any inset/gap during
    // the slide). Captured off modalDef before the block (same safety reason as
    // the sheet opts above).
    bool modalHasBg = modalDef ? modalDef->has_bg : false;
    int modalBgR = modalDef ? modalDef->bg_r : 0;
    int modalBgG = modalDef ? modalDef->bg_g : 0;
    int modalBgB = modalDef ? modalDef->bg_b : 0;

    void (^run)(void) = ^{
        // Hold the VC strong before clearing rootViewController
        // (which would otherwise dealloc it — UIWindow.rootViewController
        // is the only strong ref).
        UIViewController* vcStrong = modalVC;
        modal.rootViewController = nil;
        modal.hidden = YES;

        // Map sheet presentation enum:
        //   0 = page (PageSheet) — default
        //   1 = form (FormSheet) — smaller centered card on iPad
        //   2 = fullscreen (FullScreen) — take-over modal
        //   3 = bottomSheet (UISheetPresentationController) — drawer
        switch (sheetPres) {
            case 1: vcStrong.modalPresentationStyle = UIModalPresentationFormSheet; break;
            case 2: vcStrong.modalPresentationStyle = UIModalPresentationFullScreen; break;
            case 3:
            case 0:
            default: vcStrong.modalPresentationStyle = UIModalPresentationPageSheet; break;
        }

        // Bottom sheet — UISheetPresentationController gives detents,
        // grabber, and mid-screen positioning (iOS 15+). PageSheet
        // also exposes the same controller via `sheetPresentationController`,
        // so the grabber + detent options on a regular pageSheet work.
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController* sheet = vcStrong.sheetPresentationController;
            if (sheet) {
                NSMutableArray<UISheetPresentationControllerDetent*>* detents = [NSMutableArray array];
                // Bit 0 = medium, bit 1 = large, bit 2 = small (custom,
                // iOS 16+; degrades to no entry on iOS 15).
                if (sheetDetents & 4) {
                    if (@available(iOS 16.0, *)) {
                        UISheetPresentationControllerDetent* small =
                            [UISheetPresentationControllerDetent
                                customDetentWithIdentifier:@"zapp.small"
                                resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> ctx) {
                                    return ctx.maximumDetentValue * 0.25;
                                }];
                        if (small) [detents addObject:small];
                    }
                }
                if (sheetDetents & 1) [detents addObject:[UISheetPresentationControllerDetent mediumDetent]];
                if (sheetDetents & 2) [detents addObject:[UISheetPresentationControllerDetent largeDetent]];
                // bottomSheet with no explicit detents → both available
                // (medium + large with swipe between). Page/form sheets
                // with no detents → keep system default (large only).
                if (detents.count == 0 && sheetPres == 3) {
                    [detents addObject:[UISheetPresentationControllerDetent mediumDetent]];
                    [detents addObject:[UISheetPresentationControllerDetent largeDetent]];
                }
                if (detents.count > 0) {
                    sheet.detents = detents;
                }
                sheet.prefersGrabberVisible = sheetGrabber;
            }
        }

        if (!zapp_ios_modal_observer) {
            zapp_ios_modal_observer = [[ZappIOSModalDismissObserver alloc] init];
        }
        vcStrong.presentationController.delegate = zapp_ios_modal_observer;

        // Escape dismisses the sheet — iPad hardware keyboards expect
        // this convention and iPhone hardware keyboards do too.
        // Especially important for `presentation: "fullscreen"` which
        // has no swipe-to-dismiss gesture.
        UIKeyCommand* esc = [UIKeyCommand
            keyCommandWithInput:UIKeyInputEscape
                  modifierFlags:0
                         action:NSSelectorFromString(@"__zapp_dismiss_modal_via_escape")];
        if (@available(iOS 15.0, *)) {
            esc.wantsPriorityOverSystemBehavior = YES;
        }
        [vcStrong addKeyCommand:esc];

        // Push to the modal stack so the dismissal observer can
        // route WINDOW_MODAL_DISMISSED to the right (parent, modal).
        if (zapp_ios_modal_stack_count < ZAPP_IOS_MODAL_STACK_MAX) {
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].vc = vcStrong;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].parent_id = parentId;
            zapp_ios_modal_stack[zapp_ios_modal_stack_count].modal_id = modalId;
            zapp_ios_modal_stack_count++;
        }

        UIColor* sheetCardBg = modalHasBg
            ? [UIColor colorWithRed:modalBgR/255.0 green:modalBgG/255.0 blue:modalBgB/255.0 alpha:1.0]
            : [UIColor systemBackgroundColor];
        vcStrong.view.backgroundColor = sheetCardBg;

        [parentVC presentViewController:vcStrong animated:YES completion:nil];
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

void darwin_window_detach_modal(void* parent_handle, void* modal_handle) {
    (void)parent_handle;  // iOS dismisses via the modal's presenting controller, parent is implicit
    if (!modal_handle) return;
    ZappIOSDeferred* modalDef = zapp_ios_find_deferred(modal_handle);
    int32_t modalId = modalDef ? modalDef->numeric_id : -1;
    void (^run)(void) = ^{
        // Find the right VC in the stack by modal ID, since the modal's
        // UIWindow.rootViewController got cleared when we presented
        // (vcStrong is the only retainer left, held weakly in the stack).
        UIViewController* vc = nil;
        for (int i = zapp_ios_modal_stack_count - 1; i >= 0; i--) {
            if (zapp_ios_modal_stack[i].modal_id == modalId) {
                vc = zapp_ios_modal_stack[i].vc;
                break;
            }
        }
        if (vc.presentingViewController) {
            [vc dismissViewControllerAnimated:YES completion:nil];
        }
    };
    if ([NSThread isMainThread]) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}
