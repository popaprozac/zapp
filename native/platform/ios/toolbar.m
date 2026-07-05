// iOS native toolbar — UINavigationBar implementation.
//
// Fills the content column's UINavigationItem from the cross-platform
// placement wire JSON (the same shape darwin/toolbar.m parses on macOS).
// Mirrors darwin/toolbar.m adapted to UIKit:
//   NSToolbarItem      → UIBarButtonItem
//   NSImage            → UIImage
//   NSToolbar          → UINavigationBar (via contentVC.navigationItem)
//
// T1 scope (CORE item types only):
//   button, space, flexibleSpace, label, toggleSidebar, toggleInspector.
//   trackingSeparator dropped on iOS.
//
// T2 scope (BREADTH):
//   segmented → UISegmentedControl wrapped in UIBarButtonItem(customView:)
//   group     → flattened sub-buttons into same placement bucket
//   button.menu → UIMenu set on barButtonItem.menu (iOS 14+)
//   darwin_toolbar_update_item → live patch (label/icon/enabled/selected)
//   darwin_toolbar_remove      → hide bar + clear items + drop registry
//
// T1.5 collapse-aware delivery:
//   On iPhone the split collapses to a single column (collapsedNav). T1's
//   set_items un-hid contentNav, but collapsedNav (not contentNav) is on
//   screen while collapsed → bar stayed hidden at launch.
//   Fix (T2): darwin_toolbar_set_items and zapp_ios_toolbar_apply_for_window target
//   the nav that is actually displayed: collapsedNav when the split is collapsed,
//   contentNav when expanded. Bar-HIDDEN visibility (#782 foundation) is owned
//   per-VC by viewWillAppear — ZappIOSPaneViewController (window.m) for
//   content/sidebar, ZappRouteVC (routing.m) for routes — which fires on
//   every appearance including the split-VC column un-nest that
//   ZappRouteNavDelegate's willShowViewController: does not see.
//   ZappRouteNavDelegate (routing.m) owns toolbar ITEMS, the pop gesture, and
//   route-depth reconciliation, evaluating the SAME shared want-state rule
//   to gate its item stamp — but it is no longer the visibility writer;
//   construction-time primers and the attach/remove primers below are
//   direct corrective writes for states UIKit will not transition into on
//   its own (see each primer's own comment for why).
//   iPad de-dup: when the split is expanded/regular, UIKit auto-provides a
//   system sidebar button in the nav bar; we omit our manual toggleSidebar item
//   to avoid a duplicate. When collapsed/compact, no system button exists so we
//   include ours.
//
// Click delivery: button taps emit `window:toolbar-clicked`
//   {"windowId":"win-<n>","id":"<itemId>"} to the HOST content webview plus
//   its sidebar/inspector PANE webviews only (zapp_ios_toolbar_eval_js_host_panes,
//   the #627 pane-fan-out shape) — NOT zapp_ios_eval_js_all_webviews. #771
//   G1-E: route-webview transport slots (added in cff1324) joined the
//   all-webviews broadcast table, so a toolbar click at push-depth N fired
//   its handler once per live route webview (N+1x), multi-popping the
//   router. Toolbar/group/menu clicks are window-scoped chrome events —
//   route webviews never received them before cff1324 either, so this
//   restores the original delivery set rather than inventing new behavior.
//   Route-webview click targeting is deliberate future work (per-route
//   toolbar), not a side effect of this fix.
//
// Per-window registry: keyed by window_ptr (NSValue), stores the
// set of built UIBarButtonItems so zapp_toolbar_unregister can clear,
// PLUS the built leading/trailing/center buckets so re-apply on
// collapse/expand can rebuild the nav-item assignment without a
// fresh set_items call from the app.
//
// Main-thread contract: all UIKit mutations are dispatched to the main
// queue. zapp_toolbar_inject_metrics is declared as main-thread-only
// (matching the macOS assertion).

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <stdbool.h>
#include <objc/runtime.h>

// Associated-object keys: use static addresses, not C string literals.
// The address of these variables is the unique key — the value stored at the
// address is irrelevant; 0 is conventional.
static const char kZappToolbarButtonTargetKey = 0;
static const char kZappToolbarToggleTargetKey = 0;
// R2' (#771 T8) per-VC route chrome, set by zapp_ios_toolbar_set_vc_chrome:
//   kZappRouteToolbarEntryKey → ZappIOSToolbarEntry* toolbar OVERRIDE for the
//     route VC (replaces the window entry wholesale at stamp time; nil = fall
//     back to the window defs).
//   kZappRouteTitleKey → NSString* route title (wins over entry.centerTitle).
static const char kZappRouteToolbarEntryKey = 0;
static const char kZappRouteTitleKey = 0;

extern WKWebView* zapp_ios_content_webview_for_slot(int32_t slot);
extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_sidebar_toggle(int32_t window_id);
extern void darwin_inspector_toggle(int32_t window_id);

// Defined in ios/sidebar.m — returns the content UINavigationController
// (contentNav) for the window. Nil for no-sidebar windows → set_items no-ops.
extern UINavigationController* zapp_ios_content_nav_for_window(void* window_ptr);

// Defined in ios/sidebar.m — returns the authoritative content UIViewController
// stored at registration time. Nil for no-sidebar/unregistered windows.
// Used in the collapsed path instead of contentNav.topViewController (UIKit may
// orphan contentNav when building the combined collapsed stack).
extern UIViewController* zapp_ios_content_vc_for_window(void* window_ptr);

// Returns the combined collapsed nav controller (collapsedNav) captured by
// splitViewControllerDidCollapse:. Nil when not yet collapsed or no sidebar.
extern UINavigationController* zapp_ios_collapsed_nav_for_window(void* window_ptr);

// Returns YES when the split is currently collapsed to a single column
// (c.splitVC.isCollapsed). NO when expanded (side-by-side) or no sidebar.
extern BOOL zapp_ios_split_is_collapsed_for_window(void* window_ptr);

// Defined in ios/routing.m — single source of truth for "does this VC want
// its nav bar visible" (the same rule ZappRouteNavDelegate's willShow/didShow
// use to drive bar visibility on every push/pop). #771 T7 sub-gate: the
// setItems attach primer below consults this instead of an unconditional
// show, so a covering ZappRouteVC with navbarHidden:true keeps its hidden bar
// (kills the chrome-less-route flash) rather than getting force-shown just
// because a toolbar was (re-)registered.
extern BOOL zapp_route_bar_should_show(void* win, UIViewController* vc,
                                       UIViewController* contentVC);

// Returns YES when the sidebar is HIDDEN on iPad (displayMode == SecondaryOnly).
// Returns NO for collapsed (iPhone), no sidebar, or sidebar visible.
// Used by the expanded toolbar path to decide whether to include our manual
// toggleSidebar button: include when sidebar is visible (UIKit adds none);
// omit when hidden (UIKit's own system button is the affordance).
extern BOOL zapp_ios_sidebar_is_hidden_for_window(void* window_ptr);

// Live read of the split's CURRENT displayMode — NOT a transition target.
// Returns true only when displayMode == SecondaryOnly (sidebar hidden); false
// when collapsed, unregistered, or no split. Defined in ios/sidebar.m. Used
// by zapp_ios_toolbar_stamp_vc's include-toggle decision (live at stamp time
// — willShow/didShow re-stamps always run at settled moments). #771 G1-F:
// zapp_ios_toolbar_apply_for_window_hidden's expanded path no longer reads
// this — it trusts its `sidebarHidden` parameter per the caller contract
// documented at its definition (live truth at settled call sites, the
// transition TARGET inside willChangeToDisplayMode: so the toggle swap rides
// the display-mode animation transaction).
extern bool zapp_ios_split_display_mode_is_secondary_only(void* window_ptr);

// E2 (collapsible affordance parity): live read of the sidebar's collapsible
// flag at apply time — drives the ENABLED state of our manual toggleSidebar
// button. Sibling of the inclusion read above: inclusion decides whether the
// button is IN the bar (de-dup against UIKit's system reveal button);
// collapsible decides whether it is INTERACTIVE. macOS greys its system
// toggle via AppKit validation against NSSplitViewItem.canCollapse; UIKit has
// no validation pass, so the apply paths set `enabled` manually. Returns true
// (enabled) when no sidebar is registered. Defined in ios/sidebar.m.
extern bool zapp_ios_sidebar_is_collapsible_for_window(void* window_ptr);

// #779 (inspector collapsible affordance parity): live read of the
// inspector's collapsible flag at apply time — drives the ENABLED state of
// our manual toggleInspector button. Sibling of
// zapp_ios_sidebar_is_collapsible_for_window above, same shape: macOS greys
// its system toggleInspector toolbar item via AppKit validation against
// NSSplitViewItem.canCollapse (darwin/inspector.m); UIKit has no validation
// pass, so the apply paths set `enabled` manually. Returns true (enabled)
// when no inspector is registered. Defined in ios/inspector.m.
extern bool zapp_ios_inspector_is_collapsible_for_window(void* window_ptr);

// Defined in ios/window.m — slot lookup tables for sidebar + inspector panes.
// Return -1 when no pane of that type is registered for the host.
extern int32_t zapp_ios_sidebar_slot_for(int32_t host_slot);
extern int32_t zapp_ios_inspector_slot_for(int32_t host_slot);
// Defined in ios/window.m — the shared host+sidebar+inspector eval-JS
// primitive (also used by zapp_dispatch_event_to_js there). #771 G1-E review
// Minor 1: hoisted here so this file's toolbar/click/menu fan-out and
// window.m's window-event fan-out can never drift apart again.
extern void zapp_ios_eval_js_host_panes(int32_t host_id, NSString* js);

// ─── Icon resolver ──────────────────────────────────────────────────────────
//
// Parallel to macOS zapp_resolve_icon / menu.m's icon resolution.
//   nil / empty  → nil
//   "sf:NAME"    → [UIImage systemImageNamed:NAME]
//   "data:…"     → base64-decoded UIImage
//   else          → [UIImage imageWithContentsOfFile:]

static UIImage* zapp_ios_resolve_icon(NSString* spec) {
    if (![spec isKindOfClass:[NSString class]] || spec.length == 0) return nil;
    if ([spec hasPrefix:@"sf:"]) {
        NSString* name = [spec substringFromIndex:3];
        return [UIImage systemImageNamed:name];
    }
    if ([spec hasPrefix:@"data:"]) {
        // Find the base64 payload after the comma.
        NSRange comma = [spec rangeOfString:@","];
        if (comma.location != NSNotFound) {
            NSString* b64 = [spec substringFromIndex:comma.location + 1];
            NSData* data = [[NSData alloc] initWithBase64EncodedString:b64
                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (data) return [UIImage imageWithData:data];
        }
        return nil;
    }
    return [UIImage imageWithContentsOfFile:spec];
}

// ─── Per-window toolbar registry ────────────────────────────────────────────
//
// Stores the metadata needed to support unregister and future update_item:
//   - the host_slot (for inject_metrics and toggle actions)
//   - the built UIBarButtonItem list (for clearing on unregister)
//
// Keyed by NSValue-wrapped window_ptr (mirrors darwin/toolbar.m's
// zapp_toolbars and ios/sidebar.m's zapp_ios_sidebars).

@interface ZappIOSToolbarEntry : NSObject
@property (nonatomic, assign) int32_t hostSlot;        // numeric window id (content slot)
@property (nonatomic, strong) NSArray* allItems;        // all UIBarButtonItems built
// Tracks whether the persistent WKUserScript for --zapp-toolbar-height has been
// added. WKUserContentController has no per-script removal, so repeated
// set_items calls must add the user script only on the first call, then rely on
// evaluateJavaScript for live updates thereafter.
@property (nonatomic, assign) BOOL hasUserScript;
// Built navigation-item buckets — stored so zapp_ios_toolbar_apply_for_window
// can re-assign them to whichever nav is on-screen after a collapse/expand
// without the app needing to re-call setItems.
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* leadingItems;  // all leading (incl. toggleSidebar)
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* leadingNoToggle; // leading WITHOUT toggleSidebar
// E2: Zapp's manual toggleSidebar bar button (lives inside leadingItems, absent
// from leadingNoToggle). Stored so the apply paths can set its enabled state
// from the live collapsible read (zapp_ios_sidebar_is_collapsible_for_window)
// without rebuilding items. nil when the toolbar JSON has no toggleSidebar item.
@property (nonatomic, strong) UIBarButtonItem* toggleSidebarButton;
// #779: Zapp's manual toggleInspector bar button (lives wherever its
// `placement` puts it — leading or trailing; unlike toggleSidebar it has no
// dedicated leadingNoToggle exclusion, since iOS has no system inspector-
// reveal button to de-dup against). Stored so the apply paths can set its
// enabled state from the live collapsible read
// (zapp_ios_inspector_is_collapsible_for_window) without rebuilding items.
// nil when the toolbar JSON has no toggleInspector item.
@property (nonatomic, strong) UIBarButtonItem* toggleInspectorButton;
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* trailingItems;
@property (nonatomic, strong) NSString* centerTitle;   // nil if none
@property (nonatomic, strong) UIView*   centerView;    // nil if none
// #782 T4a: pane-tagged item buckets. Items with `pane:"sidebar"`/
// `"inspector"` are segregated OUT of the content buckets above (by
// zapp_ios_toolbar_populate_entry) into these — one leading/trailing pair per
// pane, no toggle-exclusion variant (toggleSidebar/toggleInspector items are
// content-only, never pane-tagged). Consumed by zapp_ios_toolbar_stamp_pane /
// zapp_ios_toolbar_has_pane_items below.
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* sidebarLeading;
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* sidebarTrailing;
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* inspectorLeading;
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* inspectorTrailing;
// window_ptr — stored for the apply_for_window lookup on collapse/expand.
@property (nonatomic, assign) void* windowPtr;
// T2: id-keyed dicts for update_item.
// itemsById: maps item-id → UIBarButtonItem (buttons, group sub-buttons, segmented wrapper).
// segmentedById: maps segmented-id → UISegmentedControl (for selected / enabled patch).
@property (nonatomic, strong) NSMutableDictionary<NSString*, UIBarButtonItem*>* itemsById;
@property (nonatomic, strong) NSMutableDictionary<NSString*, UISegmentedControl*>* segmentedById;
@end

@implementation ZappIOSToolbarEntry
@end

static NSMutableDictionary<NSValue*, ZappIOSToolbarEntry*>* zapp_ios_toolbars = nil;

// #771 G1 fix B: registration query for routing.m's willShow visibility rule
// (showBar = (isContent && toolbarRegistered) || (isRoute && !navbarHidden)).
// The entry registry is the single source of truth for "does this window
// currently have a toolbar": set_items creates the entry, remove() drops it —
// so after a remove(), every later nav transition keeps the content VC's bar
// hidden instead of re-showing an empty bar. Main-thread-only, like the rest
// of this file's UIKit-driven state — zapp_ios_toolbars is an unsynchronized
// NSMutableDictionary, and both callers (routing.m's willShow/didShow) run on
// the main thread via UIKit's delegate callbacks. Not safe to call off it.
bool zapp_ios_toolbar_registered_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_toolbars) return false;
    return zapp_ios_toolbars[[NSValue valueWithPointer:window_ptr]] != nil;
}

