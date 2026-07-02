// iOS native inspector — doubleColumn base + the iOS-26 dedicated Inspector
// column (UISplitViewControllerColumnInspector), with a modal-sheet fallback
// below iOS 26. Ported from the proven spike
// (spikes/ios-splitview-reference/src/AppDelegate.m + ContentViewController.m,
// human-smoked on iPad + iPhone, iOS 26.5).
//
// window.m (materialize) creates the inspector VC PERSISTENTLY (so it keeps
// accumulating route events and always shows the correct content, whichever
// path presents it), nav-wraps it, and — on iOS 26+, when a split exists —
// attaches the nav to the split's Inspector column via
// setViewController:forColumn:UISplitViewControllerColumnInspector BEFORE
// calling zapp_ios_inspector_register (see window.m's inspector pane block).
//
// iOS 26+ (UISplitViewControllerColumnInspector is API_AVAILABLE(ios(26.0)),
// orthogonal to the doubleColumn base style — Primary=sidebar, Secondary=
// content, the permanent canvas):
//   expand/collapse/toggle drive show/hideColumn:UISplitViewControllerColumnInspector;
//   visibility is read via -isShowingColumn:. The inspector-expanded/-collapsed
//   emits do NOT come from those imperative calls: every 26+ visibility change
//   (programmatic OR UIKit-initiated, e.g. the user swipe-dismissing the iPhone
//   auto-sheet) flows through the split delegate's didShowColumn:/didHideColumn:
//   (ios/sidebar.m) into zapp_ios_inspector_column_did_show/_did_hide below —
//   the SINGLE 26+ emit source, deduped by lastCollapsedEmit (exactly-once per
//   real state change; the launch-time deferred show/hideColumn stays silent).
//   On iPad (regular width) this is a hideable/resizable column beside the
//   content; on iPhone (compact width) UIKit auto-presents the SAME column
//   as a sheet — no horizontalSizeClass branching needed on our side.
//
// iOS 15–25 fallback (Zapp's deployment target is 15.0; there is no Inspector
//   column below 26 — the split itself always exists now: sidebar windows get
//   the sidebar split, no-sidebar windows the hidden-Primary split, see
//   window.m's ZappIOSHiddenPrimarySplitViewController / E3): the persistent
//   inspector nav is presented as a MODAL
//   UISheetPresentationController sheet (medium+large detents, grabber) on
//   BOTH iPhone and iPad, with a Close bar button (iPad form-sheets lack a
//   guaranteed edge dismiss). expand presents it; collapse dismisses it;
//   presented-state is read directly off the nav (presentingViewController),
//   not a separate BOOL.
//
// darwin_inspector_* symbol names are preserved (imported by router.nim).

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
extern int32_t zapp_ios_sidebar_slot_for(int32_t host_slot);

// Forward declaration — darwin_inspector_collapse is defined further down in
// this file; the Close-button target/action (installed on the <26 modal sheet
// AND on the 26+ UIKit-managed auto-sheet, see
// zapp_ios_inspector_apply_sheet_affordances) calls back into it so
// expand/collapse/toggle/Close-tap all share the exact same collapse logic
// (single source of truth for the hide + emit discipline on each path).
void darwin_inspector_collapse(int32_t window_id);

// Forward declarations — ZappIOSInspectorController (declared below) and the
// name-only emit helper (defined further down, after the emit-with-data
// helper it wraps). Needed here because presentationControllerDidDismiss:
// (below) calls it.
@class ZappIOSInspectorController;
void zapp_ios_inspector_emit(ZappIOSInspectorController* c, const char* eventName);

// Honesty helper: a control that genuinely cannot work on iOS logs ONCE per
// control per process instead of silently no-op'ing. Callers still emit the
// usual parity event so JS-side state stays coherent. Main-thread only (all
// darwin_inspector_* ops hop through zapp_ios_inspector_on_main).
void zapp_ios_control_unsupported(const char* control, const char* reason) {
    if (!control || !reason) return;
    static NSMutableSet<NSString*>* zapp_warned = nil;
    if (!zapp_warned) zapp_warned = [NSMutableSet set];
    NSString* key = [NSString stringWithUTF8String:control];
    if ([zapp_warned containsObject:key]) return;
    [zapp_warned addObject:key];
    NSLog(@"[zapp] %s is not supported on iOS: %s", control, reason);
}

