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
// and (optional) sidebar panes are built, handing it the persistent inspector
// VC + the content VC + the content webview + the host/inspector ids + the
// configured width and collapsed intent. On iPad-regular inspector.m embeds the
// inspector VC trailing-in-content (re-constraining the content webview via Auto
// Layout, never re-parenting it); on iPhone-compact it merely holds the VC (the
// sheet presentation + show/hide ops are a separate next task).
extern void zapp_ios_inspector_register(void* window, void* inspectorVC,
                                        void* contentVC, void* contentWebview,
                                        int32_t host_id, int32_t inspector_id,
                                        int32_t width, bool collapsed);

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

        // The view controller holding the content webview — either the lone
        // root VC (no sidebar) or the split's secondary column (sidebar). The
        // sidebar VC is the split's primary column; nil when there's no sidebar.
        UIViewController* contentVC = nil;
        UIViewController* sidebarVC = nil;
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
            ZappIOSSplitViewController* split =
                [[ZappIOSSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
            sidebarVC = [[UIViewController alloc] init];   // primary column
            contentVC = [[UIViewController alloc] init];   // secondary column

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
                // Sidebar = the PRIMARY column in .doubleColumn style, so its
                // width is preferredPrimaryColumnWidth. (preferredSupplementary*
                // exists ONLY in .tripleColumn and THROWS NSInvalidArgument on
                // double-column.) Governed by the min/max set above.
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
        } else {
            // Single-pane window: lone root VC hosting the content webview.
            UIViewController* root = [[UIViewController alloc] init];
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

        if (d->hasSidebar) {
            // Content pane → host slot, host identity, pane_role 0, host_has_
            // sidebar=true, host_has_inspector=d->hasInspector. Created into
            // contentVC.view (the split's secondary column), which is now attached
            // to the window. Mirrors the macOS content-pane call (which passes
            // useSidebar/useInspector). host_has_inspector injects zapp.hasInspector
            // so Window.current().inspector (and the kitchen-sink toggle) is wired.
            darwin_webview_create_ext((__bridge void*)window, d->inspectable, d->first_mouse,
                                      d->url, d->numeric_id, false,
                                      (__bridge void*)contentVC.view, d->numeric_id, 0,
                                      /*host_has_sidebar*/true, /*host_has_inspector*/d->hasInspector);
            // _ext auto-registers by UIWindow → the content webview landed in
            // the host slot. Capture it before the sidebar create clobbers it.
            WKWebView* contentWebview = (d->numeric_id >= 0 && d->numeric_id < ZAPP_MAX_WINDOW_CALLBACKS)
                ? zapp_ios_webviews[d->numeric_id] : nil;
            d->real_webview = contentWebview;
            canonicalContentWebview = contentWebview;  // captured BEFORE the sidebar _ext clobbers d->real_webview

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
            // and pins top/bottom/trailing to the container. Only called when
            // there is NO inspector pane — when an inspector is present,
            // inspector.m owns the full AutoLayout conversion (including trailing)
            // and calls zapp_ios_sidebar_register_leading_constraints to hand the
            // leading constraints to the sidebar coordinator for trait-change updates.
            // Forward-declared at file scope; defined in ios/sidebar.m.
            extern void zapp_ios_sidebar_set_content_webview(void* window, void* webview);
            if (contentWebview && !d->hasInspector) {
                zapp_ios_sidebar_set_content_webview((__bridge void*)window,
                                                     (__bridge void*)contentWebview);
            }

            // Underpage fill on both panes — ALWAYS (bgColor is the brand bg if
            // set, else the adaptive systemBackgroundColor). Filling the pre-paint
            // / overscroll gap means a presenting sheet slides up already colored
            // instead of flashing WebKit's default white and popping content in
            // (esp. visible in dark mode). The page's CSS background paints over it.
            if (@available(iOS 15.0, *)) {
                if (contentWebview) contentWebview.underPageBackgroundColor = bgColor;
                if (sidebarWebview) sidebarWebview.underPageBackgroundColor = bgColor;
            }
            // (windowId / isSidebar / hasSidebar are injected as document-start
            // user scripts inside darwin_webview_create_ext — a one-shot eval
            // here would race the page commit, as the macOS path notes.)
        } else {
            // _ext (container=NULL → adds to the scene-bound window's root view,
            // same as the legacy darwin_webview_create) so the gesture recognizers
            // form against a live responder chain. We use _ext (not the legacy
            // wrapper) to pass host_has_inspector=d->hasInspector — injecting
            // zapp.hasInspector so a no-sidebar window with an inspector still
            // wires Window.current().inspector.
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

        // --- Inspector pane (trailing, the iOS analog of macOS's trailing
        // NSSplitViewItem) -----------------------------------------------------
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
            // Persistent inspector VC owns the inspector webview for life (never
            // re-parented). Created here so the webview is born in its final home.
            UIViewController* inspectorVC = [[UIViewController alloc] init];
            inspectorVC.view.backgroundColor = [UIColor systemBackgroundColor];

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

            // Hand off to the inspector manager (ios/inspector.m): it embeds the
            // VC trailing-in-content on iPad-regular (honoring collapsed) and just
            // holds it on iPhone-compact (the sheet presentation is the next task).
            zapp_ios_inspector_register((__bridge void*)window,
                                        (__bridge void*)inspectorVC,
                                        (__bridge void*)contentVC,
                                        (__bridge void*)contentWebviewForInspector,
                                        d->numeric_id, d->inspectorNumericId,
                                        d->inspectorWidth, d->inspectorCollapsed);
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
        const char* _insUrl = wopts_inspector_url(opts);
        d->hasInspector = (_insUrl && _insUrl[0]);
        d->inspectorUrl = d->hasInspector ? strdup(_insUrl) : NULL;
        d->inspectorNumericId = wopts_inspector_numeric_id(opts);
        d->inspectorWidth = wopts_inspector_width(opts);
        d->inspectorCollapsed = wopts_inspector_collapsed(opts);
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
