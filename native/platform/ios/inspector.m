// iOS native inspector — trailing pane (the iOS analog of macOS's trailing
// NSSplitViewItem). SwiftUI's `.inspector` idiom: a trailing pane on iPad-
// regular, a sheet on iPhone-compact.
//
// THIS TASK builds the inspector's persistent view controller + webview and
// HOSTS it: a trailing pane in the content VC on iPad-regular (honoring the
// configured width + collapsed-by-default), and merely HELD off-screen on
// iPhone-compact. The iPhone sheet presentation + ALL show/hide control ops
// (darwin_inspector_toggle/collapse/expand/...) are a SEPARATE NEXT task — the
// darwin_inspector_* stubs below stay no-ops for now.
//
// Re-parenting note (the critical WKWebView invariant): the inspector webview
// is created by window.m DIRECTLY into inspectorVC.view and is NEVER moved
// between superviews here. zapp_ios_inspector_register only adds inspectorVC
// (and its already-mounted webview) as a child of the content VC, and
// re-constrains the content webview via Auto Layout (no re-parent). Re-parenting
// a live WKWebView resets its content process and kills the bridge.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <stdbool.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
extern int32_t zapp_ios_sidebar_slot_for(int32_t host_slot);

// --- Per-window registry --------------------------------------------------
//
// Keyed by the host UIWindow (NSValue-wrapped pointer), mirroring sidebar.m's
// zapp_ios_sidebars. Inspector:* control ops (next task) can arrive from ANY
// pane's transport slot; all resolve to the same host UIWindow via
// darwin_window_get_by_numeric_id, so the host-window key catches them all.

// Tag used to guard against duplicate close buttons when expand is called
// more than once on the same heldInspectorVC.
static const NSInteger kZappInspectorCloseButtonTag = 0x7A437042; // 'zCpB'

@interface ZappIOSInspectorController : NSObject <UISheetPresentationControllerDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic, weak)   UIViewController* inspectorVC;     // persistent inspector pane VC
@property (nonatomic, weak)   UIViewController* contentVC;       // the content pane VC it trails
@property (nonatomic, weak)   WKWebView* contentWebview;         // content webview (re-constrained, never re-parented)
@property (nonatomic, strong) NSLayoutConstraint* widthConstraint; // inspector pane width (0 when collapsed)
@property (nonatomic, assign) int32_t hostWindowId;             // content webview's slot
@property (nonatomic, assign) int32_t inspectorSlotId;          // inspector webview's slot
@property (nonatomic, assign) int32_t width;                    // configured (expanded) width
@property (nonatomic, assign) BOOL compact;                     // iPhone-compact (held, not embedded)
@property (nonatomic, assign) BOOL shown;                       // currently visible (false when collapsed/held)
// iPhone-compact only: the inspector VC isn't in any view hierarchy (no parent
// retains it), so the registry must keep it alive until the sheet task presents
// it. On iPad the addChildViewController: parent owns it and this stays nil.
@property (nonatomic, strong) UIViewController* heldInspectorVC;
@end

// Forward-declared so the swipe-dismiss delegate (in @implementation below) can
// call the emit helper; the definitions live after the registry helpers.
static void zapp_ios_inspector_emit(ZappIOSInspectorController* c, const char* eventName);

@implementation ZappIOSInspectorController

