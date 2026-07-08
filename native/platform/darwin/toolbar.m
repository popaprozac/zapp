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
extern void darwin_inspector_toggle(int32_t window_id);
extern int32_t zapp_inspector_divider_index(void* window_ptr);
extern int32_t zapp_inspector_slot_lookup(int32_t host_slot);
extern bool zapp_inspector_is_collapsible(void* window_ptr);   // #665: grey the toggle when off

// Tracking separator's private identifiers (never user-visible).
// Sidebar/default uses the original id (byte-stable for shipped sidebar behavior).
// Inspector gets a distinct id so both can coexist in the same toolbar.
static NSString* const kZappTrackingSeparatorId          = @"zapp.trackingSeparator";
static NSString* const kZappTrackingSeparatorInspectorId = @"zapp.trackingSeparator.inspector";
static NSString* const kZappToggleInspectorId = @"zapp.toggleInspector";

// Parse "#RGB" / "#RRGGBB" / "#RRGGBBAA" → NSColor (nil on malformed).
static NSColor* zapp_toolbar_color(NSString* hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return nil;
    NSString* s = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (s.length == 3) { // expand #RGB → #RRGGBB
        unichar c[3]; [s getCharacters:c range:NSMakeRange(0,3)];
        s = [NSString stringWithFormat:@"%C%C%C%C%C%C", c[0],c[0],c[1],c[1],c[2],c[2]];
    }
    if (s.length != 6 && s.length != 8) return nil;
    unsigned int v = 0;
    if (![[NSScanner scannerWithString:s] scanHexInt:&v]) return nil;
    CGFloat r,g,b,a;
    if (s.length == 8) { r=((v>>24)&0xFF)/255.0; g=((v>>16)&0xFF)/255.0; b=((v>>8)&0xFF)/255.0; a=(v&0xFF)/255.0; }
    else               { r=((v>>16)&0xFF)/255.0; g=((v>>8)&0xFF)/255.0; b=(v&0xFF)/255.0; a=1.0; }
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

// Build an NSItemBadge from a def's "badge" dict. Returns nil for absent/none.
API_AVAILABLE(macos(26.0))
static NSItemBadge* zapp_toolbar_badge(NSDictionary* def) {
    NSDictionary* b = [def[@"badge"] isKindOfClass:[NSDictionary class]] ? def[@"badge"] : nil;
    if (!b) return nil;
    NSString* kind = [b[@"kind"] isKindOfClass:[NSString class]] ? b[@"kind"] : @"none";
    if ([kind isEqualToString:@"count"]) {
        NSNumber* n = [b[@"count"] isKindOfClass:[NSNumber class]] ? b[@"count"] : @0;
        return [NSItemBadge badgeWithCount:n.integerValue];
    }
    if ([kind isEqualToString:@"text"]) {
        NSString* t = [b[@"text"] isKindOfClass:[NSString class]] ? b[@"text"] : @"";
        return [NSItemBadge badgeWithText:t];
    }
    if ([kind isEqualToString:@"dot"]) return [NSItemBadge indicatorBadge];
    return nil; // "none"
}

// Apply the W2 trio (style/tint/badge/bordered) from a stored def onto a live
// item. bordered is ungated; style/tint/badge require macOS 26.
static void zapp_toolbar_apply_trio(NSToolbarItem* item, NSDictionary* def) {
    NSNumber* bordered = [def[@"bordered"] isKindOfClass:[NSNumber class]] ? def[@"bordered"] : nil;
    if (@available(macOS 10.15, *)) item.bordered = bordered ? bordered.boolValue : YES;
    if (@available(macOS 26.0, *)) {
        NSString* style = [def[@"style"] isKindOfClass:[NSString class]] ? def[@"style"] : @"plain";
        BOOL prominent = [style isEqualToString:@"prominent"];
        item.style = prominent ? NSToolbarItemStyleProminent : NSToolbarItemStylePlain;
        NSString* tint = [def[@"tintColor"] isKindOfClass:[NSString class]] ? def[@"tintColor"] : nil;
        item.backgroundTintColor = prominent ? zapp_toolbar_color(tint) : nil;
        item.badge = zapp_toolbar_badge(def);
    }
}

static void zapp_toolbar_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// Shared toolbar emit — used by the NSToolbar handler. item_id must be non-NULL.
// SAFETY: the NSString conversion runs SYNCHRONOUSLY (before the dispatch_async),
// so the captured `escaped` is a retained NSString and the raw pointer never
// escapes onto the async block.
void zapp_toolbar_emit_click(int32_t host_id, const char* item_id) {
    if (!item_id) return;
    NSString* itemId = [NSString stringWithUTF8String:item_id];
    if (!itemId.length) return;
    // Escape for JS string embedding (same trio as menu.m's click emit).
    NSString* escaped = [itemId stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('window:toolbar-clicked',"
            "'{\"windowId\":\"win-%d\",\"id\":\"%@\"}');})();",
            host_id, escaped];
        darwin_webview_eval_all([js UTF8String]);
        worker_broadcast_eval_js((char*)[js UTF8String]);
    });
}

// Broadcast window:toolbar-group-selected {windowId,id,index,selected} to all
// webviews + workers (same fan-out as toolbar-clicked).
void zapp_toolbar_emit_group_select(int32_t host_id, const char* group_id, int32_t index, bool selected) {
    if (!group_id) return;
    NSString* gid = [NSString stringWithUTF8String:group_id];
    if (!gid.length) return;
    NSString* escaped = [gid stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('window:toolbar-group-selected',"
            "'{\"windowId\":\"win-%d\",\"id\":\"%@\",\"index\":%d,\"selected\":%@}');})();",
            host_id, escaped, index, selected ? @"true" : @"false"];
        darwin_webview_eval_all([js UTF8String]);
        worker_broadcast_eval_js((char*)[js UTF8String]);
    });
}

