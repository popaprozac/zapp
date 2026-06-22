// Native inspector (trailing NSSplitViewItem inspector) — parallel to
// sidebar.m. Registry keyed by the host NSWindow; control ops resolve the
// controller via the host slot (works from any pane of the window). Shares
// the event-emit helper (zapp_pane_emit) with sidebar.m.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <math.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
extern void zapp_pane_emit(int32_t host_id, int32_t accessory_slot,
                           const char* eventName, NSString* dataJson);
// Reach-through (#660 hybrid): resolve the SwiftUI `.inspector`'s OWN backing NSSplitView
// so setWidth can re-pin its thickness imperatively. SwiftUI's `.inspectorColumnWidth` is
// initial-only at runtime, so width MUST go through the thickness re-pin; the WidthReader
// captures the result into @Published inspectorWidth for persistence.
@class NSSplitViewController;
extern NSSplitView* zapp_find_split_view(NSView* v);
extern WKWebView* zapp_webview_for_slot(int32_t slot);
// SwiftUI pane drivers (defined in panes.swift) — only linked in when the
// swiftc tier is compiled (native.swiftui != false + swiftc present). Behind
// ZAPP_HAS_SWIFTUI so the opted-out/AppKit-only build doesn't reference an
// undefined symbol; swiftPaneState is never set on that path anyway.
#ifdef ZAPP_HAS_SWIFTUI
extern void zapp_swift_panes_set_inspector_presented(void* state, bool presented);
extern void zapp_swift_panes_toggle_inspector(void* state);
extern void zapp_swift_panes_set_inspector_width(void* state, int32_t w);
extern void zapp_swift_panes_set_inspector_resizable(void* state, bool resizable);
extern void zapp_swift_panes_set_inspector_collapsible(void* state, bool collapsible);
#endif

// --- Registry API consumed by window.m (Task 6) ---
// No header — the codebase externs across .m files. window.m declares these
// itself and calls them after building the split as the window's root.
//
//   void zapp_inspector_register(void* window_ptr, NSSplitViewController* splitVC,
//                                NSSplitViewItem* inspectorItem,
//                                int32_t host_id, int32_t inspector_slot_id);
//   void zapp_inspector_unregister(void* window_ptr);

@interface ZappInspectorController : NSObject
@property (nonatomic, strong) NSSplitViewController* splitVC;
@property (nonatomic, strong) NSSplitViewItem* inspectorItem;
@property (nonatomic, assign) int32_t hostWindowId;
@property (nonatomic, assign) int32_t inspectorSlotId;   // inspector webview's slot
@property (nonatomic, assign) NSInteger inspectorDividerIndex;  // divider before the trailing item
@property (nonatomic, assign) BOOL lastCollapsed;
@property (nonatomic, assign) int lastWidth;
@property (nonatomic, assign) void* swiftPaneState;  // non-owning; set for the SwiftUI path (nil = AppKit)
// Configured resize bounds captured at register (before any lock), so
// setResizable(true) can restore the original drag range after a lock.
@property (nonatomic, assign) CGFloat cfgMinThickness;
@property (nonatomic, assign) CGFloat cfgMaxThickness;
@end

static NSMutableDictionary<NSValue*, ZappInspectorController*>* zapp_inspectors = nil;

static void zapp_inspector_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// slot -> owning NSWindow -> registry key. Works from ANY pane's slot
// because all webviews live in the same host window.
static ZappInspectorController* zapp_inspector_for_slot(int32_t slot_id) {
    if (!zapp_inspectors) return nil;
    void* win_ptr = darwin_window_get_by_numeric_id(slot_id);
    if (!win_ptr) return nil;
    NSValue* key = [NSValue valueWithPointer:win_ptr];
    return zapp_inspectors[key];
}

// Current usable inspector width in points (pane view width).
static int zapp_inspector_current_width(ZappInspectorController* c) {
    if (!c || !c.inspectorItem) return 0;
    NSView* v = c.inspectorItem.viewController.view;
    if (!v) return 0;
    return (int)lround(v.frame.size.width);
}

// Emit a window event into both inspector panes (host + inspector slot).
static void zapp_inspector_emit(ZappInspectorController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, c.inspectorSlotId, eventName, dataJson);
}