// --- Per-window registry --------------------------------------------------
//
// Keyed by the host UIWindow (NSValue-wrapped pointer), mirroring sidebar.m's
// zapp_ios_sidebars. Inspector:* control ops can arrive from ANY pane's
// transport slot; all resolve to the same host UIWindow via
// darwin_window_get_by_numeric_id, so the host-window key catches them all.

@interface ZappIOSInspectorController : NSObject <UIAdaptivePresentationControllerDelegate>
// The persistent inspector nav (UINavigationController wrapping the inspector
// VC). STRONG: on iOS 26+ with a split it is also referenced by the split
// (setViewController:forColumn:Inspector), but on <26 — or with no split at
// all — nothing else retains it, so this registry is its sole owner between
// expand/collapse cycles.
@property (nonatomic, strong) UINavigationController* inspectorNav;
@property (nonatomic, weak)   UIViewController* contentVC;     // content pane VC (Primary/Secondary)
@property (nonatomic, assign) int32_t hostWindowId;           // content/host webview slot
@property (nonatomic, assign) int32_t inspectorSlotId;        // inspector webview slot
@property (nonatomic, assign) int32_t width;                   // configured (expanded) width
@property (nonatomic, assign) int32_t configuredMinWidth;  // minimumInspectorColumnWidth (0 = automatic)
@property (nonatomic, assign) int32_t configuredMaxWidth;  // maximumInspectorColumnWidth (0 = automatic)
@property (nonatomic, assign) BOOL resizable;              // divider-drag allowed (via min==max pin when NO)
@property (nonatomic, assign) BOOL collapsible;            // stored; no iOS user-collapse affordance to gate (WARN)
// Dedupe guard for the iOS-26 column emit hooks (mirrors sidebar.m's
// lastCollapsedEmit): the last collapsed state we emitted on the 26+ path.
// Seeded at register time from the create-time `collapsed` value so the
// launch-time deferred show/hideColumn dance never fires a spurious emit;
// flipped ONLY by zapp_ios_inspector_column_did_show/_did_hide. The <26
// modal-sheet fallback keeps its own (previously reviewed) emit discipline
// and never touches this flag — the two paths are mutually exclusive per
// window (a window either has a split on 26+ or it doesn't).
@property (nonatomic, assign) BOOL lastCollapsedEmit;
// Live divider-drag resize emits (#720) — mirrors sidebar.m's
// ZappIOSSidebarController.lastLayoutEmitWidth/layoutEmitScheduled. Seeded to
// the configured width at register so the first (launch) layout pass emits
// nothing; layoutEmitScheduled coalesces per-frame layout callbacks to at
// most one emit per runloop tick.
@property (nonatomic, assign) int32_t lastLayoutEmitWidth;
@property (nonatomic, assign) BOOL layoutEmitScheduled;
// Host content webview: retained here for parity with the sidebar controller
// pattern (not required by any runtime op below, but cheap to keep in sync).
@property (nonatomic, strong) WKWebView* contentWebview;
@end

@implementation ZappIOSInspectorController

// Sheet-dismiss path (<26 fallback): the user swiped the modally-presented
// inspector sheet down. This delegate method only fires for INTERACTIVE
// dismissal (swipe), never for a programmatic -dismissViewController: call,
// so there is no double-emit risk with darwin_inspector_collapse's own emit.
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    zapp_ios_inspector_emit(self, "inspector-collapsed");
}

// Close bar-button target — shared by the <26 modal sheet fallback AND the
// 26+ UIKit-managed auto-sheet (installed by
// zapp_ios_inspector_apply_sheet_affordances). Delegates to
// darwin_inspector_collapse so the tap and the programmatic collapse() path
// share identical logic (<26: dismiss + inline emit; 26+: hideColumn →
// didHideColumn delegate → single-source emit).
- (void)zapp_closeInspectorTapped {
    darwin_inspector_collapse(self.hostWindowId);
}

