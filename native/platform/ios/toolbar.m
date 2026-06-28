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
//   segmented/group/button.menu deferred to T2.
//   trackingSeparator dropped on iOS.
//
// T1.5 collapse-aware delivery:
//   On iPhone the split collapses to a single column (collapsedNav). T1's
//   set_items un-hid contentNav, but collapsedNav (not contentNav) is on
//   screen while collapsed → bar stayed hidden at launch.
//   Fix: set_items and the new zapp_ios_toolbar_reapply_for_window target the
//   nav that is actually displayed: collapsedNav when the split is collapsed,
//   contentNav when expanded. A UINavigationControllerDelegate on the collapsed
//   nav toggles bar visibility per visible VC (content → shown, sidebar → hidden)
//   so the bar is absent over the sidebar list.
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
// Built navigation-item buckets — stored so zapp_ios_toolbar_reapply_for_window
// can re-assign them to whichever nav is on-screen after a collapse/expand
// without the app needing to re-call setItems.
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* leadingItems;  // all leading (incl. toggleSidebar)
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* leadingNoToggle; // leading WITHOUT toggleSidebar
@property (nonatomic, strong) NSArray<UIBarButtonItem*>* trailingItems;
@property (nonatomic, strong) NSString* centerTitle;   // nil if none
@property (nonatomic, strong) UIView*   centerView;    // nil if none
// window_ptr — stored for use by the nav delegate (it only sees the nav, not
// the window pointer, so we keep it here for the re-apply lookup).
@property (nonatomic, assign) void* windowPtr;
@end

@implementation ZappIOSToolbarEntry
@end

static NSMutableDictionary<NSValue*, ZappIOSToolbarEntry*>* zapp_ios_toolbars = nil;

// ─── ZappIOSToolbarNavDelegate ───────────────────────────────────────────────
//
// UINavigationControllerDelegate attached to collapsedNav on iPhone.
// Toggles the navigation bar: visible when the content VC is on top (user
// navigated into the content column), hidden when the sidebar root VC is
// on top (avoids an empty gap over the sidebar list).
//
// The delegate is set on collapsedNav by zapp_ios_toolbar_reapply_for_window
// when the split collapses. It is removed (delegate = nil) when the split
// expands. We retain a strong reference via the registry entry's allItems
// through objc_setAssociatedObject on the collapsedNav, so the delegate
// object outlives the call site.
//
// NOTE: UINavigationController.delegate is an unowned/weak reference on older
// runtimes; we retain the delegate via associated object on the nav controller.

static const char kZappToolbarNavDelegateKey = 0;

@interface ZappIOSToolbarNavDelegate : NSObject <UINavigationControllerDelegate>
@property (nonatomic, assign) void* windowPtr;   // for re-apply lookup
@end

@implementation ZappIOSToolbarNavDelegate

// Called just before any push/pop animation completes on collapsedNav.
// Show the bar when contentVC is about to become visible; hide it when the
// sidebar root is about to become visible.
- (void)navigationController:(UINavigationController*)navigationController
      willShowViewController:(UIViewController*)viewController
                    animated:(BOOL)animated {
    (void)animated;
    if (!self.windowPtr || !zapp_ios_toolbars) {
        navigationController.navigationBarHidden = YES;
        return;
    }
    NSValue* key = [NSValue valueWithPointer:self.windowPtr];
    ZappIOSToolbarEntry* entry = zapp_ios_toolbars[key];
    if (!entry) {
        navigationController.navigationBarHidden = YES;
        return;
    }
    // Show the bar only when navigating TO a non-root VC (the content column).
    // Hide it when navigating back TO the root (the sidebar VC).
    //
    // In willShowViewController:, `viewController` is the destination VC.
    // The sidebar root is always viewControllers[0] (the first VC pushed at
    // collapse time). Compare by pointer: destination == root → hide bar;
    // destination != root (content VC pushed on top) → show bar.
    //
    // This cleanly handles both directions (push → show, pop → hide) without
    // needing a direct pointer to sidebarVC or contentVC.
    UIViewController* rootVC = navigationController.viewControllers.firstObject;
    BOOL goingToRoot = (viewController == rootVC);
    navigationController.navigationBarHidden = goingToRoot;
}

@end

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

// ─── Main-thread helper ──────────────────────────────────────────────────────

static void zapp_ios_toolbar_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// ─── inject_metrics (forward declaration) ───────────────────────────────────

void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script);

// ─── zapp_ios_toolbar_reapply_for_window (forward declaration) ───────────────
//
// Called from sidebar.m on collapse/expand transitions so a set toolbar
// survives the nav-controller switch. Must be declared here before sidebar.m
// extern-declares it below.

