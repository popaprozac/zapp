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

// Emit a window event into BOTH panes. eventName is the FULL wire name
// ("window:sidebar-collapsed" etc.); dataJson may be nil. Mirrors the JS
// shape + escaping of window.m's dispatchWindowEvent evals (and panel.m's
// zapp_panel_emit): single-quoted JSON literal, backslash + quote escaped.
static void zapp_sidebar_emit(ZappSidebarController* c, const char* eventName, NSString* dataJson) {
    if (!c || !eventName) return;

    NSString* dataArg = @"undefined";
    if (dataJson) {
        NSString* esc = [dataJson stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        dataArg = [NSString stringWithFormat:@"'%@'", esc];
    }
    NSString* event = [NSString stringWithUTF8String:eventName];

    // Build per-target because dispatchWindowEvent's first arg is the target
    // window id ("win-<hostId>"). Both panes belong to the same logical
    // window, so both receive the host's id.
    int32_t hostId = c.hostWindowId;
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        @"if(b&&typeof b.dispatchWindowEvent==='function'){"
        @"b.dispatchWindowEvent('win-%d','%@',%@);}})();",
        hostId, event, dataArg];
    const char* jsc = [js UTF8String];

    darwin_window_eval_js(c.hostWindowId, jsc);
    if (c.sidebarSlotId >= 0 && c.sidebarSlotId != c.hostWindowId) {
        darwin_window_eval_js(c.sidebarSlotId, jsc);
    }
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
    zapp_sidebar_emit(c, collapsed ? "window:sidebar-collapsed"
                                   : "window:sidebar-expanded", nil);
}

@implementation ZappSidebarController

// KVO on the split item's `collapsed` key — fires for system toggle, our
// animated ops, and divider snap-to-collapse alike.
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                        change:(NSDictionary*)change context:(void*)context {
    if ([keyPath isEqualToString:@"collapsed"]) {
        zapp_sidebar_sync_collapse(self);
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
    zapp_sidebar_emit(self, "window:sidebar-resized", json);
}

@end

// --- Control ops (router entry points) ---

void darwin_sidebar_toggle(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c || !c.sidebarItem) return;
        // Documented AppKit idiom: animate the collapsed property via the
        // item's animator proxy.
        [[c.sidebarItem animator] setCollapsed:!c.sidebarItem.isCollapsed];
    });
}

void darwin_sidebar_collapse(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c || !c.sidebarItem) return;
        if (c.sidebarItem.isCollapsed) return; // idempotent
        [[c.sidebarItem animator] setCollapsed:YES];
    });
}

void darwin_sidebar_expand(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c || !c.sidebarItem) return;
        if (!c.sidebarItem.isCollapsed) return; // idempotent
        [[c.sidebarItem animator] setCollapsed:NO];
    });
}

void darwin_sidebar_set_width(int32_t window_id, int32_t width) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c || !c.sidebarItem || !c.splitVC) return;
        CGFloat w = (CGFloat)width;
        CGFloat minT = c.sidebarItem.minimumThickness;
        CGFloat maxT = c.sidebarItem.maximumThickness;
        if (minT > 0 && w < minT) w = minT;
        if (maxT > 0 && w > maxT) w = maxT;
        [c.splitVC.splitView setPosition:w ofDividerAtIndex:0];
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