@end

static NSMutableDictionary<NSValue*, ZappIOSInspectorController*>* zapp_ios_inspectors = nil;

static void zapp_ios_inspector_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// slot -> owning UIWindow -> registry key. Works from ANY pane's slot (content,
// sidebar, or inspector) since they all share the host UIWindow.
static ZappIOSInspectorController* zapp_ios_inspector_for_slot(int32_t slot_id) {
    if (!zapp_ios_inspectors) return nil;
    void* win_ptr = darwin_window_get_by_numeric_id(slot_id);
    if (!win_ptr) return nil;
    NSValue* key = [NSValue valueWithPointer:win_ptr];
    return zapp_ios_inspectors[key];
}

// Walk the presentedViewController chain to the topmost currently-presented
// VC (mirrors window.m's zapp_ios_topmost_presented, kept local here to avoid
// a cross-file static dependency). Returns root when nothing is presented.
static UIViewController* zapp_ios_inspector_topmost_presented(UIViewController* root) {
    UIViewController* vc = root;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// --- Event fan-out (mirrors darwin/sidebar.m's zapp_pane_emit) ------------
//
// dispatchWindowEvent's first arg is the target window id ("win-<hostId>");
// both panes carry the host id. eventName is the bare suffix
// ("inspector-collapsed" / "inspector-resized"); bootstrap/webview.ts prepends
// "window:". dataJson is the optional 3rd arg — nil emits `undefined`, otherwise
// a single-quoted JSON literal (mirroring macOS's zapp_pane_emit), which the
// runtime parses for the bare-`width` resize payload. Eval'd to BOTH the host
// slot AND (when distinct) the inspector slot.
static void zapp_ios_inspector_emit_data(ZappIOSInspectorController* c,
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
    if (c.inspectorSlotId >= 0 && c.inspectorSlotId != c.hostWindowId) {
        darwin_window_eval_js(c.inspectorSlotId, js);
    }
    int32_t sidebarSlot = zapp_ios_sidebar_slot_for(c.hostWindowId);
    if (sidebarSlot >= 0 && sidebarSlot != c.hostWindowId && sidebarSlot != c.inspectorSlotId) {
        darwin_window_eval_js(sidebarSlot, js);
    }
}

// Name-only emit (no payload) — collapse/expand transitions.
void zapp_ios_inspector_emit(ZappIOSInspectorController* c, const char* eventName) {
    zapp_ios_inspector_emit_data(c, eventName, nil);
}

// inspector-resized carries a bare width under the top-level `width` key
// ({"width":N}), matching darwin/inspector.m's resize payload + the
// bareWidth branch in bootstrap/webview.ts's dispatchWindowEvent.
static void zapp_ios_inspector_emit_resize(ZappIOSInspectorController* c, int32_t width) {
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", (int)width];
    zapp_ios_inspector_emit_data(c, "inspector-resized", json);
}

// Live divider-drag resize emits (#720) — mirrors sidebar.m's
// zapp_ios_sidebar_note_layout_width (see that file for the full rationale on
// the per-frame viewDidLayoutSubviews source + the coalesce-to-one-tick /
// dedupe-on-rounded-width pattern). Called from window.m's
// ZappIOSPaneViewController.viewDidLayoutSubviews (paneRole 3).
//
// Two guards beyond the sidebar version, both false-positive sources unique
// to the inspector's two presentation forms:
//   - <26 (or no split): the persistent inspector nav is shown as a modal
//     UISheetPresentationController sheet. presentingViewController != nil
//     detects this — a sheet's frame changes are detent geometry, not a
//     draggable-column resize, so this reports nothing while presented.
//   - 26+: the split may exist but the Inspector column itself hidden/tiled-
//     away (isShowingColumn: false) — its VC still lays out off-screen at its
//     last width, which would otherwise read as a phantom resize.
void zapp_ios_inspector_note_layout_width(void* window_ptr, CGFloat width) {
    if (!window_ptr || !zapp_ios_inspectors) return;
    ZappIOSInspectorController* c = zapp_ios_inspectors[[NSValue valueWithPointer:window_ptr]];
    if (!c) return;
    if (c.inspectorNav.presentingViewController != nil) return;  // <26/no-split modal sheet, not a column
    UISplitViewController* split = c.contentVC.splitViewController;
    if (!split) return;
    if (@available(iOS 26.0, *)) {
        if (![split isShowingColumn:UISplitViewControllerColumnInspector]) return;
    }
    int32_t w = (int32_t)lround(width);
    if (w <= 1 || w == c.lastLayoutEmitWidth) return;
    c.lastLayoutEmitWidth = w;
    if (c.layoutEmitScheduled) return;
    c.layoutEmitScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        c.layoutEmitScheduled = NO;
        zapp_ios_inspector_emit_resize(c, c.lastLayoutEmitWidth);
    });
}

