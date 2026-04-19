// macOS menu implementation — NSMenu from JSON.
// Supports: labels, accelerators, roles, separators, checkboxes, submenus, actions.

#import <Cocoa/Cocoa.h>
#import "menu.h"

// --- Menu action target ---
// When a custom menu item is clicked, dispatch its ID back to JS.

extern void darwin_webview_eval_all(const char* js);

@interface ZappMenuTarget : NSObject
@end

@implementation ZappMenuTarget
- (void)menuItemClicked:(NSMenuItem*)sender {
    NSString* itemId = [sender representedObject];
    if (!itemId || [itemId length] == 0) return;

    // Dispatch on main queue (critical for popup menus which block the run loop)
    dispatch_async(dispatch_get_main_queue(), ^{
        // Escape for JS string embedding (backslash + double quote)
        NSString* escaped = [itemId stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('__menu:click','{\"id\":\"%@\"}');})();",
            escaped];
        darwin_webview_eval_all([js UTF8String]);
    });
}
@end

static ZappMenuTarget* zapp_menu_target = nil;

static ZappMenuTarget* get_menu_target(void) {
    if (!zapp_menu_target) zapp_menu_target = [[ZappMenuTarget alloc] init];
    return zapp_menu_target;
}

// --- Accelerator parsing ---

