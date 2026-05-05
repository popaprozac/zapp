// macOS tray / status item implementation.
//
// `NSStatusItem` lives in the menu bar at the top of the screen. Each
// item gets a button (with image + optional title), and either:
//   - a menu (NSStatusItem.menu) → system handles clicks itself, or
//   - a click target → fires events / drives an attached window.
//
// Per-tray state is keyed by a JS-supplied numeric id; the runtime
// allocates ids monotonically. Tray items survive across window opens
// and closes — they're owned by the app, not by any window.
//
// Combined mode (menu + attached window): item.menu is left UNSET so we
// retain click control. The menu is stored separately on the slot and
// shown manually on right-click via `popUpContextMenu:withEvent:forView:`.
// Left-click toggles the attached window.

#import <Cocoa/Cocoa.h>
#import "tray.h"
#import "menu.h"
#import "window.h"

extern void darwin_webview_eval_all(const char* js);

#define ZAPP_MAX_TRAYS 16

// Position kinds — must match runtime/tray.ts AttachWindowOptions.position.
typedef enum {
    ZAPP_TRAY_POS_CENTER_BELOW = 0,
    ZAPP_TRAY_POS_CENTER_ABOVE = 1,
    ZAPP_TRAY_POS_RIGHT_CENTER = 2,
} ZappTrayPositionKind;

@class ZappTrayClickTarget;

// --- Per-tray storage ---
//
// Each slot's lifetimes:
//   - `item`            — CF-retained NSStatusItem, alive until destroy.
//                          NSStatusBar does NOT keep it alive on its own
//                          (verified empirically on macOS 26.x).
//   - `menu`            — CF-retained NSMenu when a menu is configured.
//                          When no attach: also assigned to item.menu.
//                          When attach: held only here; shown manually
//                          on right-click.
//   - `attached_window` — CF-retained NSWindow we toggle on left-click.
//   - `click_target`    — strong ref via zapp_tray_strong_refs NSArray.
//   - `blur_observer`   — strong ref to the NSNotificationCenter token
//                          (via zapp_tray_strong_refs).

typedef struct {
    int32_t id;
    void* item;                     // CF-retained NSStatusItem*
    void* menu;                     // CF-retained NSMenu* (or NULL)
    void* attached_window;          // CF-retained NSWindow* (or NULL)
    ZappTrayClickTarget* __unsafe_unretained click_target;
    id __unsafe_unretained blur_observer;          // NSNotificationCenter token
    id __unsafe_unretained click_monitor_global;   // [NSEvent addGlobalMonitor...]
    id __unsafe_unretained click_monitor_local;    // [NSEvent addLocalMonitor...]
    int32_t position_kind;
    int32_t offset_x;
    int32_t offset_y;
    bool dismiss_on_blur;
    bool dismiss_on_outside_click;
    bool toggle_on_click;
} ZappTraySlot;

static ZappTraySlot zapp_trays[ZAPP_MAX_TRAYS] = {0};
static NSMutableArray* zapp_tray_strong_refs = nil;  // click targets + blur observer tokens

static inline NSStatusItem* slot_item(ZappTraySlot* slot) {
    return (__bridge NSStatusItem*)slot->item;
}

static ZappTraySlot* find_tray(int32_t id) {
    for (int i = 0; i < ZAPP_MAX_TRAYS; i++) {
        if (zapp_trays[i].item && zapp_trays[i].id == id) return &zapp_trays[i];
    }
    return NULL;
}

static ZappTraySlot* find_or_alloc_tray(int32_t id) {
    ZappTraySlot* existing = find_tray(id);
    if (existing) return existing;
    for (int i = 0; i < ZAPP_MAX_TRAYS; i++) {
        if (!zapp_trays[i].item) {
            zapp_trays[i].id = id;
            return &zapp_trays[i];
        }
    }
    return NULL;
}

// --- Forward declarations ---

static void zapp_tray_install_click_target(ZappTraySlot* slot);
static void zapp_tray_show_attached(ZappTraySlot* slot);
static void zapp_tray_hide_attached(ZappTraySlot* slot);
static void zapp_tray_install_blur_observer(ZappTraySlot* slot);
static void zapp_tray_remove_blur_observer(ZappTraySlot* slot);
static void zapp_tray_install_click_monitors(ZappTraySlot* slot);
static void zapp_tray_remove_click_monitors(ZappTraySlot* slot);
static void zapp_tray_dispatch_event(int32_t tray_id, const char* event_name);

