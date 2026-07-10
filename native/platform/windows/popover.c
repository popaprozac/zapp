// Windows native popover / flyout.
//
// macOS uses NSPopover (arrow, anchored to a view rect, transient auto-dismiss)
// hosting a host-twin WKWebView. Windows has no popover widget, so we use a
// borderless WS_POPUP top-level window hosting a WebView2 controller (a full
// host-twin via windows_webview_create_ext — own transport slot, host JS
// identity), with Win11 rounded corners + drop shadow. The pane loads once at
// create (warm); show()/hide() reuse it so page state survives. "transient"
// behavior auto-dismisses on deactivation.
//
// Mirrors darwin/popover.m. Router (router.zc) drives create/show/hide/destroy.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern HINSTANCE zapp_get_hinstance(void);
extern HWND zapp_get_hwnd(int32_t window_id);
extern void windows_webview_create_ext(void* hwnd_ptr, bool inspectable, const char* url_override,
                                       int32_t slot, int32_t identity_id, bool transparent,
                                       int pane_role, bool has_sidebar, bool has_inspector);
extern void windows_webview_resize(int32_t window_id, int w, int h);
extern void windows_webview_notify_position(int32_t window_id);
extern void windows_webview_eval_by_id(int32_t window_id, const char* js);
extern void windows_webview_eval_all(const char* js);
extern void windows_window_register_pane_id(int32_t slot, int32_t host_slot);

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#define ZAPP_DWMWCP_ROUND 2

#define ZAPP_MAX_POPOVERS 32

typedef struct {
    int      active;
    char     id[32];
    int32_t  host_slot;
    int32_t  slot;       // popover pane transport slot
    HWND     hwnd;       // WS_POPUP host window
    int      width, height; // physical px
    int      transient;  // auto-dismiss on deactivate
    int      visible;
} ZappPopover;

static ZappPopover zapp_popovers[ZAPP_MAX_POPOVERS];

static ZappPopover* pop_find(const char* id) {
    if (!id) return NULL;
    for (int i = 0; i < ZAPP_MAX_POPOVERS; i++)
        if (zapp_popovers[i].active && strcmp(zapp_popovers[i].id, id) == 0) return &zapp_popovers[i];
    return NULL;
}
static ZappPopover* pop_alloc(void) {
    for (int i = 0; i < ZAPP_MAX_POPOVERS; i++)
        if (!zapp_popovers[i].active) { memset(&zapp_popovers[i], 0, sizeof(ZappPopover)); return &zapp_popovers[i]; }
    return NULL;
}
static ZappPopover* pop_for_hwnd(HWND h) {
    for (int i = 0; i < ZAPP_MAX_POPOVERS; i++)
        if (zapp_popovers[i].active && zapp_popovers[i].hwnd == h) return &zapp_popovers[i];
    return NULL;
}

static double pop_scale(HWND hwnd) {
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

// Broadcast window:popover-closed (host id) — fires for hide() and transient
// dismiss. Mirrors darwin popoverDidClose.
static void pop_emit_closed(ZappPopover* p) {
    char js[256];
    snprintf(js, sizeof(js),
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&b._onEvent)b._onEvent('window:popover-closed',"
        "'{\"windowId\":\"win-%d\",\"popoverId\":\"%s\"}');})();",
        p->host_slot, p->id);
    windows_webview_eval_all(js);
}

static void pop_do_hide(ZappPopover* p, int emit) {
    if (!p || !p->visible) return;
    p->visible = 0;
    if (p->hwnd) ShowWindow(p->hwnd, SW_HIDE);
    if (emit) pop_emit_closed(p);
}

// WS_POPUP host window proc: transient popovers dismiss when they lose
// activation (click outside).
static LRESULT CALLBACK popover_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_ACTIVATE && LOWORD(wParam) == WA_INACTIVE) {
        ZappPopover* p = pop_for_hwnd(hwnd);
        if (p && p->transient && p->visible) pop_do_hide(p, 1);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static void pop_register_class(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.style = CS_DROPSHADOW; // flyout shadow
    wc.lpfnWndProc = popover_wndproc;
    wc.hInstance = zapp_get_hinstance();
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = L"ZappPopover";
    RegisterClassExW(&wc);
}

// Create the popover: a hidden WS_POPUP window + a warm host-twin webview.
void windows_popover_create(void* host_window_ptr, const char* popover_id,
                            const char* url, int32_t width, int32_t height,
                            const char* behavior, int32_t host_slot, int32_t popover_slot) {
    (void)host_window_ptr;
    if (!popover_id || !url || !url[0]) return;
    if (pop_find(popover_id)) return;
    HWND owner = zapp_get_hwnd(host_slot);
    pop_register_class();

    ZappPopover* p = pop_alloc();
    if (!p) return;
    p->active = 1;
    snprintf(p->id, sizeof(p->id), "%s", popover_id);
    p->host_slot = host_slot;
    p->slot = popover_slot;
    p->transient = (!behavior || strcmp(behavior, "applicationDefined") != 0); // transient/semi → dismiss
    double s = pop_scale(owner);
    p->width = (int)(width * s + 0.5);
    p->height = (int)(height * s + 0.5);

    // Owned popup (stays above the owner, off the taskbar), created hidden.
    p->hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, L"ZappPopover", L"",
        WS_POPUP, 0, 0, p->width, p->height, owner, NULL, zapp_get_hinstance(), NULL);
    if (!p->hwnd) { p->active = 0; return; }

    // Win11 rounded corners.
    int corner = ZAPP_DWMWCP_ROUND;
    DwmSetWindowAttribute(p->hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));

    // Warm host-twin webview (own slot, host identity, role 2 = popover). Loads
    // now so it's ready on first show; show()/hide() reuse it.
    windows_window_register_pane_id(popover_slot, host_slot); // in-pane action → host
    windows_webview_create_ext((void*)p->hwnd, true, url, popover_slot, host_slot,
                               false, 2, false, false);
}

