// macOS native popovers (NSPopover) — registry + delegate module.
// Shape mirrors sidebar.m/toolbar.m: a dictionary registry, create called
// from the router's __popover:create route, destroy from popover:destroy or
// the owning window's darwin_window_destroy sweep.
//
// The pane is a persistent, trusted host-twin webview (sidebar's model):
// full bootstrap, identifies as the host window, own transport slot. It
// loads ONCE at create (warm before first show); show()/hide() reuse it so
// page state survives. popoverDidClose broadcasts window:popover-closed
// {windowId, popoverId} to all webviews + workers (toolbar-click pattern).

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

extern void darwin_webview_create_ext(void* window_ptr, bool inspectable, bool accept_first_mouse,
                                      const char* url_override, int32_t numeric_id_pre_alloc,
                                      bool transparent_background,
                                      void* container_view, int32_t identity_window_id,
                                      int32_t pane_role);
extern void darwin_webview_eval_all(const char* js);
extern void worker_broadcast_eval_js(char* js);
extern WKWebView* zapp_webview_for_slot(int32_t slot);
extern void zapp_register_pane_webview(int32_t slot, WKWebView* wv, int32_t host_slot);
extern void zapp_clear_pane_slot(int32_t slot);
extern void zapp_teardown_pane_webview(WKWebView* wv);

@interface ZappPopoverController : NSObject <NSPopoverDelegate>
@property (nonatomic, strong) NSPopover* popover;
@property (nonatomic, strong) NSView* container;       // hosts the persistent webview
@property (nonatomic, weak) WKWebView* webview;
@property (nonatomic, weak) NSWindow* hostWindow;
@property (nonatomic, assign) void* hostWindowPtr;     // registry sweep key (darwin_window_destroy)
@property (nonatomic, assign) int32_t hostSlot;
@property (nonatomic, assign) int32_t popoverSlot;
@property (nonatomic, copy) NSString* popoverId;
@end

static NSMutableDictionary<NSString*, ZappPopoverController*>* zapp_popovers = nil;

@implementation ZappPopoverController

- (void)popoverDidClose:(NSNotification*)notification {
    (void)notification;
    // Fires for BOTH explicit hide() and transient auto-dismissal. The
    // popover (and its warm webview) stay alive — re-showable.
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&b._onEvent)b._onEvent('window:popover-closed',"
        "'{\"windowId\":\"win-%d\",\"popoverId\":\"%@\"}');})();",
        self.hostSlot, self.popoverId];
    darwin_webview_eval_all([js UTF8String]);
    worker_broadcast_eval_js((char*)[js UTF8String]);
}

@end

void darwin_popover_create(void* window_ptr, const char* popover_id,
                           const char* url, int32_t width, int32_t height,
                           const char* behavior, int32_t host_slot, int32_t popover_slot) {
    if (!window_ptr || !popover_id || !url || !url[0]) return;
    NSCAssert([NSThread isMainThread], @"zapp popover registry is main-thread-only");
    NSWindow* window = (__bridge NSWindow*)window_ptr;

    ZappPopoverController* c = [[ZappPopoverController alloc] init];
    c.hostWindow = window;
    c.hostWindowPtr = window_ptr;
    c.hostSlot = host_slot;
    c.popoverSlot = popover_slot;
    c.popoverId = [NSString stringWithUTF8String:popover_id];

    // Container at content size; the webview mounts into it and loads NOW
    // (warm before first show). pane_role 2 = popover (zapp.isPopover);
    // identity = the host window (host-twin, sidebar's model).
    // v1 simplification: inspectable/accept_first_mouse fixed to true —
    // threading the host window's original options through create is a
    // follow-up (popovers host the app's own dev-facing UI).
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    c.container = container;
    darwin_webview_create_ext(window_ptr, true, true, url, popover_slot, true,
                              (__bridge void*)container, host_slot, 2);
    for (NSView* sub in container.subviews) {
        if ([sub isKindOfClass:[WKWebView class]]) { c.webview = (WKWebView*)sub; break; }
    }
    if (c.webview) {
        zapp_register_pane_webview(popover_slot, c.webview, host_slot);
    }

    NSViewController* vc = [[NSViewController alloc] init];
    vc.view = container;

    NSPopover* pop = [[NSPopover alloc] init];
    pop.contentViewController = vc;
    pop.contentSize = NSMakeSize(width, height);
    pop.delegate = c;
    NSString* b = [NSString stringWithUTF8String:behavior ?: "transient"];
    if ([b isEqualToString:@"semitransient"])           pop.behavior = NSPopoverBehaviorSemitransient;
    else if ([b isEqualToString:@"applicationDefined"]) pop.behavior = NSPopoverBehaviorApplicationDefined;
    else                                                pop.behavior = NSPopoverBehaviorTransient;
    c.popover = pop;

    if (!zapp_popovers) zapp_popovers = [NSMutableDictionary dictionary];
    zapp_popovers[c.popoverId] = c;
}

