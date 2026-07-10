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
            // The quit role quits natively (honoring the quit guard) —
            // dispatching it as a JS __menu:click went nowhere because
            // no JS handler owns "__quit".
            if (strcmp(zapp_menu_entries[i].js_id, "__quit") == 0) {
                extern void windows_app_quit(bool force);
                windows_app_quit(false);
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

// Screen point for a JS (CSS px) position in a window's webview. Anchors to the
// webview's ACTUAL parent HWND — in paned windows that's the offset content/
// sidebar/inspector child, not the top-level host — then scales CSS->device px
// by that window's DPI and maps to screen. Without this, a context menu fired
// in a pane lands shifted by the pane's offset (e.g. the sidebar width). Falls
// back to the host if the controller isn't ready. (Windows analogue of the
// macOS "anchor the menu to the pane view" fix.)
static POINT zapp_menu_screen_point(int32_t window_id, int x, int y, HWND host) {
    extern void* windows_webview_parent_hwnd(int32_t);
    HWND anchor = (HWND)windows_webview_parent_hwnd(window_id);
    if (!anchor) anchor = host;
    UINT dpi = GetDpiForWindow(anchor);
    POINT pt = { MulDiv(x, (int)dpi, 96), MulDiv(y, (int)dpi, 96) };
    ClientToScreen(anchor, &pt);
    return pt;
}

void windows_menu_show_context_typed(ZappMenuItem* items, int count, int x, int y, int32_t window_id) {
    if (!items || count <= 0) return;

    HMENU menu = build_hmenu_from_typed(items, count);
    HWND hwnd = zapp_get_hwnd(window_id);
    if (!hwnd) { DestroyMenu(menu); return; }

    // Anchor to the firing webview's parent (offset-correct in paned windows).
    POINT pt = zapp_menu_screen_point(window_id, x, y, hwnd);
    TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_TOPALIGN, pt.x, pt.y, 0, hwnd, NULL);
    DestroyMenu(menu);
}

// --- JSON API (from JS bridge) ---
//
// Payload shape (the bridge envelope; we walk to a.items):
//   { t, m, a: { items: [ { id?, label?, type?, enabled?, checked?,
//                           accelerator?, role?, submenu? } ], x?, y? } }
// A small cursor-based walker — not a general JSON parser, but a
// correct one for this grammar (handles nesting, string escapes, and
// skips unknown keys/values), unlike the strstr-pattern helpers above
// which can't cope with nested arrays.

typedef struct { const char* p; } MenuCursor;