// --- iOS-26 Inspector column show/hide hooks (single 26+ emit source) ------
//
// Called from ios/sidebar.m's UISplitViewControllerDelegate
// (splitViewController:didShowColumn:/didHideColumn:, both ios(26.0))
// whenever the split's Inspector column becomes visible/hidden — REGARDLESS
// of who initiated it: darwin_inspector_expand/collapse/toggle, the
// launch-time deferred show/hideColumn in zapp_ios_inspector_register, or
// UIKit itself (the user swipe-dismissing the iPhone auto-presented sheet —
// the transition the old inline emits missed, leaving the JS `collapsed`
// getter stale). Exactly-once by construction: every 26+ visibility change
// funnels through these two functions, and lastCollapsedEmit (seeded from the
// create-time `collapsed` value) suppresses repeats and the launch dance.

// Auto-sheet affordances for the 26+ Inspector column, decided by how UIKit
// adapted the column THIS time (the form can change between shows — rotation
// or a multitasking resize in between):
//   PRESENTED (compact — iPhone, narrow iPad multitasking): UIKit auto-
//     presented the column as a sheet. In compact-HEIGHT landscape that sheet
//     is full-screen with no grabber and NO swipe-dismiss, so a Close bar
//     button is required (without it the user cannot leave the inspector);
//     in portrait it swipe-dismisses but hides the grabber, so we request the
//     grabber explicitly as well.
//   TILED (regular — iPad): a real column beside the content; it must not
//     carry an X, so any previously installed Close button is removed.
//
// Close routes through zapp_closeInspectorTapped → darwin_inspector_collapse
// → hideColumn:Inspector. show/hideColumn: is the canonical control for the
// column in EVERY adaptation, so hideColumn retracts the UIKit-managed sheet
// exactly like it hides the tiled column (and the resulting didHideColumn:
// delegate callback produces the collapsed emit).
//
// No collision with the <26 modal-sheet fallback's own Close install in
// darwin_inspector_expand: this helper only runs from the 26+ column hooks,
// and the fallback path (<26, or no split) never fires those delegate
// callbacks. Both installs target the same selector, so even a hypothetical
// overlap would be behaviorally identical.
static void zapp_ios_inspector_apply_sheet_affordances(ZappIOSInspectorController* c) {
    if (!c || !c.inspectorNav) return;
    UIViewController* inspectorRoot = c.inspectorNav.viewControllers.firstObject;
    if (!inspectorRoot) return;
    if (c.inspectorNav.presentingViewController) {
        // UIKit-managed sheet: ensure the Close escape hatch + grabber.
        if (!inspectorRoot.navigationItem.rightBarButtonItem) {
            inspectorRoot.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
                initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                      target:c
                                      action:@selector(zapp_closeInspectorTapped)];
        }
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController* sheet = c.inspectorNav.sheetPresentationController;
            if (sheet) sheet.prefersGrabberVisible = YES;
        }
    } else {
        // Real tiled column (iPad regular width): no X.
        inspectorRoot.navigationItem.rightBarButtonItem = nil;
    }
}

