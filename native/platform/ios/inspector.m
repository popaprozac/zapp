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

// --- Per-window registry --------------------------------------------------
//
// Keyed by the host UIWindow (NSValue-wrapped pointer), mirroring sidebar.m's
// zapp_ios_sidebars. Inspector:* control ops (next task) can arrive from ANY
// pane's transport slot; all resolve to the same host UIWindow via
// darwin_window_get_by_numeric_id, so the host-window key catches them all.

@interface ZappIOSInspectorController : NSObject
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

@implementation ZappIOSInspectorController
@end

static NSMutableDictionary<NSValue*, ZappIOSInspectorController*>* zapp_ios_inspectors = nil;

static void zapp_ios_inspector_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// slot -> owning UIWindow -> registry key. Works from ANY pane's slot (content,
// sidebar, or inspector) since they all share the host UIWindow. The NEXT task
// (control ops) uses this; defined now so the wiring is in place.
__attribute__((unused))
static ZappIOSInspectorController* zapp_ios_inspector_for_slot(int32_t slot_id) {
    if (!zapp_ios_inspectors) return nil;
    void* win_ptr = darwin_window_get_by_numeric_id(slot_id);
    if (!win_ptr) return nil;
    NSValue* key = [NSValue valueWithPointer:win_ptr];
    return zapp_ios_inspectors[key];
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

// --- Control ops (router entry points) — STILL STUBS ----------------------
//
// NSSplitViewController is AppKit-only; the router references these four/six
// control symbols under #ifdef __APPLE__ (true on iOS), so they must exist.
// The NEXT task implements them against the registry above (toggle the
// widthConstraint on iPad-regular, present/dismiss the sheet on iPhone-compact).
void darwin_inspector_toggle(int32_t window_id) { (void)window_id; }
void darwin_inspector_collapse(int32_t window_id) { (void)window_id; }
void darwin_inspector_expand(int32_t window_id) { (void)window_id; }
void darwin_inspector_set_width(int32_t window_id, int32_t width) { (void)window_id; (void)width; }
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) { (void)window_id; (void)can_collapse; }
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) { (void)window_id; (void)resizable; }