void zapp_ios_toolbar_reapply_for_window(void* window_ptr);

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
    vc.navigationItem.leftBarButtonItems  = leading ?: @[];
    vc.navigationItem.rightBarButtonItems = entry.trailingItems ?: @[];

    if (entry.centerTitle) {
        vc.navigationItem.title = entry.centerTitle;
        vc.navigationItem.titleView = entry.centerView; // nil clears custom view
    }

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
//   5. Delegate to zapp_ios_toolbar_reapply_for_window to pick the correct
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

        for (NSDictionary* def in items) {
            if (![def isKindOfClass:[NSDictionary class]]) continue;
            NSString* type = [def[@"type"] isKindOfClass:[NSString class]] ? def[@"type"] : @"button";
            NSString* placement = [def[@"placement"] isKindOfClass:[NSString class]]
                ? def[@"placement"] : @"leading";

            // trackingSeparator — dropped on iOS (macOS-only NSTrackingSeparatorToolbarItem).
            if ([type isEqualToString:@"trackingSeparator"]) continue;

            // segmented / group / button.menu — T2. Skip silently in T1.
            if ([type isEqualToString:@"segmented"] ||
                [type isEqualToString:@"group"]) continue;
            // button.menu check: button type with a "menu" array.
            BOOL hasMenu = [def[@"menu"] isKindOfClass:[NSArray class]] &&
                           ((NSArray*)def[@"menu"]).count > 0;
            if ([type isEqualToString:@"button"] && hasMenu) continue;

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
                // Retain the target via associated object (UIBarButtonItem.target is weak).
                objc_setAssociatedObject(item, &kZappToolbarToggleTargetKey, tgt,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                isToggleSidebar = YES;

            } else if ([type isEqualToString:@"toggleInspector"]) {
                UIImage* icon = [UIImage systemImageNamed:@"sidebar.trailing"];
                ZappIOSToolbarToggleTarget* tgt = [[ZappIOSToolbarToggleTarget alloc] init];
                tgt.windowId = host_slot;
                tgt.isSidebar = NO;
                item = [[UIBarButtonItem alloc] initWithImage:icon
                                                        style:UIBarButtonItemStylePlain
                                                       target:tgt
                                                       action:@selector(toggleTapped:)];
                objc_setAssociatedObject(item, &kZappToolbarToggleTargetKey, tgt,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
                }

            } else {
                // button (default) — requires an id.
                NSString* itemId = [def[@"id"] isKindOfClass:[NSString class]] ? def[@"id"] : nil;
                if (!itemId.length) continue;

                NSString* iconSpec = [def[@"icon"] isKindOfClass:[NSString class]] ? def[@"icon"] : @"";
                NSString* label    = [def[@"label"] isKindOfClass:[NSString class]] ? def[@"label"] : @"";
                NSNumber* enNum    = [def[@"enabled"] isKindOfClass:[NSNumber class]] ? def[@"enabled"] : nil;
                BOOL enabled = enNum ? enNum.boolValue : YES;

                ZappIOSToolbarButtonTarget* tgt = [[ZappIOSToolbarButtonTarget alloc] init];
                tgt.hostId = host_slot;
                tgt.itemId = itemId;

                UIImage* image = iconSpec.length ? zapp_ios_resolve_icon(iconSpec) : nil;
                if (image) {
                    item = [[UIBarButtonItem alloc] initWithImage:image
                                                            style:UIBarButtonItemStylePlain
                                                           target:tgt
                                                           action:@selector(buttonTapped:)];
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
            }

            if (!item) continue;

            // Bucket by placement.
            if ([placement isEqualToString:@"trailing"]) {
                [trailing addObject:item];
            } else {
                // "leading" and anything else → leading.
                [leading addObject:item];
                // leadingNoToggle omits the toggleSidebar item for iPad de-dup.
                if (!isToggleSidebar) [leadingNoToggle addObject:item];
            }
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
        entry.trailingItems   = [trailing copy];
        entry.centerTitle     = centerTitle;
        entry.centerView      = centerView;

        // Apply to the correct nav (collapsed vs expanded) and show the bar.
        // zapp_ios_toolbar_reapply_for_window reads the collapse state and picks
        // the right target nav / de-dup policy.
        zapp_ios_toolbar_reapply_for_window(window_ptr);

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

// ─── zapp_ios_toolbar_reapply_for_window ─────────────────────────────────────
//
// Called from sidebar.m's collapse/expand delegates so a set toolbar survives
// the nav-controller switch.
//
// Logic:
//   - If split is collapsed (iPhone / compact): target collapsedNav.
//       • Show bar immediately only when the content VC is on top (i.e. the nav
//         has been pushed past the sidebar root — viewControllers.count > 1).
//         When only the sidebar root is showing (count == 1), the bar stays
//         hidden to avoid an empty gap over the sidebar list.
//       • Install ZappIOSToolbarNavDelegate so future pushes/pops keep the bar
//         in sync.
//       • Use leadingItems (include manual toggleSidebar — system button absent
//         when collapsed).
//   - If split is expanded (iPad): target contentNav.
//       • Show bar unconditionally (the content column is always visible).
//       • Remove the nav delegate from any collapsedNav (it's no longer relevant).
//       • Use leadingNoToggle (omit manual toggleSidebar — UIKit provides the
//         system sidebar button automatically).
//
// Must be called on the main thread. Declared extern so sidebar.m can call it.

void zapp_ios_toolbar_reapply_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_toolbars) return;
    // Must be on main thread (UIKit constraint).
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            zapp_ios_toolbar_reapply_for_window(window_ptr);
        });
        return;
    }

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
            contentVC.navigationItem.leftBarButtonItems  = leading ?: @[];
            contentVC.navigationItem.rightBarButtonItems = entry.trailingItems ?: @[];
            if (entry.centerTitle) {
                contentVC.navigationItem.title = entry.centerTitle;
                contentVC.navigationItem.titleView = entry.centerView;
            }
        }

        // Show bar only when the content VC is on top (depth > 1 means pushed
        // past the sidebar root). Avoids an empty toolbar gap over the sidebar.
        BOOL contentOnTop = (collapsedNav.viewControllers.count > 1);
        collapsedNav.navigationBarHidden = !contentOnTop;

        // Install the nav delegate so bar visibility tracks future push/pops.
        // Check whether a delegate is already installed to avoid redundant re-add.
        id existingDelegate = collapsedNav.delegate;
        if (![existingDelegate isKindOfClass:[ZappIOSToolbarNavDelegate class]]) {
            ZappIOSToolbarNavDelegate* delegate = [[ZappIOSToolbarNavDelegate alloc] init];
            delegate.windowPtr = window_ptr;
            collapsedNav.delegate = delegate;
            // Retain the delegate via associated object (UINavigationController.delegate is weak).
            objc_setAssociatedObject(collapsedNav, &kZappToolbarNavDelegateKey, delegate,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

    } else {
        // ── Expanded path (iPad / regular) ─────────────────────────────────
        UINavigationController* contentNav = zapp_ios_content_nav_for_window(window_ptr);
        if (!contentNav) return;

        // Omit the manual toggleSidebar when expanded — UIKit auto-provides the
        // system sidebar button (displayModeButtonItem) in the content column
        // nav bar. Including ours too would create a duplicate.
        zapp_ios_toolbar_apply_to_nav(contentNav, entry, NO);

        // On expand, also clear the nav delegate from the old collapsedNav so it
        // doesn't fire stale callbacks if the nav is somehow reused.
        UINavigationController* collapsedNav = zapp_ios_collapsed_nav_for_window(window_ptr);
        if (collapsedNav) {
            id existingDelegate = collapsedNav.delegate;
            if ([existingDelegate isKindOfClass:[ZappIOSToolbarNavDelegate class]]) {
                collapsedNav.delegate = nil;
                objc_setAssociatedObject(collapsedNav, &kZappToolbarNavDelegateKey, nil,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

// ─── darwin_toolbar_update_item (stub — T2 adds the live patch) ─────────────

void darwin_toolbar_update_item(void* window_ptr, const char* item_json) {
    // T1: no-op. T2 will parse the patch and mutate the live UIBarButtonItem.
    (void)window_ptr; (void)item_json;
}

// ─── darwin_toolbar_remove (stub — T2 adds full remove) ─────────────────────

void darwin_toolbar_remove(void* window_ptr) {
    // T1: no-op. T2 will hide the bar, clear navigationItem items, drop registry.
    (void)window_ptr;
}

// ─── zapp_toolbar_inject_metrics ─────────────────────────────────────────────
//
// Mirrors darwin/toolbar.m's zapp_toolbar_inject_metrics adapted for iOS:
//   - Measures nav.navigationBar.frame.size.height (the shown bar height).
//   - Builds the CSS var JS string for --zapp-toolbar-height.
//   - Evals into the content webview.
//   - When add_user_script, adds a WKUserScript (AtDocumentStart) so
//     reloads keep the value.
//
// Sidebar/inspector pane injection is optional in T1 (mirrors the macOS
// three-slot loop; T1 only covers the content webview).

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

    // Measure height from whichever nav is currently showing the bar.
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

    NSString* js = [NSString stringWithFormat:
        @"(function(){try{var r=document.documentElement;"
        @"if(r){r.style.setProperty('--zapp-toolbar-height','%.0fpx');}}catch(e){}})();",
        toolbarH];

    WKWebView* wv = zapp_ios_content_webview_for_slot(host_slot);
    if (!wv) return;

    if (add_user_script) {
        [wv.configuration.userContentController addUserScript:
            [[WKUserScript alloc] initWithSource:js
                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                               forMainFrameOnly:NO]];
    }
    [wv evaluateJavaScript:js completionHandler:nil];
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
