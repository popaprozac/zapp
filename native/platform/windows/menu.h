// C API for Windows menus.
// Implementation in menu.c (Win32 HMENU).

#ifndef ZAPP_WINDOWS_MENU_H
#define ZAPP_WINDOWS_MENU_H

#include <stdbool.h>
#include <stdint.h>

// Set the app menu bar from a full bridge payload.
void windows_menu_set_from_payload(const char* payload_json);

// Show a context menu from a full bridge payload.
void windows_menu_show_context_from_payload(const char* payload_json, int32_t window_id);

// Build an HMENU from a bare items JSON array string (no envelope).
// Returns an HMENU as void* (avoids windows.h in this header), or NULL
// on parse failure. Caller owns it (DestroyMenu) unless attached to a
// window. Used by tray.c for the "menu": [...] payload key.
void* windows_menu_build_from_items_json(const char* items_json);

// --- Native typed API (called from Zen-C, no JSON) ---

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

void windows_menu_set_typed(ZappMenuItem* items, int count);
void windows_menu_show_context_typed(ZappMenuItem* items, int count, int x, int y, int32_t window_id);

#endif
