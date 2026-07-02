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
//   contentNav when expanded. Bar visibility in collapsed mode is set directly:
//   shown when the content VC is on top (count > 1), hidden at the sidebar root.
//   iPad de-dup: when the split is expanded/regular, UIKit auto-provides a
//   system sidebar button in the nav bar; we omit our manual toggleSidebar item
//   to avoid a duplicate. When collapsed/compact, no system button exists so we
//   include ours.
//
// Click delivery: button taps broadcast `window:toolbar-clicked`
//   {"windowId":"win-<n>","id":"<itemId>"} to ALL webviews via
//   zapp_ios_eval_js_all_webviews (mirrors darwin/toolbar.m's
//   zapp_toolbar_emit_click pattern using darwin_webview_eval_all).
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

extern WKWebView* zapp_ios_content_webview_for_slot(int32_t slot);
extern void zapp_ios_eval_js_all_webviews(const char* js);
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

// Returns YES when the sidebar is HIDDEN on iPad (displayMode == SecondaryOnly).
// Returns NO for collapsed (iPhone), no sidebar, or sidebar visible.
// Used by the expanded toolbar path to decide whether to include our manual
// toggleSidebar button: include when sidebar is visible (UIKit adds none);
// omit when hidden (UIKit's own system button is the affordance).
extern BOOL zapp_ios_sidebar_is_hidden_for_window(void* window_ptr);

// T2 (double-toggle race fix): live read of the split's CURRENT displayMode —
// NOT a transition target. Returns true only when displayMode ==
// SecondaryOnly (sidebar hidden); false when collapsed, unregistered, or no
// split. Defined in ios/sidebar.m. Used by
// zapp_ios_toolbar_apply_for_window_hidden's expanded path so the
// include-toggle decision is single-sourced from live state AT APPLY TIME,
// instead of trusting the caller-supplied `sidebarHidden` parameter — which
// may be a stale transition TARGET passed from willChangeToDisplayMode:
// (pre-settle), the root cause of both-toggles-visible / neither-visible
// under overlapping transitions (rapid toggle, rotation mid-toggle).
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

// Forward declaration — defined later.
void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script);

// N3a: inject the --zapp-* safe-area vars into a SINGLE arbitrary webview — a
// pushed route VC's webview, which is NOT a registered pane slot, so
// zapp_toolbar_inject_metrics (which only reaches zapp_ios_content_webview_for_slot)
// never touches it → it would otherwise render with 0px insets. titlebar =
// the webview's own safeAreaInsets.top (status bar + dynamic island + nav bar);
// toolbar row = 0 (route pages have no zapp-toolbar row). Must run AFTER the VC
// is laid out so safeAreaInsets is valid — routing.m calls it from the route
// VC's viewDidLayoutSubviews (idempotent; re-runs on rotation/resize).
void zapp_ios_toolbar_inject_webview_safe_area(WKWebView* wv) {
    // N3b: No-op — the env(safe-area-inset-*) WKUserScript injected at
    // document-start by darwin_webview_create_ext (webview.m) sets
    // --zapp-titlebar-height and --zapp-safe-area-* correctly at the
    // first paint. UIKit resolves env() before the first frame when the
    // webview is edge-pinned and viewport-fit=cover is present.
    // This deferred native injection is no longer needed or safe (it
    // reads stale safeAreaInsets during mid-push layout).
    (void)wv;
}

// ─── Click emit ─────────────────────────────────────────────────────────────
//
// Mirrors zapp_toolbar_emit_click in darwin/toolbar.m.
// Builds {"windowId":"win-<N>","id":"<itemId>"} and broadcasts via
// zapp_ios_eval_js_all_webviews (iOS analogue of darwin_webview_eval_all +
// worker_broadcast_eval_js).
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
        zapp_ios_eval_js_all_webviews([js UTF8String]);
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
        zapp_ios_eval_js_all_webviews([js UTF8String]);
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
// runtime; ids present). Taps emit __menu:click {"id":"<id>"} via
// zapp_ios_eval_js_all_webviews — mirrors darwin/toolbar.m's
// zapp_toolbar_emit_menu_click, which uses the SAME event name/__menu:click
// because NSMenuToolbarItem clicks route through darwin_menu_build_from_items_json
// and menu.m emits __menu:click.
//
// Recursion: items with a "submenu" array build a nested UIMenu.
// Separator items (type:"separator") build UIAction dividers (iOS 14+: use
// a UIMenuElement that acts as a standalone-display divider by creating an
// empty titled UIMenu as an inline section divider).
// checked / radioGroup: UIAction.state (.on / .off) for checkmarks.
// enabled: UIAction.attributes = .disabled when false.
// iOS 14+ required for UIMenu on UIBarButtonItem; this is the iOS 14+ API.
//
// Note: `host_id` is unused here (macOS zapp_toolbar_emit_menu_click ignores
// it too — __menu:click is window-agnostic by design).