static NSUInteger parse_modifiers(NSString* accel, NSString** key) {
    NSUInteger mods = 0;
    NSArray* parts = [accel componentsSeparatedByString:@"+"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString* part = [parts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString* lower = [part lowercaseString];
        if ([lower isEqualToString:@"cmd"] || [lower isEqualToString:@"command"] || [lower isEqualToString:@"cmdorctrl"]) {
            mods |= NSEventModifierFlagCommand;
        } else if ([lower isEqualToString:@"ctrl"] || [lower isEqualToString:@"control"]) {
            mods |= NSEventModifierFlagControl;
        } else if ([lower isEqualToString:@"alt"] || [lower isEqualToString:@"option"]) {
            mods |= NSEventModifierFlagOption;
        } else if ([lower isEqualToString:@"shift"]) {
            mods |= NSEventModifierFlagShift;
        } else {
            *key = lower;
        }
    }
    return mods;
}

// --- Role mapping ---

static SEL selector_for_role(NSString* role) {
    if ([role isEqualToString:@"copy"]) return @selector(copy:);
    if ([role isEqualToString:@"cut"]) return @selector(cut:);
    if ([role isEqualToString:@"paste"]) return @selector(paste:);
    if ([role isEqualToString:@"selectAll"]) return @selector(selectAll:);
    if ([role isEqualToString:@"undo"]) return @selector(undo:);
    if ([role isEqualToString:@"redo"]) return @selector(redo:);
    if ([role isEqualToString:@"quit"]) return @selector(terminate:);
    if ([role isEqualToString:@"hide"]) return @selector(hide:);
    if ([role isEqualToString:@"hideOthers"]) return @selector(hideOtherApplications:);
    if ([role isEqualToString:@"unhideAll"]) return @selector(unhideAllApplications:);
    if ([role isEqualToString:@"minimize"]) return @selector(performMiniaturize:);
    if ([role isEqualToString:@"zoom"]) return @selector(performZoom:);
    if ([role isEqualToString:@"close"]) return @selector(performClose:);
    if ([role isEqualToString:@"toggleFullScreen"]) return @selector(toggleFullScreen:);
    if ([role isEqualToString:@"about"]) return @selector(orderFrontStandardAboutPanel:);
    return NULL;
}

static NSMenu* build_role_edit_menu(void) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [menu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [menu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [menu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    return menu;
}

static NSMenu* build_role_window_menu(void) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Window"];
    [menu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [menu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    return menu;
}

static NSMenu* build_role_app_menu(void) {
    extern const char* app_get_bootstrap_name(void);
    const char* nameC = app_get_bootstrap_name();
    NSString* appName = nameC ? [NSString stringWithUTF8String:nameC] : @"Zapp";

    NSMenu* menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
            action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
            action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem* hideOthers = [menu addItemWithTitle:@"Hide Others"
            action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    [hideOthers setKeyEquivalentModifierMask:NSEventModifierFlagOption | NSEventModifierFlagCommand];
    [menu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
            action:@selector(terminate:) keyEquivalent:@"q"];
    return menu;
}

// --- Recursive menu builder ---

static NSMenu* build_menu_from_json(NSArray* items);

static void add_menu_item(NSMenu* menu, NSDictionary* def) {
    // Separator
    NSString* type = def[@"type"];
    if ([type isEqualToString:@"separator"]) {
        [menu addItem:[NSMenuItem separatorItem]];
        return;
    }

    // Role-based menus (full menu replacement)
    NSString* role = def[@"role"];
    if (role && !def[@"label"]) {
        if ([role isEqualToString:@"editMenu"]) {
            NSMenuItem* item = [[NSMenuItem alloc] init];
            [item setSubmenu:build_role_edit_menu()];
            [menu addItem:item];
            return;
        }
        if ([role isEqualToString:@"windowMenu"]) {
            NSMenuItem* item = [[NSMenuItem alloc] init];
            NSMenu* winMenu = build_role_window_menu();
            [item setSubmenu:winMenu];
            [menu addItem:item];
            [NSApp setWindowsMenu:winMenu];
            return;
        }
        if ([role isEqualToString:@"appMenu"]) {
            NSMenuItem* item = [[NSMenuItem alloc] init];
            [item setSubmenu:build_role_app_menu()];
            [menu addItem:item];
            return;
        }
    }

    // Regular item
    NSString* label = def[@"label"] ?: @"";
    NSString* keyEquiv = @"";
    NSUInteger modifiers = NSEventModifierFlagCommand;

    NSString* accelerator = def[@"accelerator"];
    if (accelerator) {
        NSString* key = nil;
        modifiers = parse_modifiers(accelerator, &key);
        if (key) keyEquiv = key;
    }

    // Item-level role (copy, paste, quit, etc)
    SEL action = NULL;
    if (role) {
        action = selector_for_role(role);
        // Auto-set key equivalents for standard roles (if not explicitly set)
        if (action && keyEquiv.length == 0) {
            if ([role isEqualToString:@"quit"]) { keyEquiv = @"q"; label = label.length > 0 ? label : @"Quit"; }
            else if ([role isEqualToString:@"hide"]) { keyEquiv = @"h"; label = label.length > 0 ? label : @"Hide"; }
            else if ([role isEqualToString:@"close"]) { keyEquiv = @"w"; label = label.length > 0 ? label : @"Close Window"; }
            else if ([role isEqualToString:@"minimize"]) { keyEquiv = @"m"; label = label.length > 0 ? label : @"Minimize"; }
            else if ([role isEqualToString:@"copy"]) keyEquiv = @"c";
            else if ([role isEqualToString:@"cut"]) keyEquiv = @"x";
            else if ([role isEqualToString:@"paste"]) keyEquiv = @"v";
            else if ([role isEqualToString:@"selectAll"]) keyEquiv = @"a";
            else if ([role isEqualToString:@"undo"]) keyEquiv = @"z";
            else if ([role isEqualToString:@"redo"]) keyEquiv = @"Z";
        }
    }

    NSMenuItem* item;
    if (action) {
        item = [menu addItemWithTitle:label action:action keyEquivalent:keyEquiv];
    } else {
        // Custom action — route through ZappMenuTarget
        NSString* itemId = def[@"id"];
        if (itemId && [itemId length] > 0) {
            item = [menu addItemWithTitle:label action:@selector(menuItemClicked:) keyEquivalent:keyEquiv];
            [item setTarget:get_menu_target()];
            [item setRepresentedObject:itemId];
        } else {
            item = [menu addItemWithTitle:label action:NULL keyEquivalent:keyEquiv];
        }
    }

    [item setKeyEquivalentModifierMask:modifiers];

    NSNumber* enabled = def[@"enabled"];
    if (enabled) [item setEnabled:[enabled boolValue]];

    NSNumber* checked = def[@"checked"];
    if (checked) [item setState:[checked boolValue] ? NSControlStateValueOn : NSControlStateValueOff];

    // Submenu
    NSArray* submenu = def[@"submenu"];
    if ([submenu isKindOfClass:[NSArray class]] && submenu.count > 0) {
        NSMenu* sub = build_menu_from_json(submenu);
        [sub setTitle:label];
        [item setSubmenu:sub];
    }
}

static NSMenu* build_menu_from_json(NSArray* items) {
    NSMenu* menu = [[NSMenu alloc] init];
    if (![items isKindOfClass:[NSArray class]]) return menu;
    for (NSDictionary* def in items) {
        if ([def isKindOfClass:[NSDictionary class]]) {
            add_menu_item(menu, def);
        }
    }
    return menu;
}

// --- C API ---

void darwin_menu_set(const char* items_json) {
    if (!items_json) return;
    @autoreleasepool {
        NSData* data = [[NSString stringWithUTF8String:items_json] dataUsingEncoding:NSUTF8StringEncoding];
        NSArray* items = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![items isKindOfClass:[NSArray class]]) return;

        NSMenu* mainMenu = [[NSMenu alloc] init];
        for (NSDictionary* def in items) {
            if (![def isKindOfClass:[NSDictionary class]]) continue;

            // Top-level items are menu bar entries — each needs a submenu
            NSString* label = def[@"label"] ?: @"";
            NSString* role = def[@"role"];
            NSArray* submenu = def[@"submenu"];

            NSMenuItem* barItem = [[NSMenuItem alloc] init];

            // Role-based top-level menus
            if (role) {
                if ([role isEqualToString:@"appMenu"]) {
                    [barItem setSubmenu:build_role_app_menu()];
                    [mainMenu addItem:barItem];
                    continue;
                }
                if ([role isEqualToString:@"editMenu"]) {
                    NSMenu* editMenu = build_role_edit_menu();
                    [editMenu setTitle:label.length > 0 ? label : @"Edit"];
                    [barItem setSubmenu:editMenu];
                    [mainMenu addItem:barItem];
                    continue;
                }
                if ([role isEqualToString:@"windowMenu"]) {
                    NSMenu* winMenu = build_role_window_menu();
                    [winMenu setTitle:label.length > 0 ? label : @"Window"];
                    [barItem setSubmenu:winMenu];
                    [mainMenu addItem:barItem];
                    [NSApp setWindowsMenu:winMenu];
                    continue;
                }
            }

            // Custom menu with submenu items
            if ([submenu isKindOfClass:[NSArray class]]) {
                NSMenu* sub = build_menu_from_json(submenu);
                [sub setTitle:label];
                [barItem setSubmenu:sub];
            }
            [mainMenu addItem:barItem];
        }

        [NSApp setMainMenu:mainMenu];
    }
}

void darwin_menu_show_context(const char* items_json, int32_t x, int32_t y, int32_t window_id) {
    if (!items_json) return;
    @autoreleasepool {
        NSData* data = [[NSString stringWithUTF8String:items_json] dataUsingEncoding:NSUTF8StringEncoding];
        NSArray* items = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![items isKindOfClass:[NSArray class]]) return;

        NSMenu* menu = build_menu_from_json(items);

        // Find the window's WebView to position the menu
        extern void* darwin_window_get_webview(int32_t numeric_id);
        void* wv_ptr = darwin_window_get_webview(window_id);
        if (!wv_ptr) return;

        NSView* view = (__bridge NSView*)wv_ptr;
        // CSS clientX/clientY are viewport-relative with Y growing down.
        // popUpMenuPositioningItem:atLocation:inView: uses the target view's
        // own coordinate system — if the view isn't flipped, Y grows UP from
        // the bottom, so we flip. WKWebView is a regular NSView (non-flipped)
        // even though its rendered content uses top-origin internally.
        NSPoint point = NSMakePoint((CGFloat)x, (CGFloat)y);
        if (![view isFlipped]) {
            point.y = view.bounds.size.height - point.y;
        }
        [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
    }
}

// --- Payload wrappers (extract "a" from full bridge message) ---

static NSDictionary* extract_args_dict(const char* payload_json) {
    if (!payload_json) return nil;
    NSData* data = [[NSString stringWithUTF8String:payload_json] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* full = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![full isKindOfClass:[NSDictionary class]]) return nil;
    id args = full[@"a"];
    return [args isKindOfClass:[NSDictionary class]] ? args : nil;
}

void darwin_menu_set_from_payload(const char* payload_json) {
    NSDictionary* args = extract_args_dict(payload_json);
    if (!args) return;
    NSArray* items = args[@"items"];
    if (![items isKindOfClass:[NSArray class]]) return;
    NSData* itemsData = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
    if (!itemsData) return;
    NSString* itemsStr = [[NSString alloc] initWithData:itemsData encoding:NSUTF8StringEncoding];
    darwin_menu_set([itemsStr UTF8String]);
}

void darwin_menu_show_context_from_payload(const char* payload_json, int32_t window_id) {
    NSDictionary* args = extract_args_dict(payload_json);
    if (!args) return;
    NSArray* items = args[@"items"];
    if (![items isKindOfClass:[NSArray class]]) return;
    NSData* itemsData = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
    if (!itemsData) return;
    NSString* itemsStr = [[NSString alloc] initWithData:itemsData encoding:NSUTF8StringEncoding];
    int32_t x = [args[@"x"] intValue];
    int32_t y = [args[@"y"] intValue];
    darwin_menu_show_context([itemsStr UTF8String], x, y, window_id);
}

// --- Native typed API (Zen-C → C, no JSON) ---

// Native menu target — calls a C function pointer directly, no JS bridge.
@interface ZappNativeMenuTarget : NSObject {
    @public void (*_action)(void);
}
@end

@implementation ZappNativeMenuTarget
- (void)menuItemClicked:(NSMenuItem*)sender {
    (void)sender;
    if (_action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_action();
        });
    }
}
@end

// Keep native targets alive (prevent ARC from releasing them)
static NSMutableArray* zapp_native_targets = nil;

// Role menu builders are defined above (build_role_edit_menu, build_role_window_menu, build_role_app_menu)

// Recursive menu builder from ZappMenuItem array
static void add_typed_menu_item(NSMenu* menu, ZappMenuItem* item) {
    if (!item) return;

    // Separator
    if (item->is_separator) {
        [menu addItem:[NSMenuItem separatorItem]];
        return;
    }

    NSString* role = (item->role && item->role[0] != '\0')
        ? [NSString stringWithUTF8String:item->role] : @"";

    // Role-based pre-built menus
    if ([role isEqualToString:@"editMenu"]) {
        NSMenuItem* mi = [[NSMenuItem alloc] init];
        [mi setSubmenu:build_role_edit_menu()];
        [menu addItem:mi];
        return;
    }
    if ([role isEqualToString:@"windowMenu"]) {
        NSMenuItem* mi = [[NSMenuItem alloc] init];
        [mi setSubmenu:build_role_window_menu()];
        [menu addItem:mi];
        return;
    }
    if ([role isEqualToString:@"appMenu"]) {
        NSMenuItem* mi = [[NSMenuItem alloc] init];
        [mi setSubmenu:build_role_app_menu()];
        [menu addItem:mi];
        return;
    }

    // Role-based single item (copy, paste, quit, hide, etc.)
    SEL roleSelector = selector_for_role(role);
    if (roleSelector) {
        NSString* label = (item->label && item->label[0] != '\0')
            ? [NSString stringWithUTF8String:item->label] : role;
        // Auto-set key equivalents for standard roles
        NSString* keyEq = @"";
        if ([role isEqualToString:@"quit"]) keyEq = @"q";
        else if ([role isEqualToString:@"hide"]) keyEq = @"h";
        else if ([role isEqualToString:@"close"]) keyEq = @"w";
        else if ([role isEqualToString:@"minimize"]) keyEq = @"m";
        else if ([role isEqualToString:@"copy"]) keyEq = @"c";
        else if ([role isEqualToString:@"cut"]) keyEq = @"x";
        else if ([role isEqualToString:@"paste"]) keyEq = @"v";
        else if ([role isEqualToString:@"selectAll"]) keyEq = @"a";
        else if ([role isEqualToString:@"undo"]) keyEq = @"z";
        else if ([role isEqualToString:@"redo"]) keyEq = @"Z";
        NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:label action:roleSelector keyEquivalent:keyEq];
        [menu addItem:mi];
        return;
    }

    // Regular item
    NSString* label = (item->label && item->label[0] != '\0')
        ? [NSString stringWithUTF8String:item->label] : @"";
    NSString* accel = (item->accelerator && item->accelerator[0] != '\0')
        ? [NSString stringWithUTF8String:item->accelerator] : @"";

    // Parse accelerator
    NSString* keyEquivalent = @"";
    NSEventModifierFlags modifiers = 0;
    if (accel.length > 0) {
        modifiers = parse_modifiers(accel, &keyEquivalent);
    }

    NSMenuItem* mi;
    if (item->action) {
        ZappNativeMenuTarget* target = [[ZappNativeMenuTarget alloc] init];
        target->_action = item->action;
        if (!zapp_native_targets) zapp_native_targets = [NSMutableArray new];
        [zapp_native_targets addObject:target];
        mi = [[NSMenuItem alloc] initWithTitle:label action:@selector(menuItemClicked:) keyEquivalent:keyEquivalent];
        [mi setTarget:target];
    } else {
        mi = [[NSMenuItem alloc] initWithTitle:label action:nil keyEquivalent:keyEquivalent];
    }

    if (modifiers) [mi setKeyEquivalentModifierMask:modifiers];
    [mi setEnabled:item->enabled ? YES : NO];
    if (item->checked) [mi setState:NSControlStateValueOn];

    // Submenu
    if (item->submenu && item->submenu_count > 0) {
        NSMenu* sub = [[NSMenu alloc] initWithTitle:label];
        for (int i = 0; i < item->submenu_count; i++) {
            add_typed_menu_item(sub, &item->submenu[i]);
        }
        [mi setSubmenu:sub];
    }

    [menu addItem:mi];
}

static NSMenu* build_menu_from_typed(ZappMenuItem* items, int count) {
    NSMenu* menu = [[NSMenu alloc] init];
    for (int i = 0; i < count; i++) {
        add_typed_menu_item(menu, &items[i]);
    }
    return menu;
}

void darwin_menu_set_typed(ZappMenuItem* items, int count) {
    if (!items || count <= 0) return;
    @autoreleasepool {
        // Clear previous native targets
        [zapp_native_targets removeAllObjects];

        NSMenu* mainMenu = [[NSMenu alloc] init];

        for (int i = 0; i < count; i++) {
            ZappMenuItem* item = &items[i];
            NSString* role = (item->role && item->role[0] != '\0')
                ? [NSString stringWithUTF8String:item->role] : @"";

            // Top-level role menus
            if ([role isEqualToString:@"editMenu"]) {
                NSMenuItem* mi = [[NSMenuItem alloc] init];
                [mi setSubmenu:build_role_edit_menu()];
                [mainMenu addItem:mi];
                continue;
            }
            if ([role isEqualToString:@"windowMenu"]) {
                NSMenuItem* mi = [[NSMenuItem alloc] init];
                NSMenu* wm = build_role_window_menu();
                [mi setSubmenu:wm];
                [mainMenu addItem:mi];
                [NSApp setWindowsMenu:wm];
                continue;
            }
            if ([role isEqualToString:@"appMenu"]) {
                NSMenuItem* mi = [[NSMenuItem alloc] init];
                [mi setSubmenu:build_role_app_menu()];
                [mainMenu addItem:mi];
                continue;
            }

            // Regular top-level menu with submenu
            NSString* label = (item->label && item->label[0] != '\0')
                ? [NSString stringWithUTF8String:item->label] : @"Menu";
            NSMenuItem* mi = [[NSMenuItem alloc] init];
            if (item->submenu && item->submenu_count > 0) {
                NSMenu* sub = [[NSMenu alloc] initWithTitle:label];
                for (int j = 0; j < item->submenu_count; j++) {
                    add_typed_menu_item(sub, &item->submenu[j]);
                }
                [mi setSubmenu:sub];
            }
            [mainMenu addItem:mi];
        }

        [NSApp setMainMenu:mainMenu];
    }
}

void darwin_menu_show_context_typed(ZappMenuItem* items, int count, int x, int y, int32_t window_id) {
    if (!items || count <= 0) return;
    @autoreleasepool {
        NSMenu* menu = build_menu_from_typed(items, count);

        extern void* darwin_window_get_webview(int32_t numeric_id);
        void* wv_ptr = darwin_window_get_webview(window_id);
        if (!wv_ptr) return;

        NSView* view = (__bridge NSView*)wv_ptr;
        NSPoint point = NSMakePoint((CGFloat)x, (CGFloat)y);
        if (![view isFlipped]) {
            point.y = view.bounds.size.height - point.y;
        }
        [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
    }
}