// Forward declaration — defined later.
void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script);

// ─── Window-scoped chrome-event fan-out ─────────────────────────────────────
//
// #771 G1-E: delivers `js` to the HOST content webview plus its sidebar/
// inspector PANE webviews only — same 3-target reach as the #627 pane
// fan-out (zapp_dispatch_event_to_js, window.m). Thin wrapper over the
// shared zapp_ios_eval_js_host_panes primitive (window.m; review G1-E
// Minor 1 hoist) because this file's payload shape (dynamically-built
// `_onEvent(<name>, <json>)` strings — window:toolbar-clicked,
// window:toolbar-group-selected, __menu:click) differs from
// zapp_dispatch_event_to_js's fixed window-event-id table +
// bridge.dispatchWindowEvent, so the two keep separate entry points even
// though they now share one targeting loop. Deliberately excludes route-
// webview transport slots — the #771 G1-C/D regression source — restoring
// the pre-cff1324 delivery set for these window-scoped UI events.
// Must be called on the main thread (matches zapp_dispatch_event_to_js).
static void zapp_ios_toolbar_eval_js_host_panes(int32_t host_id, NSString* js) {
    zapp_ios_eval_js_host_panes(host_id, js);
}

// ─── Click emit ─────────────────────────────────────────────────────────────
//
// Mirrors zapp_toolbar_emit_click in darwin/toolbar.m.
// Builds {"windowId":"win-<N>","id":"<itemId>"} and delivers via
// zapp_ios_toolbar_eval_js_host_panes (host + sidebar + inspector panes;
// see #771 G1-E above — darwin/toolbar.m's macOS equivalent still
// broadcasts to all webviews + workers, which is correct there since
// macOS has no route-webview transport slots to over-deliver into).
// SAFETY: escaping runs synchronously; the captured NSString is ARC-retained
// before the dispatch_async so the pointer never escapes onto the async block.

static void zapp_ios_toolbar_emit_click(int32_t host_id, NSString* itemId) {
    if (!itemId.length) return;
    // Same trio as darwin/toolbar.m's zapp_toolbar_emit_click.
    NSString* escaped = [itemId stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('window:toolbar-clicked',"
            "'{\"windowId\":\"win-%d\",\"id\":\"%@\"}');})();",
            host_id, escaped];
        zapp_ios_toolbar_eval_js_host_panes(host_id, js);
    });
}

// ─── ZappIOSToolbarButtonTarget ──────────────────────────────────────────────
//
// Lightweight ObjC target object for UIBarButtonItem actions. Retaining the
// target avoids the need for associated-object tricks. Each button item
// holds a strong ref via UIBarButtonItem.target.

@interface ZappIOSToolbarButtonTarget : NSObject
@property (nonatomic, assign) int32_t hostId;
@property (nonatomic, copy)   NSString* itemId;
@end

@implementation ZappIOSToolbarButtonTarget

- (void)buttonTapped:(UIBarButtonItem*)sender {
    (void)sender;
    zapp_ios_toolbar_emit_click(self.hostId, self.itemId);
}

@end

// ─── ZappIOSToolbarToggleTarget ──────────────────────────────────────────────
//
// Target for toggleSidebar / toggleInspector bar button items.
// Calls darwin_sidebar_toggle / darwin_inspector_toggle with the
// host window id (not a slot lookup — passed directly as the numeric id).

@interface ZappIOSToolbarToggleTarget : NSObject
@property (nonatomic, assign) int32_t windowId;
@property (nonatomic, assign) BOOL isSidebar; // YES=sidebar, NO=inspector
@end

@implementation ZappIOSToolbarToggleTarget

- (void)toggleTapped:(UIBarButtonItem*)sender {
    (void)sender;
    if (self.isSidebar) darwin_sidebar_toggle(self.windowId);
    else                darwin_inspector_toggle(self.windowId);
}

@end

// ─── ZappIOSToolbarSegmentTarget ─────────────────────────────────────────────
//
// T2: UISegmentedControl target for valueChanged.
// Emits window:toolbar-group-selected mirroring darwin/toolbar.m's
// zapp_toolbar_emit_group_select payload:
//   {"windowId":"win-<N>","id":"<groupId>","index":<N>,"selected":<bool>}
// selectionMode stored so we can report `selected` accurately:
//   one/any → selectedSegmentIndex is meaningful; report true
//   momentary → segment doesn't stay down; report true (just tapped)

static const char kZappToolbarSegmentTargetKey = 0;

@interface ZappIOSToolbarSegmentTarget : NSObject
@property (nonatomic, assign) int32_t hostId;
@property (nonatomic, copy)   NSString* groupId;
@property (nonatomic, copy)   NSString* selectionMode; // "one", "any", "momentary"
@end

@implementation ZappIOSToolbarSegmentTarget