static void mc_ws(MenuCursor* c) {
    while (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r') c->p++;
}

// Parse a JSON string (cursor on the opening quote) into buf.
// Advances past the closing quote. Returns 0 on malformed input.
static int mc_string(MenuCursor* c, char* buf, size_t buf_size) {
    if (*c->p != '"') return 0;
    c->p++;
    size_t i = 0;
    while (*c->p && *c->p != '"') {
        char ch = *c->p;
        if (ch == '\\' && c->p[1]) {
            c->p++;
            char esc = *c->p;
            switch (esc) {
                case 'n': ch = '\n'; break;
                case 't': ch = '\t'; break;
                case 'r': ch = '\r'; break;
                case 'b': ch = '\b'; break;
                case 'f': ch = '\f'; break;
                case 'u':
                    // Keep it simple: skip the 4 hex digits, emit '?'.
                    // Menu labels are UTF-8 in the wire format; \u only
                    // shows up for exotic producers.
                    if (c->p[1] && c->p[2] && c->p[3] && c->p[4]) c->p += 4;
                    ch = '?';
                    break;
                default: ch = esc; break;
            }
        }
        if (i + 1 < buf_size) buf[i++] = ch;
        c->p++;
    }
    if (*c->p != '"') return 0;
    c->p++;
    buf[i] = '\0';
    return 1;
}

// Skip any JSON value (cursor on its first char).
static void mc_skip_value(MenuCursor* c) {
    mc_ws(c);
    if (*c->p == '"') {
        char tmp[2];
        // mc_string truncates into tmp but still consumes correctly.
        mc_string(c, tmp, sizeof(tmp));
        return;
    }
    if (*c->p == '{' || *c->p == '[') {
        char open = *c->p;
        char close = (open == '{') ? '}' : ']';
        int depth = 0;
        while (*c->p) {
            if (*c->p == '"') { char tmp[2]; mc_string(c, tmp, sizeof(tmp)); continue; }
            if (*c->p == open) depth++;
            else if (*c->p == close) {
                depth--;
                if (depth == 0) { c->p++; return; }
            }
            c->p++;
        }
        return;
    }
    // number / true / false / null
    while (*c->p && *c->p != ',' && *c->p != '}' && *c->p != ']') c->p++;
}

static HMENU build_hmenu_from_json_array(MenuCursor* c);

// Parse one item object (cursor on '{') and append it to `menu`.
static int append_json_item(HMENU menu, MenuCursor* c) {
    if (*c->p != '{') return 0;
    c->p++;

    char id[128] = "";
    char label[256] = "";
    char type[32] = "";
    char accelerator[64] = "";
    char role[32] = "";
    int enabled = 1;
    int checked = 0;
    HMENU submenu = NULL;

    mc_ws(c);
    while (*c->p && *c->p != '}') {
        char key[64];
        if (!mc_string(c, key, sizeof(key))) return 0;
        mc_ws(c);
        if (*c->p != ':') return 0;
        c->p++;
        mc_ws(c);

        if (strcmp(key, "id") == 0 && *c->p == '"') mc_string(c, id, sizeof(id));
        else if (strcmp(key, "label") == 0 && *c->p == '"') mc_string(c, label, sizeof(label));
        else if (strcmp(key, "type") == 0 && *c->p == '"') mc_string(c, type, sizeof(type));
        else if (strcmp(key, "accelerator") == 0 && *c->p == '"') mc_string(c, accelerator, sizeof(accelerator));
        else if (strcmp(key, "role") == 0 && *c->p == '"') mc_string(c, role, sizeof(role));
        else if (strcmp(key, "enabled") == 0) { enabled = strncmp(c->p, "false", 5) != 0; mc_skip_value(c); }
        else if (strcmp(key, "checked") == 0) { checked = strncmp(c->p, "true", 4) == 0; mc_skip_value(c); }
        else if (strcmp(key, "submenu") == 0 && *c->p == '[') submenu = build_hmenu_from_json_array(c);
        else mc_skip_value(c);

        mc_ws(c);
        if (*c->p == ',') { c->p++; mc_ws(c); }
    }
    if (*c->p != '}') { if (submenu) DestroyMenu(submenu); return 0; }
    c->p++;

    // --- Append to menu (same role policy as the typed path) ---
    if (strcmp(type, "separator") == 0) {
        if (submenu) DestroyMenu(submenu);
        AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
        return 1;
    }
    if (role[0]) {
        if (strcmp(role, "appMenu") == 0 || strcmp(role, "windowMenu") == 0 ||
            strcmp(role, "editMenu") == 0) {
            // macOS-only chrome / WebView2-native edit handling.
            if (submenu) DestroyMenu(submenu);
            return 1;
        }
        if (strcmp(role, "quit") == 0) {
            if (submenu) DestroyMenu(submenu);
            UINT qid = alloc_menu_id("__quit", NULL);
            wchar_t* wl = menu_utf8_to_wchar(label[0] ? label : "Quit");
            AppendMenuW(menu, MF_STRING, qid, wl ? wl : L"Quit");
            if (wl) free(wl);
            return 1;
        }
        // copy/cut/paste/selectAll/undo/redo — WebView2 handles the
        // keyboard forms natively; menu-driven forms are a follow-up.
        if (submenu) DestroyMenu(submenu);
        return 1;
    }
    if (submenu) {
        wchar_t* wl = menu_utf8_to_wchar(label[0] ? label : "Menu");
        AppendMenuW(menu, MF_POPUP, (UINT_PTR)submenu, wl ? wl : L"Menu");
        if (wl) free(wl);
        return 1;
    }

    UINT cmd = alloc_menu_id(id, NULL);
    UINT flags = MF_STRING;
    if (!enabled) flags |= MF_GRAYED;
    if (checked) flags |= MF_CHECKED;
    char label_buf[336];
    if (accelerator[0]) snprintf(label_buf, sizeof(label_buf), "%s\t%s", label, accelerator);
    else snprintf(label_buf, sizeof(label_buf), "%s", label);
    wchar_t* wl = menu_utf8_to_wchar(label_buf);
    AppendMenuW(menu, flags, cmd, wl ? wl : L"");
    if (wl) free(wl);
    return 1;
}

// Cursor on '[' — builds the HMENU and advances past the closing ']'.
static HMENU build_hmenu_from_json_array(MenuCursor* c) {
    if (*c->p != '[') return NULL;
    c->p++;
    HMENU menu = CreatePopupMenu();
    mc_ws(c);
    while (*c->p && *c->p != ']') {
        if (!append_json_item(menu, c)) { DestroyMenu(menu); return NULL; }
        mc_ws(c);
        if (*c->p == ',') { c->p++; mc_ws(c); }
    }
    if (*c->p == ']') c->p++;
    return menu;
}

// Find `"items":` inside the payload's args and return a cursor on the
// '[' (or NULL). The envelope nests it as {a:{items:[...]}} — items
// only appears once.
static const char* menu_find_items_array(const char* payload_json) {
    if (!payload_json) return NULL;
    const char* p = strstr(payload_json, "\"items\":");
    if (!p) return NULL;
    p += strlen("\"items\":");
    while (*p == ' ' || *p == '\t') p++;
    return (*p == '[') ? p : NULL;
}

// Shared with tray.c: build an HMENU directly from an items JSON array
// string (the tray payload carries "menu": [...]). void* in the
// signature to keep windows.h out of menu.h.
void* windows_menu_build_from_items_json(const char* items_json) {
    if (!items_json) return NULL;
    MenuCursor c = { items_json };
    mc_ws(&c);
    return (void*)build_hmenu_from_json_array(&c);
}

void windows_menu_set_from_payload(const char* payload_json) {
    const char* items = menu_find_items_array(payload_json);
    if (!items) return;
    reset_menu_entries();

    // Top-level items become menubar entries; the JSON builder
    // produces a popup whose items we re-parent? No — build the
    // menubar directly: iterate the top-level array and append POPUP
    // entries, mirroring windows_menu_set_typed's shape.
    MenuCursor c = { items };
    if (*c.p != '[') return;
    c.p++;
    HMENU menubar = CreateMenu();
    mc_ws(&c);
    while (*c.p && *c.p != ']') {
        if (!append_json_item(menubar, &c)) { DestroyMenu(menubar); return; }
        mc_ws(&c);
        if (*c.p == ',') { c.p++; mc_ws(&c); }
    }

    for (int i = 0; i < 64; i++) {
        HWND hwnd = zapp_get_hwnd(i);
        if (hwnd) SetMenu(hwnd, menubar);
    }
}

void windows_menu_show_context_from_payload(const char* payload_json, int32_t window_id) {
    const char* items = menu_find_items_array(payload_json);
    if (!items) return;

    // x/y live alongside items in the args object. The strstr helper
    // is fine here — x/y are flat numeric keys.
    int x = 0, y = 0;
    const char* px = strstr(payload_json, "\"x\":");
    if (px) x = atoi(px + 4);
    const char* py = strstr(payload_json, "\"y\":");
    if (py) y = atoi(py + 4);

    MenuCursor c = { items };
    HMENU menu = build_hmenu_from_json_array(&c);
    if (!menu) return;
    HWND hwnd = zapp_get_hwnd(window_id);
    if (!hwnd) { DestroyMenu(menu); return; }

    // x/y arrive as CSS pixels relative to the FIRING webview; anchor to that
    // webview's parent HWND (offset-correct in paned windows) and scale CSS->
    // device px by its DPI. Anchoring to the top-level host instead shifts the
    // menu by the pane offset (e.g. the sidebar width) on paned windows.
    POINT pt = zapp_menu_screen_point(window_id, x, y, hwnd);
    // TPM_RETURNCMD not used — clicks dispatch through WM_COMMAND like
    // menubar items, sharing zapp_handle_menu_command.
    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_TOPALIGN, pt.x, pt.y, 0, hwnd, NULL);
    DestroyMenu(menu);
}