// Re-evaluate collapse state and emit a single-shot transition event.
// Called from BOTH the KVO callback and the resize-notification handler so
// either path catches the change (KVO is primary; resize-compare is the
// belt-and-suspenders fallback the contract allows).
static void zapp_inspector_sync_collapse(ZappInspectorController* c) {
    if (!c || !c.inspectorItem) return;
    BOOL collapsed = c.inspectorItem.isCollapsed;
    if (collapsed == c.lastCollapsed) return;
    c.lastCollapsed = collapsed;
    zapp_inspector_emit(c, collapsed ? "inspector-collapsed"
                                     : "inspector-expanded", nil);
}

@implementation ZappInspectorController

// KVO on the split item's `collapsed` key — fires for system toggle, our
// animated ops, and divider snap-to-collapse alike.
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                        change:(NSDictionary*)change context:(void*)context {
    if ([keyPath isEqualToString:@"collapsed"]) {
        zapp_inspector_sync_collapse(self);
    }
}

// NSSplitViewDidResizeSubviewsNotification on the split view: divider drag,
// window resize redistribution, programmatic setPosition. Emit width while
// expanded; also resync collapse here as a fallback for the KVO.
- (void)splitViewDidResize:(NSNotification*)note {
    zapp_inspector_sync_collapse(self);
    if (self.inspectorItem.isCollapsed) return;
    int w = zapp_inspector_current_width(self);
    if (w <= 0 || w == self.lastWidth) return;
    self.lastWidth = w;
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", w];
    zapp_inspector_emit(self, "inspector-resized", json);
}

@end

// Bind the SwiftUI inspector's OWN backing split so setWidth can re-pin it imperatively
// (#660 hybrid). CRITICAL: SwiftUI's `.inspector()` is a SEPARATE NSSplitView from the
// NavigationSplitView's [sidebar, content] — resolve the inspector WKWebview from its slot
// and walk UP to its enclosing NSSplitView, then bind the item that contains it. Only
// setWidth uses this; setResizable/setCollapsible are declarative (@Published).
static BOOL zapp_inspector_bind_swiftui(ZappInspectorController* c) {
    if (c.splitVC && c.inspectorItem) return YES;            // already bound
    if (!c.swiftPaneState) return NO;
    WKWebView* iv = zapp_webview_for_slot(c.inspectorSlotId);
    if (!iv) return NO;                                       // inspector webview not up yet
    NSView* arranged = iv;
    NSSplitView* isv = nil;
    while (arranged.superview) {
        if ([arranged.superview isKindOfClass:[NSSplitView class]]) { isv = (NSSplitView*)arranged.superview; break; }
        arranged = arranged.superview;
    }
    NSSplitViewController* svc = [isv.delegate isKindOfClass:[NSSplitViewController class]]
        ? (NSSplitViewController*)isv.delegate : nil;
    if (!svc) return NO;
    NSInteger itemIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)svc.splitViewItems.count; i++) {
        NSView* itemView = svc.splitViewItems[i].viewController.view;
        if (itemView == arranged || [iv isDescendantOf:itemView]) { itemIdx = i; break; }
    }
    if (itemIdx < 0) return NO;
    c.splitVC = svc;
    c.inspectorItem = svc.splitViewItems[itemIdx];
    c.inspectorDividerIndex = (itemIdx > 0) ? itemIdx - 1 : 0;
    if (c.cfgMinThickness <= 0) c.cfgMinThickness = c.inspectorItem.minimumThickness;
    if (c.cfgMaxThickness <= 0) c.cfgMaxThickness = c.inspectorItem.maximumThickness;
    return YES;
}

// --- Control ops (router entry points) ---

void darwin_inspector_toggle(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_toggle_inspector(c.swiftPaneState); return; }
#endif
        if (!c.inspectorItem) return;
        // Documented AppKit idiom: animate the collapsed property via the
        // item's animator proxy.
        [[c.inspectorItem animator] setCollapsed:!c.inspectorItem.isCollapsed];
    });
}

void darwin_inspector_collapse(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_inspector_presented(c.swiftPaneState, false); return; }
#endif
        if (!c.inspectorItem) return;
        if (c.inspectorItem.isCollapsed) return; // idempotent
        [[c.inspectorItem animator] setCollapsed:YES];
    });
}

void darwin_inspector_expand(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_inspector_presented(c.swiftPaneState, true); return; }
#endif
        if (!c.inspectorItem) return;
        if (!c.inspectorItem.isCollapsed) return; // idempotent
        [[c.inspectorItem animator] setCollapsed:NO];
    });
}

