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
// Click delivery: button taps broadcast `window:toolbar-clicked`
//   {"windowId":"win-<n>","id":"<itemId>"} to ALL webviews via
//   zapp_ios_eval_js_all_webviews (mirrors darwin/toolbar.m's
//   zapp_toolbar_emit_click pattern using darwin_webview_eval_all).
//
// Per-window registry: keyed by window_ptr (NSValue), stores the
// set of built UIBarButtonItems so zapp_toolbar_unregister can clear.
//
// Main-thread contract: all UIKit mutations are dispatched to the main
// queue. zapp_toolbar_inject_metrics is declared as main-thread-only
// (matching the macOS assertion).

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <stdbool.h>
#include <objc/runtime.h>

extern WKWebView* zapp_ios_content_webview_for_slot(int32_t slot);
extern void zapp_ios_eval_js_all_webviews(const char* js);
extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
extern void darwin_sidebar_toggle(int32_t window_id);
extern void darwin_inspector_toggle(int32_t window_id);

// Defined in ios/sidebar.m — returns the content UINavigationController
// (contentNav) for the window. Nil for no-sidebar windows → set_items no-ops.
extern UINavigationController* zapp_ios_content_nav_for_window(void* window_ptr);

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
@property (nonatomic, assign) int32_t hostSlot;       // numeric window id (content slot)
@property (nonatomic, strong) NSArray* allItems;       // all UIBarButtonItems built
@end

@implementation ZappIOSToolbarEntry
@end

static NSMutableDictionary<NSValue*, ZappIOSToolbarEntry*>* zapp_ios_toolbars = nil;

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

// ─── darwin_toolbar_set_items ────────────────────────────────────────────────
//
// Mirrors darwin/toolbar.m's darwin_toolbar_set_items adapted to UIKit.
// Main path:
//   1. Resolve the content UINavigationController via
//      zapp_ios_content_nav_for_window. Nil → no-op (no-sidebar window deferred).
//   2. Parse toolbar_json (root.items array).
//   3. Bucket items into leading / center / trailing UIBarButtonItem arrays.
//   4. Assign to contentVC.navigationItem.{left,right}BarButtonItems + title/titleView.
//   5. Show the navigation bar (navigationBarHidden = NO).
//   6. Call zapp_toolbar_inject_metrics.

void darwin_toolbar_set_items(void* window_ptr, const char* toolbar_json, int32_t host_slot) {
    if (!window_ptr || !toolbar_json || !toolbar_json[0]) return;
    NSString* json = [NSString stringWithUTF8String:toolbar_json];
    zapp_ios_toolbar_on_main(^{
        UINavigationController* nav = zapp_ios_content_nav_for_window(window_ptr);
        if (!nav) {
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

        NSMutableArray<UIBarButtonItem*>* leading  = [NSMutableArray array];
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
                objc_setAssociatedObject(item, "zapp_toggle_target", tgt,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            } else if ([type isEqualToString:@"toggleInspector"]) {
                UIImage* icon = [UIImage systemImageNamed:@"sidebar.trailing"];
                ZappIOSToolbarToggleTarget* tgt = [[ZappIOSToolbarToggleTarget alloc] init];
                tgt.windowId = host_slot;
                tgt.isSidebar = NO;
                item = [[UIBarButtonItem alloc] initWithImage:icon
                                                        style:UIBarButtonItemStylePlain
                                                       target:tgt
                                                       action:@selector(toggleTapped:)];
                objc_setAssociatedObject(item, "zapp_toggle_target", tgt,
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
                objc_setAssociatedObject(item, "zapp_button_target", tgt,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }

            if (!item) continue;

            // Bucket by placement.
            if ([placement isEqualToString:@"trailing"]) {
                [trailing addObject:item];
            } else {
                // "leading" and anything else → leading.
                [leading addObject:item];
            }
            [allBuilt addObject:item];
        }

        // Apply to contentVC.navigationItem.
        UIViewController* contentVC = nav.topViewController;
        if (!contentVC) return;

        contentVC.navigationItem.leftBarButtonItems  = leading;
        contentVC.navigationItem.rightBarButtonItems = trailing;

        // Center: title or titleView.
        if (centerTitle) {
            contentVC.navigationItem.title = centerTitle;
            contentVC.navigationItem.titleView = centerView; // nil clears any custom view
        }

        // Show the navigation bar.
        nav.navigationBarHidden = NO;

        // Update the per-window registry.
        if (!zapp_ios_toolbars) zapp_ios_toolbars = [NSMutableDictionary dictionary];
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappIOSToolbarEntry* entry = zapp_ios_toolbars[key];
        if (!entry) {
            entry = [[ZappIOSToolbarEntry alloc] init];
            entry.hostSlot = host_slot;
            zapp_ios_toolbars[key] = entry;
        }
        entry.allItems = allBuilt;

        // Inject chrome metrics into the content webview (add_user_script=true
        // on first set so reloads keep the value).
        // One tick delay so UIKit finishes laying the nav bar out before we measure.
        dispatch_async(dispatch_get_main_queue(), ^{
            zapp_toolbar_inject_metrics(window_ptr, host_slot, true);
        });
    });
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

    UINavigationController* nav = zapp_ios_content_nav_for_window(window_ptr);
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