// --- Click target ---
//
// Drives left/right click branching. Used whenever the slot is in
// click-target mode (no item.menu set). Three behaviors:
//   - left-click + attach active → toggle attached window
//   - left-click + no attach     → fire __tray:click event
//   - right-click + menu set     → show menu via popUpContextMenu:
//   - right-click + no menu      → fire __tray:right-click event

@interface ZappTrayClickTarget : NSObject {
    @public int32_t tray_id;
}
@end

@implementation ZappTrayClickTarget
- (void)trayButtonClicked:(id)sender {
    (void)sender;

    ZappTraySlot* slot = find_tray(self->tray_id);
    if (!slot) return;

    NSEvent* event = [NSApp currentEvent];
    BOOL isRight = (event.type == NSEventTypeRightMouseDown ||
                    event.type == NSEventTypeRightMouseUp ||
                    (event.type == NSEventTypeLeftMouseDown && (event.modifierFlags & NSEventModifierFlagControl)));

    if (isRight) {
        if (slot->menu) {
            // Show stored menu manually anchored to the button.
            NSMenu* menu = (__bridge NSMenu*)slot->menu;
            NSStatusItem* item = slot_item(slot);
            [NSMenu popUpContextMenu:menu withEvent:event forView:item.button];
            return;
        }
        zapp_tray_dispatch_event(self->tray_id, "__tray:right-click");
        return;
    }

    // Left click
    if (slot->attached_window) {
        NSWindow* win = (__bridge NSWindow*)slot->attached_window;
        if (slot->toggle_on_click && win.isVisible) {
            zapp_tray_hide_attached(slot);
        } else {
            zapp_tray_show_attached(slot);
        }
        return;
    }
    zapp_tray_dispatch_event(self->tray_id, "__tray:click");
}
@end

// --- Event dispatch ---

static void zapp_tray_dispatch_event(int32_t tray_id, const char* event_name) {
    int32_t tid = tray_id;
    const char* name = event_name;
    dispatch_async(dispatch_get_main_queue(), ^{
        char js[256];
        snprintf(js, sizeof(js),
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('%s','{\"id\":%d}');})();",
            name, (int)tid);
        darwin_webview_eval_all(js);
    });
}

// --- Click target install/teardown ---

static void zapp_tray_install_click_target(ZappTraySlot* slot) {
    if (!zapp_tray_strong_refs) zapp_tray_strong_refs = [NSMutableArray array];

    NSStatusItem* item = slot_item(slot);
    // Clear item.menu so we get raw click events. If a menu is configured,
    // it's still retained on the slot and shown manually on right-click.
    item.menu = nil;

    if (!slot->click_target) {
        ZappTrayClickTarget* target = [[ZappTrayClickTarget alloc] init];
        target->tray_id = slot->id;
        [zapp_tray_strong_refs addObject:target];
        slot->click_target = target;
    }
    item.button.target = slot->click_target;
    item.button.action = @selector(trayButtonClicked:);
    [item.button sendActionOn:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown];
}

// --- Position math ---
//
// Compute the top-left point (in screen coords) for the attached window,
// based on the tray button's frame and the configured position kind +
// offset. macOS coords are bottom-left origin.

static NSPoint zapp_tray_compute_top_left(ZappTraySlot* slot, NSRect buttonScreenFrame, NSSize winSize) {
    CGFloat centerX = NSMidX(buttonScreenFrame);
    CGFloat midY    = NSMidY(buttonScreenFrame);
    CGFloat offsetX = (CGFloat)slot->offset_x;
    CGFloat offsetY = (CGFloat)slot->offset_y;

    NSPoint topLeft;
    switch (slot->position_kind) {
        case ZAPP_TRAY_POS_CENTER_ABOVE:
            // Top-left sits above the button. y = top of button + winH + offsetY.
            topLeft = NSMakePoint(centerX - winSize.width / 2 + offsetX,
                                  NSMaxY(buttonScreenFrame) + winSize.height + offsetY);
            break;
        case ZAPP_TRAY_POS_RIGHT_CENTER:
            // Top-left sits to the right of the button, vertically centered.
            topLeft = NSMakePoint(NSMaxX(buttonScreenFrame) + offsetX,
                                  midY + winSize.height / 2);
            break;
        case ZAPP_TRAY_POS_CENTER_BELOW:
        default:
            // Top-left sits below the button. y = bottom of button - offsetY.
            topLeft = NSMakePoint(centerX - winSize.width / 2 + offsetX,
                                  NSMinY(buttonScreenFrame) - offsetY);
            break;
    }
    return topLeft;
}

