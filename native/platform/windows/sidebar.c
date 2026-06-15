// Windows native sidebar + inspector split panes.
//
// macOS uses an NSSplitViewController with .sidebar / inspector NSSplitViewItems
// hosting host-twin WKWebViews. Windows has no split widget, so we carve the
// main window's client area into [sidebar | splitter | content | splitter |
// inspector] using child HWNDs, each hosting a WebView2 controller (the panes
// are full host-twins via windows_webview_create_ext — own transport slot, host
// JS identity). The splitters are thin draggable child windows; WM_SIZE reflows.
//
// Control ops (windows_sidebar_* / windows_inspector_*) are the router entry
// points for sidebar:/inspector:* actions. Collapse/resize emit
// dispatchWindowEvent('win-<host>', ...) into both panes (parity with darwin's
// zapp_pane_emit). Keyed by host transport slot.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern HINSTANCE zapp_get_hinstance(void);
extern void windows_webview_create_ext(void* hwnd_ptr, bool inspectable, const char* url_override,
                                       int32_t slot, int32_t identity_id, bool transparent,
                                       int pane_role, bool has_sidebar, bool has_inspector);
extern void windows_webview_resize(int32_t window_id, int w, int h);
extern void windows_webview_notify_position(int32_t window_id);
extern void windows_webview_eval_by_id(int32_t window_id, const char* js);
extern char* zapp_escape_dup(const char* src); // dispatch.zc — JS single-quote escape
extern void windows_window_register_pane_id(int32_t slot, int32_t host_slot); // window.c

#define ZAPP_MAX_PANE_WINDOWS 64
#define ZAPP_SPLITTER_PX 6

typedef struct {
    int      active;
    HWND     host_hwnd;
    int32_t  host_slot;

    int32_t  sidebar_slot;     // -1 when no sidebar
    HWND     sidebar_child;
    HWND     sidebar_splitter;
    int      sidebar_width;    // physical px
    int      sidebar_min, sidebar_max;
    int      sidebar_collapsed;

    int32_t  inspector_slot;   // -1 when no inspector
    HWND     inspector_child;
    HWND     inspector_splitter;
    int      inspector_width;  // physical px
    int      inspector_min, inspector_max;
    int      inspector_collapsed;

    HWND     content_child;    // host webview's child window
    int      splitter_px;
} ZappPaneWindow;

static ZappPaneWindow zapp_panes[ZAPP_MAX_PANE_WINDOWS];

static ZappPaneWindow* panes_for(int32_t host_slot) {
    if (host_slot < 0 || host_slot >= ZAPP_MAX_PANE_WINDOWS) return NULL;
    ZappPaneWindow* p = &zapp_panes[host_slot];
    return p->active ? p : NULL;
}

int windows_panes_has(int32_t host_slot) { return panes_for(host_slot) != NULL; }

static double panes_scale(HWND hwnd) {
    typedef UINT (WINAPI *GetDpiForWindow_t)(HWND);
    static GetDpiForWindow_t fn = NULL;
    static int looked = 0;
    if (!looked) { looked = 1;
        HMODULE u = GetModuleHandleW(L"user32.dll");
        if (u) fn = (GetDpiForWindow_t)(void*)GetProcAddress(u, "GetDpiForWindow");
    }
    if (fn && hwnd) { UINT d = fn(hwnd); if (d > 0) return (double)d / 96.0; }
    return 1.0;
}
static int sx(HWND h, int v) { return (int)(v * panes_scale(h) + 0.5); }

// Eval dispatchWindowEvent('win-<host>', event, data) into the host + accessory
// panes (both carry the host identity). data_json already-JSON or NULL.
static void pane_emit(int32_t host_slot, int32_t accessory_slot,
                      const char* event, const char* data_json) {
    char* esc = NULL;
    char* data_arg = NULL;
    if (data_json) {
        esc = zapp_escape_dup(data_json);
        if (esc) {
            size_t n = strlen(esc) + 3;
            data_arg = (char*)malloc(n);
            if (data_arg) snprintf(data_arg, n, "'%s'", esc);
        }
    }
    const char* arg = data_arg ? data_arg : "undefined";
    const char* tmpl =
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&typeof b.dispatchWindowEvent==='function'){"
        "b.dispatchWindowEvent('win-%d','%s',%s);}})();";
    int needed = snprintf(NULL, 0, tmpl, host_slot, event, arg);
    if (needed > 0) {
        char* js = (char*)malloc((size_t)needed + 1);
        if (js) {
            snprintf(js, (size_t)needed + 1, tmpl, host_slot, event, arg);
            windows_webview_eval_by_id(host_slot, js);
            if (accessory_slot >= 0 && accessory_slot != host_slot)
                windows_webview_eval_by_id(accessory_slot, js);
            free(js);
        }
    }
    free(esc);
    free(data_arg);
}

