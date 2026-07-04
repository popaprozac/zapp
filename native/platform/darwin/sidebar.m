// Native sidebar (NSSplitViewController + .sidebar NSSplitViewItem) — the
// split registry + control ops + collapse/resize observation. Construction
// happens in window.m (the split must be the window's root before any
// webview loads); everything after lives here.
//
// Registry is keyed by the HOST NSWindow, because sidebar:* actions can
// arrive from EITHER pane's transport slot (the sidebar webview has its own
// slot) — slot -> webview -> .window resolves both to the same key.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_window_eval_js(int32_t window_id, const char* js);
// window.m slot-lookup helpers: resolve a host window's sidebar/inspector
// transport slots so pane events fan out to every pane (#627).
extern int32_t zapp_sidebar_slot_lookup(int32_t host_slot);
extern int32_t zapp_inspector_slot_lookup(int32_t host_slot);
@class NSSplitViewController;
extern NSSplitView* zapp_find_split_view(NSView* v);
// toolbar.m: re-inject chrome-metric CSS vars (incl. safe-area) after sidebar
// geometry changes so --zapp-safe-area-left tracks live sidebar overlap.
extern void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script);

// --- Registry API consumed by window.m (Task 5) ---
// No header — the codebase externs across .m files. window.m declares these
// itself and calls them after building the split as the window's root.
//
//   void zapp_sidebar_register(void* window_ptr, NSSplitViewController* splitVC,
//                              NSSplitViewItem* sidebarItem,
//                              int32_t host_id, int32_t sidebar_slot_id);
//   void zapp_sidebar_unregister(void* window_ptr);

@interface ZappSidebarController : NSObject
@property (nonatomic, strong) NSSplitViewController* splitVC;
@property (nonatomic, strong) NSSplitViewItem* sidebarItem;
@property (nonatomic, assign) int32_t hostWindowId;   // main webview's slot
@property (nonatomic, assign) int32_t sidebarSlotId;  // sidebar webview's slot
@property (nonatomic, assign) BOOL lastCollapsed;
@property (nonatomic, assign) int lastWidth;
// Configured resize bounds captured at register (before any lock), so
// setResizable(true) can restore the original drag range after a lock.
@property (nonatomic, assign) CGFloat cfgMinThickness;
@property (nonatomic, assign) CGFloat cfgMaxThickness;
@end

static NSMutableDictionary<NSValue*, ZappSidebarController*>* zapp_sidebars = nil;

static void zapp_sidebar_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// slot -> owning NSWindow -> registry key. Works from EITHER pane's slot
// because both webviews live in the same host window.
static ZappSidebarController* zapp_sidebar_for_slot(int32_t slot_id) {
    if (!zapp_sidebars) return nil;
    void* win_ptr = darwin_window_get_by_numeric_id(slot_id);
    if (!win_ptr) return nil;
    NSValue* key = [NSValue valueWithPointer:win_ptr];
    return zapp_sidebars[key];
}

// Current usable sidebar width in points (pane view width).
static int zapp_sidebar_current_width(ZappSidebarController* c) {
    if (!c || !c.sidebarItem) return 0;
    NSView* v = c.sidebarItem.viewController.view;
    if (!v) return 0;
    return (int)lround(v.frame.size.width);
}

// Shared pane event-emit: dispatch a window event into ALL panes of the host
// window — the host/content pane plus the sidebar and inspector panes (when
// present). eventName is the BARE suffix ("sidebar-collapsed" /
// "inspector-resized" etc.); dispatchWindowEvent in bootstrap/webview.ts
// prepends "window:". dataJson may be nil. Single-quoted JSON literal,
// backslash + quote escaped. Exported — also used by inspector.m.
//
// This deliberately bypasses the gJsListeners bitmask (these event ids aren't
// in the Nim WindowEvent enum / eventNameToId) — see #627. Fan-out mirrors
// zapp_dispatch_event_to_js in window.m.
void zapp_pane_emit(int32_t host_id, const char* eventName, NSString* dataJson) {
    if (!eventName) return;

    NSString* dataArg = @"undefined";
    if (dataJson) {
        NSString* esc = [dataJson stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        dataArg = [NSString stringWithFormat:@"'%@'", esc];
    }
    NSString* event = [NSString stringWithUTF8String:eventName];

    // Build once: dispatchWindowEvent's first arg is the target window id
    // ("win-<hostId>"). All panes belong to the same logical window, so all
    // receive the host's id.
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        @"if(b&&typeof b.dispatchWindowEvent==='function'){"
        @"b.dispatchWindowEvent('win-%d','%@',%@);}})();",
        host_id, event, dataArg];
    const char* jsc = [js UTF8String];

    // Host/content pane (always).
    darwin_window_eval_js(host_id, jsc);
    // Sidebar pane (if this window has one).
    int32_t sidebar_slot = zapp_sidebar_slot_lookup(host_id);
    if (sidebar_slot >= 0 && sidebar_slot != host_id) {
        darwin_window_eval_js(sidebar_slot, jsc);
    }
    // Inspector pane (if this window has one).
    int32_t inspector_slot = zapp_inspector_slot_lookup(host_id);
    if (inspector_slot >= 0 && inspector_slot != host_id) {
        darwin_window_eval_js(inspector_slot, jsc);
    }
}

