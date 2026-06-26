// Native inspector (trailing NSSplitViewItem inspector) — parallel to
// sidebar.m. Registry keyed by the host NSWindow; control ops resolve the
// controller via the host slot (works from any pane of the window). Shares
// the event-emit helper (zapp_pane_emit) with sidebar.m.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <math.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
extern void zapp_pane_emit(int32_t host_id, const char* eventName, NSString* dataJson);
@class NSSplitViewController;
extern NSSplitView* zapp_find_split_view(NSView* v);
extern WKWebView* zapp_webview_for_slot(int32_t slot);

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

// Emit a window event into all panes of the host window (#627 fan-out).
static void zapp_inspector_emit(ZappInspectorController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, eventName, dataJson);
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

// --- Control ops (router entry points) ---

void darwin_inspector_toggle(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
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
        if (!c.inspectorItem) return;
        if (c.inspectorItem.isCollapsed) return; // idempotent
        [[c.inspectorItem animator] setCollapsed:YES];
    });
}

void darwin_inspector_expand(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
        if (!c.inspectorItem) return;
        if (!c.inspectorItem.isCollapsed) return; // idempotent
        [[c.inspectorItem animator] setCollapsed:NO];
    });
}

void darwin_inspector_set_width(int32_t window_id, int32_t width) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
        if (!c.inspectorItem || !c.splitVC) return;
        CGFloat w = (CGFloat)width;
        if (w < 50) w = 50;   // sanity floor
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
        if (!c.inspectorItem) return;
        c.inspectorItem.canCollapse = can_collapse ? YES : NO;
        // #665: revalidate the toolbar so the toggleInspector button greys/ungreys now
        // (validateToolbarItem: reads canCollapse). AppKit's own schedule is lazy.
        NSWindow* win = (__bridge NSWindow*)darwin_window_get_by_numeric_id(c.hostWindowId);
        [win.toolbar validateVisibleItems];
    });
}

// Allow/disallow resizing the inspector by dragging the divider. Disallow locks
// the pane at its current width (min==max); allow restores the configured
// min/max drag range captured at register.
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
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
        @try {
            [c.inspectorItem removeObserver:c forKeyPath:@"collapsed"];
        } @catch (__unused NSException* e) {}
        [[NSNotificationCenter defaultCenter] removeObserver:c];
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

// #665: whether the inspector currently allows collapse. Used by toolbar.m's
// validateToolbarItem: to grey the toggleInspector button when collapsible:false.
// Returns YES when there's no inspector (don't disable a toggle the window doesn't have).
bool zapp_inspector_is_collapsible(void* window_ptr) {
    if (!window_ptr || !zapp_inspectors) return true;
    ZappInspectorController* c = zapp_inspectors[[NSValue valueWithPointer:window_ptr]];
    if (!c || !c.inspectorItem) return true;
    return c.inspectorItem.canCollapse ? true : false;
}