void zapp_ios_inspector_column_did_show(void* window) {
    if (!window) return;
    zapp_ios_inspector_on_main(^{
        if (!zapp_ios_inspectors) return;
        ZappIOSInspectorController* c = zapp_ios_inspectors[[NSValue valueWithPointer:window]];
        if (!c) return;
        // Affordances run on EVERY show (not deduped) — the presentation form
        // may differ from the previous show. Prefer the synchronous
        // presentingViewController check; if UIKit hasn't wired up the
        // auto-presentation by the time this delegate callback runs, re-check
        // on the next main-queue tick (the deferred pass also correctly
        // REMOVES the Close button when the column landed tiled).
        if (c.inspectorNav.presentingViewController) {
            zapp_ios_inspector_apply_sheet_affordances(c);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                zapp_ios_inspector_apply_sheet_affordances(c);
            });
        }
        if (!c.lastCollapsedEmit) return;  // already expanded — no state change, stay silent
        c.lastCollapsedEmit = NO;
        zapp_ios_inspector_emit(c, "inspector-expanded");
    });
}

void zapp_ios_inspector_column_did_hide(void* window) {
    if (!window) return;
    zapp_ios_inspector_on_main(^{
        if (!zapp_ios_inspectors) return;
        ZappIOSInspectorController* c = zapp_ios_inspectors[[NSValue valueWithPointer:window]];
        if (!c) return;
        if (c.lastCollapsedEmit) return;   // already collapsed — no state change, stay silent
        c.lastCollapsedEmit = YES;
        zapp_ios_inspector_emit(c, "inspector-collapsed");
    });
}