// --- Show / hide attached window ---

static void zapp_tray_show_attached(ZappTraySlot* slot) {
    if (!slot->attached_window) return;
    NSWindow* win = (__bridge NSWindow*)slot->attached_window;
    NSStatusItem* item = slot_item(slot);
    NSStatusBarButton* button = item.button;
    NSWindow* buttonWindow = button.window;

    NSRect buttonScreenFrame = [buttonWindow convertRectToScreen:button.frame];
    NSSize winSize = win.frame.size;
    NSPoint topLeft = zapp_tray_compute_top_left(slot, buttonScreenFrame, winSize);

    // Clamp to the screen the menu bar lives on.
    NSScreen* screen = buttonWindow.screen ?: [NSScreen mainScreen];
    NSRect screenFrame = screen.visibleFrame;
    if (topLeft.x + winSize.width > NSMaxX(screenFrame)) {
        topLeft.x = NSMaxX(screenFrame) - winSize.width;
    }
    if (topLeft.x < NSMinX(screenFrame)) {
        topLeft.x = NSMinX(screenFrame);
    }

    [win setFrameTopLeftPoint:topLeft];
    [win setLevel:NSFloatingWindowLevel];
    [NSApp activateIgnoringOtherApps:YES];
    [win makeKeyAndOrderFront:nil];

    if (slot->dismiss_on_blur) {
        zapp_tray_install_blur_observer(slot);
    }
    if (slot->dismiss_on_outside_click) {
        zapp_tray_install_click_monitors(slot);
    }
}

static void zapp_tray_hide_attached(ZappTraySlot* slot) {
    if (!slot->attached_window) return;
    NSWindow* win = (__bridge NSWindow*)slot->attached_window;
    zapp_tray_remove_blur_observer(slot);
    zapp_tray_remove_click_monitors(slot);
    [win orderOut:nil];
}

// --- Blur observer ---
//
// When the attached window resigns key (user clicked elsewhere, app lost
// focus, etc.), dismiss it. The token is returned by addObserverForName:
// and must be passed back to removeObserver: to detach.

static void zapp_tray_install_blur_observer(ZappTraySlot* slot) {
    if (slot->blur_observer || !slot->attached_window) return;
    if (!zapp_tray_strong_refs) zapp_tray_strong_refs = [NSMutableArray array];

    NSWindow* win = (__bridge NSWindow*)slot->attached_window;
    int32_t tid = slot->id;
    id token = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowDidResignKeyNotification
                    object:win
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        ZappTraySlot* s = find_tray(tid);
        if (s && s->dismiss_on_blur) zapp_tray_hide_attached(s);
    }];
    slot->blur_observer = token;
    [zapp_tray_strong_refs addObject:token];
}

static void zapp_tray_remove_blur_observer(ZappTraySlot* slot) {
    if (!slot->blur_observer) return;
    [[NSNotificationCenter defaultCenter] removeObserver:slot->blur_observer];
    [zapp_tray_strong_refs removeObject:slot->blur_observer];
    slot->blur_observer = nil;
}

// --- Click-outside monitors ---
//
// Two NSEvent monitors that together cover every "click anywhere
// outside the popover" path:
//
//   - Global monitor: clicks landing in OTHER apps. Fires after the
//     event has been dispatched (we can't swallow it).
//   - Local monitor: clicks landing in OUR app. Skip clicks on the
//     popover itself (those are user input) and on the tray button
//     (the toggle handler will run instead, otherwise we'd fight it
//     by hiding then re-showing).
//
// The blur observer (windowDidResignKey) stays in place as a backup
// for cmd-tab and similar focus-only transitions.

static void zapp_tray_install_click_monitors(ZappTraySlot* slot) {
    if (!slot->attached_window) return;
    if (!zapp_tray_strong_refs) zapp_tray_strong_refs = [NSMutableArray array];

    int32_t tid = slot->id;
    NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown;

    if (!slot->click_monitor_global) {
        id g = [NSEvent addGlobalMonitorForEventsMatchingMask:mask
                                                       handler:^(NSEvent* _Nonnull event) {
            (void)event;
            ZappTraySlot* s = find_tray(tid);
            if (s && s->dismiss_on_outside_click) zapp_tray_hide_attached(s);
        }];
        slot->click_monitor_global = g;
        if (g) [zapp_tray_strong_refs addObject:g];
    }

    if (!slot->click_monitor_local) {
        id l = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                      handler:^NSEvent* _Nullable(NSEvent* _Nonnull event) {
            ZappTraySlot* s = find_tray(tid);
            if (!s || !s->attached_window) return event;
            NSWindow* popover = (__bridge NSWindow*)s->attached_window;
            NSWindow* clickWin = event.window;
            // Click inside the popover → user input, don't dismiss.
            if (clickWin == popover) return event;
            // Click on the tray button → its action will toggle us.
            // Don't dismiss here or we'd fight the toggle.
            NSStatusItem* item = slot_item(s);
            if (item && clickWin == item.button.window) return event;
            // Anything else is "outside" — dismiss.
            if (s->dismiss_on_outside_click) zapp_tray_hide_attached(s);
            return event;
        }];
        slot->click_monitor_local = l;
        if (l) [zapp_tray_strong_refs addObject:l];
    }
}