- (void)segmentChanged:(UISegmentedControl*)sender {
    NSInteger idx = sender.selectedSegmentIndex;
    if (idx == UISegmentedControlNoSegment) return;
    // Emit group-selected — mirrors darwin/toolbar.m's zapp_toolbar_emit_group_select.
    NSString* gid = self.groupId;
    if (!gid.length) return;
    NSString* escaped = [gid stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    int32_t hid = self.hostId;
    int32_t idxInt = (int32_t)idx;
    dispatch_async(dispatch_get_main_queue(), ^{
        // `selected` is always true on iOS — the segment that fired the change
        // event is the one just selected (momentary or persistent).
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('window:toolbar-group-selected',"
            "'{\"windowId\":\"win-%d\",\"id\":\"%@\",\"index\":%d,\"selected\":true}');})();",
            hid, escaped, idxInt];
        // #771 G1-E: window-scoped host+panes fan-out (see above) instead of
        // zapp_ios_eval_js_all_webviews — same regression class as toolbar clicks.
        zapp_ios_toolbar_eval_js_host_panes(hid, js);
    });
}

@end

// ─── Main-thread helper ──────────────────────────────────────────────────────

static void zapp_ios_toolbar_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// ─── zapp_ios_toolbar_apply_for_window (forward declarations) ──────────────
//
// Called from sidebar.m on collapse/expand transitions so a set toolbar
// survives the nav-controller switch. Must be declared here before sidebar.m
// extern-declares it below.
//
// The _hidden variant accepts an explicit sidebarHidden state (the transition
// TARGET) so willChangeToDisplayMode: can drive the toggle decision
// synchronously without reading the stale splitVC.displayMode.

void zapp_ios_toolbar_apply_for_window(void* window_ptr);
void zapp_ios_toolbar_apply_for_window_hidden(void* window_ptr, BOOL sidebarHidden);

// ─── T2: UIMenu builder ──────────────────────────────────────────────────────
//
// Builds a UIMenu from the stripped MenuItemDef array (actions removed by the
// runtime; ids present). Taps emit __menu:click {"id":"<id>"} — mirrors
// darwin/toolbar.m's zapp_toolbar_emit_menu_click, which uses the SAME event
// name/__menu:click because NSMenuToolbarItem clicks route through
// darwin_menu_build_from_items_json and menu.m emits __menu:click.
//
// Recursion: items with a "submenu" array build a nested UIMenu.
// Separator items (type:"separator") build UIAction dividers (iOS 14+: use
// a UIMenuElement that acts as a standalone-display divider by creating an
// empty titled UIMenu as an inline section divider).
// checked / radioGroup: UIAction.state (.on / .off) for checkmarks.
// enabled: UIAction.attributes = .disabled when false.
// iOS 14+ required for UIMenu on UIBarButtonItem; this is the iOS 14+ API.
//
// #771 G1-E: on macOS, zapp_toolbar_emit_menu_click ignores `host_id` and
// broadcasts __menu:click to ALL webviews because __menu:click there has
// several origins (main menu bar, context menu, tray menu, toolbar
// button.menu) that are genuinely window-agnostic. On iOS, ios/menu.m stubs
// out app/context/tray menus entirely (see that file) — this UIMenu builder
// is the ONLY __menu:click origin, and it is always built from one window's
// toolbar button.menu (darwin_toolbar_set_items / darwin_toolbar_update_item
// below, both of which have a host slot in scope). So on iOS __menu:click IS
// a window-scoped chrome event in practice: `host_id` is threaded through
// (unlike macOS) and clicks deliver via zapp_ios_toolbar_eval_js_host_panes
// (host + sidebar + inspector panes), the same fan-out as toolbar clicks —
// avoiding the same route-webview multi-fire class.

API_AVAILABLE(ios(14.0))
static NSArray<UIMenuElement*>* zapp_ios_build_menu_elements(int32_t host_id, NSArray* items);

API_AVAILABLE(ios(14.0))
static NSArray<UIMenuElement*>* zapp_ios_build_menu_elements(int32_t host_id, NSArray* items) {
    if (![items isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<UIMenuElement*>* elements = [NSMutableArray array];
    for (NSDictionary* def in items) {
        if (![def isKindOfClass:[NSDictionary class]]) continue;
        NSString* type = [def[@"type"] isKindOfClass:[NSString class]] ? def[@"type"] : @"normal";

        // Separator → UIMenu inline section (no title, no children) acts as divider.
        if ([type isEqualToString:@"separator"]) {
            UIMenu* sep = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                         options:UIMenuOptionsDisplayInline children:@[]];
            [elements addObject:sep];
            continue;
        }

        NSString* itemId  = [def[@"id"] isKindOfClass:[NSString class]] ? def[@"id"] : @"";
        NSString* label   = [def[@"label"] isKindOfClass:[NSString class]] ? def[@"label"] : @"";
        NSNumber* enabled = [def[@"enabled"] isKindOfClass:[NSNumber class]] ? def[@"enabled"] : nil;
        NSNumber* checked = [def[@"checked"] isKindOfClass:[NSNumber class]] ? def[@"checked"] : nil;
        NSArray*  submenu = [def[@"submenu"] isKindOfClass:[NSArray class]] ? def[@"submenu"] : nil;

        if (submenu.count > 0) {
            // Nested submenu → UIMenu (not a UIAction; iOS shows a disclosure indicator).
            NSArray<UIMenuElement*>* children = zapp_ios_build_menu_elements(host_id, submenu);
            UIMenu* sub = [UIMenu menuWithTitle:label children:children];
            [elements addObject:sub];
            continue;
        }

        // Leaf item → UIAction.
        NSString* capturedId = itemId;
        int32_t capturedHostId = host_id;
        UIAction* action = [UIAction actionWithTitle:label
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction* _Nonnull act) {
            (void)act;
            if (!capturedId.length) return;
            // Emit __menu:click {"id":"<id>"} — mirrors darwin/toolbar.m's
            // zapp_toolbar_emit_menu_click event + payload exactly.
            NSString* esc = [capturedId stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
            esc = [esc stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
            NSString* js = [NSString stringWithFormat:
                @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
                "if(b&&b._onEvent)b._onEvent('__menu:click','{\"id\":\"%@\"}');})();",
                esc];
            // #771 G1-E: window-scoped host+panes fan-out — see builder comment above.
            zapp_ios_toolbar_eval_js_host_panes(capturedHostId, js);
        }];
        // Enabled state.
        if (enabled && !enabled.boolValue) {
            action.attributes = UIMenuElementAttributesDisabled;
        }
        // Checkmark state (maps to UIMenuElementState).
        if (checked && checked.boolValue) {
            action.state = UIMenuElementStateOn;
        } else {
            action.state = UIMenuElementStateOff;
        }
        [elements addObject:action];
    }
    return elements;
}

API_AVAILABLE(ios(14.0))
static UIMenu* zapp_ios_build_uimenu(int32_t host_id, NSArray* items) {
    NSArray<UIMenuElement*>* children = zapp_ios_build_menu_elements(host_id, items);
    return [UIMenu menuWithTitle:@"" children:children];
}

// ─── zapp_ios_toolbar_stamp_items / _force (internal) ────────────────────────
//
// #771 datum 3 (structural): the single place item buckets are written onto a
// navigationItem. Every apply path funnels here so the DISPLAYED VC always
// carries the entry's CURRENT UIBarButtonItem instances — there is no longer a
// "generation" of items left behind on a hidden VC.
//
// #771 G1-F fix round 2: `force` lets a caller bypass the idempotence guard
// below and unconditionally re-run the navigationItem ASSIGNMENTS even when
// the computed arrays/title are pointer-identical to what's already there.
// This exists for exactly one caller (the didShow re-stamp in routing.m):
// during an interactive swipe-back, UIKit reparents shared customView items
// (segmented control, label items, titleView) out of the displayed bar into
// the incoming bar's content view; on a CANCELLED swipe, UIKit discards that
// content view — and the views inside it — without ever rebuilding the
// displayed bar. Only the array/titleView SETTERS force UIKit to rebuild bar
// content, even when the assigned objects are identical to what's already
// held; a guarded (skipped) stamp is a no-op that leaves the custom views
// missing. force=YES restores the pre-guard "always assign" behavior for
// that one recovery path. All other callers keep the guarded behavior.
static void zapp_ios_toolbar_stamp_items_force(UIViewController* vc,
                                               ZappIOSToolbarEntry* entry,
                                               BOOL includeToggleSidebar,
                                               BOOL force) {
    if (!vc) return;
    // R2' (#771 T8): a per-VC toolbar override replaces the window entry
    // WHOLESALE. Resolved here — the single choke point — so every apply
    // path (willShow/didShow stamp_vc, apply_to_nav on collapse/expand,
    // set_items re-apply landing on a route top) is override-aware and can
    // never clobber a route's own items with the window defs. No-op when the
    // caller already resolved the override (stamp_vc_force) — same object.
    ZappIOSToolbarEntry* vcOverride =
        objc_getAssociatedObject(vc, &kZappRouteToolbarEntryKey);
    if (vcOverride) entry = vcOverride;
    if (!entry) return;
    NSArray<UIBarButtonItem*>* leading = includeToggleSidebar
        ? entry.leadingItems
        : entry.leadingNoToggle;
    // #771 G1-F idempotence guard: skip the navigationItem ASSIGNMENTS when
    // the computed arrays / title are content-identical to what the
    // navigationItem already holds. UIBarButtonItem does not override
    // isEqual:, so isEqualToArray: is per-element POINTER equality — "same"
    // means the navigationItem already carries these exact shared instances
    // in this exact order (the T3 displayed-VC model), and re-assigning them
    // can only trigger a spurious UIKit nav-bar relayout (the mid-animation
    // over-slide when the settled re-apply lands inside a display-mode
    // transition). A skipped stamp is by definition a visual no-op; anything
    // different still stamps, so the settled live-read re-apply remains a
    // real correctness backstop for cancelled/diverged transitions (the
    // 30bb802 double-toggle guarantee). set_items rebuilds fresh
    // UIBarButtonItem instances, so a new item set can never be skipped.
    // `force` (fix round 2) bypasses this guard entirely — see header comment.
    NSArray* newLead  = leading ?: @[];
    NSArray* newTrail = entry.trailingItems ?: @[];
    BOOL leadSame  = [(vc.navigationItem.leftBarButtonItems  ?: @[]) isEqualToArray:newLead];
    BOOL trailSame = [(vc.navigationItem.rightBarButtonItems ?: @[]) isEqualToArray:newTrail];
    // R2' (#771 T8): a per-VC route title wins over the entry's center label
    // (and suppresses the entry's titleView — the title owns the center slot).
    // Resolved BEFORE the idempotence guard so titleSame is computed against
    // what this stamp actually wants to display; folding it in afterwards
    // would make every guarded stamp of a titled route churn nil→routeTitle.
    NSString* routeTitle = objc_getAssociatedObject(vc, &kZappRouteTitleKey);
    NSString* wantTitle    = routeTitle.length ? routeTitle : entry.centerTitle;
    UIView*   wantTitleView = routeTitle.length ? nil : entry.centerView;
    NSString* curTitle = vc.navigationItem.title;
    BOOL titleSame = (curTitle == wantTitle) ||
                     (curTitle && wantTitle &&
                      [curTitle isEqualToString:wantTitle]);
    BOOL titleViewSame = (vc.navigationItem.titleView == wantTitleView);
    if (force || !(leadSame && trailSame)) {
        // Keep the system back button when items are stamped onto a pushed VC
        // (a non-nil leftBarButtonItems otherwise suppresses it).
        vc.navigationItem.leftItemsSupplementBackButton = YES;
        vc.navigationItem.leftBarButtonItems  = newLead;
        vc.navigationItem.rightBarButtonItems = newTrail;
    }
    if (force || !titleSame)     vc.navigationItem.title = wantTitle;    // nil clears it
    if (force || !titleViewSame) vc.navigationItem.titleView = wantTitleView; // nil clears it
    // E2 / #779 collapsible→enabled wiring (live read at stamp time). These
    // are property writes on the SHARED UIBarButtonItem instances — they must
    // run even when the assignments above are skipped (a skip means the bar
    // already shows these instances; these writes are how their interactive
    // state stays fresh).
    entry.toggleSidebarButton.enabled =
        zapp_ios_sidebar_is_collapsible_for_window(entry.windowPtr);
    entry.toggleInspectorButton.enabled =
        zapp_ios_inspector_is_collapsible_for_window(entry.windowPtr);
}

// Guarded (default) entry point — force=NO. Kept as the stable call shape for
// every existing caller (zapp_ios_toolbar_apply_to_nav, the collapsed branch
// of zapp_ios_toolbar_apply_for_window_hidden, and the guarded willShow path
// via zapp_ios_toolbar_stamp_vc).
static void zapp_ios_toolbar_stamp_items(UIViewController* vc,
                                         ZappIOSToolbarEntry* entry,
                                         BOOL includeToggleSidebar) {
    zapp_ios_toolbar_stamp_items_force(vc, entry, includeToggleSidebar, NO);
}

// ─── zapp_ios_toolbar_has_pane_items / zapp_ios_toolbar_stamp_pane ───────────
//
// #782 T4a: pane-filtered read + stamp for the sidebar/inspector nav bars.
// The entry's sidebarLeading/sidebarTrailing/inspectorLeading/
// inspectorTrailing buckets are populated by zapp_ios_toolbar_populate_entry
// above from items tagged pane:"sidebar"/"inspector" (segregated OUT of the
// content buckets there — fixes the pre-T4a leak into the content navbar).
//
// has_pane_items is a query only (T4b's config-implied want-state gate for
// the sidebar bar — the inspector bar is already shown unconditionally by
// this task). stamp_pane writes that pane's leading/trailing items + title
// onto a SPECIFIC VC's navigationItem — the pane's own root VC (inspector
// nav's / sidebar nav's viewControllers.firstObject), never the content VC.
//
// Both resolve the entry via a direct dictionary lookup keyed by window_ptr,
// mirroring zapp_ios_toolbar_stamp_vc_force — panes never carry a per-VC
// toolbar OVERRIDE (that R2' mechanism is content-route-only), so there is no
// override to consult here. Main-thread only, like the rest of this file's
// UIKit-driven state.
// Resolves the entry's leading/trailing buckets for a KNOWN pane. Returns NO
// (and leaves the out-params untouched) for an unknown pane string — review
// Minor: an explicit isEqualToString: per pane, so a bogus pane never silently
// reads the inspector buckets.
static BOOL zapp_ios_toolbar_pane_buckets(ZappIOSToolbarEntry* entry, NSString* pane,
                                          NSArray<UIBarButtonItem*>** outLeading,
                                          NSArray<UIBarButtonItem*>** outTrailing) {
    if ([pane isEqualToString:@"sidebar"]) {
        if (outLeading)  *outLeading  = entry.sidebarLeading;
        if (outTrailing) *outTrailing = entry.sidebarTrailing;
        return YES;
    }
    if ([pane isEqualToString:@"inspector"]) {
        if (outLeading)  *outLeading  = entry.inspectorLeading;
        if (outTrailing) *outTrailing = entry.inspectorTrailing;
        return YES;
    }
    return NO;
}

bool zapp_ios_toolbar_has_pane_items(void* window_ptr, NSString* pane) {
    if (!window_ptr || !pane || !zapp_ios_toolbars) return false;
    ZappIOSToolbarEntry* entry = zapp_ios_toolbars[[NSValue valueWithPointer:window_ptr]];
    if (!entry) return false;
    NSArray<UIBarButtonItem*>* lead = nil;
    NSArray<UIBarButtonItem*>* trail = nil;
    if (!zapp_ios_toolbar_pane_buckets(entry, pane, &lead, &trail)) return false;
    return (lead.count + trail.count) > 0;
}

// ─── zapp_ios_sidebar_owns_bar_for_window ────────────────────────────────────
//
// #782 follow-up (iPad-expanded double-toggle): does the sidebar own a visible
// nav bar right now? This is the sidebar's config-implied want-state — the
// sidebar bar is shown iff the sidebar was given a title OR pane-tagged
// ("pane":"sidebar") toolbar items (web-canvas default: no config → no bar).
// Non-static (plain C-ABI) so routing.m's zapp_route_bar_want_state can call
// this SAME predicate for `sidebarHasChrome` (the want-state that actually
// shows/hides the sidebar bar via viewWillAppear) instead of re-inlining the
// same two-accessor OR there — one definition, nothing to keep in lockstep.
//
// Why the CONTENT bar's include-toggle decision needs it: once the sidebar owns
// its own bar, UIKit auto-places the sidebar-collapse toggle in THAT bar
// (top-trailing) whenever the sidebar is visible. Our manual toggleSidebar in
// the content bar would then be a SECOND toggle for the same action. So the
// expanded include-toggle decision omits the manual one whenever the sidebar is
// visible-AND-owns-a-bar. The other expanded states are unchanged:
//   • sidebar HIDDEN → its bar is off-screen and UIKit puts a "show sidebar"
//     reveal button in the CONTENT bar, so the manual one stays omitted there
//     (this fix does not touch the hidden path — it was already omitted);
//   • sidebar VISIBLE but BARLESS (no title, no pane items) → UIKit provides
//     NO system button anywhere, so the manual toggle is the ONLY affordance
//     and must remain (the pre-#782 scenario).
// Only VISIBLE-AND-OWNS-A-BAR flips from include→omit — the exact double state.
BOOL zapp_ios_sidebar_owns_bar_for_window(void* window_ptr) {
    extern NSString* zapp_ios_sidebar_title_for_window(void* window_ptr);
    return (zapp_ios_sidebar_title_for_window(window_ptr).length > 0)
        || zapp_ios_toolbar_has_pane_items(window_ptr, @"sidebar");
}

// #782 T4a (review I2). The window toolbar's pane-tagged TRAILING bucket —
// the pane's own items, WITHOUT any Close. inspector.m's
// zapp_ios_inspector_reconcile_right_items reads the "inspector" bucket and
// layers the owned Close on top. Empty array for no entry / unknown pane.
NSArray<UIBarButtonItem*>* zapp_ios_toolbar_pane_trailing_items(void* window_ptr, NSString* pane) {
    if (!window_ptr || !pane || !zapp_ios_toolbars) return @[];
    ZappIOSToolbarEntry* entry = zapp_ios_toolbars[[NSValue valueWithPointer:window_ptr]];
    if (!entry) return @[];
    NSArray<UIBarButtonItem*>* trail = nil;
    if (!zapp_ios_toolbar_pane_buckets(entry, pane, NULL, &trail)) return @[];
    return trail ?: @[];
}

// Stamps `pane`'s leading/trailing buckets + title onto `vc`. Generic across
// panes — the inspector's owned Close is NOT handled here (review I2): it is
// layered on afterwards by zapp_ios_inspector_reconcile_right_items, which
// OWNS the inspector's rightBarButtonItems. The sidebar has no Close, so its
// right items are exactly the pane trailing bucket. No-op for an unknown pane.
void zapp_ios_toolbar_stamp_pane(void* window_ptr, UIViewController* vc, NSString* pane, NSString* title) {
    if (!window_ptr || !vc || !pane || !zapp_ios_toolbars) return;
    ZappIOSToolbarEntry* entry = zapp_ios_toolbars[[NSValue valueWithPointer:window_ptr]];
    if (!entry) return;
    NSArray<UIBarButtonItem*>* paneLeading = nil;
    NSArray<UIBarButtonItem*>* paneTrailing = nil;
    if (!zapp_ios_toolbar_pane_buckets(entry, pane, &paneLeading, &paneTrailing)) return;
    vc.navigationItem.leftBarButtonItems  = paneLeading  ?: @[];
    vc.navigationItem.rightBarButtonItems = paneTrailing ?: @[];
    vc.navigationItem.title = title.length ? title : nil;
}

// ─── zapp_ios_toolbar_apply_to_nav (internal helper) ─────────────────────────
//
// Assigns the stored leading/trailing/center buckets from `entry` to the given
// nav controller's topViewController.navigationItem and shows the nav bar.
// `includeToggleSidebar` controls whether the full leading array (with our
// manual toggleSidebar item) or the no-toggle variant is used — callers pass
// YES when collapsed/compact (system button absent), NO when expanded/regular
// (system button auto-provided by UIKit → de-dup).
//
// Must be called on the main thread.

static void zapp_ios_toolbar_apply_to_nav(UINavigationController* nav,
                                          ZappIOSToolbarEntry* entry,
                                          BOOL includeToggleSidebar) {
    if (!nav || !entry) return;
    UIViewController* vc = nav.topViewController;
    if (!vc) return;

    zapp_ios_toolbar_stamp_items(vc, entry, includeToggleSidebar);

    // Bar visibility is owned exclusively by ZappRouteNavDelegate's
    // willShowViewController: (routing.m). Do NOT touch navigationBarHidden here.
}

// ─── zapp_ios_toolbar_populate_entry (internal) ──────────────────────────────
//
// R2' (#771 T8): builds all UIBarButtonItem buckets from a parsed wire `items`
// array into `entry` — extracted verbatim from darwin_toolbar_set_items so
// per-route toolbar overrides (zapp_ios_toolbar_set_vc_chrome) reuse the
// IDENTICAL builder (same click targets, same id maps, same toggle capture).
// The moved loop keeps its original (block-level) indentation so the
// extraction reads as a pure move in the diff. Main thread only (both callers
// already are).
static void zapp_ios_toolbar_populate_entry(ZappIOSToolbarEntry* entry,
                                            NSArray* items,
                                            int32_t host_slot,
                                            void* window_ptr) {
    (void)window_ptr; // reserved — the loop reaches per-window state via host_slot only
        NSMutableArray<UIBarButtonItem*>* leading        = [NSMutableArray array];
        NSMutableArray<UIBarButtonItem*>* leadingNoToggle = [NSMutableArray array];
        // center: title string or titleView UILabel (only the last one wins).
        NSString* centerTitle = nil;
        UIView*   centerView  = nil;
        NSMutableArray<UIBarButtonItem*>* trailing = [NSMutableArray array];
        // #782 T4a: pane-tagged item buckets — populated below by the
        // per-item `pane` read, segregated OUT of the content buckets above.
        // One leading/trailing pair per pane; no toggle-exclusion variant
        // (toggleSidebar/toggleInspector are content-only, never pane-tagged).
        NSMutableArray<UIBarButtonItem*>* sidebarLeading    = [NSMutableArray array];
        NSMutableArray<UIBarButtonItem*>* sidebarTrailing   = [NSMutableArray array];
        NSMutableArray<UIBarButtonItem*>* inspectorLeading  = [NSMutableArray array];
        NSMutableArray<UIBarButtonItem*>* inspectorTrailing = [NSMutableArray array];
        NSMutableArray* allBuilt = [NSMutableArray array]; // for registry
        NSMutableDictionary<NSString*, UIBarButtonItem*>* itemsById = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString*, UISegmentedControl*>* segmentedById = [NSMutableDictionary dictionary];
        // E2: capture the manual toggleSidebar item so the apply paths can grey
        // it when the sidebar is non-collapsible. Stays nil when the toolbar
        // has no toggleSidebar — the entry assignment below then RESETS any
        // previously stored button (repeat setItems without a toggle).
        UIBarButtonItem* toggleSidebarItem = nil;
        // #779: capture the manual toggleInspector item so the apply paths can
        // grey it when the inspector is non-collapsible. Stays nil when the
        // toolbar has no toggleInspector — the entry assignment below then
        // RESETS any previously stored button (repeat setItems without a toggle).
        UIBarButtonItem* toggleInspectorItem = nil;

        for (NSDictionary* def in items) {
            if (![def isKindOfClass:[NSDictionary class]]) continue;
            NSString* type = [def[@"type"] isKindOfClass:[NSString class]] ? def[@"type"] : @"button";
            NSString* placement = [def[@"placement"] isKindOfClass:[NSString class]]
                ? def[@"placement"] : @"leading";
            // #782 T4a: pane tag — segregates sidebar/inspector items OUT of
            // the content buckets (previously dropped/leaked into content;
            // zero `@"pane"` reads existed here before this task). Untagged
            // (nil) items are unaffected — original placement-only routing
            // into the content buckets, unchanged.
            NSString* pane = [def[@"pane"] isKindOfClass:[NSString class]] ? def[@"pane"] : nil;
            BOOL isTrailing = [placement isEqualToString:@"trailing"];
            // #782 T4a: is this item routed to a pane bucket? Pane buckets have
            // no toggle-exclusion variant — bucketNoToggle points at the SAME
            // array as bucket — so every add-to-both site below must add pane
            // items EXACTLY ONCE (guarded by !isPaneItem). The untagged content
            // path (isPaneItem == NO) keeps its original add-to-both behavior
            // byte-identical, including the pre-existing content-trailing
            // double-add for the compound types — that is out of scope here.
            BOOL isPaneItem = ([pane isEqualToString:@"sidebar"] ||
                               [pane isEqualToString:@"inspector"]);

            // Determine the target bucket once.
            NSMutableArray<UIBarButtonItem*>* bucket;
            NSMutableArray<UIBarButtonItem*>* bucketNoToggle;
            if ([pane isEqualToString:@"sidebar"]) {
                bucket = isTrailing ? sidebarTrailing : sidebarLeading;
                bucketNoToggle = bucket;
            } else if ([pane isEqualToString:@"inspector"]) {
                bucket = isTrailing ? inspectorTrailing : inspectorLeading;
                bucketNoToggle = bucket;
            } else {
                bucket = isTrailing ? trailing : leading;
                bucketNoToggle = isTrailing ? trailing : leadingNoToggle;
            }

            // trackingSeparator — dropped on iOS (macOS-only NSTrackingSeparatorToolbarItem).
            // badge / style:prominent / controlRepresentation — ignored without error.
            if ([type isEqualToString:@"trackingSeparator"]) continue;

            // ── T2: segmented ────────────────────────────────────────────────
            if ([type isEqualToString:@"segmented"]) {
                NSString* groupId = [def[@"id"] isKindOfClass:[NSString class]] ? def[@"id"] : nil;
                if (!groupId.length) continue;
                NSArray* segs = [def[@"segments"] isKindOfClass:[NSArray class]] ? def[@"segments"] : @[];
                if (segs.count == 0) continue;
                NSString* modeStr = [def[@"selectionMode"] isKindOfClass:[NSString class]]
                    ? def[@"selectionMode"] : @"momentary";

                UISegmentedControl* sc = [[UISegmentedControl alloc] init];
                for (NSUInteger i = 0; i < segs.count; i++) {
                    NSDictionary* seg = segs[i];
                    if (![seg isKindOfClass:[NSDictionary class]]) {
                        [sc insertSegmentWithTitle:@"" atIndex:i animated:NO];
                        continue;
                    }
                    NSString* segIcon = [seg[@"icon"] isKindOfClass:[NSString class]] ? seg[@"icon"] : @"";
                    UIImage* img = segIcon.length ? zapp_ios_resolve_icon(segIcon) : nil;
                    if (img) {
                        [sc insertSegmentWithImage:img atIndex:i animated:NO];
                    } else {
                        NSString* segLabel = [seg[@"label"] isKindOfClass:[NSString class]] ? seg[@"label"] : @"";
                        [sc insertSegmentWithTitle:segLabel atIndex:i animated:NO];
                    }
                    // Per-segment enabled.
                    NSNumber* segEn = [seg[@"enabled"] isKindOfClass:[NSNumber class]] ? seg[@"enabled"] : nil;
                    if (segEn && !segEn.boolValue) {
                        [sc setEnabled:NO forSegmentAtIndex:i];
                    }
                }

                // selectionMode:
                //   "one"      → persistent single-select (momentary=NO)
                //   "any"      → no native multi-select on iOS; approximate as single-select + note
                //   "momentary"→ momentary=YES (segment springs back)
                if ([modeStr isEqualToString:@"momentary"]) {
                    sc.momentary = YES;
                } else {
                    // "one" and "any" both use persistent single-select.
                    // "any" (multi-select) has no native UIKit equivalent on nav bars —
                    // approximated as single-select. This is noted in the task report.
                    sc.momentary = NO;
                }

                // Apply initial selection (wire format: always number[]).
                NSArray* selArr = [def[@"selected"] isKindOfClass:[NSArray class]] ? def[@"selected"] : @[];
                if (selArr.count > 0) {
                    NSInteger selIdx = [selArr[0] integerValue];
                    if (selIdx >= 0 && selIdx < (NSInteger)segs.count) {
                        sc.selectedSegmentIndex = selIdx;
                    }
                }

                // Wire the target.
                ZappIOSToolbarSegmentTarget* tgt = [[ZappIOSToolbarSegmentTarget alloc] init];
                tgt.hostId        = host_slot;
                tgt.groupId       = groupId;
                tgt.selectionMode = modeStr;
                [sc addTarget:tgt action:@selector(segmentChanged:)
                    forControlEvents:UIControlEventValueChanged];

                UIBarButtonItem* wrapperItem =
                    [[UIBarButtonItem alloc] initWithCustomView:sc];
                // Retain the target via associated object on the wrapper item.
                objc_setAssociatedObject(wrapperItem, &kZappToolbarSegmentTargetKey, tgt,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                [bucket addObject:wrapperItem];
                // #782 T4a: pane buckets share one array (bucket==bucketNoToggle)
                // — skip the second add so the segmented control isn't duplicated.
                if (!isPaneItem) [bucketNoToggle addObject:wrapperItem];
                [allBuilt addObject:wrapperItem];
                itemsById[groupId] = wrapperItem;
                segmentedById[groupId] = sc;
                continue;
            }

            // ── T2: group — flatten sub-buttons into same placement bucket ──
            if ([type isEqualToString:@"group"]) {
                NSArray* subItems = [def[@"items"] isKindOfClass:[NSArray class]] ? def[@"items"] : @[];
                for (NSDictionary* sub in subItems) {
                    if (![sub isKindOfClass:[NSDictionary class]]) continue;
                    NSString* subId = [sub[@"id"] isKindOfClass:[NSString class]] ? sub[@"id"] : nil;
                    if (!subId.length) continue;
                    NSString* subIcon  = [sub[@"icon"]  isKindOfClass:[NSString class]] ? sub[@"icon"]  : @"";
                    NSString* subLabel = [sub[@"label"] isKindOfClass:[NSString class]] ? sub[@"label"] : @"";
                    NSNumber* subEn    = [sub[@"enabled"] isKindOfClass:[NSNumber class]] ? sub[@"enabled"] : nil;
                    BOOL subEnabled = subEn ? subEn.boolValue : YES;

                    ZappIOSToolbarButtonTarget* tgt = [[ZappIOSToolbarButtonTarget alloc] init];
                    tgt.hostId = host_slot;
                    tgt.itemId = subId;

                    UIImage* img = subIcon.length ? zapp_ios_resolve_icon(subIcon) : nil;
                    UIBarButtonItem* subItem;
                    if (img) {
                        subItem = [[UIBarButtonItem alloc] initWithImage:img
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:tgt
                                                                  action:@selector(buttonTapped:)];
                        // VoiceOver label for icon-only bar items. We set
                        // accessibilityLabel only (not title) — setting both image
                        // and title on a UIBarButtonItem causes UIKit to render the
                        // title text in the bar instead of the icon.
                        if (subLabel.length) subItem.accessibilityLabel = subLabel;
                    } else {
                        subItem = [[UIBarButtonItem alloc] initWithTitle:subLabel
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:tgt
                                                                  action:@selector(buttonTapped:)];
                    }
                    subItem.enabled = subEnabled;
                    objc_setAssociatedObject(subItem, &kZappToolbarButtonTargetKey, tgt,
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                    [bucket addObject:subItem];
                    // #782 T4a: pane buckets share one array — single add.
                    if (!isPaneItem) [bucketNoToggle addObject:subItem];
                    [allBuilt addObject:subItem];
                    itemsById[subId] = subItem;
                }
                continue;
            }

            UIBarButtonItem* item = nil;
            BOOL isToggleSidebar = NO;

            if ([type isEqualToString:@"space"]) {
                item = [[UIBarButtonItem alloc]
                    initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace
                    target:nil action:nil];
                item.width = 8.0; // nominal fixed space

            } else if ([type isEqualToString:@"flexibleSpace"]) {
                item = [[UIBarButtonItem alloc]
                    initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                    target:nil action:nil];

            } else if ([type isEqualToString:@"toggleSidebar"]) {
                UIImage* icon = [UIImage systemImageNamed:@"sidebar.leading"];
                ZappIOSToolbarToggleTarget* tgt = [[ZappIOSToolbarToggleTarget alloc] init];
                tgt.windowId = host_slot;
                tgt.isSidebar = YES;
                item = [[UIBarButtonItem alloc] initWithImage:icon
                                                        style:UIBarButtonItemStylePlain
                                                       target:tgt
                                                       action:@selector(toggleTapped:)];
                // VoiceOver label. Not setting title — UIBarButtonItem with both
                // image and title renders title text in the bar (icon-only broken).
                NSString* toggleSidebarLabel = [def[@"label"] isKindOfClass:[NSString class]]
                    ? def[@"label"] : @"";
                item.accessibilityLabel = toggleSidebarLabel.length
                    ? toggleSidebarLabel : @"Toggle Sidebar";
                // Retain the target via associated object (UIBarButtonItem.target is weak).
                objc_setAssociatedObject(item, &kZappToolbarToggleTargetKey, tgt,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                isToggleSidebar = YES;
                toggleSidebarItem = item; // E2: stored on the entry for enabled-state wiring

            } else if ([type isEqualToString:@"toggleInspector"]) {
                UIImage* icon = [UIImage systemImageNamed:@"sidebar.trailing"];
                ZappIOSToolbarToggleTarget* tgt = [[ZappIOSToolbarToggleTarget alloc] init];
                tgt.windowId = host_slot;
                tgt.isSidebar = NO;
                item = [[UIBarButtonItem alloc] initWithImage:icon
                                                        style:UIBarButtonItemStylePlain
                                                       target:tgt
                                                       action:@selector(toggleTapped:)];
                // VoiceOver label. Not setting title — same reason as toggleSidebar.
                NSString* toggleInspectorLabel = [def[@"label"] isKindOfClass:[NSString class]]
                    ? def[@"label"] : @"";
                item.accessibilityLabel = toggleInspectorLabel.length
                    ? toggleInspectorLabel : @"Toggle Inspector";
                objc_setAssociatedObject(item, &kZappToolbarToggleTargetKey, tgt,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                toggleInspectorItem = item; // #779: stored on the entry for enabled-state wiring

            } else if ([type isEqualToString:@"label"]) {
                NSString* text = [def[@"text"] isKindOfClass:[NSString class]] ? def[@"text"] : @"";
                if ([placement isEqualToString:@"center"]) {
                    // Set as navigation title (string form; UILabel path below).
                    centerTitle = text;
                    centerView  = nil; // string title wins unless explicitly set
                    continue; // not a bar button item
                } else {
                    // Non-center label: custom-view UILabel bar item.
                    UILabel* lbl = [[UILabel alloc] init];
                    lbl.text = text;
                    lbl.font = [UIFont systemFontOfSize:[UIFont smallSystemFontSize]];
                    [lbl sizeToFit];
                    item = [[UIBarButtonItem alloc] initWithCustomView:lbl];
                    // Store by id for update_item (text patch).
                    NSString* labelId = [def[@"id"] isKindOfClass:[NSString class]] ? def[@"id"] : nil;
                    if (labelId.length) itemsById[labelId] = item;
                }

            } else {
                // button (default) — requires an id.
                NSString* itemId = [def[@"id"] isKindOfClass:[NSString class]] ? def[@"id"] : nil;
                if (!itemId.length) continue;

                NSString* iconSpec = [def[@"icon"] isKindOfClass:[NSString class]] ? def[@"icon"] : @"";
                NSString* label    = [def[@"label"] isKindOfClass:[NSString class]] ? def[@"label"] : @"";
                NSNumber* enNum    = [def[@"enabled"] isKindOfClass:[NSNumber class]] ? def[@"enabled"] : nil;
                BOOL enabled = enNum ? enNum.boolValue : YES;

                // ── T2: button.menu ──────────────────────────────────────────
                NSArray* menuArr = [def[@"menu"] isKindOfClass:[NSArray class]] ? def[@"menu"] : nil;
                BOOL hasMenu = (menuArr.count > 0);
                if (hasMenu && @available(ios 14.0, *)) {
                    UIImage* image = iconSpec.length ? zapp_ios_resolve_icon(iconSpec) : nil;
                    UIMenu* menu = zapp_ios_build_uimenu(host_slot, menuArr);
                    if (image) {
                        item = [[UIBarButtonItem alloc] initWithImage:image
                                                               style:UIBarButtonItemStylePlain
                                                              target:nil action:nil];
                        // VoiceOver label for icon-only bar items. Not setting title
                        // — UIBarButtonItem renders title text (not icon) when both are set.
                        if (label.length) item.accessibilityLabel = label;
                    } else {
                        item = [[UIBarButtonItem alloc] initWithTitle:label
                                                               style:UIBarButtonItemStylePlain
                                                              target:nil action:nil];
                    }
                    item.menu = menu;
                    item.enabled = enabled;
                    itemsById[itemId] = item;
                    [bucket addObject:item];
                    // #782 T4a: pane buckets share one array — single add.
                    if (!isPaneItem) [bucketNoToggle addObject:item];
                    [allBuilt addObject:item];
                    continue;
                }

                // Plain button (no menu, or iOS < 14 fallback — just skip menu).
                ZappIOSToolbarButtonTarget* tgt = [[ZappIOSToolbarButtonTarget alloc] init];
                tgt.hostId = host_slot;
                tgt.itemId = itemId;

                UIImage* image = iconSpec.length ? zapp_ios_resolve_icon(iconSpec) : nil;
                if (image) {
                    item = [[UIBarButtonItem alloc] initWithImage:image
                                                            style:UIBarButtonItemStylePlain
                                                           target:tgt
                                                           action:@selector(buttonTapped:)];
                    // VoiceOver label for icon-only bar items. Not setting title
                    // — UIBarButtonItem renders title text (not icon) when both are set.
                    if (label.length) item.accessibilityLabel = label;
                } else {
                    item = [[UIBarButtonItem alloc] initWithTitle:label
                                                            style:UIBarButtonItemStylePlain
                                                           target:tgt
                                                           action:@selector(buttonTapped:)];
                }
                item.enabled = enabled;
                // Retain the target (UIBarButtonItem.target is weak/unretained).
                objc_setAssociatedObject(item, &kZappToolbarButtonTargetKey, tgt,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                itemsById[itemId] = item;
            }

            if (!item) continue;

            // Bucket by placement. `bucket` and `bucketNoToggle` both point at `trailing`
            // for trailing items (so only add once). For leading items `bucket` is `leading`
            // and `bucketNoToggle` is `leadingNoToggle` (separate arrays).
            [bucket addObject:item];
            if (!isToggleSidebar && bucket != bucketNoToggle) [bucketNoToggle addObject:item];
            [allBuilt addObject:item];
        }

        entry.allItems        = allBuilt;
        entry.leadingItems    = [leading copy];
        entry.leadingNoToggle = [leadingNoToggle copy];
        entry.toggleSidebarButton = toggleSidebarItem; // E2: nil when no toggle in this set
        entry.toggleInspectorButton = toggleInspectorItem; // #779: nil when no toggle in this set

        entry.trailingItems   = [trailing copy];
        entry.centerTitle     = centerTitle;
        entry.centerView      = centerView;
        entry.itemsById       = itemsById;
        entry.segmentedById   = segmentedById;
        // #782 T4a
        entry.sidebarLeading    = [sidebarLeading copy];
        entry.sidebarTrailing   = [sidebarTrailing copy];
        entry.inspectorLeading  = [inspectorLeading copy];
        entry.inspectorTrailing = [inspectorTrailing copy];
}

// ─── darwin_toolbar_set_items ────────────────────────────────────────────────
//
// Mirrors darwin/toolbar.m's darwin_toolbar_set_items adapted to UIKit.
// Main path:
//   1. Resolve the content UINavigationController via
//      zapp_ios_content_nav_for_window. Nil → no-op (no-sidebar window deferred).
//   2. Parse toolbar_json (root.items array).
//   3. Get-or-create the registry entry, then build the leading /
//      leadingNoToggle / center / trailing buckets + id maps into it via
//      zapp_ios_toolbar_populate_entry (shared with per-route overrides, R2').
//   4. Apply to the live nav's top VC (zapp_ios_toolbar_apply_to_nav) + run
//      the attach primer.
//   5. Call zapp_toolbar_inject_metrics.

void darwin_toolbar_set_items(void* window_ptr, const char* toolbar_json, int32_t host_slot) {
    if (!window_ptr || !toolbar_json || !toolbar_json[0]) return;
    NSString* json = [NSString stringWithUTF8String:toolbar_json];
    zapp_ios_toolbar_on_main(^{
        UINavigationController* contentNav = zapp_ios_content_nav_for_window(window_ptr);
        if (!contentNav) {
            // Nav-less plain window (no split): nothing to attach a bar to. Safe no-op.
            return;
        }

        NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSError* err = nil;
        NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![root isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[zapp] iOS toolbar: invalid toolbarJson (%@) — setItems ignored",
                  err ? err.localizedDescription : @"not an object");
            return;
        }
        NSArray* items = [root[@"items"] isKindOfClass:[NSArray class]] ? root[@"items"] : @[];
        if (items.count == 0) {
            NSLog(@"[zapp] iOS toolbar: setItems with empty items array — ignored");
            return;
        }

        // Update the per-window registry with the parsed buckets.
        if (!zapp_ios_toolbars) zapp_ios_toolbars = [NSMutableDictionary dictionary];
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappIOSToolbarEntry* entry = zapp_ios_toolbars[key];
        if (!entry) {
            entry = [[ZappIOSToolbarEntry alloc] init];
            entry.hostSlot = host_slot;
            entry.windowPtr = window_ptr;
            zapp_ios_toolbars[key] = entry;
        }
        zapp_ios_toolbar_populate_entry(entry, items, host_slot, window_ptr);

        // Apply directly to the live content nav's top VC. Resolve the nav via
        // the split's content VC (works on both collapsed iPhone and expanded iPad).
        // includeToggleSidebar: include our manual button when collapsed (UIKit adds
        // no system button then) or when expanded+sidebar-visible (UIKit also adds none).
        // Omit when expanded+sidebar-hidden (UIKit provides its own system button).
        {
            extern UIViewController* zapp_ios_content_vc_for_window(void* window_ptr);
            UIViewController* cvc = zapp_ios_content_vc_for_window(window_ptr);
            UINavigationController* applyNav = cvc ? cvc.navigationController : contentNav;
            if (applyNav) {
                BOOL collapsed = zapp_ios_split_is_collapsed_for_window(window_ptr);
                BOOL sidebarHidden = !collapsed && zapp_ios_sidebar_is_hidden_for_window(window_ptr);
                // #782 double-toggle fix: expanded → include our manual
                // toggleSidebar ONLY when the sidebar is visible AND barless
                // (UIKit provides no system button then). When the sidebar owns
                // a bar its own UIKit toggle covers it; when hidden UIKit's
                // content reveal button covers it — omit ours either way.
                // Collapsed (iPhone) always keeps the manual toggle (UIKit shows
                // none in compact), so the owns-bar term must NOT reach it.
                BOOL includeToggle = collapsed
                    ? YES
                    : (!sidebarHidden && !zapp_ios_sidebar_owns_bar_for_window(window_ptr));
                zapp_ios_toolbar_apply_to_nav(applyNav, entry, includeToggle);

                // #771 G1-B PRIMER: set_items can run with NO nav transition in
                // flight — e.g. a bare remove() → setItems() re-attach from app
                // code (kitchen-sink's Toolbar section), not a route push/pop.
                // ZappRouteNavDelegate's willShowViewController: (routing.m) is
                // the sole ONGOING bar-visibility owner, but it only fires on a
                // real UIKit transition — a bar left hidden by
                // darwin_toolbar_remove's matching PRIMER below would otherwise
                // never be re-shown. Same class as the three construction-time
                // primers (window.m:818, sidebar.m:662/846/853): a direct,
                // idempotent visibility write for a state UIKit will not
                // transition into on its own.
                //
                // #771 T7 sub-gate: the old heuristic here
                // ((!collapsed || topIsContent) && hidden → show) fired
                // unconditionally whenever the content VC was (or wasn't
                // collapsed-relevant) on top, blind to what's ACTUALLY on top
                // of the bar the user sees. Two bugs followed: (1) a
                // navbarHidden:true route's OWN setItems call (kitchen-sink's
                // main-pane.ts fires setItems unconditionally on every route
                // webview boot) forced that route's deliberately-hidden bar
                // back open — a visible flash until didShow's re-assert hid it
                // one beat later; (2) resolving via `cvc.navigationController`
                // (applyNav) rather than the shape-correct nav meant the
                // primer could miss the collapsed/combined nav entirely on
                // iPhone at launch, leaving the Home bar absent until the next
                // transition re-ran willShow.
                //
                // Fix: resolve the nav for the CURRENT shape exactly like
                // zapp_ios_toolbar_apply_for_window_hidden does — collapsed →
                // the collapsed/combined nav, expanded → contentNav (the nav
                // whose bar is actually on screen) — then consult the SAME
                // want-state rule ZappRouteNavDelegate's willShow/didShow use
                // (zapp_route_bar_should_show, routing.m) for whatever VC is
                // really on top of THAT nav. Registration is true by
                // definition here (the entry was just created/updated above),
                // so for a bare content top this reduces to "show"; for a
                // covering navbarHidden route on top it correctly stays NO.
                UINavigationController* primerNav = collapsed
                    ? zapp_ios_collapsed_nav_for_window(window_ptr)
                    : contentNav;
                UIViewController* primerTop = primerNav.topViewController;
                if (primerNav && primerTop && primerNav.navigationBarHidden
                    && zapp_route_bar_should_show(window_ptr, primerTop, cvc)) {
                    [primerNav setNavigationBarHidden:NO animated:NO];
                }
            }
        }

        // #782 T4a: stamp the sidebar/inspector panes' own item buckets +
        // titles onto their root VCs. The inspector column already shows a
        // bar unconditionally (no want-state gate), so this is the ONLY
        // stamp it needs outside a show transition (column_did_show,
        // ios/inspector.m, covers the first-show-before-any-setItems case).
        // The sidebar stamp here is harmless plumbing ahead of T4b: its bar
        // stays hidden until T4b wires up the config-implied want-state, so
        // stamped items/title simply sit unseen until then.
        {
            extern UIViewController* zapp_ios_inspector_root_vc_for_window(void* window_ptr);
            extern NSString* zapp_ios_inspector_title_for_window(void* window_ptr);
            // #782 T4a (review I2): reconcile OWNS the inspector's right items
            // (owned Close layered over pane trailing). stamp_pane sets
            // left + title + right=paneTrailing; reconcile then rebuilds right
            // with the owned Close if wantsClose — so a set_items call can
            // never wipe a wanted Close.
            extern void zapp_ios_inspector_reconcile_right_items(void* window_ptr);
            UIViewController* inspectorRootVC = zapp_ios_inspector_root_vc_for_window(window_ptr);
            if (inspectorRootVC) {
                zapp_ios_toolbar_stamp_pane(window_ptr, inspectorRootVC, @"inspector",
                                            zapp_ios_inspector_title_for_window(window_ptr));
                zapp_ios_inspector_reconcile_right_items(window_ptr);
            }
            extern UIViewController* zapp_ios_sidebar_vc_for_window(void* window_ptr);
            extern NSString* zapp_ios_sidebar_title_for_window(void* window_ptr);
            UIViewController* sidebarRootVC = zapp_ios_sidebar_vc_for_window(window_ptr);
            if (sidebarRootVC) {
                zapp_ios_toolbar_stamp_pane(window_ptr, sidebarRootVC, @"sidebar",
                                            zapp_ios_sidebar_title_for_window(window_ptr));
            }
        }

        // Inject chrome metrics into the content webview. The persistent
        // WKUserScript (add_user_script=true) is added only the first time for
        // this entry — WKUserContentController has no per-script removal, so
        // repeated set_items calls would pile up scripts unboundedly. After the
        // first injection, live updates use evaluateJavaScript only.
        // One tick delay so UIKit finishes laying the nav bar out before we measure.
        BOOL needsUserScript = !entry.hasUserScript;
        if (needsUserScript) entry.hasUserScript = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            zapp_toolbar_inject_metrics(window_ptr, host_slot, needsUserScript);
        });
    });
}

// ─── zapp_ios_toolbar_apply_for_window ─────────────────────────────────────
//
// Called from sidebar.m's collapse/expand delegates so a set toolbar survives
// the nav-controller switch.
//
// Logic:
//   - If split is collapsed (iPhone / compact): target collapsedNav.
//       • Apply items to contentVC.navigationItem (items appear when content is on top).
//       • Show bar only when the content VC is on top (count > 1).
//       • Use leadingItems (include manual toggleSidebar — system button absent
//         when collapsed).
//   - If split is expanded (iPad): target contentNav.
//       • Show bar unconditionally (the content column is always visible).
//       • Use leadingNoToggle (omit manual toggleSidebar) UNLESS the sidebar is
//         visible AND barless — then UIKit provides no system button anywhere,
//         so leadingItems (our manual toggle) is the only affordance. When the
//         sidebar is hidden OR owns its own bar (#782), UIKit provides the
//         system toggle (content reveal button, or the sidebar-bar toggle
//         respectively), so ours is omitted. See
//         zapp_ios_sidebar_owns_bar_for_window.
//
// Must be called on the main thread. Declared extern so sidebar.m can call it.

// ─── zapp_ios_toolbar_apply_for_window_hidden ─────────────────────────────────
//
// Applies a registered toolbar to the correct nav (collapsed vs expanded).
//
// `sidebarHidden` CALLER CONTRACT (#771 G1-F, revising T2's advisory-only
// rule): the parameter is AUTHORITATIVE for the expanded path's
// include-toggle decision. Callers must pass the sidebar-hidden state that
// will be TRUE FOR THE FRAMES THESE ITEMS ARE SEEN IN:
//   • zapp_ios_toolbar_apply_for_window (the only other caller) — a LIVE
//     read (zapp_ios_sidebar_is_hidden_for_window) taken at apply time;
//     correct at every settled call site (didCollapse/didExpand, the settled
//     dispatch_async re-applies, inspector show/hide, set_collapsible).
//   • sidebar.m willChangeToDisplayMode: (sync pre-settle apply) — the
//     transition TARGET derived from the delegate's displayMode parameter.
//     Inside willChange the live displayMode still reads the OUTGOING mode,
//     so a live read here stamped the OLD arrays (functional no-op) and
//     deferred the real toggle swap to the settled tick — landing
//     MID-ANIMATION and relayouting the bar mid-width-animation: the G1-F
//     over-slide + snap-back. Passing the target stamps the swap
//     synchronously, riding the same animation transaction (the 899aef2
//     invariant).
// T2's double-toggle guarantee is preserved one level up: the settled
// dispatch_async re-apply goes through apply_for_window's LIVE read at APPLY
// time, so under overlapping transitions (rapid toggle, rotation mid-toggle)
// whichever settled re-apply runs LAST reads whatever is CURRENTLY true and
// self-corrects, regardless of dispatch ordering. stamp_items' idempotence
// guard makes that backstop a visual no-op when the transition settled as
// announced.
//
// Collapsed (iPhone compact): apply items to the content VC's navigationItem
//   (so they appear when the content VC is on top of collapsedNav), and show
//   the bar only when the content VC is on top. (Collapsed has no displayMode
//   concept — UIKit never shows a system reveal button there — so the
//   parameter is not consulted on this path.)
// Expanded (iPad regular): apply to contentNav's topViewController.
//   includeToggleSidebar = !sidebarHidden.
//
// Must be called on the main thread. Declared extern so sidebar.m can call it.

void zapp_ios_toolbar_apply_for_window_hidden(void* window_ptr, BOOL sidebarHidden) {
    if (!window_ptr || !zapp_ios_toolbars) return;
    // Must be on main thread (UIKit constraint).
    NSCAssert([NSThread isMainThread],
              @"zapp_ios_toolbar_apply_for_window_hidden must be called on the main thread");

    NSValue* key = [NSValue valueWithPointer:window_ptr];
    ZappIOSToolbarEntry* entry = zapp_ios_toolbars[key];
    if (!entry) return; // no toolbar registered for this window — no-op

    BOOL collapsed = zapp_ios_split_is_collapsed_for_window(window_ptr);

    if (collapsed) {
        // ── Collapsed path (iPhone / compact) ──────────────────────────────
        UINavigationController* collapsedNav = zapp_ios_collapsed_nav_for_window(window_ptr);
        if (!collapsedNav) {
            // The split may not have fired splitViewControllerDidCollapse: yet
            // (it is created already-collapsed on iPhone). The sidebar will
            // call us again from didCollapse: once it captures collapsedNav.
            // Nothing to do right now.
            return;
        }

        // Apply items directly to the CONTENT VC's navigationItem.
        // In collapsed mode, the content VC is pushed onto collapsedNav as a child;
        // we must target its navigationItem specifically (not topViewController,
        // which may be the sidebar VC at this moment). The assignment is idempotent
        // and harmless whether content is on top or not — items will appear when
        // the content VC is shown.
        // Use the authoritative contentVC stored at registration time (not
        // contentNav.topViewController — UIKit may orphan contentNav when it builds
        // the combined collapsed stack, making topViewController unreliable here).
        UIViewController* contentVC = zapp_ios_content_vc_for_window(window_ptr);
        if (contentVC) {
            // Collapsed always includes the manual toggleSidebar (UIKit shows
            // no system reveal button in compact).
            zapp_ios_toolbar_stamp_items(contentVC, entry, YES);
        }

        // Bar-HIDDEN visibility on the collapsed nav is owned per-VC by
        // viewWillAppear (#782 foundation — ZappIOSPaneViewController in
        // window.m for content, ZappRouteVC in routing.m for routes), not by
        // ZappRouteNavDelegate's willShowViewController: (routing.m), which
        // owns toolbar items, the pop gesture, and route-depth reconciliation.
        // Do NOT write navigationBarHidden here — viewWillAppear fires on
        // every appearance and sets the correct state without drift.

    } else {
        // ── Expanded path (iPad / regular) ─────────────────────────────────
        UINavigationController* contentNav = zapp_ios_content_nav_for_window(window_ptr);
        if (!contentNav) return;

        // Include our manual toggleSidebar button ONLY when the sidebar is
        // (or is about to be) VISIBLE **and does not own its own bar**. #782
        // gave the sidebar a bar when it has chrome (title / pane items); when
        // it does, UIKit auto-places the sidebar-collapse toggle in THAT bar, so
        // ours in the content column would be a duplicate. When the sidebar is
        // visible but BARLESS, UIKit adds no system button anywhere, so ours is
        // the only affordance. When the sidebar is HIDDEN, UIKit shows its own
        // "show sidebar" system button in the content bar — omit ours either way.
        //
        // #771 G1-F: decide from the `sidebarHidden` PARAMETER, per the caller
        // contract in the header comment above — live truth at settled call
        // sites, the transition TARGET inside willChangeToDisplayMode:.
        // Trusting the target there is the point: the toggle swap is stamped
        // synchronously INSIDE the display-mode animation transaction (899aef2
        // invariant) instead of one tick later mid-animation (T2's live read
        // reproduced the OUTGOING mode inside willChange, deferring the real
        // swap to the settled re-apply → the visible over-slide + snap-back).
        // The settled re-apply still re-derives from live state and remains
        // the final word under overlapping transitions; stamp_items'
        // idempotence guard makes it a visual no-op when the transition
        // settled as announced.
        // #782 double-toggle fix: on the expanded path, once the sidebar owns
        // its own bar UIKit auto-places the sidebar-collapse toggle THERE (when
        // visible), so the content bar must drop our manual toggleSidebar to
        // avoid a duplicate. The `sidebarHidden` timing invariant is untouched
        // (still the caller-supplied parameter — the transition TARGET inside
        // willChange, live truth at settled sites); the added owns-bar term is a
        // config-derived predicate that is INVARIANT across a show/hide
        // animation, so it neither reads nor perturbs the display-mode timing.
        // Hidden state is unchanged (was already omitted); visible-and-barless
        // still keeps the manual toggle (UIKit provides none).
        BOOL includeToggle = !sidebarHidden
            && !zapp_ios_sidebar_owns_bar_for_window(window_ptr);
        zapp_ios_toolbar_apply_to_nav(contentNav, entry, includeToggle);
    }
}

void zapp_ios_toolbar_apply_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_toolbars) return;
    // Must be on main thread (UIKit constraint).
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            zapp_ios_toolbar_apply_for_window(window_ptr);
        });
        return;
    }
    // Read the live sidebar-hidden state and delegate to the explicit-state variant.
    BOOL sidebarHidden = zapp_ios_sidebar_is_hidden_for_window(window_ptr);
    zapp_ios_toolbar_apply_for_window_hidden(window_ptr, sidebarHidden);
}