// --- Registry API consumed by window.m ------------------------------------
//
// window.m calls this AFTER building the persistent inspector nav and (on
// iOS 26+, when a split exists) attaching it to the split's Inspector column.
// This function:
//   • strongly retains inspectorNav — it must survive on <26 (or with no
//     split at all), where nothing else holds a reference to it.
//   • stores contentVC (weak), ids, width, min/max, collapsible, resizable,
//     and seeds the lastCollapsedEmit dedupe from the create-time collapsed
//     value (so the deferred launch column op below emits nothing).
//   • on iOS 26+ with a split: applies preferred width + min/max (or the
//     resizable:false min==max pin), then honors `collapsed` EXPLICITLY in
//     BOTH directions with a deferred show/hideColumn (one tick, so it lands
//     AFTER UIKit's initial layout — Zapp's materialize attaches the column
//     VISIBLE, unlike the spike, so collapsed:true needs the explicit hide).
//   • registers the controller in the registry so darwin_inspector_* can
//     find it from any pane's transport slot.
void zapp_ios_inspector_register(void* window, void* inspectorNav, void* contentVC,
                                 void* contentWebview, int32_t host_id,
                                 int32_t inspector_id, int32_t width, int32_t min_width,
                                 int32_t max_width, bool collapsed, bool collapsible,
                                 bool resizable) {
    if (!window || !inspectorNav || !contentVC) return;
    zapp_ios_inspector_on_main(^{
        if (!zapp_ios_inspectors) zapp_ios_inspectors = [NSMutableDictionary dictionary];

        UINavigationController* nav = (__bridge UINavigationController*)inspectorNav;
        UIViewController* cvc = (__bridge UIViewController*)contentVC;
        if (!nav || !cvc) return;

        ZappIOSInspectorController* c = [[ZappIOSInspectorController alloc] init];
        c.inspectorNav    = nav;   // strong — see header comment
        c.contentVC       = cvc;   // weak
        c.hostWindowId    = host_id;
        c.inspectorSlotId = inspector_id;
        c.width           = (width > 0 ? width : 280);
        c.configuredMinWidth = min_width;
        c.configuredMaxWidth = max_width;
        c.resizable       = (BOOL)resizable;
        c.collapsible     = (BOOL)collapsible;
        c.contentWebview  = (__bridge WKWebView*)contentWebview;
        // #720: seed the live-resize dedupe to the configured width so the
        // first (launch) viewDidLayoutSubviews pass — which lands at that same
        // width — does not fire a spurious resize event.
        c.lastLayoutEmitWidth = c.width;
        c.layoutEmitScheduled = NO;
        // Seed the 26+ emit dedupe from the create-time collapsed state so the
        // deferred launch show/hideColumn below reaches the delegate hooks as a
        // SAME-STATE callback (silent) — no spurious launch emit in either
        // direction; only a real post-launch state change emits.
        c.lastCollapsedEmit = collapsed ? YES : NO;

        // Shared warn path for controls the iOS inspector genuinely cannot
        // honor when it isn't a dedicated split column (<26, or 26+ with no
        // sidebar split to attach the Inspector column to — the modal-sheet
        // fallback in both cases). min/max never warn here: Nim always
        // materializes them (180/400 defaults), so a mismatch there isn't an
        // explicit app choice the way resizable:false/collapsible:false are.
        void (^warnUnsupportedOnSheetFallback)(void) = ^{
            if (!c.resizable) {
                zapp_ios_control_unsupported("inspector.resizable",
                    "below iOS 26 (or without a sidebar split) the inspector is a system modal sheet");
            }
            if (!c.collapsible) {
                zapp_ios_control_unsupported("inspector.collapsible",
                    "the iOS inspector sheet has no user-collapse affordance to gate; "
                    "programmatic collapse()/expand()/toggle() always work");
            }
        };

        // iOS 26+: initial width + visibility on the dedicated Inspector
        // column, when a split exists (sidebar window). No-op on <26 or when
        // there is no split — the modal-sheet fallback simply isn't presented
        // until darwin_inspector_expand is called (that IS "collapsed").
        if (@available(iOS 26.0, *)) {
            UISplitViewController* split = cvc.splitViewController;
            if (split) {
                if (c.width > 0) {
                    split.preferredInspectorColumnWidth = (CGFloat)c.width;
                }
                if (!c.resizable && c.width > 0) {
                    // resizable:false at create — pin the column (ownership pattern,
                    // mirrors darwin_sidebar_set_width's frozen path).
                    split.minimumInspectorColumnWidth = (CGFloat)c.width;
                    split.maximumInspectorColumnWidth = (CGFloat)c.width;
                } else {
                    if (c.configuredMinWidth > 0)
                        split.minimumInspectorColumnWidth = (CGFloat)c.configuredMinWidth;
                    if (c.configuredMaxWidth > 0)
                        split.maximumInspectorColumnWidth = (CGFloat)c.configuredMaxWidth;
                }
                if (!c.collapsible) {
                    zapp_ios_control_unsupported("inspector.collapsible",
                        "the iOS Inspector column has no user-collapse affordance to gate; "
                        "programmatic collapse()/expand()/toggle() always work");
                }
                // Zapp's materialize starts the Inspector column VISIBLE (unlike the
                // spike's hidden-by-default assumption), so honor `collapsed` explicitly
                // in BOTH directions. Deferred to the next runloop so it runs AFTER
                // UIKit's initial column layout (mirrors the launch-visibility dance).
                if (!collapsed) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [split showColumn:UISplitViewControllerColumnInspector];
                    });
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [split hideColumn:UISplitViewControllerColumnInspector];
                    });
                }
            } else {
                warnUnsupportedOnSheetFallback();
            }
        } else {
            warnUnsupportedOnSheetFallback();
        }

        NSValue* key = [NSValue valueWithPointer:window];
        zapp_ios_inspectors[key] = c;

        NSLog(@"[native] iOS inspector registered (column model): host=%d inspector=%d width=%d collapsed=%d",
              host_id, inspector_id, c.width, (int)collapsed);
    });
}

void zapp_ios_inspector_unregister(void* window) {
    if (!window) return;
    zapp_ios_inspector_on_main(^{
        if (!zapp_ios_inspectors) return;
        NSValue* key = [NSValue valueWithPointer:window];
        [zapp_ios_inspectors removeObjectForKey:key];
    });
}

