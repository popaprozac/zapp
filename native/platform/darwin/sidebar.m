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
// Reach-through (Sub-cycle 2c): resolve the SwiftUI-backed NSSplitView/Controller
// (defined in window.m) so the AppKit sidebar primitives can drive it.
@class NSSplitViewController;
extern NSSplitViewController* zapp_find_split_vc(NSViewController* vc);
extern NSSplitView* zapp_find_split_view(NSView* v);
extern void zapp_dump_view_tree(NSView* v, int depth);
// SwiftUI pane drivers (defined in panes.swift) — only linked in when the
// swiftc tier is compiled (native.swiftui != false + swiftc present). Behind
// ZAPP_HAS_SWIFTUI so the opted-out/AppKit-only build doesn't reference an
// undefined symbol; swiftPaneState is never set on that path anyway.
#ifdef ZAPP_HAS_SWIFTUI
extern void zapp_swift_panes_set_sidebar_visible(void* state, bool visible);
extern void zapp_swift_panes_toggle_sidebar(void* state);
#endif

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
@property (nonatomic, assign) void* swiftPaneState;  // non-owning; set for the SwiftUI path (nil = AppKit)
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

// Shared pane event-emit: dispatch a window event into the host pane and one
// accessory pane (sidebar or inspector). eventName is the BARE suffix
// ("sidebar-collapsed" / "inspector-resized" etc.); dispatchWindowEvent in
// bootstrap/webview.ts prepends "window:". dataJson may be nil. Single-quoted
// JSON literal, backslash + quote escaped. Exported — also used by inspector.m.
void zapp_pane_emit(int32_t host_id, int32_t accessory_slot,
                    const char* eventName, NSString* dataJson) {
    if (!eventName) return;

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
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        @"if(b&&typeof b.dispatchWindowEvent==='function'){"
        @"b.dispatchWindowEvent('win-%d','%@',%@);}})();",
        host_id, event, dataArg];
    const char* jsc = [js UTF8String];

    darwin_window_eval_js(host_id, jsc);
    if (accessory_slot >= 0 && accessory_slot != host_id) {
        darwin_window_eval_js(accessory_slot, jsc);
    }
}

// Emit a window event into both sidebar panes (host + sidebar slot).
static void zapp_sidebar_emit(ZappSidebarController* c, const char* eventName, NSString* dataJson) {
    if (!c) return;
    zapp_pane_emit(c.hostWindowId, c.sidebarSlotId, eventName, dataJson);
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
}

@end

// Lazily bind the SwiftUI-backed split to the controller so the AppKit bodies
// work on the SwiftUI path. A NavigationSplitView's NSSplitView lives in the
// VIEW tree with its NSSplitViewController as the split view's delegate (proven
// in the 2c risk gate — the child-VC walk does NOT find it). Resolve on first
// control op because the split only exists after layout. items: [sidebar,
// content, (inspector?)]. The AppKit bodies then drive c.splitVC.splitView,
// which IS the sv we found here (svc is sv's delegate). Cached for the window's
// lifetime — not re-resolved if SwiftUI ever tears down and rebuilds the split
// (stable across nav + resize per the gate; under ARC a stale cache would no-op
// safely rather than crash).
static BOOL zapp_sidebar_bind_swiftui(ZappSidebarController* c) {
    if (c.splitVC && c.sidebarItem) return YES;            // already bound
    if (!c.swiftPaneState) return NO;
    void* win_ptr = darwin_window_get_by_numeric_id(c.hostWindowId);
    NSWindow* win = (__bridge NSWindow*)win_ptr;
    NSSplitView* sv = zapp_find_split_view(win.contentView);
    NSSplitViewController* svc = [sv.delegate isKindOfClass:[NSSplitViewController class]]
        ? (NSSplitViewController*)sv.delegate : nil;
    if (!svc || svc.splitViewItems.count == 0) return NO;  // not laid out yet / not found
    c.splitVC = svc;
    c.sidebarItem = svc.splitViewItems.firstObject;
    if (c.cfgMinThickness <= 0) c.cfgMinThickness = c.sidebarItem.minimumThickness;
    if (c.cfgMaxThickness <= 0) c.cfgMaxThickness = c.sidebarItem.maximumThickness;
    return YES;
}

// --- Control ops (router entry points) ---