// --- Splitter drag ---

static struct { int active; int32_t host; int which; int start_x; int start_w; } g_drag;

static const wchar_t* PANE_HOST_CLASS  = L"ZappPaneHost";
static const wchar_t* PANE_SPLIT_CLASS = L"ZappPaneSplitter";

static int clampi(int v, int lo, int hi) {
    if (lo > 0 && v < lo) v = lo;
    if (hi > 0 && v > hi) v = hi;
    if (v < 0) v = 0;
    return v;
}

static LRESULT CALLBACK splitter_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_SETCURSOR:
            SetCursor(LoadCursorW(NULL, IDC_SIZEWE));
            return TRUE;
        case WM_LBUTTONDOWN: {
            int32_t host = (int32_t)GetWindowLongPtrW(hwnd, GWLP_USERDATA) - 1;
            ZappPaneWindow* p = panes_for(host);
            if (!p) break;
            int which = (hwnd == p->inspector_splitter) ? 1 : 0;
            POINT pt; GetCursorPos(&pt);
            g_drag.active = 1; g_drag.host = host; g_drag.which = which;
            g_drag.start_x = pt.x;
            g_drag.start_w = which ? p->inspector_width : p->sidebar_width;
            SetCapture(hwnd);
            return 0;
        }
        case WM_MOUSEMOVE: {
            if (!g_drag.active || GetCapture() != hwnd) break;
            ZappPaneWindow* p = panes_for(g_drag.host);
            if (!p) break;
            POINT pt; GetCursorPos(&pt);
            int delta = pt.x - g_drag.start_x;
            int neww;
            int32_t slot;
            const char* evt;
            if (g_drag.which == 0) {           // sidebar grows rightward
                neww = clampi(g_drag.start_w + delta, p->sidebar_min, p->sidebar_max);
                p->sidebar_width = neww; slot = p->sidebar_slot; evt = "sidebar-resized";
            } else {                            // inspector grows leftward
                neww = clampi(g_drag.start_w - delta, p->inspector_min, p->inspector_max);
                p->inspector_width = neww; slot = p->inspector_slot; evt = "inspector-resized";
            }
            extern int windows_panes_layout(int32_t);
            windows_panes_layout(g_drag.host);
            int logical = (int)(neww / panes_scale(p->host_hwnd) + 0.5);
            char json[40];
            snprintf(json, sizeof(json), "{\"width\":%d}", logical);
            pane_emit(g_drag.host, slot, evt, json);
            return 0;
        }
        case WM_LBUTTONUP:
            if (g_drag.active) { ReleaseCapture(); g_drag.active = 0; }
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static void panes_register_classes(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    WNDCLASSEXW host = {0};
    host.cbSize = sizeof(host);
    host.lpfnWndProc = DefWindowProcW;
    host.hInstance = zapp_get_hinstance();
    host.hCursor = LoadCursorW(NULL, IDC_ARROW);
    host.lpszClassName = PANE_HOST_CLASS;
    RegisterClassExW(&host);

    WNDCLASSEXW split = {0};
    split.cbSize = sizeof(split);
    split.lpfnWndProc = splitter_wndproc;
    split.hInstance = zapp_get_hinstance();
    split.lpszClassName = PANE_SPLIT_CLASS;
    RegisterClassExW(&split);
}

static HWND make_child(HWND parent, const wchar_t* cls) {
    return CreateWindowExW(0, cls, L"", WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 0, 0,
                           parent, NULL, zapp_get_hinstance(), NULL);
}