// iPhone-compact swipe-down dismiss: the system tears the sheet down without
// going through darwin_inspector_collapse, so sync `shown` + emit collapsed
// here to keep the JS `win.inspector.collapsed` state honest (same lesson as
// the sidebar overlay tap-out).
- (void)presentationControllerDidDismiss:(UIPresentationController*)pc {
    (void)pc;
    self.shown = NO;
    zapp_ios_inspector_emit(self, "inspector-collapsed");
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
static void zapp_ios_inspector_emit(ZappIOSInspectorController* c, const char* eventName) {
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
// window.m calls this AFTER the content (+ optional sidebar) panes are built
// and the inspector webview has been created into inspectorVC.view. On iPad-
// regular we embed inspectorVC as a trailing child of the content VC and
// re-constrain the content webview to leave room (Auto Layout — NO re-parent).
// On iPhone-compact we merely hold inspectorVC in the controller (the sheet
// presentation is the next task).
void zapp_ios_inspector_register(void* window, void* inspectorVC, void* contentVC,
                                 void* contentWebview, int32_t host_id,
                                 int32_t inspector_id, int32_t width, bool collapsed) {
    if (!window || !inspectorVC || !contentVC) return;
    zapp_ios_inspector_on_main(^{
        if (!zapp_ios_inspectors) zapp_ios_inspectors = [NSMutableDictionary dictionary];

        UIViewController* ivc = (__bridge UIViewController*)inspectorVC;
        UIViewController* cvc = (__bridge UIViewController*)contentVC;
        WKWebView* cwv = (__bridge WKWebView*)contentWebview;
        if (!ivc || !cvc) return;

        ZappIOSInspectorController* c = [[ZappIOSInspectorController alloc] init];
        c.inspectorVC = ivc;
        c.contentVC = cvc;
        c.contentWebview = cwv;
        c.hostWindowId = host_id;
        c.inspectorSlotId = inspector_id;
        c.width = width;

        // compact == iPhone (or iPad in narrow multitasking): hold the VC, don't
        // embed. The trailing pane is an iPad-regular affordance; iPhone gets a
        // sheet in the next task.
        UIWindow* hostWindow = (__bridge UIWindow*)window;
        c.compact = (hostWindow.traitCollection.horizontalSizeClass
                     == UIUserInterfaceSizeClassCompact);

        if (!c.compact) {
            // iPad-regular: embed the inspector as a trailing pane in the content
            // VC. The inspector webview was created directly into ivc.view and is
            // carried along as ivc.view becomes a subview of cvc.view — this does
            // NOT re-parent the webview (it stays inside ivc.view).
            [cvc addChildViewController:ivc];
            ivc.view.translatesAutoresizingMaskIntoConstraints = NO;
            [cvc.view addSubview:ivc.view];
            [ivc didMoveToParentViewController:cvc];

            NSLayoutConstraint* w =
                [ivc.view.widthAnchor constraintEqualToConstant:(collapsed ? 0 : width)];
            [NSLayoutConstraint activateConstraints:@[
                [ivc.view.topAnchor constraintEqualToAnchor:cvc.view.topAnchor],
                [ivc.view.bottomAnchor constraintEqualToAnchor:cvc.view.bottomAnchor],
                [ivc.view.trailingAnchor constraintEqualToAnchor:cvc.view.trailingAnchor],
                w,
            ]];

            // Re-constrain the content webview to leave room for the inspector.
            // It was mounted full-frame via autoresizingMask in webview.m; switch
            // it to Auto Layout pinned content-leading..inspector-leading. This
            // re-CONSTRAINS the existing webview in place — it does NOT re-parent
            // it (the webview stays a subview of cvc.view).
            if (cwv) {
                cwv.translatesAutoresizingMaskIntoConstraints = NO;
                [NSLayoutConstraint activateConstraints:@[
                    [cwv.leadingAnchor constraintEqualToAnchor:cvc.view.leadingAnchor],
                    [cwv.topAnchor constraintEqualToAnchor:cvc.view.topAnchor],
                    [cwv.bottomAnchor constraintEqualToAnchor:cvc.view.bottomAnchor],
                    [cwv.trailingAnchor constraintEqualToAnchor:ivc.view.leadingAnchor],
                ]];
            }
            c.widthConstraint = w;
            c.shown = !collapsed;
        } else {
            // iPhone-compact: do NOT add to the hierarchy. Just hold inspectorVC
            // in the controller so it survives (no parent retains it here — the
            // weak inspectorVC property alone would let it dealloc once window.m's
            // local goes out of scope). The sheet presentation in the next task
            // will present this held VC.
            c.heldInspectorVC = ivc;
            c.shown = NO;
        }

        NSValue* key = [NSValue valueWithPointer:window];
        zapp_ios_inspectors[key] = c;

        NSLog(@"[native] iOS inspector registered: host=%d inspector=%d compact=%d shown=%d width=%d",
              host_id, inspector_id, (int)c.compact, (int)c.shown, width);
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
// NSSplitViewController is AppKit-only; on iOS we drive the trailing pane's
// widthConstraint (iPad-regular) or present/dismiss the held VC as a sheet
// (iPhone-compact). All keyed by a transport slot (host OR inspector pane);
// zapp_ios_inspector_for_slot resolves either to the host record.

// Show the inspector. iPad-regular: animate the trailing pane in (width 0 ->
// configured). iPhone-compact: present the held VC as a sheet (medium + large
// detents, grabber). Never re-parents the webview — the sheet PRESENTS the held
// VC, which already owns its webview.
void darwin_inspector_expand(int32_t window_id) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        if (c.compact) {
            // iPhone: present the held VC as a sheet.
            UIViewController* ivc = c.heldInspectorVC;
            if (!ivc || ivc.presentingViewController) return; // already presented
            void* winptr = darwin_window_get_by_numeric_id(c.hostWindowId);
            UIWindow* win = (__bridge UIWindow*)winptr;
            UIViewController* presenter = win.rootViewController;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            ivc.modalPresentationStyle = UIModalPresentationPageSheet;
            if (@available(iOS 15.0, *)) {
                UISheetPresentationController* sheet = ivc.sheetPresentationController;
                if (sheet) {
                    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                      UISheetPresentationControllerDetent.largeDetent];
                    sheet.prefersGrabberVisible = YES;
                    sheet.prefersEdgeAttachedInCompactHeight = YES;
                    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
                    sheet.delegate = c; // for swipe-dismiss sync (presentationControllerDidDismiss:)
                }
            }
            ivc.presentationController.delegate = c; // UIAdaptivePresentationControllerDelegate

            // Add a guaranteed dismiss affordance: the grabber sits in the iOS
            // top-edge gesture zone in landscape, making it unreachable (activates
            // Notification Center). A native close button (top-trailing, safe-area-
            // inset) bypasses that zone entirely. Guard with a tag so a second call
            // to expand (while already presented) doesn't add a second button.
            if (![ivc.view viewWithTag:kZappInspectorCloseButtonTag]) {
                // Capture a weak ref to `c` so the button block doesn't retain the
                // controller cycle. We mirror presentationControllerDidDismiss: exactly:
                // dismiss + set shown=NO + emit inspector-collapsed.
                __weak ZappIOSInspectorController* weakC = c;
                UIButton* closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                closeBtn.tag = kZappInspectorCloseButtonTag;
                UIImage* xImg = [UIImage systemImageNamed:@"xmark.circle.fill"];
                if (xImg) {
                    UIImageSymbolConfiguration* cfg =
                        [UIImageSymbolConfiguration configurationWithPointSize:24
                                                                        weight:UIImageSymbolWeightMedium];
                    closeBtn.configuration = nil; // use legacy image path for tint
                    [closeBtn setImage:[xImg imageByApplyingSymbolConfiguration:cfg]
                              forState:UIControlStateNormal];
                } else {
                    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
                }
                closeBtn.tintColor = [UIColor secondaryLabelColor];
                closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
                [ivc.view addSubview:closeBtn];
                // High z-order: above the inspector webview.
                [ivc.view bringSubviewToFront:closeBtn];
                [NSLayoutConstraint activateConstraints:@[
                    [closeBtn.topAnchor constraintEqualToAnchor:ivc.view.safeAreaLayoutGuide.topAnchor
                                                       constant:12.0],
                    [closeBtn.trailingAnchor constraintEqualToAnchor:ivc.view.safeAreaLayoutGuide.trailingAnchor
                                                            constant:-12.0],
                ]];
                [closeBtn addAction:[UIAction actionWithHandler:^(__kindof UIAction* action) {
                    (void)action;
                    ZappIOSInspectorController* sc = weakC;
                    if (!sc) return;
                    UIViewController* iv = sc.heldInspectorVC;
                    if (iv && iv.presentingViewController) {
                        [iv dismissViewControllerAnimated:YES completion:nil];
                    }
                    // Mirror presentationControllerDidDismiss: — sync state + emit.
                    sc.shown = NO;
                    zapp_ios_inspector_emit(sc, "inspector-collapsed");
                }] forControlEvents:UIControlEventTouchUpInside];
            }

            [presenter presentViewController:ivc animated:YES completion:nil];
        } else {
            // iPad: animate the trailing pane in (widthConstraint 0 -> width).
            c.widthConstraint.constant = (c.width > 0 ? c.width : 280);
            [UIView animateWithDuration:0.25 animations:^{ [c.contentVC.view layoutIfNeeded]; }];
        }
        c.shown = YES;
        zapp_ios_inspector_emit(c, "inspector-expanded");
    });
}

// Hide the inspector. iPad-regular: animate the trailing pane out (width -> 0).
// iPhone-compact: dismiss the presented sheet.
void darwin_inspector_collapse(int32_t window_id) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        if (c.compact) {
            UIViewController* ivc = c.heldInspectorVC;
            if (ivc && ivc.presentingViewController)
                [ivc dismissViewControllerAnimated:YES completion:nil];
        } else {
            c.widthConstraint.constant = 0;
            [UIView animateWithDuration:0.25 animations:^{ [c.contentVC.view layoutIfNeeded]; }];
        }
        c.shown = NO;
        zapp_ios_inspector_emit(c, "inspector-collapsed");
    });
}

