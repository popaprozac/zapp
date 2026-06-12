// macOS native toolbar (NSToolbar) — registry + delegate module.
// Shape mirrors sidebar.m: a dictionary keyed by the host NSWindow,
// attach called from window.m construction, unregister from destroy.
//
// Click delivery: custom-button clicks broadcast the window-event name
// `window:toolbar-clicked` {"windowId":"win-<n>","id":"<itemId>"} to ALL
// webviews + workers via bridge._onEvent (menu.m's __menu:click pattern;
// per-window, hence the windowId field). One emit feeds both surfaces:
// the creator's action map and any pane's win.on(TOOLBAR_CLICKED).

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

extern void darwin_webview_eval_all(const char* js);
extern void worker_broadcast_eval_js(char* js);
// menu.m (de-static'ed): sf:/file-path/data-URL icon resolver.
extern NSImage* zapp_resolve_icon(NSString* spec, CGFloat size, int templateMode);
// menu.m: builds a retained NSMenu from a MenuItemDef JSON array; clicks
// ride the existing __menu:click broadcast (zero new plumbing here).
extern void* darwin_menu_build_from_items_json(const char* items_json);
// window.m dispatch-table lookups: pane webviews for chrome-metrics injection.
extern WKWebView* zapp_webview_for_slot(int32_t slot);
extern int32_t zapp_sidebar_slot_lookup(int32_t host_slot);

// Tracking separator's private identifier (never user-visible).
static NSString* const kZappTrackingSeparatorId = @"zapp.trackingSeparator";

void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script);

@interface ZappToolbarController : NSObject <NSToolbarDelegate>
@property (nonatomic, weak) NSWindow* window;
@property (nonatomic, assign) int32_t windowNumericId;
@property (nonatomic, strong) NSArray<NSToolbarItemIdentifier>* identifiers;
@property (nonatomic, strong) NSDictionary<NSString*, NSDictionary*>* buttonsById;
// Chrome-metrics bookkeeping: KVO on the window's contentLayoutRect fires on
// every layout change (incl. live resize); the queue flag coalesces to one
// re-measure per runloop tick and the cached values skip no-op re-injections.
@property (nonatomic, assign) BOOL metricsUpdateQueued;
@property (nonatomic, assign) CGFloat lastInjectedInset;
@property (nonatomic, assign) CGFloat lastInjectedToolbarH;
@end

static NSMutableDictionary<NSValue*, ZappToolbarController*>* zapp_toolbars = nil;

@implementation ZappToolbarController

// Live chrome-metric updates: the user can right-click the toolbar and switch
// Icon Only / Text Only / Icon and Text at runtime — the band height changes
// with no window resize, but contentLayoutRect (KVO-compliant) tracks it.
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                        change:(NSDictionary*)change context:(void*)context {
    (void)object; (void)change; (void)context;
    if (![keyPath isEqualToString:@"contentLayoutRect"]) return;
    if (self.metricsUpdateQueued) return;
    self.metricsUpdateQueued = YES;
    __weak ZappToolbarController* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ZappToolbarController* s = weakSelf;
        if (!s) return;
        s.metricsUpdateQueued = NO;
        NSWindow* w = s.window;
        if (w) zapp_toolbar_inject_metrics((__bridge void*)w, s.windowNumericId, false);
    });
}

- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar {
    (void)toolbar;
    return self.identifiers;
}

- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar {
    (void)toolbar;
    return self.identifiers;
}

- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar
        itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
    willBeInsertedIntoToolbar:(BOOL)flag {
    (void)toolbar; (void)flag;

    if ([identifier isEqualToString:kZappTrackingSeparatorId]) {
        // Divider tracks the sidebar split. The split view lives on the
        // window's NSSplitViewController root (sidebar construction path).
        if (@available(macOS 11.0, *)) {
            NSViewController* vc = self.window.contentViewController;
            if ([vc isKindOfClass:[NSSplitViewController class]]) {
                NSSplitView* sv = ((NSSplitViewController*)vc).splitView;
                return [NSTrackingSeparatorToolbarItem
                    trackingSeparatorToolbarItemWithIdentifier:identifier
                                                     splitView:sv
                                                  dividerIndex:0];
            }
        }
        return nil;
    }

    // Custom button (system identifiers never reach this callback —
    // AppKit builds toggle/space items itself).
    NSDictionary* def = self.buttonsById[identifier];
    if (!def) return nil;

    // Pull-down menu item (Mail's filter button). The runtime stripped the
    // action callbacks; this re-serializes the cleaned MenuItemDef array for
    // menu.m's JSON builder. Clicks dispatch via __menu:click as usual.
    NSArray* menuItems = [def[@"menu"] isKindOfClass:[NSArray class]] ? def[@"menu"] : nil;
    if (menuItems.count) {
        if (@available(macOS 10.15, *)) {
            NSMenuToolbarItem* mitem = [[NSMenuToolbarItem alloc] initWithItemIdentifier:identifier];
            NSString* mlabel = [def[@"label"] isKindOfClass:[NSString class]] ? def[@"label"] : @"";
            mitem.label = mlabel;
            mitem.paletteLabel = mlabel.length ? mlabel : identifier;
            mitem.toolTip = mlabel;
            NSString* micon = [def[@"icon"] isKindOfClass:[NSString class]] ? def[@"icon"] : @"";
            if (micon.length) {
                mitem.image = zapp_resolve_icon(micon, 18.0, 1);
            }
            NSData* mdata = [NSJSONSerialization dataWithJSONObject:menuItems options:0 error:nil];
            NSString* mjson = mdata ? [[NSString alloc] initWithData:mdata encoding:NSUTF8StringEncoding] : nil;
            NSMenu* menu = mjson ? (__bridge_transfer NSMenu*)darwin_menu_build_from_items_json([mjson UTF8String]) : nil;
            if (menu) mitem.menu = menu;
            mitem.showsIndicator = YES; // the chevron
            return mitem;
        }
        // < 10.15: fall through to a plain button (clicks still broadcast).
    }

    NSToolbarItem* item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    NSString* label = [def[@"label"] isKindOfClass:[NSString class]] ? def[@"label"] : @"";
    item.label = label;
    item.paletteLabel = label.length ? label : identifier;
    item.toolTip = label;
    NSString* icon = [def[@"icon"] isKindOfClass:[NSString class]] ? def[@"icon"] : @"";
    if (icon.length) {
        // templateMode 1 = force template — toolbar glyphs must be template
        // images to pick up the bar's tint/vibrancy.
        item.image = zapp_resolve_icon(icon, 18.0, 1);
    }
    item.target = self;
    item.action = @selector(zappToolbarItemClicked:);
    if (@available(macOS 10.15, *)) {
        item.bordered = YES; // modern pill-button look in unified styles
    }
    return item;
}

- (void)zappToolbarItemClicked:(NSToolbarItem*)sender {
    NSString* itemId = sender.itemIdentifier;
    if (!itemId.length) return;
    int32_t numericId = self.windowNumericId;
    // Escape for JS string embedding (same trio as menu.m's click emit).
    NSString* escaped = [itemId stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('window:toolbar-clicked',"
            "'{\"windowId\":\"win-%d\",\"id\":\"%@\"}');})();",
            numericId, escaped];
        darwin_webview_eval_all([js UTF8String]);
        worker_broadcast_eval_js((char*)[js UTF8String]);
    });
}

@end

void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json, int32_t window_numeric_id) {
    if (!window_ptr || !toolbar_json || !toolbar_json[0]) return;
    NSCAssert([NSThread isMainThread], @"zapp toolbar registry is main-thread-only");
    NSWindow* window = (__bridge NSWindow*)window_ptr;

    NSData* data = [NSData dataWithBytes:toolbar_json length:strlen(toolbar_json)];
    NSError* err = nil;
    NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![root isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[zapp] toolbar: invalid toolbarJson (%@) — toolbar not attached",
              err ? err.localizedDescription : @"not an object");
        return;
    }
    NSArray* items = root[@"items"];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return;

    NSMutableArray<NSToolbarItemIdentifier>* ids = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSDictionary*>* buttons = [NSMutableDictionary dictionary];
    for (NSDictionary* def in items) {
        if (![def isKindOfClass:[NSDictionary class]]) continue;
        NSString* type = [def[@"type"] isKindOfClass:[NSString class]] ? def[@"type"] : @"button";
        if ([type isEqualToString:@"toggleSidebar"]) {
            // System item: AppKit supplies icon/animation and routes the
            // action to the split view controller's toggleSidebar:. State
            // stays consistent with win.sidebar.* — both mutate the same
            // NSSplitViewItem.collapsed, so sidebar.m's KVO still emits
            // SIDEBAR_COLLAPSED/EXPANDED either way.
            [ids addObject:NSToolbarToggleSidebarItemIdentifier];
        } else if ([type isEqualToString:@"trackingSeparator"]) {
            [ids addObject:kZappTrackingSeparatorId];
        } else if ([type isEqualToString:@"space"]) {
            [ids addObject:NSToolbarSpaceItemIdentifier];
        } else if ([type isEqualToString:@"flexibleSpace"]) {
            [ids addObject:NSToolbarFlexibleSpaceItemIdentifier];
        } else {
            // Custom button. The runtime validated id presence/uniqueness;
            // belt-and-suspenders here because native Zen-C apps can set
            // toolbarJson directly.
            NSString* itemId = def[@"id"];
            if (![itemId isKindOfClass:[NSString class]] || itemId.length == 0) continue;
            if (buttons[itemId]) continue;
            [ids addObject:itemId];
            buttons[itemId] = def;
        }
    }
    if (ids.count == 0) return;

    ZappToolbarController* c = [[ZappToolbarController alloc] init];
    c.window = window;
    c.windowNumericId = window_numeric_id;
    c.identifiers = ids;
    c.buttonsById = buttons;

    NSToolbar* tb = [[NSToolbar alloc] initWithIdentifier:
        [NSString stringWithFormat:@"zapp-toolbar-%d", window_numeric_id]];
    tb.delegate = c;
    tb.allowsUserCustomization = NO;
    NSString* style = [root[@"style"] isKindOfClass:[NSString class]] ? root[@"style"] : @"unified";
    tb.displayMode = [style isEqualToString:@"expanded"]
        ? NSToolbarDisplayModeIconAndLabel
        : NSToolbarDisplayModeIconOnly;
    if (@available(macOS 11.0, *)) {
        if ([style isEqualToString:@"unifiedCompact"]) window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
        else if ([style isEqualToString:@"expanded"])  window.toolbarStyle = NSWindowToolbarStyleExpanded;
        else                                           window.toolbarStyle = NSWindowToolbarStyleUnified;
    }

    // Register BEFORE assigning window.toolbar — the assignment triggers
    // delegate callbacks synchronously, and the registry retains the
    // controller (NSToolbar.delegate is weak/unretained).
    if (!zapp_toolbars) zapp_toolbars = [NSMutableDictionary dictionary];
    zapp_toolbars[[NSValue valueWithPointer:window_ptr]] = c;
    window.toolbar = tb;

    // Live metric updates: re-measure whenever the chrome geometry changes
    // (user toggles Icon/Text display modes via the toolbar context menu).
    // Removed in zapp_toolbar_unregister.
    [window addObserver:c forKeyPath:@"contentLayoutRect" options:0 context:NULL];
}