// --- Control ops (router entry points) ------------------------------------
//
// All keyed by a transport slot (host OR inspector pane);
// zapp_ios_inspector_for_slot resolves either to the host record.

// Show the inspector.
//   iOS 26+ with a split: showColumn:Inspector (adapts automatically — a
//     resizable column on iPad, an auto-presented sheet on iPhone).
//   <26, or no split: present the retained inspector nav as a modal sheet
//     (medium+large detents, grabber, Close button). Guarded against
//     double-present.
void darwin_inspector_expand(int32_t window_id) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;

        UISplitViewController* split = c.contentVC.splitViewController;

        if (@available(iOS 26.0, *)) {
            if (split) {
                // No inline emit: showColumn flows through the split delegate's
                // didShowColumn: → zapp_ios_inspector_column_did_show — the
                // single 26+ emit source (deduped there, so a no-op expand on
                // an already-visible column stays silent).
                [split showColumn:UISplitViewControllerColumnInspector];
                return;
            }
        }

        // <26 (or no split): modal sheet fallback.
        if (c.inspectorNav.presentingViewController) return;  // already presented — guard double-present

        c.inspectorNav.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController* sheet = c.inspectorNav.sheetPresentationController;
            if (sheet) {
                sheet.detents = @[
                    [UISheetPresentationControllerDetent mediumDetent],
                    [UISheetPresentationControllerDetent largeDetent],
                ];
                sheet.prefersGrabberVisible = YES;
            }
        }
        // Close button — iPad form-sheets lack a guaranteed edge-dismiss
        // affordance, so give the inspector's root VC an explicit Close item.
        UIViewController* inspectorRoot = c.inspectorNav.viewControllers.firstObject;
        inspectorRoot.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                  target:c
                                  action:@selector(zapp_closeInspectorTapped)];
        c.inspectorNav.presentationController.delegate = c;

        UIViewController* presenterRoot = split ?: c.contentVC;
        UIViewController* presenter = zapp_ios_inspector_topmost_presented(presenterRoot);
        [presenter presentViewController:c.inspectorNav animated:YES completion:nil];
        zapp_ios_inspector_emit(c, "inspector-expanded");
    });
}

// Hide the inspector.
//   iOS 26+ with a split: hideColumn:Inspector.
//   <26, or no split: dismiss the modal sheet if presented.
void darwin_inspector_collapse(int32_t window_id) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;

        UISplitViewController* split = c.contentVC.splitViewController;

        if (@available(iOS 26.0, *)) {
            if (split) {
                // No inline emit: hideColumn flows through the split delegate's
                // didHideColumn: → zapp_ios_inspector_column_did_hide — the
                // single 26+ emit source (deduped there, so a no-op collapse on
                // an already-hidden column stays silent).
                [split hideColumn:UISplitViewControllerColumnInspector];
                return;
            }
        }

        // <26 (or no split): dismiss the modal sheet if it is actually presented
        // (guard against a spurious emit on a no-op collapse).
        if (c.inspectorNav.presentingViewController) {
            [c.inspectorNav dismissViewControllerAnimated:YES completion:nil];
            zapp_ios_inspector_emit(c, "inspector-collapsed");
        }
    });
}

// Toggle from live state.
//   iOS 26+ with a split: branch on -isShowingColumn:Inspector — the clean
//     iOS-26 API, no BOOL bookkeeping needed.
//   <26, or no split: branch on whether the modal sheet is currently presented.
void darwin_inspector_toggle(int32_t window_id) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;

        UISplitViewController* split = c.contentVC.splitViewController;

        if (@available(iOS 26.0, *)) {
            if (split) {
                // No inline emits: both branches flow through the split
                // delegate's didShow/didHideColumn: hooks — the single 26+
                // emit source (see zapp_ios_inspector_column_did_show/_did_hide).
                if ([split isShowingColumn:UISplitViewControllerColumnInspector]) {
                    [split hideColumn:UISplitViewControllerColumnInspector];
                } else {
                    [split showColumn:UISplitViewControllerColumnInspector];
                }
                return;
            }
        }

        // <26 (or no split): toggle the modal sheet presentation. Delegate to
        // expand/collapse so the emit + guard logic stays in one place.
        if (c.inspectorNav.presentingViewController) {
            darwin_inspector_collapse(window_id);
        } else {
            darwin_inspector_expand(window_id);
        }
    });
}