API_AVAILABLE(ios(14.0))
static NSArray<UIMenuElement*>* zapp_ios_build_menu_elements(NSArray* items);

API_AVAILABLE(ios(14.0))
static NSArray<UIMenuElement*>* zapp_ios_build_menu_elements(NSArray* items) {
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
            NSArray<UIMenuElement*>* children = zapp_ios_build_menu_elements(submenu);
            UIMenu* sub = [UIMenu menuWithTitle:label children:children];
            [elements addObject:sub];
            continue;
        }

        // Leaf item → UIAction.
        NSString* capturedId = itemId;
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
            zapp_ios_eval_js_all_webviews([js UTF8String]);
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
static UIMenu* zapp_ios_build_uimenu(NSArray* items) {
    NSArray<UIMenuElement*>* children = zapp_ios_build_menu_elements(items);
    return [UIMenu menuWithTitle:@"" children:children];
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

    NSArray<UIBarButtonItem*>* leading = includeToggleSidebar
        ? entry.leadingItems
        : entry.leadingNoToggle;
    // Keep the system back button when items are stamped onto a pushed VC.
    // Without this, assigning leftBarButtonItems replaces UIKit's automatic
    // back button (UIKit doc: a non-nil leftBarButtonItems suppresses it).
    vc.navigationItem.leftItemsSupplementBackButton = YES;
    vc.navigationItem.leftBarButtonItems  = leading ?: @[];
    vc.navigationItem.rightBarButtonItems = entry.trailingItems ?: @[];

    // E2 (collapsible affordance parity): grey our toggleSidebar button when
    // the sidebar is non-collapsible — macOS greys its system toggle via
    // AppKit validation; UIKit has no validation pass, so set enabled here,
    // from the same live-at-apply-time state family as the inclusion read
    // (zapp_ios_split_display_mode_is_secondary_only). Inclusion and
    // enablement are orthogonal: inclusion de-dups against UIKit's system
    // reveal button; enabled gates interactivity when ours IS shown.
    // nil-safe: no toggle item, or no sidebar registered (helper returns
    // true), leaves everything as-is.
    entry.toggleSidebarButton.enabled =
        zapp_ios_sidebar_is_collapsible_for_window(entry.windowPtr);

    // #779 (inspector collapsible affordance parity): same mechanism, sibling
    // button — grey our toggleInspector button when the inspector is
    // non-collapsible. toggleInspector has no inclusion/de-dup logic (no
    // system inspector-reveal button to collide with), so this is the only
    // gate on it. nil-safe: no toggle item, or no inspector registered
    // (helper returns true), leaves everything as-is.
    entry.toggleInspectorButton.enabled =
        zapp_ios_inspector_is_collapsible_for_window(entry.windowPtr);

    vc.navigationItem.title = entry.centerTitle;       // nil clears it
    vc.navigationItem.titleView = entry.centerView;    // nil clears it

    nav.navigationBarHidden = NO;
}

// ─── darwin_toolbar_set_items ────────────────────────────────────────────────
//
// Mirrors darwin/toolbar.m's darwin_toolbar_set_items adapted to UIKit.
// Main path:
//   1. Resolve the content UINavigationController via
//      zapp_ios_content_nav_for_window. Nil → no-op (no-sidebar window deferred).
//   2. Parse toolbar_json (root.items array).
//   3. Bucket items into leading / center / trailing UIBarButtonItem arrays.
//      Separate leading into: leadingItems (full, with toggleSidebar) and
//      leadingNoToggle (without toggleSidebar, for expanded/iPad de-dup).
//   4. Store buckets in the registry entry.
//   5. Delegate to zapp_ios_toolbar_apply_for_window to pick the correct
//      nav controller (collapsed vs expanded) and apply items there.
//   6. Call zapp_toolbar_inject_metrics.

