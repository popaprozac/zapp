// Windows native sidebar + inspector split panes.
//
// macOS uses an NSSplitViewController with .sidebar / inspector NSSplitViewItems
// that host host-twin WKWebViews. Windows has no split widget, so we carve the
// main window's client area into [sidebar | splitter | content | splitter |
// inspector] using child HWNDs, each hosting a WebView2 controller (the panes
// are full host-twins via windows_webview_create_ext — own transport slot, host
// JS identity). The splitters are thin child windows; WM_SIZE reflows everything.
//
// This file: layout + registry + (next slice) splitter drag, collapse, events,
// and the sidebar:/inspector:* control ops. Keyed by host transport slot.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

extern HINSTANCE zapp_get_hinstance(void);
extern HWND zapp_get_hwnd(int32_t window_id);
extern void windows_webview_create_ext(void* hwnd_ptr, bool inspectable, const char* url_override,
                                       int32_t slot, int32_t identity_id, bool transparent,
                                       int pane_role, bool has_sidebar, bool has_inspector);
extern void windows_webview_resize(int32_t window_id, int w, int h);
extern void windows_webview_notify_position(int32_t window_id);

#define ZAPP_MAX_PANE_WINDOWS 64
#define ZAPP_SPLITTER_PX 6   // splitter thickness (physical px scaled below)

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
    int      splitter_px;      // DPI-scaled splitter thickness
} ZappPaneWindow;

static ZappPaneWindow zapp_panes[ZAPP_MAX_PANE_WINDOWS];

static ZappPaneWindow* panes_for(int32_t host_slot) {
    if (host_slot < 0 || host_slot >= ZAPP_MAX_PANE_WINDOWS) return NULL;
    ZappPaneWindow* p = &zapp_panes[host_slot];
    return p->active ? p : NULL;
}

// 1 if this window has native panes (window.c WM_SIZE consults this).
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

// --- Child window classes (content/pane host + splitter) ---

static const wchar_t* PANE_HOST_CLASS = L"ZappPaneHost";
static const wchar_t* PANE_SPLIT_CLASS = L"ZappPaneSplitter";

static LRESULT CALLBACK splitter_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_SETCURSOR) {
        SetCursor(LoadCursorW(NULL, IDC_SIZEWE));
        return TRUE;
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

// Lay out [sidebar | splitter | content | splitter | inspector] in the host
// client area and resize each controller to fill its child. Returns 1 when the
// window has panes (so WM_SIZE skips the plain single-webview resize).
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

    // Leading sidebar.
    if (p->sidebar_slot >= 0 && !p->sidebar_collapsed && p->sidebar_child) {
        int w = p->sidebar_width;
        if (w > W - sp) w = (W - sp > 0) ? W - sp : 0;
        SetWindowPos(p->sidebar_child, NULL, 0, 0, w, H, SWP_NOZORDER | SWP_SHOWWINDOW);
        windows_webview_resize(p->sidebar_slot, w, H);
        windows_webview_notify_position(p->sidebar_slot);
        if (p->sidebar_splitter)
            SetWindowPos(p->sidebar_splitter, HWND_TOP, w, 0, sp, H, SWP_SHOWWINDOW);
        content_left = w + sp;
    } else {
        if (p->sidebar_child) ShowWindow(p->sidebar_child, SW_HIDE);
        if (p->sidebar_splitter) ShowWindow(p->sidebar_splitter, SW_HIDE);
    }

    // Trailing inspector.
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
    } else {
        if (p->inspector_child) ShowWindow(p->inspector_child, SW_HIDE);
        if (p->inspector_splitter) ShowWindow(p->inspector_splitter, SW_HIDE);
    }

    // Content fills the middle.
    int cw = content_right - content_left;
    if (cw < 0) cw = 0;
    SetWindowPos(p->content_child, NULL, content_left, 0, cw, H, SWP_NOZORDER | SWP_SHOWWINDOW);
    windows_webview_resize(p->host_slot, cw, H);
    windows_webview_notify_position(p->host_slot);
    return 1;
}

// WM_MOVE: WebView2 caches parent screen position — nudge every pane controller.
void windows_panes_notify_move(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p) return;
    windows_webview_notify_position(p->host_slot);
    if (p->sidebar_slot >= 0) windows_webview_notify_position(p->sidebar_slot);
    if (p->inspector_slot >= 0) windows_webview_notify_position(p->inspector_slot);
}

// Create the split: child windows + host-twin pane webviews. Called from
// windows_window_create when sidebar and/or inspector options are present.
// Widths/min/max are logical px (DPI-scaled here). The host webview is mounted
// into a content child window (not the main HWND) so the layout owns its bounds.
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

    // Content child (host webview). Created first so it's beneath the panes.
    p->content_child = make_child(host_hwnd, PANE_HOST_CLASS);

    if (has_sidebar) {
        p->sidebar_slot = sidebar_slot;
        p->sidebar_width = sx(host_hwnd, sb_width);
        p->sidebar_min = sx(host_hwnd, sb_min);
        p->sidebar_max = sx(host_hwnd, sb_max);
        p->sidebar_collapsed = sb_collapsed ? 1 : 0;
        p->sidebar_child = make_child(host_hwnd, PANE_HOST_CLASS);
        p->sidebar_splitter = make_child(host_hwnd, PANE_SPLIT_CLASS);
    }
    if (has_inspector) {
        p->inspector_slot = inspector_slot;
        p->inspector_width = sx(host_hwnd, insp_width);
        p->inspector_min = sx(host_hwnd, insp_min);
        p->inspector_max = sx(host_hwnd, insp_max);
        p->inspector_collapsed = insp_collapsed ? 1 : 0;
        p->inspector_child = make_child(host_hwnd, PANE_HOST_CLASS);
        p->inspector_splitter = make_child(host_hwnd, PANE_SPLIT_CLASS);
    }

    // Position the children before the (async) controllers attach.
    windows_panes_layout(host_slot);

    // Host webview → content child, self identity, pane flags so Window.current()
    // exposes the sidebar/inspector handles. Panes → own slot, HOST identity,
    // transparent so a backdrop can show, role 1 (sidebar) / 3 (inspector).
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