// Mirror menu.m's __menu:click emit so NSMenuToolbarItem clicks route
// identically. menu.m emits, verbatim:
//   b._onEvent('__menu:click','{"id":"<escaped>"}')
// with the same backslash/double-quote/single-quote escaping trio and the same
// darwin_webview_eval_all + worker_broadcast_eval_js fan-out. SAFETY identical
// to zapp_toolbar_emit_click: the const char* is converted synchronously.
void zapp_toolbar_emit_menu_click(int32_t host_id, const char* menu_id) {
    (void)host_id;  // __menu:click is window-agnostic (matches menu.m's shape).
    if (!menu_id) return;
    NSString* menuId = [NSString stringWithUTF8String:menu_id];
    if (!menuId.length) return;
    NSString* escaped = [menuId stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('__menu:click','{\"id\":\"%@\"}');})();",
            escaped];
        darwin_webview_eval_all([js UTF8String]);
        worker_broadcast_eval_js((char*)[js UTF8String]);
    });
}

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
// Safe-area cache: sidebar collapse/resize changes sa.left without changing
// the titlebar/toolbar metrics — include it in the skip-guard so re-injection
// runs whenever the sidebar overlap changes.
@property (nonatomic, assign) CGFloat lastInjectedSafeLeft;
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

    if ([identifier isEqualToString:kZappToggleInspectorId]) {
        NSToolbarItem* item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Inspector";
        item.paletteLabel = @"Toggle Inspector";
        item.toolTip = @"Toggle Inspector";
        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:@"sidebar.right"
                          accessibilityDescription:@"Toggle Inspector"];
        }
        item.target = self;
        item.action = @selector(zappToggleInspectorClicked:);
        if (@available(macOS 10.15, *)) item.bordered = YES;
        return item;
    }

    if ([identifier isEqualToString:kZappTrackingSeparatorId] ||
        [identifier isEqualToString:kZappTrackingSeparatorInspectorId]) {
        // Divider tracks a split pane. "pane" in the stored def determines
        // which divider: "inspector" → zapp_inspector_divider_index,
        // anything else (including absent/nil) → divider 0 (sidebar).
        if (@available(macOS 11.0, *)) {
            NSViewController* vc = self.window.contentViewController;
            if ([vc isKindOfClass:[NSSplitViewController class]]) {
                NSSplitView* sv = ((NSSplitViewController*)vc).splitView;
                NSDictionary* def = self.buttonsById[identifier];
                NSString* pane = [def[@"pane"] isKindOfClass:[NSString class]] ? def[@"pane"] : @"sidebar";
                NSInteger dividerIndex = 0;
                if ([pane isEqualToString:@"inspector"]) {
                    int32_t di = zapp_inspector_divider_index((__bridge void*)self.window);
                    if (di < 0) return nil; // no inspector — drop
                    dividerIndex = (NSInteger)di;
                }
                return [NSTrackingSeparatorToolbarItem
                    trackingSeparatorToolbarItemWithIdentifier:identifier
                                                     splitView:sv
                                                  dividerIndex:dividerIndex];
            }
        }
        return nil;
    }

    // Custom button (system identifiers never reach this callback —
    // AppKit builds toggle/space items itself).
    NSDictionary* def = self.buttonsById[identifier];
    if (!def) return nil;

    // Segmented control group (NSToolbarItemGroup, macOS 10.15+).
    if ([def[@"type"] isEqualToString:@"segmented"]) {
        if (@available(macOS 10.15, *)) {
            NSArray* segs = [def[@"segments"] isKindOfClass:[NSArray class]] ? def[@"segments"] : @[];
            NSString* modeStr = [def[@"selectionMode"] isKindOfClass:[NSString class]] ? def[@"selectionMode"] : @"momentary";
            NSToolbarItemGroupSelectionMode mode = [modeStr isEqualToString:@"one"] ? NSToolbarItemGroupSelectionModeSelectOne
                : ([modeStr isEqualToString:@"any"] ? NSToolbarItemGroupSelectionModeSelectAny : NSToolbarItemGroupSelectionModeMomentary);
            // Build titles or images. Prefer images when any segment has an icon.
            BOOL useImages = NO;
            for (NSDictionary* s in segs) if ([s[@"icon"] isKindOfClass:[NSString class]] && ((NSString*)s[@"icon"]).length) { useImages = YES; break; }
            // #744: `labels` feeds the collapsed/overflow menu representation
            // AppKit builds for the group — an empty string there renders as a
            // blank chevron entry. Fall back to the segment id, then its index,
            // so labels never contains @"".
            NSMutableArray* labels = [NSMutableArray array];
            for (NSUInteger si = 0; si < segs.count; si++) {
                NSDictionary* s = segs[si];
                NSString* segLabel = [s[@"label"] isKindOfClass:[NSString class]] && ((NSString*)s[@"label"]).length
                    ? s[@"label"]
                    : ([s[@"id"] isKindOfClass:[NSString class]] && ((NSString*)s[@"id"]).length ? s[@"id"] : [NSString stringWithFormat:@"%lu", (unsigned long)si]);
                [labels addObject:segLabel];
            }
            NSToolbarItemGroup* group;
            if (useImages) {
                NSMutableArray<NSImage*>* imgs = [NSMutableArray array];
                for (NSDictionary* s in segs) {
                    NSString* ic = [s[@"icon"] isKindOfClass:[NSString class]] ? s[@"icon"] : @"";
                    NSImage* im = ic.length ? zapp_resolve_icon(ic, 18.0, 1) : [[NSImage alloc] initWithSize:NSMakeSize(1,1)];
                    [imgs addObject:(im ?: [[NSImage alloc] initWithSize:NSMakeSize(1,1)])];
                }
                group = [NSToolbarItemGroup groupWithItemIdentifier:identifier images:imgs selectionMode:mode labels:labels target:self action:@selector(zappToolbarGroupChanged:)];
            } else {
                NSMutableArray<NSString*>* titles = [NSMutableArray array];
                for (NSDictionary* s in segs) [titles addObject:([s[@"label"] isKindOfClass:[NSString class]] ? s[@"label"] : @"")];
                group = [NSToolbarItemGroup groupWithItemIdentifier:identifier titles:titles selectionMode:mode labels:nil target:self action:@selector(zappToolbarGroupChanged:)];
            }
            // #744 residual: `labels` (above) only feeds the per-segment
            // overflow-menu ENTRIES. The group ITEM ITSELF has no label unless
            // we set one — collapsed to a single chevron button, that renders
            // BLANK. Only set when the def carries a non-empty top-level
            // `label`; unlabeled groups keep prior (unlabeled) behavior.
            NSString* groupLabel = [def[@"label"] isKindOfClass:[NSString class]] ? def[@"label"] : @"";
            if (groupLabel.length) {
                group.label = groupLabel;
                group.paletteLabel = groupLabel;
            }
            // #744 completion: in icon-only toolbar display mode, AppKit
            // renders the collapsed group's IMAGE, not its label — `label`
            // (above) alone still leaves a blank button body. Only set when
            // the def carries a non-empty top-level `icon`; unlabeled/
            // unimaged groups keep prior (blank) behavior.
            NSString* groupIcon = [def[@"icon"] isKindOfClass:[NSString class]] ? def[@"icon"] : @"";
            if (groupIcon.length) group.image = zapp_resolve_icon(groupIcon, 18.0, 1);
            NSString* repr = [def[@"controlRepresentation"] isKindOfClass:[NSString class]] ? def[@"controlRepresentation"] : @"automatic";
            group.controlRepresentation = [repr isEqualToString:@"expanded"] ? NSToolbarItemGroupControlRepresentationExpanded
                : ([repr isEqualToString:@"collapsed"] ? NSToolbarItemGroupControlRepresentationCollapsed : NSToolbarItemGroupControlRepresentationAutomatic);
            // initial selection
            NSArray* sel = [def[@"selected"] isKindOfClass:[NSArray class]] ? def[@"selected"] : @[];
            for (NSNumber* n in sel) { NSInteger i = n.integerValue; if (i >= 0 && i < (NSInteger)segs.count) [group setSelected:YES atIndex:i]; }
            // per-segment enabled
            for (NSUInteger i = 0; i < group.subitems.count && i < segs.count; i++) {
                NSNumber* en = [segs[i][@"enabled"] isKindOfClass:[NSNumber class]] ? segs[i][@"enabled"] : nil;
                group.subitems[i].enabled = en ? en.boolValue : YES;
            }
            return group;
        }
        NSLog(@"[zapp] toolbar: segmented group requires macOS 10.15 — item dropped");
        return nil;
    }

    // Plain grouping (NSToolbarItemGroup with full button subitems, macOS 10.15+).
    if ([def[@"type"] isEqualToString:@"group"]) {
        if (@available(macOS 10.15, *)) {
            NSToolbarItemGroup* group = [[NSToolbarItemGroup alloc] initWithItemIdentifier:identifier];
            NSArray* subs = [def[@"items"] isKindOfClass:[NSArray class]] ? def[@"items"] : @[];
            NSMutableArray<NSToolbarItem*>* built = [NSMutableArray array];
            for (NSDictionary* sub in subs) {
                NSString* sid = [sub[@"id"] isKindOfClass:[NSString class]] ? sub[@"id"] : nil;
                if (!sid.length) continue;
                NSToolbarItem* bi = [[NSToolbarItem alloc] initWithItemIdentifier:sid];
                NSString* lbl = [sub[@"label"] isKindOfClass:[NSString class]] ? sub[@"label"] : @"";
                bi.label = lbl; bi.paletteLabel = lbl.length ? lbl : sid; bi.toolTip = lbl;
                NSString* ic = [sub[@"icon"] isKindOfClass:[NSString class]] ? sub[@"icon"] : @"";
                if (ic.length) bi.image = zapp_resolve_icon(ic, 18.0, 1);
                bi.target = self; bi.action = @selector(zappToolbarItemClicked:);
                zapp_toolbar_apply_trio(bi, sub);   // bordered (+ macOS-26 trio if present)
                // Honor enabled:false — group sub-items aren't in buttonsById, so
                // validateToolbarItem: can't answer for them; disable autovalidation
                // so the explicit state sticks (mirrors the segmented flavor).
                NSNumber* en = [sub[@"enabled"] isKindOfClass:[NSNumber class]] ? sub[@"enabled"] : nil;
                bi.autovalidates = NO;
                bi.enabled = en ? en.boolValue : YES;
                [built addObject:bi];
            }
            group.subitems = built;
            NSString* repr = [def[@"controlRepresentation"] isKindOfClass:[NSString class]] ? def[@"controlRepresentation"] : @"automatic";
            group.controlRepresentation = [repr isEqualToString:@"expanded"] ? NSToolbarItemGroupControlRepresentationExpanded
                : ([repr isEqualToString:@"collapsed"] ? NSToolbarItemGroupControlRepresentationCollapsed : NSToolbarItemGroupControlRepresentationAutomatic);
            return group;
        }
        NSLog(@"[zapp] toolbar: group requires macOS 10.15 — item dropped");
        return nil;
    }

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
            NSNumber* ind = [def[@"indicator"] isKindOfClass:[NSNumber class]] ? def[@"indicator"] : nil;
            mitem.showsIndicator = ind ? ind.boolValue : YES; // the chevron
            // No action → AppKit never validates this item; own .enabled
            // directly (mirrors validateToolbarItem: for action buttons).
            mitem.autovalidates = NO;
            NSNumber* men = [def[@"enabled"] isKindOfClass:[NSNumber class]] ? def[@"enabled"] : nil;
            mitem.enabled = men ? men.boolValue : YES;
            zapp_toolbar_apply_trio(mitem, def);
            return mitem;
        }
        // < 10.15: fall through to a plain button (clicks still broadcast).
    }

    // Non-interactive text label (NSTextField hosted in an NSToolbarItem).
    if ([def[@"type"] isEqualToString:@"label"]) {
        NSString* text = [def[@"text"] isKindOfClass:[NSString class]] ? def[@"text"] : @"";
        NSToolbarItem* labelItem = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        NSTextField* tf = [NSTextField labelWithString:text];
        tf.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
        [tf sizeToFit];
        labelItem.view = tf;
        labelItem.label = text;
        labelItem.paletteLabel = text.length ? text : identifier;
        labelItem.minSize = tf.fittingSize;
        labelItem.maxSize = tf.fittingSize;
        labelItem.autovalidates = NO;
        labelItem.enabled = YES;
        // #745: without an explicit menuFormRepresentation, AppKit synthesizes
        // an ENABLED NSMenuItem for the >> overflow menu, which looks
        // clickable. Represent the label as disabled text.
        NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:(text.length ? text : identifier)
                                                     action:NULL keyEquivalent:@""];
        mi.enabled = NO;
        labelItem.menuFormRepresentation = mi;
        // Custom-view items don't display their hosted NSTextField until the
        // toolbar performs its first layout pass — at create time the field
        // renders blank until something forces a relayout. Re-apply sizing on
        // the next main-queue turn (after that first pass) so the text shows at
        // launch, exactly as updateItem({text}) corrects it post-layout.
        dispatch_async(dispatch_get_main_queue(), ^{
            [tf sizeToFit];
            NSSize fit = tf.fittingSize;
            labelItem.minSize = fit;
            labelItem.maxSize = fit;
        });
        return labelItem;
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
    zapp_toolbar_apply_trio(item, def);
    return item;
}