void darwin_inspector_set_width(int32_t window_id, int32_t width) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
        // #660 hybrid: width is imperative (SwiftUI `.inspectorColumnWidth` is initial-only).
        // On the SwiftUI path, bind resolves the inspector's own split; the WidthReader then
        // captures the result into @Published inspectorWidth for persistence.
        if (c.swiftPaneState && !zapp_inspector_bind_swiftui(c)) {
            if (getenv("ZAPP_LOG")) NSLog(@"[zapp] inspector: SwiftUI split not resolved yet — set_width skipped");
            return;
        }
        if (!c.inspectorItem || !c.splitVC) return;
        CGFloat w = (CGFloat)width;
        if (w < 50) w = 50;   // sanity floor
        // #660 hybrid: move the inspector's own split divider (same mechanism as the sidebar)
        // on BOTH paths. The old SwiftUI re-pin wrote item thickness directly, which SwiftUI's
        // `.inspectorColumnWidth` modifier re-asserts its [min,max] over → no effect. Now that
        // the inspector has a declarative resizable RANGE, setPosition within it works; the
        // WidthReader then captures the result into @Published inspectorWidth for persistence.
        CGFloat minT = c.inspectorItem.minimumThickness;
        CGFloat maxT = c.inspectorItem.maximumThickness;
        if (minT > 0 && w < minT) w = minT;
        if (maxT > 0 && w > maxT) w = maxT;
        // Trailing pane: divider x measured from the left = (total - inspector width).
        CGFloat total = c.splitVC.splitView.bounds.size.width;
        [c.splitVC.splitView setPosition:(total - w) ofDividerAtIndex:c.inspectorDividerIndex];
    });
}

// Allow/disallow the user collapsing the inspector (NSSplitViewItem.canCollapse).
// Programmatic collapse/expand still work regardless.
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_inspector_collapsible(c.swiftPaneState, can_collapse); return; }
#endif
        if (!c.inspectorItem) return;
        c.inspectorItem.canCollapse = can_collapse ? YES : NO;
    });
}

// Allow/disallow resizing the inspector by dragging the divider. Disallow locks
// the pane at its current width (min==max); allow restores the configured
// min/max drag range captured at register.
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_inspector_resizable(c.swiftPaneState, resizable); return; }
#endif
        if (!c.inspectorItem) return;
        if (resizable) {
            c.inspectorItem.minimumThickness = c.cfgMinThickness;
            c.inspectorItem.maximumThickness = c.cfgMaxThickness;
        } else {
            CGFloat w = (CGFloat)zapp_inspector_current_width(c);
            if (w <= 0) w = c.inspectorItem.minimumThickness; // pre-layout fallback
            c.inspectorItem.minimumThickness = w;
            c.inspectorItem.maximumThickness = w;
        }
    });
}

// --- Registry API for window.m (Task 6) ---

// SwiftUI-backed register: no splitVC/NSSplitViewItem, no KVO/NSNotification
// observers (the Swift callback is the observation source). lastCollapsed is the
// dedup baseline, seeded from the visibility the PaneState was created with.
void zapp_inspector_register_swiftui(void* window_ptr, void* paneState,
                                     int32_t host_id, int32_t inspector_slot_id,
                                     bool initial_collapsed,
                                     int32_t min_width, int32_t max_width) {
    if (!window_ptr || !paneState) return;
    zapp_inspector_on_main(^{
        if (!zapp_inspectors) zapp_inspectors = [NSMutableDictionary dictionary];
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappInspectorController* c = [[ZappInspectorController alloc] init];
        c.swiftPaneState = paneState;
        c.hostWindowId = host_id;
        c.inspectorSlotId = inspector_slot_id;
        c.lastCollapsed = initial_collapsed ? YES : NO;
        // Configured drag bounds from create-time config. SwiftUI's `.inspector()`
        // LOCKS the item thickness (min==max==initial), so capturing min/max at bind
        // time gives a degenerate 270/270 range — setResizable(true) then re-pins to
        // 270 and the inspector snaps back. Seeding real bounds here lets the bind-time
        // `if (cfg* <= 0)` guards no-op (they don't clobber a positive value).
        c.cfgMinThickness = (CGFloat)min_width;
        c.cfgMaxThickness = (CGFloat)max_width;
        zapp_inspectors[key] = c;
    });
}