// Emit a window event into all panes of the host window (#627 fan-out).
static void zapp_sidebar_emit(ZappSidebarController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, eventName, dataJson);
}

// Re-evaluate collapse state and emit a single-shot transition event.
// Called from BOTH the KVO callback and the resize-notification handler so
// either path catches the change (KVO is primary; resize-compare is the
// belt-and-suspenders fallback the contract allows).
static void zapp_sidebar_sync_collapse(ZappSidebarController* c) {
    if (!c || !c.sidebarItem) return;
    BOOL collapsed = c.sidebarItem.isCollapsed;
    if (collapsed == c.lastCollapsed) return;
    c.lastCollapsed = collapsed;
    zapp_sidebar_emit(c, collapsed ? "sidebar-collapsed"
                                   : "sidebar-expanded", nil);
}

@implementation ZappSidebarController

// KVO on the split item's `collapsed` key — fires for system toggle, our
// animated ops, and divider snap-to-collapse alike.
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                        change:(NSDictionary*)change context:(void*)context {
    if ([keyPath isEqualToString:@"collapsed"]) {
        zapp_sidebar_sync_collapse(self);
        // Re-inject chrome metrics so --zapp-safe-area-left reflects the new
        // sidebar width (0 when collapsed, sidebar width when expanded).
        void* winPtr = darwin_window_get_by_numeric_id(self.hostWindowId);
        if (winPtr) zapp_toolbar_inject_metrics(winPtr, self.hostWindowId, false);
    }
}

// NSSplitViewDidResizeSubviewsNotification on the split view: divider drag,
// window resize redistribution, programmatic setPosition. Emit width while
// expanded; also resync collapse here as a fallback for the KVO.
- (void)splitViewDidResize:(NSNotification*)note {
    zapp_sidebar_sync_collapse(self);
    if (self.sidebarItem.isCollapsed) return;
    int w = zapp_sidebar_current_width(self);
    if (w <= 0 || w == self.lastWidth) return;
    self.lastWidth = w;
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", w];
    zapp_sidebar_emit(self, "sidebar-resized", json);
    // Re-inject chrome metrics so --zapp-safe-area-left tracks the live
    // sidebar width after a divider drag or window resize redistribution.
    void* winPtr = darwin_window_get_by_numeric_id(self.hostWindowId);
    if (winPtr) zapp_toolbar_inject_metrics(winPtr, self.hostWindowId, false);
}

@end

// --- Control ops (router entry points) ---

void darwin_sidebar_toggle(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (!c.sidebarItem) return;
        // Documented AppKit idiom: animate the collapsed property via the
        // item's animator proxy.
        [[c.sidebarItem animator] setCollapsed:!c.sidebarItem.isCollapsed];
    });
}

void darwin_sidebar_collapse(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (!c.sidebarItem) return;
        if (c.sidebarItem.isCollapsed) return; // idempotent
        [[c.sidebarItem animator] setCollapsed:YES];
    });
}

void darwin_sidebar_expand(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (!c.sidebarItem) return;
        if (!c.sidebarItem.isCollapsed) return; // idempotent
        [[c.sidebarItem animator] setCollapsed:NO];
    });
}

// iPhone master-detail column reveal — meaningful only on a collapsed iOS
// UISplitViewController. On macOS the sidebar + content panes are always
// side-by-side (NSSplitViewController never "collapses" to a single column),
// so there's nothing to reveal: no-ops. Defined here so the shared router's
// `#ifdef __APPLE__` branch links into the macOS build (parity with
// ios/sidebar.m, which carries the real implementation).
void darwin_sidebar_show_content(int32_t window_id) { (void)window_id; }
void darwin_sidebar_show_sidebar(int32_t window_id) { (void)window_id; }

// Presentation (tile/overlay/automatic) is an iOS UISplitViewController concept;
// AppKit's NSSplitViewController tiles and never overlays. No-op on macOS.
void darwin_sidebar_set_presentation(int32_t window_id, const char* mode) {
    (void)window_id; (void)mode;
}