// Lay out [sidebar | splitter | content | splitter | inspector]. Returns 1 when
// the window has panes (WM_SIZE then skips the single-webview resize).
int windows_panes_layout(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p) return 0;

    RECT rc;
    GetClientRect(p->host_hwnd, &rc);
    int W = rc.right - rc.left;
    int H = rc.bottom - rc.top;
    int sp = p->splitter_px;

    int content_left = 0;
    int content_right = W;

    if (p->sidebar_slot >= 0 && !p->sidebar_collapsed && p->sidebar_child) {
        int w = p->sidebar_width;
        if (w > W - sp) w = (W - sp > 0) ? W - sp : 0;
        SetWindowPos(p->sidebar_child, NULL, 0, 0, w, H, SWP_NOZORDER | SWP_SHOWWINDOW);
        windows_webview_resize(p->sidebar_slot, w, H);
        windows_webview_notify_position(p->sidebar_slot);
        if (p->sidebar_splitter)
            SetWindowPos(p->sidebar_splitter, HWND_TOP, w, 0, sp, H, SWP_SHOWWINDOW);
        content_left = w + sp;
    } else if (p->sidebar_slot >= 0 && p->sidebar_child) {
        // Collapsed: keep the child SIZED (just hidden) so its WebView2 still
        // navigates/loads — a 0-size controller never loads, leaving the pane
        // blank when later expanded. Park it under the content area, hidden.
        SetWindowPos(p->sidebar_child, NULL, 0, 0, p->sidebar_width, H, SWP_NOZORDER | SWP_HIDEWINDOW);
        windows_webview_resize(p->sidebar_slot, p->sidebar_width, H);
        if (p->sidebar_splitter) ShowWindow(p->sidebar_splitter, SW_HIDE);
    }

    if (p->inspector_slot >= 0 && !p->inspector_collapsed && p->inspector_child) {
        int w = p->inspector_width;
        if (w > W - content_left - sp) w = (W - content_left - sp > 0) ? W - content_left - sp : 0;
        int x = W - w;
        SetWindowPos(p->inspector_child, NULL, x, 0, w, H, SWP_NOZORDER | SWP_SHOWWINDOW);
        windows_webview_resize(p->inspector_slot, w, H);
        windows_webview_notify_position(p->inspector_slot);
        if (p->inspector_splitter)
            SetWindowPos(p->inspector_splitter, HWND_TOP, x - sp, 0, sp, H, SWP_SHOWWINDOW);
        content_right = x - sp;
    } else if (p->inspector_slot >= 0 && p->inspector_child) {
        // Collapsed: keep sized (hidden) so the webview still loads (see sidebar).
        SetWindowPos(p->inspector_child, NULL, content_left, 0, p->inspector_width, H, SWP_NOZORDER | SWP_HIDEWINDOW);
        windows_webview_resize(p->inspector_slot, p->inspector_width, H);
        if (p->inspector_splitter) ShowWindow(p->inspector_splitter, SW_HIDE);
    }

    int cw = content_right - content_left;
    if (cw < 0) cw = 0;
    SetWindowPos(p->content_child, NULL, content_left, 0, cw, H, SWP_NOZORDER | SWP_SHOWWINDOW);
    windows_webview_resize(p->host_slot, cw, H);
    windows_webview_notify_position(p->host_slot);
    return 1;
}

void windows_panes_notify_move(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p) return;
    windows_webview_notify_position(p->host_slot);
    if (p->sidebar_slot >= 0) windows_webview_notify_position(p->sidebar_slot);
    if (p->inspector_slot >= 0) windows_webview_notify_position(p->inspector_slot);
}

void windows_panes_init(HWND host_hwnd, int32_t host_slot, int inspectable,
                        const char* host_url,
                        int32_t sidebar_slot, const char* sidebar_url,
                        int sb_width, int sb_min, int sb_max, int sb_collapsed,
                        int32_t inspector_slot, const char* inspector_url,
                        int insp_width, int insp_min, int insp_max, int insp_collapsed) {
    if (host_slot < 0 || host_slot >= ZAPP_MAX_PANE_WINDOWS) return;
    panes_register_classes();

    ZappPaneWindow* p = &zapp_panes[host_slot];
    memset(p, 0, sizeof(*p));
    p->active = 1;
    p->host_hwnd = host_hwnd;
    p->host_slot = host_slot;
    p->sidebar_slot = -1;
    p->inspector_slot = -1;
    p->splitter_px = sx(host_hwnd, ZAPP_SPLITTER_PX);

    bool has_sidebar = (sidebar_slot >= 0 && sidebar_url && sidebar_url[0]);
    bool has_inspector = (inspector_slot >= 0 && inspector_url && inspector_url[0]);

    p->content_child = make_child(host_hwnd, PANE_HOST_CLASS);

    if (has_sidebar) {
        p->sidebar_slot = sidebar_slot;
        p->sidebar_width = sx(host_hwnd, sb_width);
        p->sidebar_min = sx(host_hwnd, sb_min);
        p->sidebar_max = sx(host_hwnd, sb_max);
        p->sidebar_collapsed = sb_collapsed ? 1 : 0;
        p->sidebar_child = make_child(host_hwnd, PANE_HOST_CLASS);
        p->sidebar_splitter = make_child(host_hwnd, PANE_SPLIT_CLASS);
        SetWindowLongPtrW(p->sidebar_splitter, GWLP_USERDATA, host_slot + 1);
        windows_window_register_pane_id(sidebar_slot, host_slot); // sender→host remap
    }
    if (has_inspector) {
        p->inspector_slot = inspector_slot;
        p->inspector_width = sx(host_hwnd, insp_width);
        p->inspector_min = sx(host_hwnd, insp_min);
        p->inspector_max = sx(host_hwnd, insp_max);
        p->inspector_collapsed = insp_collapsed ? 1 : 0;
        p->inspector_child = make_child(host_hwnd, PANE_HOST_CLASS);
        p->inspector_splitter = make_child(host_hwnd, PANE_SPLIT_CLASS);
        SetWindowLongPtrW(p->inspector_splitter, GWLP_USERDATA, host_slot + 1);
        windows_window_register_pane_id(inspector_slot, host_slot); // sender→host remap
    }

    windows_panes_layout(host_slot);

    windows_webview_create_ext((void*)p->content_child, inspectable != 0, host_url,
                               host_slot, -1, false, 0, has_sidebar, has_inspector);
    if (has_sidebar) {
        windows_webview_create_ext((void*)p->sidebar_child, inspectable != 0, sidebar_url,
                                   sidebar_slot, host_slot, true, 1, has_sidebar, has_inspector);
    }
    if (has_inspector) {
        windows_webview_create_ext((void*)p->inspector_child, inspectable != 0, inspector_url,
                                   inspector_slot, host_slot, true, 3, has_sidebar, has_inspector);
    }
}