void darwin_toolbar_set_items(void* window_ptr, const char* toolbar_json, int32_t host_slot) {
    if (!window_ptr || !toolbar_json || !toolbar_json[0]) return;
    NSString* json = [NSString stringWithUTF8String:toolbar_json];
    zapp_ios_toolbar_on_main(^{
        UINavigationController* contentNav = zapp_ios_content_nav_for_window(window_ptr);
        if (!contentNav) {
            // No-sidebar window: deferred (T1 decision). Safe no-op.
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

        NSMutableArray<UIBarButtonItem*>* leading        = [NSMutableArray array];
        NSMutableArray<UIBarButtonItem*>* leadingNoToggle = [NSMutableArray array];
        // center: title string or titleView UILabel (only the last one wins).
        NSString* centerTitle = nil;
        UIView*   centerView  = nil;
        NSMutableArray<UIBarButtonItem*>* trailing = [NSMutableArray array];
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

            // Determine the target bucket once.
            NSMutableArray<UIBarButtonItem*>* bucket =
                [placement isEqualToString:@"trailing"] ? trailing : leading;
            NSMutableArray<UIBarButtonItem*>* bucketNoToggle =
                [placement isEqualToString:@"trailing"] ? trailing : leadingNoToggle;

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
                [bucketNoToggle addObject:wrapperItem];
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
                    [bucketNoToggle addObject:subItem];
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
                    UIMenu* menu = zapp_ios_build_uimenu(menuArr);
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
                    [bucketNoToggle addObject:item];
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
                zapp_ios_toolbar_apply_to_nav(applyNav, entry, !sidebarHidden);
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
//       • Use leadingNoToggle (omit manual toggleSidebar — UIKit provides the
//         system sidebar button automatically).
//
// Must be called on the main thread. Declared extern so sidebar.m can call it.

// ─── zapp_ios_toolbar_apply_for_window_hidden ─────────────────────────────────
//
// Applies a registered toolbar to the correct nav (collapsed vs expanded).
//
// T2 (double-toggle race fix): `sidebarHidden` is now ADVISORY ONLY. It used
// to be trusted verbatim in the expanded path, but willChangeToDisplayMode:
// passes the transition TARGET, not settled state — under overlapping
// transitions (rapid toggle, rotation mid-toggle) that value can go stale,
// producing either two visible toggles (ours + UIKit's system reveal button)
// or zero. The expanded path now single-sources the include-toggle decision
// from a LIVE read of the split's CURRENT displayMode
// (zapp_ios_split_display_mode_is_secondary_only, ios/sidebar.m) taken at
// apply time. The parameter is kept only for ABI/call-site compatibility —
// callers may still pass the transition target as a pre-settle hint.
//
// Collapsed (iPhone compact): apply items to the content VC's navigationItem
//   (so they appear when the content VC is on top of collapsedNav), and show
//   the bar only when the content VC is on top. (Collapsed has no displayMode
//   concept — UIKit never shows a system reveal button there — so this path
//   is unaffected by the live-read change.)
// Expanded (iPad regular): apply to contentNav's topViewController, show bar.
//   includeToggleSidebar = live read of !(displayMode == SecondaryOnly).
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
            NSArray<UIBarButtonItem*>* leading = entry.leadingItems; // include toggleSidebar
            contentVC.navigationItem.leftItemsSupplementBackButton = YES;
            contentVC.navigationItem.leftBarButtonItems  = leading ?: @[];
            contentVC.navigationItem.rightBarButtonItems = entry.trailingItems ?: @[];
            // E2: same collapsible→enabled wiring as zapp_ios_toolbar_apply_to_nav
            // (this path assigns items directly, bypassing that helper). The
            // collapsed path always includes the toggle, so the disabled render
            // is the only non-collapsible affordance cue on iPhone.
            entry.toggleSidebarButton.enabled =
                zapp_ios_sidebar_is_collapsible_for_window(window_ptr);
            // #779: same collapsible→enabled wiring, sibling button — the
            // collapsed path applies items directly, bypassing apply_to_nav.
            entry.toggleInspectorButton.enabled =
                zapp_ios_inspector_is_collapsible_for_window(window_ptr);
            contentVC.navigationItem.title = entry.centerTitle;       // nil clears it
            contentVC.navigationItem.titleView = entry.centerView;    // nil clears it
        }

        // Show bar only when the content VC is on top (depth > 1 means pushed
        // past the sidebar root). Avoids an empty toolbar gap over the sidebar.
        BOOL contentOnTop = (collapsedNav.viewControllers.count > 1);
        collapsedNav.navigationBarHidden = !contentOnTop;

    } else {
        // ── Expanded path (iPad / regular) ─────────────────────────────────
        UINavigationController* contentNav = zapp_ios_content_nav_for_window(window_ptr);
        if (!contentNav) return;

        // Include our manual toggleSidebar button ONLY when the sidebar is
        // VISIBLE. When the sidebar is visible, UIKit adds no system button, so
        // ours is the only affordance. When the sidebar is HIDDEN, UIKit shows
        // its own "show sidebar" system button — omit ours to avoid a duplicate.
        //
        // T2: the `sidebarHidden` PARAMETER may be a transition TARGET passed
        // from willChangeToDisplayMode: (pre-settle) — trusting it verbatim is
        // what caused the double-toggle race under overlapping transitions.
        // UIKit's own system reveal button is driven by the split's ACTUAL
        // displayMode, so decide from a LIVE read here too; the settled
        // re-apply (sidebar.m's willChangeToDisplayMode: hook, hopped one tick
        // via dispatch_async) issues the final word once displayMode has
        // actually committed to the target.
        BOOL includeToggle = !zapp_ios_split_display_mode_is_secondary_only(window_ptr);
        (void)sidebarHidden; // advisory only — kept for ABI/call-site compatibility
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
            UIMenu* menu = zapp_ios_build_uimenu(patch[@"menu"]);
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
                collapsedNav.navigationBarHidden = YES;
                // Clear items on the content VC's navigationItem.
                UIViewController* contentVC = zapp_ios_content_vc_for_window(window_ptr);
                if (contentVC) {
                    contentVC.navigationItem.leftItemsSupplementBackButton = YES;
                    contentVC.navigationItem.leftBarButtonItems  = @[];
                    contentVC.navigationItem.rightBarButtonItems = @[];
                    contentVC.navigationItem.title     = nil;
                    contentVC.navigationItem.titleView = nil;
                }
                // Clear the nav delegate (no toolbar → no bar visibility management).
                collapsedNav.delegate = nil;
            }
        } else {
            // ── Expanded (iPad) ───────────────────────────────────────────
            UINavigationController* contentNav = zapp_ios_content_nav_for_window(window_ptr);
            if (contentNav) {
                contentNav.navigationBarHidden = YES;
                UIViewController* vc = contentNav.topViewController;
                if (vc) {
                    vc.navigationItem.leftItemsSupplementBackButton = YES;
                    vc.navigationItem.leftBarButtonItems  = @[];
                    vc.navigationItem.rightBarButtonItems = @[];
                    vc.navigationItem.title     = nil;
                    vc.navigationItem.titleView = nil;
                }
            }
        }

        // Drop the registry entry before re-injecting metrics so that
        // inject_metrics measures a hidden bar (height → 0).
        [zapp_ios_toolbars removeObjectForKey:key];

        // Re-inject --zapp-toolbar-height: 0 and --zapp-titlebar-height: 0
        // (one tick so UIKit hides the bar first). Clear all pane webviews.
        // Entry is gone so we can't call inject_metrics — build the JS inline.
        int32_t sidebarSlot   = zapp_ios_sidebar_slot_for(slot);
        int32_t inspectorSlot = zapp_ios_inspector_slot_for(slot);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString* js = @"(function(){try{var r=document.documentElement;if(r){"
                            "r.style.setProperty('--zapp-titlebar-height','0px');"
                            "r.style.setProperty('--zapp-toolbar-height','0px');"
                            "r.style.setProperty('--zapp-safe-area-top','0px');"
                            "r.style.setProperty('--zapp-safe-area-left','0px');"
                            "r.style.setProperty('--zapp-safe-area-right','0px');"
                            "r.style.setProperty('--zapp-safe-area-bottom','0px');"
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