// #782 T5: runtime title update is an iOS-only concept — iOS panes are
// UINavigationController columns whose bar shows a navigationItem.title.
// macOS has ONE window toolbar (no per-pane nav bar); apps own the sidebar
// header themselves in HTML. No-op, defined here so the shared router's
// darwin_sidebar_set_title call links on macOS (parity with ios/sidebar.m,
// which carries the real implementation).
void darwin_sidebar_set_title(int32_t window_id, const char* title) {
    (void)window_id; (void)title;
}

void darwin_sidebar_set_width(int32_t window_id, int32_t width) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (!c.sidebarItem || !c.splitVC) return;
        CGFloat w = (CGFloat)width;
        CGFloat minT = c.sidebarItem.minimumThickness;
        CGFloat maxT = c.sidebarItem.maximumThickness;
        if (minT > 0 && w < minT) w = minT;
        if (maxT > 0 && w > maxT) w = maxT;
        [c.splitVC.splitView setPosition:w ofDividerAtIndex:0];
    });
}

// Allow/disallow the user collapsing the sidebar (NSSplitViewItem.canCollapse).
// Programmatic collapse/expand still work regardless — this gates the system
// behaviors (divider snap, toolbar toggle).
void darwin_sidebar_set_collapsible(int32_t window_id, bool can_collapse) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (!c.sidebarItem) return;
        c.sidebarItem.canCollapse = can_collapse ? YES : NO;
        // #665: revalidate so the system NSToolbarToggleSidebarItem greys when the sidebar
        // is non-collapsible (AppKit auto-validates the toggle against the item's canCollapse).
        NSWindow* win = (__bridge NSWindow*)darwin_window_get_by_numeric_id(c.hostWindowId);
        [win.toolbar validateVisibleItems];
    });
}

// Allow/disallow resizing the sidebar by dragging the divider. Disallow locks
// the pane at its current width (min==max); allow restores the configured
// min/max drag range captured at register.
void darwin_sidebar_set_resizable(int32_t window_id, bool resizable) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (!c.sidebarItem) return;
        if (resizable) {
            c.sidebarItem.minimumThickness = c.cfgMinThickness;
            c.sidebarItem.maximumThickness = c.cfgMaxThickness;
        } else {
            CGFloat w = (CGFloat)zapp_sidebar_current_width(c);
            if (w <= 0) w = c.sidebarItem.minimumThickness;
            c.sidebarItem.minimumThickness = w;
            c.sidebarItem.maximumThickness = w;
        }
    });
}

// --- Registry API for window.m (Task 5) ---

void zapp_sidebar_register(void* window_ptr, NSSplitViewController* splitVC,
                           NSSplitViewItem* sidebarItem, int32_t host_id,
                           int32_t sidebar_slot_id) {
    if (!window_ptr || !splitVC || !sidebarItem) return;
    zapp_sidebar_on_main(^{
        if (!zapp_sidebars) zapp_sidebars = [NSMutableDictionary dictionary];
        NSValue* key = [NSValue valueWithPointer:window_ptr];

        ZappSidebarController* c = [[ZappSidebarController alloc] init];
        c.splitVC = splitVC;
        c.sidebarItem = sidebarItem;
        c.hostWindowId = host_id;
        c.sidebarSlotId = sidebar_slot_id;
        c.lastCollapsed = sidebarItem.isCollapsed;
        c.lastWidth = zapp_sidebar_current_width(c);
        // Capture configured drag bounds before any setResizable lock so we
        // can restore the range on a later setResizable(true).
        c.cfgMinThickness = sidebarItem.minimumThickness;
        c.cfgMaxThickness = sidebarItem.maximumThickness;

        [sidebarItem addObserver:c forKeyPath:@"collapsed"
                         options:NSKeyValueObservingOptionNew context:NULL];
        [[NSNotificationCenter defaultCenter]
            addObserver:c
               selector:@selector(splitViewDidResize:)
                   name:NSSplitViewDidResizeSubviewsNotification
                 object:splitVC.splitView];

        zapp_sidebars[key] = c;
    });
}

void zapp_sidebar_unregister(void* window_ptr) {
    if (!window_ptr) return;
    zapp_sidebar_on_main(^{
        if (!zapp_sidebars) return;
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappSidebarController* c = zapp_sidebars[key];
        if (!c) return;
        @try {
            [c.sidebarItem removeObserver:c forKeyPath:@"collapsed"];
        } @catch (__unused NSException* e) {}
        [[NSNotificationCenter defaultCenter] removeObserver:c];
        [zapp_sidebars removeObjectForKey:key];
    });
}