void windows_panes_destroy(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p) return;
    if (p->sidebar_splitter) DestroyWindow(p->sidebar_splitter);
    if (p->inspector_splitter) DestroyWindow(p->inspector_splitter);
    if (p->sidebar_child) DestroyWindow(p->sidebar_child);
    if (p->inspector_child) DestroyWindow(p->inspector_child);
    if (p->content_child) DestroyWindow(p->content_child);
    memset(p, 0, sizeof(*p));
}

// --- Control ops (router entry points for sidebar:/inspector:*) ---

void windows_sidebar_collapse(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p || p->sidebar_slot < 0 || p->sidebar_collapsed) return;
    p->sidebar_collapsed = 1;
    windows_panes_layout(host_slot);
    pane_emit(host_slot, p->sidebar_slot, "sidebar-collapsed", NULL);
}
void windows_sidebar_expand(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p || p->sidebar_slot < 0 || !p->sidebar_collapsed) return;
    p->sidebar_collapsed = 0;
    windows_panes_layout(host_slot);
    pane_emit(host_slot, p->sidebar_slot, "sidebar-expanded", NULL);
}
void windows_sidebar_toggle(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p || p->sidebar_slot < 0) return;
    if (p->sidebar_collapsed) windows_sidebar_expand(host_slot);
    else windows_sidebar_collapse(host_slot);
}
void windows_sidebar_set_width(int32_t host_slot, int32_t width) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p || p->sidebar_slot < 0) return;
    p->sidebar_width = clampi(sx(p->host_hwnd, width), p->sidebar_min, p->sidebar_max);
    windows_panes_layout(host_slot);
    int logical = (int)(p->sidebar_width / panes_scale(p->host_hwnd) + 0.5);
    char json[40]; snprintf(json, sizeof(json), "{\"width\":%d}", logical);
    pane_emit(host_slot, p->sidebar_slot, "sidebar-resized", json);
}

void windows_inspector_collapse(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p || p->inspector_slot < 0 || p->inspector_collapsed) return;
    p->inspector_collapsed = 1;
    windows_panes_layout(host_slot);
    pane_emit(host_slot, p->inspector_slot, "inspector-collapsed", NULL);
}
void windows_inspector_expand(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p || p->inspector_slot < 0 || !p->inspector_collapsed) return;
    p->inspector_collapsed = 0;
    windows_panes_layout(host_slot);
    pane_emit(host_slot, p->inspector_slot, "inspector-expanded", NULL);
}
void windows_inspector_toggle(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p || p->inspector_slot < 0) return;
    if (p->inspector_collapsed) windows_inspector_expand(host_slot);
    else windows_inspector_collapse(host_slot);
}
void windows_inspector_set_width(int32_t host_slot, int32_t width) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p || p->inspector_slot < 0) return;
    p->inspector_width = clampi(sx(p->host_hwnd, width), p->inspector_min, p->inspector_max);
    windows_panes_layout(host_slot);
    int logical = (int)(p->inspector_width / panes_scale(p->host_hwnd) + 0.5);
    char json[40]; snprintf(json, sizeof(json), "{\"width\":%d}", logical);
    pane_emit(host_slot, p->inspector_slot, "inspector-resized", json);
}
