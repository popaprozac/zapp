// Windows menu implementation — HMENU from JSON + typed API.
// Supports: labels, accelerators, separators, checkboxes, submenus, custom actions.
// Menu item clicks dispatch via WM_COMMAND → JS bridge event or native callback.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "menu.h"

// --- Forward declarations ---

extern void windows_webview_eval_all(const char* js);
extern HWND zapp_get_hwnd(int32_t window_id);

// --- Menu item ID tracking ---
// Each menu item gets a unique UINT command ID for WM_COMMAND dispatch.

#define ZAPP_MENU_ID_BASE 0x1000
#define ZAPP_MAX_MENU_ITEMS 256

typedef struct {
    UINT cmd_id;
    char js_id[128];     // JS-side item ID (for bridge events)
    void (*action)(void); // Native callback (for typed API)
} ZappMenuEntry;

static ZappMenuEntry zapp_menu_entries[ZAPP_MAX_MENU_ITEMS] = {0};
static int zapp_menu_entry_count = 0;
static UINT zapp_next_cmd_id = ZAPP_MENU_ID_BASE;

static UINT alloc_menu_id(const char* js_id, void (*action)(void)) {
    if (zapp_menu_entry_count >= ZAPP_MAX_MENU_ITEMS) return 0;
    UINT id = zapp_next_cmd_id++;
    ZappMenuEntry* e = &zapp_menu_entries[zapp_menu_entry_count++];
    e->cmd_id = id;
    if (js_id) strncpy(e->js_id, js_id, sizeof(e->js_id) - 1);
    e->action = action;
    return id;
}

static void reset_menu_entries(void) {
    zapp_menu_entry_count = 0;
    zapp_next_cmd_id = ZAPP_MENU_ID_BASE;
}

// Called from WndProc on WM_COMMAND
void zapp_handle_menu_command(UINT cmd_id) {
    for (int i = 0; i < zapp_menu_entry_count; i++) {
        if (zapp_menu_entries[i].cmd_id == cmd_id) {
            // Native callback takes priority
            if (zapp_menu_entries[i].action) {
                zapp_menu_entries[i].action();
                return;
            }
            // JS bridge dispatch
            if (zapp_menu_entries[i].js_id[0]) {
                char js[512];
                snprintf(js, sizeof(js),
                    "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
                    "if(b&&b._onEvent)b._onEvent('__menu:click','{\"id\":\"%s\"}');})();",
                    zapp_menu_entries[i].js_id);
                windows_webview_eval_all(js);
            }
            return;
        }
    }
}

// --- UTF helper ---

static wchar_t* menu_utf8_to_wchar(const char* s) {
    if (!s || !s[0]) return NULL;
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (len <= 0) return NULL;
    wchar_t* ws = (wchar_t*)malloc(len * sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, s, -1, ws, len);
    return ws;
}

// --- Minimal JSON helpers for menu parsing ---

// Simple JSON string field extraction
static const char* menu_json_str(const char* json, const char* key, char* buf, int buf_size) {
    if (!json || !key) return NULL;
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char* p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    int i = 0;
    while (*p && *p != '"' && i < buf_size - 1) {
        if (*p == '\\' && *(p+1)) { buf[i++] = *(p+1); p += 2; }
        else { buf[i++] = *p++; }
    }
    buf[i] = '\0';
    return buf;
}

// --- Typed API (called from Zen-C) ---

static HMENU build_hmenu_from_typed(ZappMenuItem* items, int count);