// args_json: {"popoverId":..., "anchor":{...}, "edge":"bottom"} — anchor is
// either {"toolbarItem":"id"} or {"x","y","width","height"} in the HOST
// pane's CSS pixels. WKWebView is flipped (top-left origin, panel.m
// precedent) so DOM rects map directly to view coordinates; flipped-view
// edges: top=MinY, bottom=MaxY, left=MinX, right=MaxX.
void darwin_popover_show(const char* popover_id, const char* args_json) {
    if (!popover_id || !zapp_popovers) return;
    NSCAssert([NSThread isMainThread], @"zapp popover show is main-thread-only");
    ZappPopoverController* c = zapp_popovers[[NSString stringWithUTF8String:popover_id]];
    if (!c || !c.popover) return;
    NSWindow* window = c.hostWindow;
    // Liveness guard for ALL anchor paths: a reversibly-closed window is
    // ordered out but alive (releasedWhenClosed:NO) — showing a popover
    // against it would float the bubble over nothing.
    if (!window || !window.isVisible) return;

    NSDictionary* args = nil;
    if (args_json) {
        NSData* data = [NSData dataWithBytes:args_json length:strlen(args_json)];
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) args = parsed;
    }
    NSDictionary* anchor = [args[@"anchor"] isKindOfClass:[NSDictionary class]] ? args[@"anchor"] : nil;
    NSString* edgeName = [args[@"edge"] isKindOfClass:[NSString class]] ? args[@"edge"] : @"bottom";
    NSRectEdge edge = NSRectEdgeMaxY;                      // "bottom" (flipped view)
    if ([edgeName isEqualToString:@"top"])        edge = NSRectEdgeMinY;
    else if ([edgeName isEqualToString:@"left"])  edge = NSRectEdgeMinX;
    else if ([edgeName isEqualToString:@"right"]) edge = NSRectEdgeMaxX;

    NSString* toolbarItemId = [anchor[@"toolbarItem"] isKindOfClass:[NSString class]] ? anchor[@"toolbarItem"] : nil;
    if (toolbarItemId.length) {
        if (@available(macOS 14.0, *)) {
            for (NSToolbarItem* item in window.toolbar.items) {
                if ([item.itemIdentifier isEqualToString:toolbarItemId]) {
                    [c.popover showRelativeToToolbarItem:item];
                    return;
                }
            }
        }
        NSLog(@"[zapp] popover: toolbar item \"%@\" not found (or macOS < 14) — anchoring to titlebar", toolbarItemId);
        WKWebView* hostPane = zapp_webview_for_slot(c.hostSlot);
        if (!hostPane) return;
        [c.popover showRelativeToRect:NSMakeRect(0, 0, hostPane.bounds.size.width, 1)
                               ofView:hostPane preferredEdge:NSRectEdgeMaxY];
        return;
    }

    CGFloat x = [anchor[@"x"] isKindOfClass:[NSNumber class]] ? [anchor[@"x"] doubleValue] : 0;
    CGFloat y = [anchor[@"y"] isKindOfClass:[NSNumber class]] ? [anchor[@"y"] doubleValue] : 0;
    CGFloat w = [anchor[@"width"] isKindOfClass:[NSNumber class]] ? [anchor[@"width"] doubleValue] : 1;
    CGFloat h = [anchor[@"height"] isKindOfClass:[NSNumber class]] ? [anchor[@"height"] doubleValue] : 1;
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    WKWebView* hostPane = zapp_webview_for_slot(c.hostSlot);
    if (!hostPane) return;
    [c.popover showRelativeToRect:NSMakeRect(x, y, w, h) ofView:hostPane preferredEdge:edge];
}

void darwin_popover_hide(const char* popover_id) {
    if (!popover_id || !zapp_popovers) return;
    NSCAssert([NSThread isMainThread], @"zapp popover hide is main-thread-only");
    ZappPopoverController* c = zapp_popovers[[NSString stringWithUTF8String:popover_id]];
    if (c.popover.isShown) [c.popover performClose:nil];
}

// Full teardown: close, harden-teardown the webview (alpha.29 pattern),
// free the dispatch slot, drop the registry entry.
static void zapp_popover_destroy_controller(ZappPopoverController* c) {
    if (!c) return;
    if (c.popover.isShown) [c.popover performClose:nil];
    if (c.webview) zapp_teardown_pane_webview(c.webview);
    zapp_clear_pane_slot(c.popoverSlot);
    c.popover.delegate = nil;
    [zapp_popovers removeObjectForKey:c.popoverId];
}

void darwin_popover_destroy(const char* popover_id) {
    if (!popover_id || !zapp_popovers) return;
    NSCAssert([NSThread isMainThread], @"zapp popover destroy is main-thread-only");
    zapp_popover_destroy_controller(zapp_popovers[[NSString stringWithUTF8String:popover_id]]);
}

// Called from darwin_window_destroy: destroy every popover owned by the
// window being torn down.
void zapp_popover_unregister_window(void* window_ptr) {
    if (!window_ptr || !zapp_popovers) return;
    NSMutableArray<ZappPopoverController*>* doomed = [NSMutableArray array];
    for (NSString* key in zapp_popovers) {
        ZappPopoverController* c = zapp_popovers[key];
        if (c.hostWindowPtr == window_ptr) [doomed addObject:c];
    }
    for (ZappPopoverController* c in doomed) zapp_popover_destroy_controller(c);
}
