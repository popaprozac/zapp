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

extern void darwin_webview_eval_all(const char* js);
extern void worker_broadcast_eval_js(char* js);
// menu.m (de-static'ed): sf:/file-path/data-URL icon resolver.
extern NSImage* zapp_resolve_icon(NSString* spec, CGFloat size, int templateMode);

// Tracking separator's private identifier (never user-visible).
static NSString* const kZappTrackingSeparatorId = @"zapp.trackingSeparator";

@interface ZappToolbarController : NSObject <NSToolbarDelegate>
@property (nonatomic, weak) NSWindow* window;
@property (nonatomic, assign) int32_t windowNumericId;
@property (nonatomic, strong) NSArray<NSToolbarItemIdentifier>* identifiers;
@property (nonatomic, strong) NSDictionary<NSString*, NSDictionary*>* buttonsById;
@end

static NSMutableDictionary<NSValue*, ZappToolbarController*>* zapp_toolbars = nil;

@implementation ZappToolbarController

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
    NSWindow* window = (__bridge NSWindow*)window_ptr;

    NSData* data = [NSData dataWithBytes:toolbar_json length:strlen(toolbar_json)];
    NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return;
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
}

void zapp_toolbar_unregister(void* window_ptr) {
    if (!window_ptr || !zapp_toolbars) return;
    [zapp_toolbars removeObjectForKey:[NSValue valueWithPointer:window_ptr]];
}
