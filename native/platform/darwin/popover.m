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
                                      int32_t pane_role, bool host_has_sidebar,
                                      bool host_has_inspector);
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
#ifdef ZAPP_HAS_CEF
    // Popover content on CEF (webEngine:"chromium" build): mount a CEF browser
    // (pane_role=2 -> zapp.isPopover in the shared carrier builder), host-twin
    // identity = the host window — exactly as window.m's CEF pane-mount does.
    // c.webview stays nil (no WKWebView); teardown routes through the CEF
    // slot instead (zapp_popover_destroy_controller, below).
    {
        extern NSURL* zapp_resolve_url(const char* url_cstr);
        extern void zapp_cef_create_browser_in_view(void* parent_view, const char* url,
                                                    int32_t window_slot, const char* window_id,
                                                    const char* owner_id, int pane_role,
                                                    bool host_has_sidebar, bool host_has_inspector);
        NSString* hostWindowId = [NSString stringWithFormat:@"win-%d", host_slot];
        NSString* ownerId = [NSString stringWithFormat:@"owner-%p", window];
        NSURL* nsUrl = zapp_resolve_url(url);
        const char* cefUrl = nsUrl ? [[nsUrl absoluteString] UTF8String] : "zapp://index.html";
        if (!cefUrl || cefUrl[0] == '\0') cefUrl = "zapp://index.html";
        zapp_cef_create_browser_in_view((__bridge void*)container, cefUrl, popover_slot,
                                        [hostWindowId UTF8String], [ownerId UTF8String],
                                        2, false, false);
        // Mirror the WK #else path's zapp_register_pane_webview so
        // zapp_window_ids[popover_slot] is set to the host-twin id — without it,
        // Workers.create() and chrome/window ops from CEF popover content no-op
        // (darwin_window_id_string(popover_slot) -> NULL; router.nim:259,504).
        // nil webview: CEF has no WKWebView; zapp_register_webview stores nil
        // harmlessly (window.m:133) and sets the id. Same mechanism the CEF
        // sidebar/inspector panes use (window.m:1216/1233).
        zapp_register_pane_webview(popover_slot, nil, host_slot);
    }
#else
    darwin_webview_create_ext(window_ptr, true, true, url, popover_slot, true,
                              (__bridge void*)container, host_slot, 2, false, false);
    for (NSView* sub in container.subviews) {
        if ([sub isKindOfClass:[WKWebView class]]) { c.webview = (WKWebView*)sub; break; }
    }
    if (c.webview) {
        zapp_register_pane_webview(popover_slot, c.webview, host_slot);
    }
#endif

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
// either {"toolbarItem":"id"} or {"x","y","width","height"} in CSS pixels.
// rect coords are CSS px of the SENDER pane's webview — the pane that
// measured the element. WKWebView is flipped (top-left origin, panel.m
// precedent) so DOM rects map directly to view coordinates; flipped-view
// edges: top=MinY, bottom=MaxY, left=MinX, right=MaxX.
void darwin_popover_show(const char* popover_id, const char* args_json, int32_t sender_slot) {
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

    // Position against the SENDER's pane when it belongs to this popover's
    // window (element rects are measured in the calling pane's viewport —
    // sidebar panes are offset from the main pane). Foreign/worker senders
    // fall back to the host's main pane. All candidates are WKWebViews
    // (flipped, top-left origin), so DOM rects map directly.
    WKWebView* anchorView = zapp_webview_for_slot(sender_slot);
    if (!anchorView || anchorView.window != window) {
        anchorView = zapp_webview_for_slot(c.hostSlot);
    }
#ifdef ZAPP_HAS_CEF
    if (!anchorView) {
        // No WKWebView -> a CEF pane. Its browser NSView anchors the popover.
        // Cast to WKWebView* is deliberate: the show tail below uses only NSView
        // API (.window/.bounds/.isFlipped/showRelativeToRect:ofView:) on it.
        extern void* zapp_cef_view_for_slot(int32_t slot);
        NSView* cv = (__bridge NSView*)zapp_cef_view_for_slot(sender_slot);
        if (!cv || cv.window != window) cv = (__bridge NSView*)zapp_cef_view_for_slot(c.hostSlot);
        anchorView = (WKWebView*)cv;
    }
#endif
    if (!anchorView) return;

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
        [c.popover showRelativeToRect:NSMakeRect(0, 0, anchorView.bounds.size.width, 1)
                               ofView:anchorView preferredEdge:NSRectEdgeMaxY];
        return;
    }

    CGFloat x = [anchor[@"x"] isKindOfClass:[NSNumber class]] ? [anchor[@"x"] doubleValue] : 0;
    CGFloat y = [anchor[@"y"] isKindOfClass:[NSNumber class]] ? [anchor[@"y"] doubleValue] : 0;
    CGFloat w = [anchor[@"width"] isKindOfClass:[NSNumber class]] ? [anchor[@"width"] doubleValue] : 1;
    CGFloat h = [anchor[@"height"] isKindOfClass:[NSNumber class]] ? [anchor[@"height"] doubleValue] : 1;
    if (w < 1) w = 1;
    if (h < 1) h = 1;
#ifdef ZAPP_HAS_CEF
    // WKWebView is flipped (top-left); CEF's browser NSView may not be. When it
    // isn't, convert the DOM-top-left y so the popover anchors at the element,
    // not mirrored. isFlipped-guarded so a flipped view (incl. all WK) is untouched.
    if (!anchorView.isFlipped) { y = anchorView.bounds.size.height - y - h; }
#endif
    [c.popover showRelativeToRect:NSMakeRect(x, y, w, h) ofView:anchorView preferredEdge:edge];
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
#ifdef ZAPP_HAS_CEF
    extern void zapp_cef_teardown_browser_for_slot(int32_t slot);
    zapp_cef_teardown_browser_for_slot(c.popoverSlot);   // no-op if no CEF browser at slot
#endif
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