// AppKit's canonical enabled mechanism for action items: the toolbar
// revalidates on its own schedule (key-window changes, event loop idle),
// overwriting any bare `.enabled` set — so the stored def is the source of
// truth and this answers every revalidation pass. Default YES.
- (BOOL)validateToolbarItem:(NSToolbarItem*)item {
    // #665: grey the inspector toggle when the inspector is non-collapsible (parity with
    // the SwiftUI path's .disabled). canCollapse on the NSSplitViewItem is the source.
    if ([item.itemIdentifier isEqualToString:kZappToggleInspectorId])
        return zapp_inspector_is_collapsible((__bridge void*)self.window);
    NSDictionary* def = self.buttonsById[item.itemIdentifier];
    NSNumber* en = [def[@"enabled"] isKindOfClass:[NSNumber class]] ? def[@"enabled"] : nil;
    return en ? en.boolValue : YES;
}

- (void)zappToggleInspectorClicked:(NSToolbarItem*)sender {
    (void)sender;
    darwin_inspector_toggle(self.windowNumericId);
}

- (void)zappToolbarItemClicked:(NSToolbarItem*)sender {
    if (!sender.itemIdentifier.length) return;
    zapp_toolbar_emit_click(self.windowNumericId, [sender.itemIdentifier UTF8String]);
}

