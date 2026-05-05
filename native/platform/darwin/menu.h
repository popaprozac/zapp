// C API for macOS menus.
// Implementation in menu.m (Objective-C).

#ifndef ZAPP_DARWIN_MENU_H
#define ZAPP_DARWIN_MENU_H

#include <stdbool.h>
#include <stdint.h>

// Set the app menu bar from a JSON items array.
void darwin_menu_set(const char* items_json);

// Set the app menu bar from a full bridge payload (extracts "a.items").
void darwin_menu_set_from_payload(const char* payload_json);

// Show a context menu at the given position.
void darwin_menu_show_context(const char* items_json, int32_t x, int32_t y, int32_t window_id);

// Show a context menu from a full bridge payload (extracts "a.items", "a.x", "a.y").
void darwin_menu_show_context_from_payload(const char* payload_json, int32_t window_id);

// Build an NSMenu from a JSON items array (the same array shape
// `darwin_menu_set` consumes). Returns `void*` so the header stays
// pure C; callers bridge-cast to `NSMenu*`. Used by tray.m to mount
// menus on NSStatusItem instances. Returns NULL on parse failure.
// The returned NSMenu is autoreleased — caller must retain to keep
// it alive (e.g. via NSStatusItem.menu = ...).
void* darwin_menu_build_from_items_json(const char* items_json);

// --- Native typed API (called from Zen-C, no JSON) ---

// ZappMenuItem must match the MenuItem struct layout in menu.zc
typedef struct ZappMenuItem {
    char* label;
    char* accelerator;
    char* role;
    int is_separator;
    int enabled;
    int checked;
    struct ZappMenuItem* submenu;
    int submenu_count;
    void (*action)(void);
} ZappMenuItem;

void darwin_menu_set_typed(ZappMenuItem* items, int count);
void darwin_menu_show_context_typed(ZappMenuItem* items, int count, int x, int y, int32_t window_id);

#endif