// ─── zapp_ios_toolbar_stamp_vc / _force ──────────────────────────────────────
//
// #771 datum 3: stamp the window's registered toolbar onto a SPECIFIC VC —
// called by ZappRouteNavDelegate (routing.m) at willShow/didShow so the VC
// being shown always receives the entry's current item instances (content VC
// after a pop, route VC at push). The include-toggle decision is the same
// live-state read set_items uses. Main thread only.
//
// #771 G1-F fix round 2: `force` threads straight through to
// zapp_ios_toolbar_stamp_items_force — see that function's header comment.
// routing.m passes YES ONLY at the didShow re-stamp call site (the cancelled-
// interactive-swipe recovery path); willShow keeps calling the guarded
// zapp_ios_toolbar_stamp_vc wrapper below (force=NO).
void zapp_ios_toolbar_stamp_vc_force(void* window_ptr, UIViewController* vc, BOOL force) {
    if (!window_ptr || !vc) return;
    NSCAssert([NSThread isMainThread],
              @"zapp_ios_toolbar_stamp_vc_force must be called on the main thread");
    ZappIOSToolbarEntry* entry = nil;
    if (zapp_ios_toolbars) {
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        entry = zapp_ios_toolbars[key];
    }
    // R2' (#771 T8): a per-VC toolbar override replaces the window entry
    // wholesale (falls back to the window defs when absent). Resolved here —
    // not just in stamp_items_force — so a window with NO registered toolbar
    // but a route WITH one still stamps (the old !zapp_ios_toolbars bail
    // above would have skipped it).
    ZappIOSToolbarEntry* override = objc_getAssociatedObject(vc, &kZappRouteToolbarEntryKey);
    if (override) entry = override;
    if (!entry) {
        // I1 (#771 T8 review): a title-only push (no toolbar override) into a
        // window that never registered a toolbar previously left this VC's
        // navigationItem.title untouched — there is no entry to reach the
        // title-only stamp arm inside stamp_items_force below, so we bailed
        // before it ever ran. The bar itself DOES show in this scenario
        // (want-state is `isRoute && !navbarHidden`, independent of whether a
        // toolbar entry exists), so the route's title must still land. Apply
        // it directly here, then bail (no items to stamp).
        NSString* routeTitle = objc_getAssociatedObject(vc, &kZappRouteTitleKey);
        if (routeTitle.length) vc.navigationItem.title = routeTitle;
        return;
    }
    BOOL collapsed = zapp_ios_split_is_collapsed_for_window(window_ptr);
    // #782 double-toggle fix: expanded → include the manual toggleSidebar only
    // when the sidebar is visible (not secondaryOnly) AND barless. Once the
    // sidebar owns a bar, UIKit's toggle lives there, so omit ours from the
    // content column. Collapsed keeps the manual toggle (guarded by the ternary
    // — UIKit shows no system toggle in compact).
    BOOL includeToggle = collapsed
        ? YES
        : (!zapp_ios_split_display_mode_is_secondary_only(window_ptr)
           && !zapp_ios_sidebar_owns_bar_for_window(window_ptr));
    zapp_ios_toolbar_stamp_items_force(vc, entry, includeToggle, force);
}