- (void)zappToolbarGroupChanged:(NSToolbarItemGroup*)sender {
    if (![sender isKindOfClass:[NSToolbarItemGroup class]]) return;
    NSInteger idx = sender.selectedIndex;
    // Momentary groups report -1; fall back to the highlighted segment if needed.
    if (idx < 0) { for (NSInteger i = 0; i < (NSInteger)sender.subitems.count; i++) if ([sender isSelectedAtIndex:i]) { idx = i; break; } }
    BOOL sel = (idx >= 0) ? [sender isSelectedAtIndex:idx] : NO;
    zapp_toolbar_emit_group_select(self.windowNumericId, [sender.itemIdentifier UTF8String], (int32_t)idx, sel);
}

@end

// Dedup helper for system-item identifiers that cannot appear more than once.
// Checks all three placement buckets so an item added to any slot isn't
// re-added to another (NSToolbar raises on duplicate non-space identifiers).
static BOOL zapp_toolbar_has_id(NSArray* a, NSArray* b, NSArray* c, NSString* x) {
    return [a containsObject:x] || [b containsObject:x] || [c containsObject:x];
}

// Parse the wire items array into the identifier list + custom-button defs.
// Shared by darwin_toolbar_attach and darwin_toolbar_set_items.
// Items are bucketed by their "placement" key (default "leading"), then
// concatenated as: leading | flexSpace | center | flexSpace | trailing,
// with NSToolbarFlexibleSpaceItemIdentifier auto-inserted only between
// non-empty groups. Within-bucket order is preserved (stable).
static NSArray<NSToolbarItemIdentifier>* zapp_toolbar_parse_items(
    NSArray* items, NSMutableDictionary<NSString*, NSDictionary*>* buttons) {
    NSMutableArray<NSToolbarItemIdentifier>* leading  = [NSMutableArray array];
    NSMutableArray<NSToolbarItemIdentifier>* center   = [NSMutableArray array];
    NSMutableArray<NSToolbarItemIdentifier>* trailing = [NSMutableArray array];
    for (NSDictionary* def in items) {
        if (![def isKindOfClass:[NSDictionary class]]) continue;
        NSString* type = [def[@"type"] isKindOfClass:[NSString class]] ? def[@"type"] : @"button";
        // Route this item to its slot bucket (default leading).
        NSString* placement = [def[@"placement"] isKindOfClass:[NSString class]] ? def[@"placement"] : @"leading";
        NSMutableArray<NSToolbarItemIdentifier>* bucket =
            [placement isEqualToString:@"center"]   ? center   :
            [placement isEqualToString:@"trailing"]  ? trailing : leading;
        if ([type isEqualToString:@"toggleSidebar"]) {
            // System item: AppKit supplies icon/animation and routes the
            // action to the split view controller's toggleSidebar:. State
            // stays consistent with win.sidebar.* — both mutate the same
            // NSSplitViewItem.collapsed, so sidebar.m's KVO still emits
            // SIDEBAR_COLLAPSED/EXPANDED either way.
            // NSToolbar raises on duplicate non-space identifiers; AppKit's
            // own default-identifiers attach path filters dups, so mirror it.
            if (!zapp_toolbar_has_id(leading, center, trailing, NSToolbarToggleSidebarItemIdentifier))
                [bucket addObject:NSToolbarToggleSidebarItemIdentifier];
        } else if ([type isEqualToString:@"toggleInspector"]) {
            if (!zapp_toolbar_has_id(leading, center, trailing, kZappToggleInspectorId))
                [bucket addObject:kZappToggleInspectorId];
        } else if ([type isEqualToString:@"trackingSeparator"]) {
            NSString* tsPane = [def[@"pane"] isKindOfClass:[NSString class]] ? def[@"pane"] : @"sidebar";
            NSString* tsId = [tsPane isEqualToString:@"inspector"]
                ? kZappTrackingSeparatorInspectorId : kZappTrackingSeparatorId;
            if (!zapp_toolbar_has_id(leading, center, trailing, tsId)) {
                [bucket addObject:tsId];
                buttons[tsId] = def;  // carries "pane"
            }
        } else if ([type isEqualToString:@"space"]) {
            [bucket addObject:NSToolbarSpaceItemIdentifier];
        } else if ([type isEqualToString:@"flexibleSpace"]) {
            [bucket addObject:NSToolbarFlexibleSpaceItemIdentifier];
        } else if ([type isEqualToString:@"segmented"]) {
            NSString* gid = [def[@"id"] isKindOfClass:[NSString class]] ? def[@"id"] : nil;
            if (gid.length == 0 || buttons[gid]) continue;
            [bucket addObject:gid];
            buttons[gid] = def;   // carries segments/selectionMode/selected/controlRepresentation
        } else if ([type isEqualToString:@"group"]) {
            NSString* gid = [def[@"id"] isKindOfClass:[NSString class]] ? def[@"id"] : nil;
            if (gid.length == 0 || buttons[gid]) continue;
            [bucket addObject:gid];
            buttons[gid] = def;   // carries items/controlRepresentation
        } else if ([type isEqualToString:@"label"]) {
            NSString* lid = [def[@"id"] isKindOfClass:[NSString class]] ? def[@"id"] : nil;
            if (lid.length == 0 || buttons[lid]) continue;
            [bucket addObject:lid];
            buttons[lid] = def;   // carries "text"
        } else {
            // Custom button. The runtime validated id presence/uniqueness;
            // belt-and-suspenders here because native Zen-C apps can set
            // toolbarJson directly.
            NSString* itemId = def[@"id"];
            if (![itemId isKindOfClass:[NSString class]] || itemId.length == 0) continue;
            if (buttons[itemId]) continue;
            [bucket addObject:itemId];
            buttons[itemId] = def;
        }
    }
    // Concatenate buckets: leading | flexSpace | center | flexSpace | trailing.
    // Auto-flexSpace is inserted only between non-empty groups.
    NSMutableArray<NSToolbarItemIdentifier>* out = [NSMutableArray array];
    [out addObjectsFromArray:leading];
    if (center.count > 0) {
        if (out.count > 0) [out addObject:NSToolbarFlexibleSpaceItemIdentifier];
        [out addObjectsFromArray:center];
        if (trailing.count > 0) [out addObject:NSToolbarFlexibleSpaceItemIdentifier];
        [out addObjectsFromArray:trailing];
    } else if (trailing.count > 0) {
        if (out.count > 0) [out addObject:NSToolbarFlexibleSpaceItemIdentifier];
        [out addObjectsFromArray:trailing];
    }
    return out;
}

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

    NSMutableDictionary<NSString*, NSDictionary*>* buttons = [NSMutableDictionary dictionary];
    NSArray<NSToolbarItemIdentifier>* ids = zapp_toolbar_parse_items(items, buttons);
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