// Measure + inject the chrome-metric CSS vars into the window's pane(s).
//   --zapp-titlebar-height = the full top chrome inset (frame − contentLayoutRect)
//   --zapp-toolbar-height  = the measured NSToolbarView row height (== the band
//                            in unified styles; the sub-row in "expanded")
// Called one tick after attach (initial, add_user_script=true so reloads keep
// the value) and from the contentLayoutRect KVO on runtime display-mode
// changes (add_user_script=false — WKUserContentController can't remove
// individual scripts, so repeated adds would pile up; after a mode change a
// reloaded page briefly sees the attach-time value until the next KVO fires).
void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script) {
    NSWindow* window = (__bridge NSWindow*)window_ptr;
    if (!window) return;
    NSCAssert([NSThread isMainThread], @"zapp toolbar metrics are main-thread-only");

    CGFloat totalInset = window.frame.size.height - window.contentLayoutRect.size.height;
    if (totalInset < 0) totalInset = 0;

    // The row that CONTAINS the toolbar items. Class-name walk is the only
    // way to find it; fall back to the full band (== unified behavior) if
    // AppKit ever renames NSToolbarView.
    CGFloat toolbarH = 0;
    NSView* theme = window.contentView.superview;
    for (NSView* container in theme.subviews) {
        if (![NSStringFromClass([container class]) containsString:@"TitlebarContainer"]) continue;
        for (NSView* tb1 in container.subviews) {
            for (NSView* tb2 in tb1.subviews) {
                if ([NSStringFromClass([tb2 class]) containsString:@"NSToolbarView"]) {
                    toolbarH = tb2.frame.size.height;
                    break;
                }
            }
            if (toolbarH > 0) break;
        }
        break;
    }
    if (toolbarH <= 0) toolbarH = totalInset;

    // Skip no-op re-injections (the KVO also fires during plain window
    // resizes, where the chrome height doesn't change). Initial injection
    // (add_user_script) always runs.
    ZappToolbarController* c = zapp_toolbars[[NSValue valueWithPointer:window_ptr]];
    if (!add_user_script && c &&
        c.lastInjectedInset == totalInset && c.lastInjectedToolbarH == toolbarH) {
        return;
    }
    if (c) {
        c.lastInjectedInset = totalInset;
        c.lastInjectedToolbarH = toolbarH;
    }

    NSString* js = [NSString stringWithFormat:
        @"(function(){try{var r=document.documentElement;"
        @"if(r){r.style.setProperty('--zapp-titlebar-height','%.0fpx');"
        @"r.style.setProperty('--zapp-toolbar-height','%.0fpx');}}catch(e){}})();",
        totalInset, toolbarH];

    int32_t slots[2] = { host_slot, zapp_sidebar_slot_lookup(host_slot) };
    for (int i = 0; i < 2; i++) {
        WKWebView* wv = zapp_webview_for_slot(slots[i]);
        if (!wv) continue;
        if (add_user_script) {
            [wv.configuration.userContentController addUserScript:
                [[WKUserScript alloc] initWithSource:js
                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
        }
        [wv evaluateJavaScript:js completionHandler:nil];
    }
}

void zapp_toolbar_unregister(void* window_ptr) {
    if (!window_ptr || !zapp_toolbars) return;
    NSCAssert([NSThread isMainThread], @"zapp toolbar registry is main-thread-only");
    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappToolbarController* c = zapp_toolbars[key];
    if (c) {
        @try {
            [(__bridge NSWindow*)window_ptr removeObserver:c forKeyPath:@"contentLayoutRect"];
        } @catch (NSException* e) {
            (void)e; // not registered — harmless
        }
    }
    [zapp_toolbars removeObjectForKey:key];
}