// Toggle from LIVE state — the iPhone sheet can be swipe-dismissed out from
// under us, and the iPad pane width is authoritative, so never trust a cached
// flag here.
void darwin_inspector_toggle(int32_t window_id) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        BOOL isShown;
        if (c.compact) isShown = (c.heldInspectorVC && c.heldInspectorVC.presentingViewController != nil);
        else isShown = (c.widthConstraint.constant > 0.5);
        // The collapse/expand ops re-dispatch to main (already on it here — they
        // run inline since [NSThread isMainThread] is true).
        if (isShown) darwin_inspector_collapse(window_id);
        else darwin_inspector_expand(window_id);
    });
}

// Set the (expanded) inspector width. iPad: re-animate the pane if currently
// shown; otherwise just stores for the next expand. iPhone: the sheet is full
// width, so width is n/a there (no-op). Emits inspector-resized either way for
// state parity with the runtime InspectorHandle.
void darwin_inspector_set_width(int32_t window_id, int32_t width) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        c.width = width;
        if (!c.compact && c.widthConstraint.constant > 0.5) {  // only if currently shown
            c.widthConstraint.constant = width;
            [UIView animateWithDuration:0.15 animations:^{ [c.contentVC.view layoutIfNeeded]; }];
        }
        // compact: full-width sheet — width is n/a (documented no-op there).
        zapp_ios_inspector_emit_resize(c, width);
    });
}

// User-collapsible gating is an NSSplitViewItem affordance; the iOS inspector is
// driven explicitly (pane constraint / sheet present-dismiss), so there's no
// equivalent knob. No-op for router parity (documented).
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) {
    (void)window_id; (void)can_collapse;
}

// Divider-drag resize isn't a UIKit affordance (the trailing pane width is set
// programmatically, the sheet is full-width). No-op for router parity
// (documented).
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) {
    (void)window_id; (void)resizable;
}