// Replace the full item set. Registry hit: reconcile the SAME NSToolbar
// instance (the delegate serves the new defs). Registry miss: late-attach
// via darwin_toolbar_attach (style honored), then schedule this path's own
// metrics injection — window.m's construction-time injection already ran
// (toolbar-less) and stays unchanged.
void darwin_toolbar_set_items(void* window_ptr, const char* toolbar_json, int32_t host_slot) {
    if (!window_ptr || !toolbar_json || !toolbar_json[0]) return;
    NSString* json = [NSString stringWithUTF8String:toolbar_json];
    NSWindow* window = (__bridge NSWindow*)window_ptr;
    zapp_toolbar_on_main(^{
        NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSError* err = nil;
        NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![root isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[zapp] toolbar: invalid toolbarJson (%@) — setItems ignored",
                  err ? err.localizedDescription : @"not an object");
            return;
        }
        NSValue* key = [NSValue valueWithPointer:(__bridge void*)window];
        ZappToolbarController* c = zapp_toolbars ? zapp_toolbars[key] : nil;
        if (!c) {
            // Late attach. Style in the json is honored here (fresh attach).
            darwin_toolbar_attach((__bridge void*)window, [json UTF8String], host_slot);
            if (!zapp_toolbars || !zapp_toolbars[key]) return; // attach rejected (no items)
            // One tick so AppKit lays the band out before measuring;
            // add_user_script=true so reloads keep the value (attach parity).
            dispatch_async(dispatch_get_main_queue(), ^{
                zapp_toolbar_inject_metrics((__bridge void*)window, host_slot, true);
            });
            return;
        }
        if (root[@"style"]) {
            NSLog(@"[zapp] toolbar: style can only be set when attaching — ignored (toolbar already present)");
        }
        NSArray* items = [root[@"items"] isKindOfClass:[NSArray class]] ? root[@"items"] : @[];
        NSMutableDictionary<NSString*, NSDictionary*>* buttons = [NSMutableDictionary dictionary];
        NSArray<NSToolbarItemIdentifier>* ids = zapp_toolbar_parse_items(items, buttons);
        if (ids.count == 0) {
            NSLog(@"[zapp] toolbar: setItems with no items — use toolbar.remove() to destroy the toolbar");
            return;
        }
        NSToolbar* tb = window.toolbar;
        if (!tb) return; // registered but no toolbar — shouldn't happen; bail
        // New defs BEFORE reconcile — insertItemWithItemIdentifier: consults
        // the delegate (allowed list + item construction) synchronously.
        c.identifiers = ids;
        c.buttonsById = buttons;
        while (tb.items.count > 0) [tb removeItemAtIndex:0];
        for (NSToolbarItemIdentifier ident in ids) {
            // Append-at-count, NOT at the loop index: when the delegate
            // returns nil for an identifier (trackingSeparator without a
            // split view, pre-10.15 fallthrough) AppKit skips the insert
            // and an indexed loop would drift out of range and throw.
            [tb insertItemWithItemIdentifier:ident atIndex:(NSInteger)tb.items.count];
        }
        // The contentLayoutRect KVO catches band-height changes; this covers
        // the same-height case cheaply (no-op-skip cache absorbs it).
        zapp_toolbar_inject_metrics((__bridge void*)window, host_slot, false);
    });
}