static void zapp_tray_remove_click_monitors(ZappTraySlot* slot) {
    if (slot->click_monitor_global) {
        [NSEvent removeMonitor:slot->click_monitor_global];
        [zapp_tray_strong_refs removeObject:slot->click_monitor_global];
        slot->click_monitor_global = nil;
    }
    if (slot->click_monitor_local) {
        [NSEvent removeMonitor:slot->click_monitor_local];
        [zapp_tray_strong_refs removeObject:slot->click_monitor_local];
        slot->click_monitor_local = nil;
    }
}

// --- Payload helpers ---

static NSDictionary* extract_args(const char* payload_json) {
    if (!payload_json) return @{};
    NSData* data = [[NSString stringWithUTF8String:payload_json] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return @{};
    id args = ((NSDictionary*)obj)[@"a"];
    if (![args isKindOfClass:[NSDictionary class]]) return @{};
    return (NSDictionary*)args;
}

// Apply an icon path with optional template flag. Templates auto-tint
// for light/dark mode — best UX for menu-bar icons. Falls back to a
// stock symbol if the path can't be loaded.
static void apply_icon(NSStatusItem* item, NSString* path, BOOL template_flag) {
    if (!item || path.length == 0) return;
    NSImage* img = [[NSImage alloc] initWithContentsOfFile:path];
    if (!img) {
        if (@available(macOS 11.0, *)) {
            img = [NSImage imageWithSystemSymbolName:@"questionmark.circle"
                                accessibilityDescription:nil];
        }
    }
    if (img) {
        img.size = NSMakeSize(18, 18);
        img.template = template_flag;
        item.button.image = img;
    }
}

// Build an NSMenu from the items array. Returns CF-retained pointer
// (caller must release / re-bridge to balance). Returns NULL if the
// items array is empty/missing.
static void* build_menu_ptr_from_items(NSArray* menuItems) {
    if (![menuItems isKindOfClass:[NSArray class]] || menuItems.count == 0) return NULL;
    NSData* itemsData = [NSJSONSerialization dataWithJSONObject:menuItems options:0 error:nil];
    NSString* itemsJson = itemsData
        ? [[NSString alloc] initWithData:itemsData encoding:NSUTF8StringEncoding]
        : @"[]";
    return darwin_menu_build_from_items_json([itemsJson UTF8String]);
}

// Replace whatever's currently in slot->menu with a new CF-retained
// NSMenu (or clear if menuItems is empty). Whether to surface to
// item.menu depends on whether an attach is active.
static void zapp_tray_apply_menu(ZappTraySlot* slot, NSArray* menuItems) {
    // Release prior retained menu via bridge_transfer.
    if (slot->menu) {
        NSMenu* prior = (__bridge_transfer NSMenu*)slot->menu;
        (void)prior;
        slot->menu = NULL;
    }

    void* menuPtr = build_menu_ptr_from_items(menuItems);
    if (menuPtr) {
        slot->menu = menuPtr;  // already +1 retained from build_menu_ptr_from_items
    }

    NSStatusItem* item = slot_item(slot);
    if (slot->attached_window) {
        // Combined / attach-only mode — never set item.menu (we manage clicks).
        item.menu = nil;
    } else if (slot->menu) {
        // Menu-only mode — let the system handle clicks for us.
        item.menu = (__bridge NSMenu*)slot->menu;
        // Drop click target since system handles clicks.
        item.button.target = nil;
        item.button.action = NULL;
    } else {
        // No menu, no attach — fall back to click-event mode.
        item.menu = nil;
        zapp_tray_install_click_target(slot);
    }
}

// --- Public entry points ---

void darwin_tray_create_from_payload(const char* payload_json) {
    @autoreleasepool {
        if (!zapp_tray_strong_refs) zapp_tray_strong_refs = [NSMutableArray array];

        NSDictionary* args = extract_args(payload_json);
        int32_t tid = [args[@"id"] intValue];
        if (tid < 0) return;
        if (find_tray(tid)) return;  // idempotent

        ZappTraySlot* slot = find_or_alloc_tray(tid);
        if (!slot) return;

        NSStatusItem* item = [[NSStatusBar systemStatusBar]
            statusItemWithLength:NSVariableStatusItemLength];
        slot->item = (__bridge_retained void*)item;

        NSString* iconPath = args[@"icon"];
        BOOL templateFlag = args[@"template"] ? [args[@"template"] boolValue] : YES;
        if ([iconPath isKindOfClass:[NSString class]]) apply_icon(item, iconPath, templateFlag);

        NSString* title = args[@"title"];
        if ([title isKindOfClass:[NSString class]] && title.length > 0) {
            item.button.title = title;
        }

        NSString* tooltip = args[@"tooltip"];
        if ([tooltip isKindOfClass:[NSString class]] && tooltip.length > 0) {
            item.button.toolTip = tooltip;
        }

        NSArray* menuItems = args[@"menu"];
        BOOL hasMenu = ([menuItems isKindOfClass:[NSArray class]] && menuItems.count > 0);

        if (hasMenu) {
            // Menu mode — let the system handle clicks. Stored on the
            // slot too so `attachWindow` can switch to combined mode
            // without re-receiving the menu items.
            void* menuPtr = build_menu_ptr_from_items(menuItems);
            if (menuPtr) {
                slot->menu = menuPtr;
                item.menu = (__bridge NSMenu*)slot->menu;
            }
        } else {
            // Click-event mode — wire the click target.
            zapp_tray_install_click_target(slot);
        }
    }
}

void darwin_tray_set_icon_from_payload(const char* payload_json) {
    @autoreleasepool {
        NSDictionary* args = extract_args(payload_json);
        int32_t tid = [args[@"id"] intValue];
        ZappTraySlot* slot = find_tray(tid);
        if (!slot) return;
        NSString* path = args[@"path"];
        BOOL templateFlag = args[@"template"] ? [args[@"template"] boolValue] : YES;
        if ([path isKindOfClass:[NSString class]]) apply_icon(slot_item(slot), path, templateFlag);
    }
}

void darwin_tray_set_title_from_payload(const char* payload_json) {
    @autoreleasepool {
        NSDictionary* args = extract_args(payload_json);
        int32_t tid = [args[@"id"] intValue];
        ZappTraySlot* slot = find_tray(tid);
        if (!slot) return;
        NSString* title = args[@"title"];
        slot_item(slot).button.title = ([title isKindOfClass:[NSString class]]) ? title : @"";
    }
}

void darwin_tray_set_tooltip_from_payload(const char* payload_json) {
    @autoreleasepool {
        NSDictionary* args = extract_args(payload_json);
        int32_t tid = [args[@"id"] intValue];
        ZappTraySlot* slot = find_tray(tid);
        if (!slot) return;
        NSString* tt = args[@"tooltip"];
        slot_item(slot).button.toolTip = ([tt isKindOfClass:[NSString class]]) ? tt : @"";
    }
}

void darwin_tray_set_menu_from_payload(const char* payload_json) {
    @autoreleasepool {
        NSDictionary* args = extract_args(payload_json);
        int32_t tid = [args[@"id"] intValue];
        ZappTraySlot* slot = find_tray(tid);
        if (!slot) return;
        NSArray* menuItems = args[@"items"];
        zapp_tray_apply_menu(slot, menuItems);
    }
}

void darwin_tray_attach_window_from_payload(const char* payload_json) {
    @autoreleasepool {
        NSDictionary* args = extract_args(payload_json);
        int32_t tid = [args[@"id"] intValue];
        ZappTraySlot* slot = find_tray(tid);
        if (!slot) return;

        // Runtime extracts the integer N from "win-N" before sending,
        // so we can look up directly in the dispatch table.
        NSNumber* widNum = args[@"windowId"];
        if (![widNum isKindOfClass:[NSNumber class]]) return;
        int32_t windowId = [widNum intValue];
        void* winPtr = darwin_window_get_by_numeric_id(windowId);
        if (!winPtr) return;

        // Release any prior attachment first.
        if (slot->attached_window) {
            zapp_tray_remove_blur_observer(slot);
            NSWindow* prior = (__bridge_transfer NSWindow*)slot->attached_window;
            (void)prior;
            slot->attached_window = NULL;
        }

        // Take a +1 retain on the window so it survives even if the
        // user's WindowHandle reference is dropped on the JS side.
        slot->attached_window = (__bridge_retained void*)((__bridge NSWindow*)winPtr);

        // Read config — runtime defaults applied on JS side, but be
        // defensive in case payload was hand-built.
        NSString* posStr = args[@"position"];
        if ([posStr isEqualToString:@"centerAbove"])      slot->position_kind = ZAPP_TRAY_POS_CENTER_ABOVE;
        else if ([posStr isEqualToString:@"rightCenter"]) slot->position_kind = ZAPP_TRAY_POS_RIGHT_CENTER;
        else                                              slot->position_kind = ZAPP_TRAY_POS_CENTER_BELOW;

        NSDictionary* offset = args[@"offset"];
        if ([offset isKindOfClass:[NSDictionary class]]) {
            slot->offset_x = [offset[@"x"] intValue];
            slot->offset_y = [offset[@"y"] intValue];
        } else {
            slot->offset_x = 0;
            slot->offset_y = 4;
        }

        slot->dismiss_on_blur          = args[@"dismissOnBlur"] ? [args[@"dismissOnBlur"] boolValue] : YES;
        slot->dismiss_on_outside_click = args[@"dismissOnOutsideClick"] ? [args[@"dismissOnOutsideClick"] boolValue] : YES;
        slot->toggle_on_click          = args[@"toggleOnClick"] ? [args[@"toggleOnClick"] boolValue] : YES;

        // Switch to click-target mode so we can drive the toggle from
        // left-click. Any retained menu now becomes a right-click menu.
        zapp_tray_install_click_target(slot);
    }
}

void darwin_tray_detach_window_from_payload(const char* payload_json) {
    @autoreleasepool {
        NSDictionary* args = extract_args(payload_json);
        int32_t tid = [args[@"id"] intValue];
        ZappTraySlot* slot = find_tray(tid);
        if (!slot) return;

        zapp_tray_remove_blur_observer(slot);
        zapp_tray_remove_click_monitors(slot);
        if (slot->attached_window) {
            // Hide the popover so the user doesn't end up with a
            // floating orphan after detach. Restore its level to normal
            // so future explicit `Window.show()` calls behave naturally.
            NSWindow* prior = (__bridge_transfer NSWindow*)slot->attached_window;
            slot->attached_window = NULL;
            [prior orderOut:nil];
            [prior setLevel:NSNormalWindowLevel];
        }

        // Restore prior mode: if a menu was retained, hand control
        // back to the system; else stay in click-event mode.
        NSStatusItem* item = slot_item(slot);
        if (slot->menu) {
            item.menu = (__bridge NSMenu*)slot->menu;
            item.button.target = nil;
            item.button.action = NULL;
        } else {
            // Click target stays installed — click events resume.
        }
    }
}

void darwin_tray_destroy_from_payload(const char* payload_json) {
    @autoreleasepool {
        NSDictionary* args = extract_args(payload_json);
        int32_t tid = [args[@"id"] intValue];
        ZappTraySlot* slot = find_tray(tid);
        if (!slot) return;

        zapp_tray_remove_blur_observer(slot);
        zapp_tray_remove_click_monitors(slot);
        if (slot->attached_window) {
            NSWindow* w = (__bridge_transfer NSWindow*)slot->attached_window;
            slot->attached_window = NULL;
            // Hide the popover when the tray is destroyed — it has no
            // anchor to show from anymore. App can `Window.show()` it
            // explicitly later if it has another use for the handle.
            [w orderOut:nil];
            [w setLevel:NSNormalWindowLevel];
        }
        if (slot->menu) {
            NSMenu* m = (__bridge_transfer NSMenu*)slot->menu;
            (void)m;
            slot->menu = NULL;
        }

        NSStatusItem* item = (__bridge_transfer NSStatusItem*)slot->item;
        slot->item = NULL;
        [[NSStatusBar systemStatusBar] removeStatusItem:item];

        if (slot->click_target) {
            [zapp_tray_strong_refs removeObject:slot->click_target];
            slot->click_target = nil;
        }

        slot->id = 0;
        slot->position_kind = 0;
        slot->offset_x = 0;
        slot->offset_y = 0;
        slot->dismiss_on_blur = false;
        slot->dismiss_on_outside_click = false;
        slot->toggle_on_click = false;
    }
}