// Guarded (default) entry point — force=NO. Kept as the stable call shape for
// the willShow stamp in routing.m.
void zapp_ios_toolbar_stamp_vc(void* window_ptr, UIViewController* vc) {
    zapp_ios_toolbar_stamp_vc_force(window_ptr, vc, NO);
}

// ─── zapp_ios_toolbar_set_vc_chrome ──────────────────────────────────────────
//
// R2' (#771 T8): store per-VC chrome on a pushed route VC — an optional route
// title and an optional toolbar-override entry built from the same wire JSON
// shape as darwin_toolbar_set_items. The stamping choke point reads both:
// the override entry replaces the window entry wholesale; the title overrides
// entry.centerTitle. NULL title / NULL toolbar_json clear. Called by
// routing.m before the push (so the first willShow already sees it).
// Main thread only (the push seam runs on it).
void zapp_ios_toolbar_set_vc_chrome(void* window_ptr, UIViewController* vc,
                                    const char* title, const char* toolbar_json,
                                    int32_t host_slot) {
    if (!vc) return;
    objc_setAssociatedObject(vc, &kZappRouteTitleKey,
        (title && title[0]) ? [NSString stringWithUTF8String:title] : nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ZappIOSToolbarEntry* override = nil;
    if (toolbar_json && toolbar_json[0]) {
        NSData* data = [[NSString stringWithUTF8String:toolbar_json]
                           dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* root = data
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
            : nil;
        NSArray* items = ([root isKindOfClass:[NSDictionary class]] &&
                          [root[@"items"] isKindOfClass:[NSArray class]]) ? root[@"items"] : nil;
        if (items.count > 0) {
            override = [[ZappIOSToolbarEntry alloc] init];
            override.hostSlot = host_slot;
            override.windowPtr = window_ptr;
            zapp_ios_toolbar_populate_entry(override, items, host_slot, window_ptr);
        }
    }
    objc_setAssociatedObject(vc, &kZappRouteToolbarEntryKey, override,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ─── darwin_toolbar_update_item ──────────────────────────────────────────────
//
// T2: Patch one item in place. item_json = {"id", ...only patched keys}.
// Mirrors darwin/toolbar.m's darwin_toolbar_update_item adapted to UIKit.
//
// Supported patch keys (iOS UIKit equivalents):
//   label  → barButtonItem.title (for text-title buttons) or UILabel.text (label items)
//   icon   → barButtonItem.image (for image buttons)
//   enabled → barButtonItem.enabled
//   selected → UISegmentedControl.selectedSegmentIndex (for segmented items; wire: number[])
//   menu   → rebuild UIMenu on a button.menu item (iOS 14+)
//   text   → same as label but for type:"label" items — UILabel.text
// Ignored/graceful: badge, style, tintColor, bordered, controlRepresentation.
// Unknown id → no-op (match macOS behavior).

void darwin_toolbar_update_item(void* window_ptr, const char* item_json) {
    if (!window_ptr || !item_json || !item_json[0]) return;
    NSString* json = [NSString stringWithUTF8String:item_json];
    zapp_ios_toolbar_on_main(^{
        if (!zapp_ios_toolbars) return;
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappIOSToolbarEntry* entry = zapp_ios_toolbars[key];
        if (!entry) return; // no toolbar registered — no-op (matches macOS)

        NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* patch = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![patch isKindOfClass:[NSDictionary class]]) return;

        NSString* itemId = [patch[@"id"] isKindOfClass:[NSString class]] ? patch[@"id"] : nil;
        if (!itemId.length) return;

        // ── Segmented control ────────────────────────────────────────────────
        UISegmentedControl* sc = entry.segmentedById[itemId];
        if (sc) {
            // selected: wire is always number[]; apply first element.
            if ([patch[@"selected"] isKindOfClass:[NSArray class]]) {
                NSArray* sel = patch[@"selected"];
                if (sel.count > 0) {
                    NSInteger idx = [sel[0] integerValue];
                    if (idx >= 0 && idx < sc.numberOfSegments) {
                        sc.selectedSegmentIndex = idx;
                    }
                } else {
                    // Empty array → deselect (e.g. momentary reset).
                    sc.selectedSegmentIndex = UISegmentedControlNoSegment;
                }
            }
            if ([patch[@"enabled"] isKindOfClass:[NSNumber class]]) {
                sc.enabled = [(NSNumber*)patch[@"enabled"] boolValue];
            }
            // icon/label for segmented: not patched at the control level on iOS
            // (individual segment images/titles would require index; not in the patch shape).
            return;
        }

        // ── Bar button item (button / group sub-button / button.menu / label) ─
        UIBarButtonItem* barItem = entry.itemsById[itemId];
        if (!barItem) {
            // Unknown id: no-op (matches darwin/toolbar.m behavior).
            NSLog(@"[zapp] iOS toolbar: updateItem unknown id \"%@\" — ignored", itemId);
            return;
        }

        // label / text → title or UILabel.text.
        NSString* newLabel = nil;
        if ([patch[@"label"] isKindOfClass:[NSString class]]) newLabel = patch[@"label"];
        if ([patch[@"text"]  isKindOfClass:[NSString class]]) newLabel = patch[@"text"]; // overrides label if both

        if (newLabel) {
            // Check if the custom view is a UILabel (type:"label" items).
            if ([barItem.customView isKindOfClass:[UILabel class]]) {
                UILabel* lbl = (UILabel*)barItem.customView;
                lbl.text = newLabel;
                [lbl sizeToFit];
            } else {
                barItem.title = newLabel;
            }
        }

        // icon → image.
        if ([patch[@"icon"] isKindOfClass:[NSString class]] && ((NSString*)patch[@"icon"]).length) {
            UIImage* img = zapp_ios_resolve_icon(patch[@"icon"]);
            if (img) barItem.image = img;
        }

        // enabled.
        if ([patch[@"enabled"] isKindOfClass:[NSNumber class]]) {
            barItem.enabled = [(NSNumber*)patch[@"enabled"] boolValue];
        }

        // menu → rebuild UIMenu (iOS 14+; button.menu items only).
        if ([patch[@"menu"] isKindOfClass:[NSArray class]] && @available(ios 14.0, *)) {
            UIMenu* menu = zapp_ios_build_uimenu(entry.hostSlot, patch[@"menu"]);
            barItem.menu = menu;
        }

        // badge / style / tintColor / bordered / controlRepresentation →
        // gracefully ignored (not available on UIBarButtonItem / nav bar).
    });
}

// ─── darwin_toolbar_remove ────────────────────────────────────────────────────
//
// T2: Hide the nav bar, clear navigationItem items, drop the registry entry,
// re-inject --zapp-toolbar-height: 0.
//
// Mirrors darwin/toolbar.m's darwin_toolbar_remove adapted for iOS.
// Must work correctly whether the split is collapsed (iPhone) or expanded (iPad)
// — uses the same collapse-aware target selection as apply_for_window.
// No-op when no toolbar is registered for this window.

void darwin_toolbar_remove(void* window_ptr) {
    if (!window_ptr) return;
    zapp_ios_toolbar_on_main(^{
        if (!zapp_ios_toolbars) return;
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappIOSToolbarEntry* entry = zapp_ios_toolbars[key];
        if (!entry) return; // not registered — no-op

        int32_t slot = entry.hostSlot;
        BOOL collapsed = zapp_ios_split_is_collapsed_for_window(window_ptr);

        if (collapsed) {
            // ── Collapsed (iPhone) ────────────────────────────────────────
            UINavigationController* collapsedNav = zapp_ios_collapsed_nav_for_window(window_ptr);
            if (collapsedNav) {
                // Clear items on the content VC's navigationItem.
                UIViewController* contentVC = zapp_ios_content_vc_for_window(window_ptr);
                if (contentVC) {
                    contentVC.navigationItem.leftItemsSupplementBackButton = YES;
                    contentVC.navigationItem.leftBarButtonItems  = @[];
                    contentVC.navigationItem.rightBarButtonItems = @[];
                    contentVC.navigationItem.title     = nil;
                    contentVC.navigationItem.titleView = nil;
                }
                // #771 G1-B PRIMER (symmetric with set_items' attach-time show
                // above): no nav transition follows remove() in the bare
                // remove()/setItems() cycle, so willShowViewController: (the
                // ongoing visibility owner) never fires to hide the now-
                // toolbar-less bar — it would otherwise stay visible-but-empty
                // forever, occluding content that (correctly, per the fix
                // below) no longer reserves space for it. Only hide when the
                // content VC is actually the one on top — a covering
                // ZappRouteVC keeps its OWN bar state regardless of this
                // window's toolbar-registration state: routing.m's willShow
                // shows/hides a ZappRouteVC's bar per THAT route's own
                // navbarHidden opt-out flag, not unconditionally.
                if (contentVC && collapsedNav.topViewController == contentVC
                    && !collapsedNav.navigationBarHidden) {
                    [collapsedNav setNavigationBarHidden:YES animated:NO];
                }
                // #771 R2' + G1 fix B: the nav delegate STAYS installed (it
                // used to be nil'd here as "no toolbar → no bar visibility
                // management"). ZappRouteNavDelegate now (a) owns the
                // interactive-pop gesture guard and route-depth
                // reconciliation — nil'ing it would break swipe-back on
                // already-pushed routes — and (b) is registration-aware:
                // willShow consults zapp_ios_toolbar_registered_for_window,
                // so with the entry dropped below it keeps the content VC
                // bar-less across every later transition by itself.
            }
        } else {
            // ── Expanded (iPad) ───────────────────────────────────────────
            UINavigationController* contentNav = zapp_ios_content_nav_for_window(window_ptr);
            if (contentNav) {
                // Clear items on the content VC's navigationItem (not
                // topViewController's) — a covering ZappRouteVC's T8
                // per-route title/toolbar stamp must survive remove(),
                // mirroring the collapsed branch above.
                UIViewController* contentVC = zapp_ios_content_vc_for_window(window_ptr);
                if (contentVC) {
                    contentVC.navigationItem.leftItemsSupplementBackButton = YES;
                    contentVC.navigationItem.leftBarButtonItems  = @[];
                    contentVC.navigationItem.rightBarButtonItems = @[];
                    contentVC.navigationItem.title     = nil;
                    contentVC.navigationItem.titleView = nil;
                }
                // #771 G1-B PRIMER: see the collapsed branch above for
                // rationale. Expanded has no "sidebar root" state — vc IS the
                // content VC whenever no route currently covers it.
                UIViewController* vc = contentNav.topViewController;
                if (vc && vc == contentVC && !contentNav.navigationBarHidden) {
                    [contentNav setNavigationBarHidden:YES animated:NO];
                }
            }
        }

        // Drop the registry entry before re-injecting metrics so that
        // inject_metrics measures a hidden bar (height → 0).
        [zapp_ios_toolbars removeObjectForKey:key];

        // Re-inject --zapp-toolbar-height: 0. The PRIMER above already hid
        // the bar synchronously, so 0 is unconditionally correct here — no
        // measurement (or one-tick wait for layout) needed, unlike the
        // show-a-real-bar case. Clear all pane webviews. Entry is gone so we
        // can't call inject_metrics — build the JS inline.
        //
        // #771 G1-B: --zapp-toolbar-height is the ONLY var stomped here.
        // --zapp-titlebar-height and --zapp-safe-area-* stay on the reactive
        // env(safe-area-inset-*) CSS fallback (webview.m's document-start
        // WKUserScript) — same ownership split zapp_toolbar_inject_metrics's
        // injectIntoWebview documents below. WKWebView recomputes
        // safeAreaInsets (and therefore env()) live as the just-hidden bar
        // changes the content view's safe area; no native re-injection is
        // needed or correct here. A prior version force-set these to a frozen
        // "0px" inline style via .style.setProperty, which PERMANENTLY shadows
        // the CSS env() rule (inline beats stylesheet in the cascade, and
        // nothing ever called .style.removeProperty to release it) — since
        // injectIntoWebview only ever re-injects --zapp-toolbar-height (by the
        // same ownership contract), that frozen "0px" was never cleared on a
        // later attach. This was the actual root cause of #771 G1: the
        // re-attached bar's row height WAS measured correctly, but
        // --zapp-titlebar-height stayed stuck at the stale "0px" this
        // function had inline-set, permanently masking env()'s correct
        // (reactive) value — hence "content underlapping the re-attached bar,
        // titlebar-height stale."
        int32_t sidebarSlot   = zapp_ios_sidebar_slot_for(slot);
        int32_t inspectorSlot = zapp_ios_inspector_slot_for(slot);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString* js = @"(function(){try{var r=document.documentElement;if(r){"
                            "r.style.setProperty('--zapp-toolbar-height','0px');"
                            "}}catch(e){}})();";
            WKWebView* wv = zapp_ios_content_webview_for_slot(slot);
            if (wv) [wv evaluateJavaScript:js completionHandler:nil];
            if (sidebarSlot >= 0) {
                WKWebView* sbWv = zapp_ios_content_webview_for_slot(sidebarSlot);
                if (sbWv) [sbWv evaluateJavaScript:js completionHandler:nil];
            }
            if (inspectorSlot >= 0) {
                WKWebView* insWv = zapp_ios_content_webview_for_slot(inspectorSlot);
                if (insWv) [insWv evaluateJavaScript:js completionHandler:nil];
            }
        });
    });
}

// ─── zapp_toolbar_inject_metrics ─────────────────────────────────────────────
//
// Mirrors darwin/toolbar.m's zapp_toolbar_inject_metrics adapted for iOS.
//
// Injects chrome-metric CSS vars into all pane webviews (content, sidebar,
// inspector) so the web layout reserves space for the native chrome:
//
//   --zapp-titlebar-height  = content webview's safeAreaInsets.top
//                             (= status-bar + dynamic-island + shown nav bar)
//                             → THE KEY VAR: kitchen-sink .main-pane /
//                               .sidebar-pane / .inspector-pane all use this.
//   --zapp-toolbar-height   = nav bar row height when shown (0 when hidden)
//                             → for apps that want just the bar-band height.
//   --zapp-safe-area-{top,left,right,bottom} = content webview safeAreaInsets
//                             → mirrors macOS; injected into the content pane only.
//
// For the SIDEBAR and INSPECTOR panes, inject:
//   --zapp-titlebar-height  = that pane's safeAreaInsets.top (status bar)
//   --zapp-toolbar-height   = 0 (those panes have no toolbar row)
//   --zapp-safe-area-{top,left,right,bottom} = that pane's safeAreaInsets
//
// safeAreaInsets MUST be read AFTER layout (called one tick after UIKit sets
// items so the nav bar is laid out). On iPhone at launch the bar is hidden
// over the sidebar, so safeAreaInsets.top on the content webview only reflects
// the status-bar portion; once the content VC is shown (bar appears),
// willShowViewController: fires a second one-tick-deferred inject so the
// --zapp-titlebar-height updates to the full inset.
//
// The persistent WKUserScript (add_user_script=true) records the value at
// AtDocumentStart so reloads keep it. Live updates use evaluateJavaScript only
// (add_user_script=false) — WKUserContentController has no per-script removal,
// so repeated adds would pile up. The first call from set_items passes
// add_user_script=true; the willShowViewController re-inject passes false.

void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script) {
    if (!window_ptr) return;
    // Must run on the main thread (UIKit constraint + WKWebView API).
    if (![NSThread isMainThread]) {
        bool addScript = add_user_script;
        dispatch_async(dispatch_get_main_queue(), ^{
            zapp_toolbar_inject_metrics(window_ptr, host_slot, addScript);
        });
        return;
    }

    // ── Measure the toolbar row height ──────────────────────────────────────
    //
    // Collapsed → collapsedNav owns the displayed bar (if content is on top).
    // Expanded  → contentNav owns the bar.
    UINavigationController* nav = nil;
    BOOL collapsed = zapp_ios_split_is_collapsed_for_window(window_ptr);
    if (collapsed) {
        nav = zapp_ios_collapsed_nav_for_window(window_ptr);
        if (!nav) nav = zapp_ios_content_nav_for_window(window_ptr); // fallback
    } else {
        nav = zapp_ios_content_nav_for_window(window_ptr);
    }
    CGFloat toolbarH = 0;
    if (nav && !nav.navigationBarHidden) {
        toolbarH = nav.navigationBar.frame.size.height;
        if (toolbarH < 0) toolbarH = 0;
    }

    // ── Helper: build + inject the metric vars into a single webview ─────────
    //
    // For the CONTENT webview: inject all four safe-area vars + the titlebar +
    // toolbar heights. safeAreaInsets.top on the content WKWebView is the FULL
    // top inset including status bar + dynamic island + the shown nav bar, so it
    // is the authoritative source for --zapp-titlebar-height (the var used by
    // kitchen-sink .main-pane padding-top).
    //
    // For SIDEBAR / INSPECTOR webviews: inject their own safeAreaInsets (status
    // bar only on most devices; same full inset on iPhone when bar is hidden) as
    // --zapp-titlebar-height, and --zapp-toolbar-height = 0.
    //
    // toolbarH is only non-zero for the CONTENT pane (its nav bar is the source
    // of the row height); sidebar/inspector pass 0 explicitly.

    void (^injectIntoWebview)(WKWebView*, CGFloat, BOOL) =
        ^(WKWebView* wv, CGFloat tbH, BOOL addScript) {
        if (!wv) return;

        // --zapp-titlebar-height and --zapp-safe-area-* are owned by the
        // env(safe-area-inset-*) WKUserScript injected at document-start
        // in darwin_webview_create_ext (webview.m). Only --zapp-toolbar-height
        // is injected here — it holds the nav bar ROW height, which env() has
        // no equivalent for.
        NSString* js = [NSString stringWithFormat:
            @"(function(){try{var r=document.documentElement;if(r){"
            @"r.style.setProperty('--zapp-toolbar-height','%.0fpx');"
            @"}}catch(e){}})();",
            tbH];

        if (addScript) {
            [wv.configuration.userContentController addUserScript:
                [[WKUserScript alloc] initWithSource:js
                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                   forMainFrameOnly:NO]];
        }
        [wv evaluateJavaScript:js completionHandler:nil];
    };

    // ── Content webview ──────────────────────────────────────────────────────
    WKWebView* contentWv = zapp_ios_content_webview_for_slot(host_slot);
    injectIntoWebview(contentWv, toolbarH, (BOOL)add_user_script);

    // ── Sidebar pane webview ──────────────────────────────────────────────────
    // Toolbar height = 0 (no toolbar row in the sidebar column).
    int32_t sidebarSlot = zapp_ios_sidebar_slot_for(host_slot);
    if (sidebarSlot >= 0) {
        WKWebView* sidebarWv = zapp_ios_content_webview_for_slot(sidebarSlot);
        injectIntoWebview(sidebarWv, 0.0, (BOOL)add_user_script);
    }

    // ── Inspector pane webview ───────────────────────────────────────────────
    // Toolbar height = 0 (no toolbar row in the inspector column).
    int32_t inspectorSlot = zapp_ios_inspector_slot_for(host_slot);
    if (inspectorSlot >= 0) {
        WKWebView* inspectorWv = zapp_ios_content_webview_for_slot(inspectorSlot);
        injectIntoWebview(inspectorWv, 0.0, (BOOL)add_user_script);
    }
}

// ─── zapp_toolbar_unregister ─────────────────────────────────────────────────
//
// Clears the per-window toolbar registry entry.
// Mirrors darwin/toolbar.m's zapp_toolbar_unregister (registry cleanup only;
// no KVO removal needed on iOS since there's no NSWindow.contentLayoutRect).

void zapp_toolbar_unregister(void* window_ptr) {
    if (!window_ptr || !zapp_ios_toolbars) return;
    zapp_ios_toolbar_on_main(^{
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        [zapp_ios_toolbars removeObjectForKey:key];
    });
}

// ─── darwin_toolbar_attach (no-op on iOS) ───────────────────────────────────
//
// iOS uses the darwin_toolbar_set_items late-attach path exclusively.
// macOS calls this at window construction; on iOS window.m never calls it.
// Keep as a safe no-op to preserve symbol parity.

void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json, int32_t window_numeric_id) {
    (void)window_ptr; (void)toolbar_json; (void)window_numeric_id;
}