// Patch one item in place. item_json = {"id", ...only patched keys}.
// Merges into the stored def first (future delegate rebuilds must agree),
// then mutates the live NSToolbarItem. A shape change (menu added to a
// plain button, or removed) rebuilds that one item at its index instead —
// NSToolbarItem and NSMenuToolbarItem can't convert in place.
void darwin_toolbar_update_item(void* window_ptr, const char* item_json) {
    if (!window_ptr || !item_json || !item_json[0]) return;
    NSString* json = [NSString stringWithUTF8String:item_json];
    NSWindow* window = (__bridge NSWindow*)window_ptr;
    zapp_toolbar_on_main(^{
        NSValue* key = [NSValue valueWithPointer:(__bridge void*)window];
        ZappToolbarController* c = zapp_toolbars ? zapp_toolbars[key] : nil;
        if (!c || !window.toolbar) {
            NSLog(@"[zapp] toolbar: updateItem on a window without a toolbar — ignored");
            return;
        }
        NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* patch = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![patch isKindOfClass:[NSDictionary class]]) return;
        NSString* itemId = [patch[@"id"] isKindOfClass:[NSString class]] ? patch[@"id"] : nil;
        if (!itemId.length) return;
        NSDictionary* def = c.buttonsById[itemId];
        if (!def) {
            NSLog(@"[zapp] toolbar: updateItem unknown id \"%@\" — ignored", itemId);
            return;
        }

        // Merge patched keys into the stored def (source of truth for the
        // delegate and validateToolbarItem:).
        NSMutableDictionary* merged = [def mutableCopy];
        for (NSString* k in patch) {
            if (![k isEqualToString:@"id"]) merged[k] = patch[k];
        }
        NSMutableDictionary<NSString*, NSDictionary*>* buttons = [c.buttonsById mutableCopy];
        buttons[itemId] = merged;
        c.buttonsById = buttons;

        // Find the live item.
        NSToolbarItem* live = nil;
        NSInteger idx = -1;
        NSArray<NSToolbarItem*>* arr = window.toolbar.items;
        for (NSInteger i = 0; i < (NSInteger)arr.count; i++) {
            if ([arr[(NSUInteger)i].itemIdentifier isEqualToString:itemId]) {
                live = arr[(NSUInteger)i];
                idx = i;
                break;
            }
        }
        if (!live) return; // def updated; nothing displayed to mutate

        BOOL wantsMenu = [merged[@"menu"] isKindOfClass:[NSArray class]] && ((NSArray*)merged[@"menu"]).count > 0;
        BOOL isMenuItem = NO;
        if (@available(macOS 10.15, *)) isMenuItem = [live isKindOfClass:[NSMenuToolbarItem class]];
        if (wantsMenu != isMenuItem) {
            // Shape change: rebuild this one item — the delegate serves the
            // merged def (becomes/stops being an NSMenuToolbarItem).
            [window.toolbar removeItemAtIndex:idx];
            [window.toolbar insertItemWithItemIdentifier:itemId atIndex:idx];
            return;
        }

        if ([patch[@"label"] isKindOfClass:[NSString class]]) {
            NSString* label = patch[@"label"];
            live.label = label;
            live.paletteLabel = label.length ? label : itemId;
            live.toolTip = label;
        }
        // Label item text update: patch the hosted NSTextField's stringValue.
        if ([patch[@"text"] isKindOfClass:[NSString class]]) {
            NSString* newText = patch[@"text"];
            if ([live.view isKindOfClass:[NSTextField class]]) {
                NSTextField* tf = (NSTextField*)live.view;
                tf.stringValue = newText;
                [tf sizeToFit];
                live.label = newText;
                live.paletteLabel = newText.length ? newText : itemId;
                NSSize fit = tf.fittingSize;
                live.minSize = fit;
                live.maxSize = fit;
            }
        }
        if ([patch[@"icon"] isKindOfClass:[NSString class]] && ((NSString*)patch[@"icon"]).length) {
            live.image = zapp_resolve_icon(patch[@"icon"], 18.0, 1);
        }
        if (@available(macOS 10.15, *)) {
            if (isMenuItem) {
                NSMenuToolbarItem* mlive = (NSMenuToolbarItem*)live;
                if ([patch[@"menu"] isKindOfClass:[NSArray class]]) {
                    // Fresh NSMenu — the flicker-free checkmark refresh.
                    NSData* mdata = [NSJSONSerialization dataWithJSONObject:patch[@"menu"] options:0 error:nil];
                    NSString* mjson = mdata ? [[NSString alloc] initWithData:mdata encoding:NSUTF8StringEncoding] : nil;
                    NSMenu* menu = mjson ? (__bridge_transfer NSMenu*)darwin_menu_build_from_items_json([mjson UTF8String]) : nil;
                    if (menu) mlive.menu = menu;
                }
                if ([patch[@"indicator"] isKindOfClass:[NSNumber class]]) {
                    mlive.showsIndicator = [patch[@"indicator"] boolValue];
                }
                if ([patch[@"enabled"] isKindOfClass:[NSNumber class]]) {
                    mlive.enabled = [patch[@"enabled"] boolValue]; // autovalidates is NO
                }
            }
        }
        // W2 trio: re-apply from the merged def (covers style/tint/badge/bordered;
        // badge {"kind":"none"} → cleared). Works for both button + menu items.
        if (patch[@"style"] || patch[@"tintColor"] || patch[@"bordered"] || patch[@"badge"]) {
            zapp_toolbar_apply_trio(live, merged);
        }
        // Segmented group: apply live selected + controlRepresentation.
        if (@available(macOS 10.15, *)) {
            if ([live isKindOfClass:[NSToolbarItemGroup class]]) {
                NSToolbarItemGroup* g = (NSToolbarItemGroup*)live;
                if ([patch[@"selected"] isKindOfClass:[NSArray class]]) {
                    for (NSInteger i = 0; i < (NSInteger)g.subitems.count; i++) [g setSelected:NO atIndex:i];
                    for (NSNumber* n in (NSArray*)patch[@"selected"]) { NSInteger i = n.integerValue; if (i >= 0 && i < (NSInteger)g.subitems.count) [g setSelected:YES atIndex:i]; }
                }
                NSString* repr = [patch[@"controlRepresentation"] isKindOfClass:[NSString class]] ? patch[@"controlRepresentation"] : nil;
                if (repr) g.controlRepresentation = [repr isEqualToString:@"expanded"] ? NSToolbarItemGroupControlRepresentationExpanded
                    : ([repr isEqualToString:@"collapsed"] ? NSToolbarItemGroupControlRepresentationCollapsed : NSToolbarItemGroupControlRepresentationAutomatic);
            }
        }
        // Action buttons: enabled lives in the merged def; force a
        // validation pass so it applies now, not on the next idle.
        [window.toolbar validateVisibleItems];
    });
}