void darwin_sidebar_toggle(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_toggle_sidebar(c.swiftPaneState); return; }
#endif
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
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_sidebar_visible(c.swiftPaneState, false); return; }
#endif
        if (!c.sidebarItem) return;
        if (c.sidebarItem.isCollapsed) return; // idempotent
        [[c.sidebarItem animator] setCollapsed:YES];
    });
}

void darwin_sidebar_expand(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_sidebar_visible(c.swiftPaneState, true); return; }
#endif
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

void darwin_sidebar_set_width(int32_t window_id, int32_t width) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (c.swiftPaneState && !zapp_sidebar_bind_swiftui(c)) {
            if (getenv("ZAPP_LOG")) NSLog(@"[zapp] sidebar: SwiftUI split not resolved yet — set_width skipped");
            return;
        }
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
        if (c.swiftPaneState && !zapp_sidebar_bind_swiftui(c)) {
            if (getenv("ZAPP_LOG")) NSLog(@"[zapp] sidebar: SwiftUI split not resolved yet — set_collapsible skipped");
            return;
        }
        if (!c.sidebarItem) return;
        c.sidebarItem.canCollapse = can_collapse ? YES : NO;
    });
}

// Allow/disallow resizing the sidebar by dragging the divider. Disallow locks
// the pane at its current width (min==max); allow restores the configured
// min/max drag range captured at register.
void darwin_sidebar_set_resizable(int32_t window_id, bool resizable) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (c.swiftPaneState && !zapp_sidebar_bind_swiftui(c)) {
            if (getenv("ZAPP_LOG")) NSLog(@"[zapp] sidebar: SwiftUI split not resolved yet — set_resizable skipped");
            return;
        }
        if (!c.sidebarItem) return;
        if (resizable) {
            c.sidebarItem.minimumThickness = c.cfgMinThickness;
            c.sidebarItem.maximumThickness = c.cfgMaxThickness;
        } else {
            CGFloat w = (CGFloat)zapp_sidebar_current_width(c);
            if (w <= 0) w = c.sidebarItem.minimumThickness; // pre-layout fallback
            c.sidebarItem.minimumThickness = w;
            c.sidebarItem.maximumThickness = w;
        }
    });
}

// --- Registry API for window.m (Task 5) ---

// SwiftUI-backed register: no splitVC/NSSplitViewItem, no KVO/NSNotification
// observers (the Swift callback is the observation source). lastCollapsed is the
// dedup baseline, seeded from the visibility the PaneState was created with.
void zapp_sidebar_register_swiftui(void* window_ptr, void* paneState,
                                   int32_t host_id, int32_t sidebar_slot_id,
                                   bool initial_collapsed) {
    if (!window_ptr || !paneState) return;
    zapp_sidebar_on_main(^{
        if (!zapp_sidebars) zapp_sidebars = [NSMutableDictionary dictionary];
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappSidebarController* c = [[ZappSidebarController alloc] init];
        c.swiftPaneState = paneState;
        c.hostWindowId = host_id;
        c.sidebarSlotId = sidebar_slot_id;
        c.lastCollapsed = initial_collapsed ? YES : NO;
        zapp_sidebars[key] = c;
    });
}

// Reverse path: SwiftUI sidebar visibility changed. Dedup against lastCollapsed,
// then emit the same event the AppKit KVO path emits. Called by window.m's
// reverse dispatcher (always on the main thread — SwiftUI bindings fire on main).
void zapp_sidebar_note_swiftui_visibility(void* window_ptr, bool collapsed) {
    if (!window_ptr || !zapp_sidebars) return;
    ZappSidebarController* c = zapp_sidebars[[NSValue valueWithPointer:window_ptr]];
    if (!c) return;
    if (collapsed == c.lastCollapsed) return;  // dedup (absorbs redundant sets)
    c.lastCollapsed = collapsed;
    zapp_sidebar_emit(c, collapsed ? "sidebar-collapsed" : "sidebar-expanded", nil);
}

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
        if (!c.swiftPaneState) {  // AppKit-only observers; none installed on the SwiftUI path
            @try {
                [c.sidebarItem removeObserver:c forKeyPath:@"collapsed"];
            } @catch (__unused NSException* e) {}
            [[NSNotificationCenter defaultCenter] removeObserver:c];
        }
        // Do NOT release swiftPaneState here — the window delegate owns it.
        [zapp_sidebars removeObjectForKey:key];
    });
}