// Reverse path: SwiftUI inspector visibility changed. Dedup against lastCollapsed,
// then emit the same event the AppKit KVO path emits. Called by window.m's
// reverse dispatcher (always on the main thread — SwiftUI bindings fire on main).
void zapp_inspector_note_swiftui_visibility(void* window_ptr, bool collapsed) {
    if (!window_ptr || !zapp_inspectors) return;
    ZappInspectorController* c = zapp_inspectors[[NSValue valueWithPointer:window_ptr]];
    if (!c) return;
    if (collapsed == c.lastCollapsed) return;  // dedup (absorbs redundant sets)
    c.lastCollapsed = collapsed;
    zapp_inspector_emit(c, collapsed ? "inspector-collapsed" : "inspector-expanded", nil);
}

// Reverse path: SwiftUI inspector rendered width changed (WidthReader). Dedup against
// lastWidth, then emit "inspector-resized" (parity with the AppKit splitViewDidResize
// path). Called by window.m's reverse dispatcher (always on the main thread).
void zapp_inspector_note_swiftui_width(void* window_ptr, int width) {
    if (!window_ptr || !zapp_inspectors || width <= 0) return;
    ZappInspectorController* c = zapp_inspectors[[NSValue valueWithPointer:window_ptr]];
    if (!c) return;
    if (width == c.lastWidth) return;  // dedup
    c.lastWidth = width;
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", width];
    zapp_inspector_emit(c, "inspector-resized", json);
}

void zapp_inspector_register(void* window_ptr, void* splitVCp, void* inspectorItemp,
                              int32_t host_id, int32_t inspector_slot_id) {
    if (!window_ptr || !splitVCp || !inspectorItemp) return;
    zapp_inspector_on_main(^{
        if (!zapp_inspectors) zapp_inspectors = [NSMutableDictionary dictionary];
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        NSSplitViewController* splitVC = (__bridge NSSplitViewController*)splitVCp;
        NSSplitViewItem* inspectorItem = (__bridge NSSplitViewItem*)inspectorItemp;

        ZappInspectorController* c = [[ZappInspectorController alloc] init];
        c.splitVC = splitVC;
        c.inspectorItem = inspectorItem;
        c.hostWindowId = host_id;
        c.inspectorSlotId = inspector_slot_id;
        c.inspectorDividerIndex = [splitVC.splitViewItems indexOfObject:inspectorItem] - 1;
        c.lastCollapsed = inspectorItem.isCollapsed;
        c.lastWidth = zapp_inspector_current_width(c);
        // Capture configured drag bounds before any setResizable lock so we
        // can restore the range on a later setResizable(true).
        c.cfgMinThickness = inspectorItem.minimumThickness;
        c.cfgMaxThickness = inspectorItem.maximumThickness;

        [inspectorItem addObserver:c forKeyPath:@"collapsed"
                           options:NSKeyValueObservingOptionNew context:NULL];
        [[NSNotificationCenter defaultCenter]
            addObserver:c
               selector:@selector(splitViewDidResize:)
                   name:NSSplitViewDidResizeSubviewsNotification
                 object:splitVC.splitView];

        zapp_inspectors[key] = c;
    });
}

void zapp_inspector_unregister(void* window_ptr) {
    if (!window_ptr) return;
    zapp_inspector_on_main(^{
        if (!zapp_inspectors) return;
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappInspectorController* c = zapp_inspectors[key];
        if (!c) return;
        if (!c.swiftPaneState) {  // AppKit-only observers; none installed on the SwiftUI path
            @try {
                [c.inspectorItem removeObserver:c forKeyPath:@"collapsed"];
            } @catch (__unused NSException* e) {}
            [[NSNotificationCenter defaultCenter] removeObserver:c];
        }
        // Do NOT release swiftPaneState here — the window delegate owns it.
        [zapp_inspectors removeObjectForKey:key];
    });
}

// Divider index of the inspector for a window, or -1 if none. Used by
// toolbar.m to point an inspector trackingSeparator at the right divider.
int32_t zapp_inspector_divider_index(void* window_ptr) {
    if (!window_ptr || !zapp_inspectors) return -1;
    ZappInspectorController* c = zapp_inspectors[[NSValue valueWithPointer:window_ptr]];
    if (!c) return -1;
    return (int32_t)c.inspectorDividerIndex;
}