// Destroy the toolbar. ORDER IS LOAD-BEARING:
//  1. remove the contentLayoutRect KVO observer — the controller is about
//     to lose its only strong ref (the registry), and the coalesced KVO
//     block holds it weakly: it would silently skip the final re-inject;
//  2. detach the NSToolbar;
//  3. one tick later, re-measure capturing the WINDOW + SLOT (not the
//     controller) — titlebar height shrinks back, toolbar-height → 0px;
//  4. drop the registry entry (controller deallocates).
// No-op when not registered.
void darwin_toolbar_remove(void* window_ptr) {
    if (!window_ptr) return;
    NSWindow* window = (__bridge NSWindow*)window_ptr;
    zapp_toolbar_on_main(^{
        NSValue* key = [NSValue valueWithPointer:(__bridge void*)window];
        ZappToolbarController* c = zapp_toolbars ? zapp_toolbars[key] : nil;
        if (!c) return;
        int32_t slot = c.windowNumericId;
        @try {
            [window removeObserver:c forKeyPath:@"contentLayoutRect"];
        } @catch (NSException* e) {
            (void)e; // not registered — harmless
        }
        window.toolbar = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Registry entry is gone by now → the no-op-skip cache is
            // bypassed and inject runs unconditionally (block captures the
            // window strongly through the tick).
            zapp_toolbar_inject_metrics((__bridge void*)window, slot, false);
        });
        [zapp_toolbars removeObjectForKey:key];
    });
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
    // No NSToolbarView found: with a live toolbar that's the class-name-walk
    // fallback (treat the full band as the row, == unified behavior); with no
    // toolbar (post-remove re-inject) the row is genuinely gone — 0px.
    if (toolbarH <= 0) toolbarH = window.toolbar ? totalInset : 0;

    // Read the HOST content webview's safe-area insets so Extend-mode content
    // can avoid the overlap region (sidebar sits over the content webview).
    WKWebView* hostWv = zapp_webview_for_slot(host_slot);
    NSEdgeInsets sa = hostWv ? hostWv.safeAreaInsets : NSEdgeInsetsZero;

    // Approximate window corner radius for Tahoe (macOS 26+). The exact radius
    // isn't cleanly exposed by AppKit; 12pt is a close approximation used here
    // so apps can inset content away from the rounded corners. Not exact.
    CGFloat corner = 0.0;
    if (@available(macOS 26.0, *)) corner = 12.0;

    // Skip no-op re-injections (the KVO also fires during plain window
    // resizes, where the chrome height doesn't change). Initial injection
    // (add_user_script) always runs. Safe-area-left is included because
    // sidebar collapse/resize changes it independently of titlebar/toolbar.
    ZappToolbarController* c = zapp_toolbars[[NSValue valueWithPointer:window_ptr]];
    if (!add_user_script && c &&
        c.lastInjectedInset == totalInset && c.lastInjectedToolbarH == toolbarH &&
        c.lastInjectedSafeLeft == sa.left) {
        return;
    }
    if (c) {
        c.lastInjectedInset = totalInset;
        c.lastInjectedToolbarH = toolbarH;
        c.lastInjectedSafeLeft = sa.left;
    }

    NSString* js = [NSString stringWithFormat:
        @"(function(){try{var r=document.documentElement;"
        @"if(r){r.style.setProperty('--zapp-titlebar-height','%.0fpx');"
        @"r.style.setProperty('--zapp-toolbar-height','%.0fpx');}}catch(e){}})();",
        totalInset, toolbarH];

    int32_t slots[3] = { host_slot, zapp_sidebar_slot_lookup(host_slot), zapp_inspector_slot_lookup(host_slot) };
    for (int i = 0; i < 3; i++) {
        if (slots[i] < 0) continue;
        WKWebView* wv = zapp_webview_for_slot(slots[i]);
        if (wv) {
            if (add_user_script) {
                [wv.configuration.userContentController addUserScript:
                    [[WKUserScript alloc] initWithSource:js
                        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
            }
            [wv evaluateJavaScript:js completionHandler:nil];
        }
#ifdef ZAPP_HAS_CEF
        else {
            // CEF pane: no WKWebView. Route through the CEF-aware per-slot eval
            // (darwin_window_eval_js's ZAPP_HAS_CEF branch reaches the CEF browser
            // at this slot). No WKUserScript equivalent on CEF, and the CEF client
            // (zapp_cef_client.c) wires no load-handler yet, so a manual page
            // reload on a CEF pane does NOT re-apply these vars immediately —
            // known limitation; they re-apply on the next KVO-driven layout
            // change (toolbar display-mode switch, window resize crossing a
            // chrome-height boundary, etc). Revisit once a load-end hook lands.
            extern void darwin_window_eval_js(int32_t window_id, const char* js);
            darwin_window_eval_js(slots[i], [js UTF8String]);
        }
#endif
    }

    // Inject safe-area + corner vars into the HOST webview only. In Extend
    // mode the content view extends under the floating sidebar; these vars let
    // the app keep foreground content clear of the overlap + rounded corners.
    NSString* saJs = [NSString stringWithFormat:
        @"(function(){try{var r=document.documentElement;if(r){"
        @"r.style.setProperty('--zapp-safe-area-top','%.0fpx');"
        @"r.style.setProperty('--zapp-safe-area-left','%.0fpx');"
        @"r.style.setProperty('--zapp-safe-area-right','%.0fpx');"
        @"r.style.setProperty('--zapp-safe-area-bottom','%.0fpx');"
        @"r.style.setProperty('--zapp-corner-inset','%.0fpx');}}catch(e){}})();",
        sa.top, sa.left, sa.right, sa.bottom, corner];
    if (hostWv) {
        if (add_user_script) {
            [hostWv.configuration.userContentController addUserScript:
                [[WKUserScript alloc] initWithSource:saJs
                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
        }
        [hostWv evaluateJavaScript:saJs completionHandler:nil];
    }
#ifdef ZAPP_HAS_CEF
    else {
        // CEF host pane: same CEF-aware per-slot eval fallback as the main
        // loop above, keyed by host_slot (the host webview's numeric slot).
        extern void darwin_window_eval_js(int32_t window_id, const char* js);
        darwin_window_eval_js(host_slot, [saJs UTF8String]);
    }
#endif
}

#ifdef ZAPP_HAS_CEF
// Re-inject toolbar chrome-metrics for the window owning `slot`. Called from
// on_after_created (CEF client) once a pane browser is ready, because the
// INITIAL inject (window.m, one tick after the pane-create REQUESTS) races
// the async cef_browser_host_create_browser — the host browser is registered
// by then but the sidebar/inspector browsers register LATER, so their eval is
// silently dropped (empty slot). This re-fires per pane the moment it exists.
// Compiled out on a `system` build → toolbar.m stays byte-identical there.
void zapp_toolbar_reinject_for_slot(int32_t slot) {
    extern void* darwin_window_get_by_numeric_id(int32_t);
    void (^work)(void) = ^{
        void* winPtr = darwin_window_get_by_numeric_id(slot);   // C1 resolver: pane slot → host NSWindow
        if (!winPtr) return;
        ZappToolbarController* c = zapp_toolbars[[NSValue valueWithPointer:winPtr]];
        if (!c) return;                                          // window has no toolbar → nothing to do
        zapp_toolbar_inject_metrics(winPtr, c.windowNumericId, false);  // host_slot = c.windowNumericId
    };
    if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
}
#endif

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