// Set the (expanded) inspector width.
//   iOS 26+ with a split: drives split.preferredInspectorColumnWidth (takes
//     precedence over preferredInspectorColumnWidthFraction — verified in the
//     UISplitViewController.h SDK header).
//     Post-user-drag, UIKit's private drag-pin overrides the preferred width
//     (user-resize-wins policy; see docs/superpowers/research/
//     2026-07-01-ios-column-width-drag-pin.md) — the assignment still ARMS
//     the width the user's divider double-tap snaps back to.
//   <26, or no split: full-width/full-screen modal sheet — width is n/a;
//     warns once via zapp_ios_control_unsupported.
// Emits inspector-resized for state parity with the runtime InspectorHandle.
void darwin_inspector_set_width(int32_t window_id, int32_t width) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        c.width = width;

        bool applied = false;
        if (@available(iOS 26.0, *)) {
            UISplitViewController* split = c.contentVC.splitViewController;
            if (split && width > 0) {
                split.preferredInspectorColumnWidth = (CGFloat)width;
                applied = true;
            }
        }
        if (!applied) {
            zapp_ios_control_unsupported("inspector.setWidth",
                "below iOS 26 (or without a sidebar split) the inspector is a system modal sheet with no adjustable width");
        }
        zapp_ios_inspector_emit_resize(c, width);
    });
}

// There is no iOS user-collapse affordance on the Inspector column to gate
// (presentsWithGesture governs the primary column only — SDK header :128).
// Store the intent for state parity and warn once; darwin_inspector_toggle/
// collapse/expand ALWAYS keep working regardless (matches the sidebar's
// documented semantics).
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        c.collapsible = (BOOL)can_collapse;
        if (!can_collapse) {
            zapp_ios_control_unsupported("inspector.setCollapsible",
                "the iOS Inspector column has no user-collapse affordance to gate; "
                "programmatic collapse()/expand()/toggle() always work");
        }
    });
}

// Lock or unlock the inspector divider drag. resizable==false clamps
// minimumInspectorColumnWidth == maximumInspectorColumnWidth to the LIVE
// column width (a drag never updates c.width, so clamping to the configured
// value would snap the pane to a stale width — same rationale as
// darwin_sidebar_set_resizable). resizable==true restores the configured
// min/max (0 = UISplitViewControllerAutomaticDimension, the header default).
// <26 / no-split: the modal sheet has no divider — warn once, still store.
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        c.resizable = (BOOL)resizable;

        if (@available(iOS 26.0, *)) {
            UISplitViewController* split = c.contentVC.splitViewController;
            if (split) {
                if (!resizable) {
                    CGFloat liveWidth = c.inspectorNav.view.bounds.size.width;
                    CGFloat lockWidth = (liveWidth > 0.0)
                        ? liveWidth
                        : ((c.width > 0) ? (CGFloat)c.width
                                         : split.preferredInspectorColumnWidth);
                    if (lockWidth > 0.0) {
                        split.minimumInspectorColumnWidth = lockWidth;
                        split.maximumInspectorColumnWidth = lockWidth;
                    }
                } else {
                    split.minimumInspectorColumnWidth = (c.configuredMinWidth > 0)
                        ? (CGFloat)c.configuredMinWidth
                        : UISplitViewControllerAutomaticDimension;
                    split.maximumInspectorColumnWidth = (c.configuredMaxWidth > 0)
                        ? (CGFloat)c.configuredMaxWidth
                        : UISplitViewControllerAutomaticDimension;
                }
                return;
            }
        }
        zapp_ios_control_unsupported("inspector.setResizable",
            "below iOS 26 (or without a sidebar split) the inspector is a system modal sheet");
    });
}