// Find a JSON number field within [start,end): "key": <number> → double.
static double pop_json_num(const char* json, const char* key, double dflt) {
    if (!json) return dflt;
    char pat[48];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char* p = strstr(json, pat);
    if (!p) return dflt;
    p = strchr(p, ':');
    if (!p) return dflt;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    char* endp = NULL;
    double v = strtod(p, &endp);
    return (endp == p) ? dflt : v;
}

// Show near the anchor. args_json: {"anchor":{"x","y","width","height"} or
// {"toolbarItem"}, "edge":"top|bottom|left|right"} — anchor in CSS px in the
// host webview viewport. (toolbarItem has no Windows native toolbar → falls
// back to anchoring at the host's top-left.)
void windows_popover_show(const char* popover_id, const char* args_json, int32_t sender_slot) {
    (void)sender_slot;
    ZappPopover* p = pop_find(popover_id);
    if (!p || !p->hwnd) return;
    HWND owner = zapp_get_hwnd(p->host_slot);
    if (!owner) return;
    // The anchor rect is CSS px relative to the firing webview, which in paned
    // windows lives in a child HWND offset from the host (content/sidebar/
    // inspector). Anchor coordinate math to that webview's parent so the popover
    // lands on its anchor; fall back to the host if the controller isn't ready.
    extern void* windows_webview_parent_hwnd(int32_t);
    HWND anchor_hwnd = (HWND)windows_webview_parent_hwnd(p->host_slot);
    if (!anchor_hwnd) anchor_hwnd = owner;

    // Parse anchor rect (CSS px) + edge from the args JSON.
    const char* anchor = args_json ? strstr(args_json, "\"anchor\"") : NULL;
    int ax = (int)pop_json_num(anchor, "x", 0);
    int ay = (int)pop_json_num(anchor, "y", 0);
    int aw = (int)pop_json_num(anchor, "width", 1);
    int ah = (int)pop_json_num(anchor, "height", 1);
    int edge = 1; // bottom
    if (args_json) {
        const char* e = strstr(args_json, "\"edge\"");
        if (e) {
            e = strchr(e, ':');
            if (e) {
                if (strstr(e, "\"top\""))        edge = 0;
                else if (strstr(e, "\"left\""))  edge = 2;
                else if (strstr(e, "\"right\"")) edge = 3;
            }
        }
    }

    // Anchor CSS px → webview-client px → screen px (anchor = the firing
    // webview's parent, offset-correct in paned windows).
    double s = pop_scale(anchor_hwnd);
    POINT origin = { 0, 0 };
    ClientToScreen(anchor_hwnd, &origin);
    int sx = origin.x + (int)(ax * s + 0.5);
    int sy = origin.y + (int)(ay * s + 0.5);
    int sw = (int)(aw * s + 0.5);
    int sh = (int)(ah * s + 0.5);

    int gap = (int)(6 * s + 0.5);
    int cx = sx + sw / 2 - p->width / 2;  // centered on the anchor (horizontal)
    int cy = sy + sh / 2 - p->height / 2; // centered on the anchor (vertical)
    int px, py;
    switch (edge) {
        case 0: px = cx; py = sy - p->height - gap; break;            // top
        case 2: px = sx - p->width - gap; py = cy; break;             // left
        case 3: px = sx + sw + gap; py = cy; break;                   // right
        default: px = cx; py = sy + sh + gap; break;                  // bottom
    }
    // Keep on the work area of the owner's monitor.
    HMONITOR mon = MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi; mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(mon, &mi)) {
        if (px + p->width > mi.rcWork.right)  px = mi.rcWork.right - p->width;
        if (py + p->height > mi.rcWork.bottom) py = mi.rcWork.bottom - p->height;
        if (px < mi.rcWork.left) px = mi.rcWork.left;
        if (py < mi.rcWork.top)  py = mi.rcWork.top;
    }

    windows_webview_resize(p->slot, p->width, p->height);
    SetWindowPos(p->hwnd, HWND_TOP, px, py, p->width, p->height, SWP_SHOWWINDOW | SWP_NOACTIVATE);
    windows_webview_notify_position(p->slot);
    p->visible = 1;
    // Activate so a click outside fires WM_ACTIVATE/WA_INACTIVE (transient).
    if (p->transient) SetForegroundWindow(p->hwnd);
}

void windows_popover_hide(const char* popover_id) {
    pop_do_hide(pop_find(popover_id), 1);
}

void windows_popover_destroy(const char* popover_id) {
    ZappPopover* p = pop_find(popover_id);
    if (!p) return;
    if (p->hwnd) DestroyWindow(p->hwnd);
    p->hwnd = NULL;
    p->active = 0;
}