static void add_typed_item(HMENU menu, ZappMenuItem* item) {
    if (!item) return;

    if (item->is_separator) {
        AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
        return;
    }

    // Skip macOS-only roles (appMenu, editMenu, windowMenu, hide, hideOthers, etc.)
    if (item->role && item->role[0]) {
        const char* r = item->role;
        if (strcmp(r, "appMenu") == 0 || strcmp(r, "windowMenu") == 0 ||
            strcmp(r, "hide") == 0 || strcmp(r, "hideOthers") == 0 ||
            strcmp(r, "unhideAll") == 0 || strcmp(r, "about") == 0) {
            return; // Skip macOS-only roles
        }
        // editMenu → build standard Edit submenu
        if (strcmp(r, "editMenu") == 0) {
            // Edit menu roles are handled by WebView2 natively (Ctrl+C/V/X/A/Z)
            return;
        }
        // Role-based items: quit, close, minimize, etc.
        if (strcmp(r, "quit") == 0) {
            UINT id = alloc_menu_id("", NULL);
            wchar_t* label = menu_utf8_to_wchar(item->label && item->label[0] ? item->label : "Quit");
            AppendMenuW(menu, MF_STRING, id, label ? label : L"Quit");
            if (label) free(label);
            // The quit command will be handled specially
            zapp_menu_entries[zapp_menu_entry_count - 1].action = NULL;
            strncpy(zapp_menu_entries[zapp_menu_entry_count - 1].js_id, "__quit", 127);
            return;
        }
    }

    // Submenu
    if (item->submenu && item->submenu_count > 0) {
        HMENU sub = build_hmenu_from_typed(item->submenu, item->submenu_count);
        wchar_t* label = menu_utf8_to_wchar(item->label ? item->label : "Menu");
        AppendMenuW(menu, MF_POPUP, (UINT_PTR)sub, label ? label : L"Menu");
        if (label) free(label);
        return;
    }

    // Regular item
    UINT id = alloc_menu_id("", item->action);
    UINT flags = MF_STRING;
    if (!item->enabled) flags |= MF_GRAYED;
    if (item->checked) flags |= MF_CHECKED;

    // Build label with accelerator hint (e.g. "New Window\tCtrl+N")
    char label_buf[256];
    if (item->accelerator && item->accelerator[0]) {
        snprintf(label_buf, sizeof(label_buf), "%s\t%s",
                 item->label ? item->label : "", item->accelerator);
    } else {
        snprintf(label_buf, sizeof(label_buf), "%s", item->label ? item->label : "");
    }
    wchar_t* wlabel = menu_utf8_to_wchar(label_buf);
    AppendMenuW(menu, flags, id, wlabel ? wlabel : L"");
    if (wlabel) free(wlabel);
}

static HMENU build_hmenu_from_typed(ZappMenuItem* items, int count) {
    HMENU menu = CreatePopupMenu();
    for (int i = 0; i < count; i++) {
        add_typed_item(menu, &items[i]);
    }
    return menu;
}

void windows_menu_set_typed(ZappMenuItem* items, int count) {
    if (!items || count <= 0) return;
    reset_menu_entries();

    HMENU menubar = CreateMenu();

    for (int i = 0; i < count; i++) {
        ZappMenuItem* item = &items[i];

        // Skip macOS-only top-level roles
        if (item->role && item->role[0]) {
            const char* r = item->role;
            if (strcmp(r, "appMenu") == 0 || strcmp(r, "editMenu") == 0 ||
                strcmp(r, "windowMenu") == 0) {
                continue;
            }
        }

        if (item->submenu && item->submenu_count > 0) {
            HMENU sub = build_hmenu_from_typed(item->submenu, item->submenu_count);
            wchar_t* label = menu_utf8_to_wchar(item->label ? item->label : "Menu");
            AppendMenuW(menubar, MF_POPUP, (UINT_PTR)sub, label ? label : L"Menu");
            if (label) free(label);
        }
    }

    // Set menu on all windows
    for (int i = 0; i < 64; i++) {
        HWND hwnd = zapp_get_hwnd(i);
        if (hwnd) SetMenu(hwnd, menubar);
    }
}

void windows_menu_show_context_typed(ZappMenuItem* items, int count, int x, int y, int32_t window_id) {
    if (!items || count <= 0) return;

    HMENU menu = build_hmenu_from_typed(items, count);
    HWND hwnd = zapp_get_hwnd(window_id);
    if (!hwnd) { DestroyMenu(menu); return; }

    // Convert client coords to screen coords
    POINT pt = { x, y };
    ClientToScreen(hwnd, &pt);
    TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_TOPALIGN, pt.x, pt.y, 0, hwnd, NULL);
    DestroyMenu(menu);
}

// --- JSON API (from JS bridge) ---

void windows_menu_set_from_payload(const char* payload_json) {
    // For now, JS menus are handled via the typed API path
    // Full JSON parsing would be needed for complete parity
    // The typed API covers native Zen-C menus
    (void)payload_json;
}

void windows_menu_show_context_from_payload(const char* payload_json, int32_t window_id) {
    (void)payload_json;
    (void)window_id;
}
