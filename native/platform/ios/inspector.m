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
//   visibility is read via -isShowingColumn: (no BOOL bookkeeping needed).
//   On iPad (regular width) this is a hideable/resizable column beside the
//   content; on iPhone (compact width) UIKit auto-presents the SAME column
//   as a sheet — no horizontalSizeClass branching needed on our side.
//
// iOS 15–25 fallback (Zapp's deployment target is 15.0; there is no Inspector
//   column below 26, and a no-sidebar window has no split to attach one to
//   even on 26+): the persistent inspector nav is presented as a MODAL
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

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
extern int32_t zapp_ios_sidebar_slot_for(int32_t host_slot);

// Forward declaration — darwin_inspector_collapse is defined further down in
// this file; the Close-button target/action (installed on the <26 modal
// sheet) calls back into it so expand/collapse/toggle/Close-tap all share the
// exact same collapse logic (single source of truth for the emit + guard).
void darwin_inspector_collapse(int32_t window_id);

// Forward declarations — ZappIOSInspectorController (declared below) and the
// name-only emit helper (defined further down, after the emit-with-data
// helper it wraps). Needed here because presentationControllerDidDismiss:
// (below) calls it.
@class ZappIOSInspectorController;
void zapp_ios_inspector_emit(ZappIOSInspectorController* c, const char* eventName);

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

// Close bar-button target (<26 modal sheet fallback). Delegates to
// darwin_inspector_collapse so the tap and the programmatic collapse() path
// share identical logic (dismiss + emit + guard).
- (void)zapp_closeInspectorTapped {
    darwin_inspector_collapse(self.hostWindowId);
}

@end

static NSMutableDictionary<NSValue*, ZappIOSInspectorController*>* zapp_ios_inspectors = nil;

// TEMPORARY FU-1 instrumentation (removed once the root cause lands).
// Frames logged in each view's own coordinate space — widths are what matter.
static void zapp_ios_fu1_dump(ZappIOSInspectorController* c, const char* tag) {
    UISplitViewController* split = c.contentVC.splitViewController;
    BOOL showing = NO;
    if (@available(iOS 26.0, *)) {
        if (split) showing = [split isShowingColumn:UISplitViewControllerColumnInspector];
    }
    fprintf(stderr,
        "[zapp-nav] FU1 %s: splitW=%.0f secondaryW=%.0f webviewW=%.0f inspNavW=%.0f showing=%d behavior=%ld mode=%ld\n",
        tag,
        split ? split.view.bounds.size.width : -1.0,
        c.contentVC.view.bounds.size.width,
        c.contentWebview ? c.contentWebview.bounds.size.width : -1.0,
        c.inspectorNav ? c.inspectorNav.view.bounds.size.width : -1.0,
        (int)showing,
        split ? (long)split.preferredSplitBehavior : -1L,
        split ? (long)split.displayMode : -1L);
}

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

// --- Registry API consumed by window.m ------------------------------------
//
// window.m calls this AFTER building the persistent inspector nav and (on
// iOS 26+, when a split exists) attaching it to the split's Inspector column.
// This function:
//   • strongly retains inspectorNav — it must survive on <26 (or with no
//     split at all), where nothing else holds a reference to it.
//   • stores contentVC (weak), ids, width.
//   • on iOS 26+ with a split: applies the configured width and, unless the
//     app asked for collapsed:true, shows the column once (deferred one tick
//     so it lands AFTER UIKit's initial layout — the column starts HIDDEN by
//     default when attached, confirmed on the spike, regardless of the
//     collapsed intent).
//   • registers the controller in the registry so darwin_inspector_* can
//     find it from any pane's transport slot.
void zapp_ios_inspector_register(void* window, void* inspectorNav, void* contentVC,
                                 void* contentWebview, int32_t host_id,
                                 int32_t inspector_id, int32_t width, bool collapsed) {
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
        c.contentWebview  = (__bridge WKWebView*)contentWebview;

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
            }
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
                [split showColumn:UISplitViewControllerColumnInspector];
                zapp_ios_fu1_dump(c, "immediate");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ zapp_ios_fu1_dump(c, "settled"); });
                zapp_ios_inspector_emit(c, "inspector-expanded");
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
                [split hideColumn:UISplitViewControllerColumnInspector];
                zapp_ios_fu1_dump(c, "immediate");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ zapp_ios_fu1_dump(c, "settled"); });
                zapp_ios_inspector_emit(c, "inspector-collapsed");
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
                if ([split isShowingColumn:UISplitViewControllerColumnInspector]) {
                    [split hideColumn:UISplitViewControllerColumnInspector];
                    zapp_ios_inspector_emit(c, "inspector-collapsed");
                } else {
                    [split showColumn:UISplitViewControllerColumnInspector];
                    zapp_ios_inspector_emit(c, "inspector-expanded");
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
//   <26, or no split: full-width/full-screen modal sheet — width is n/a
//     (documented no-op there).
// Emits inspector-resized for state parity with the runtime InspectorHandle.
void darwin_inspector_set_width(int32_t window_id, int32_t width) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        c.width = width;

        if (@available(iOS 26.0, *)) {
            UISplitViewController* split = c.contentVC.splitViewController;
            if (split && width > 0) {
                split.preferredInspectorColumnWidth = (CGFloat)width;
            }
        }
        zapp_ios_inspector_emit_resize(c, width);
    });
}

// User-collapsible gating is an NSSplitViewItem affordance; the iOS inspector is
// driven explicitly (show/hideColumn: / modal sheet), so there's no equivalent
// knob. No-op for router parity (documented).
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) {
    (void)window_id; (void)can_collapse;
}

// Divider-drag resize isn't a UIKit affordance on the Inspector column (its
// width is set programmatically; the <26 fallback is a full-width/full-screen
// sheet). No-op for router parity (documented).
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) {
    (void)window_id; (void)resizable;
}
