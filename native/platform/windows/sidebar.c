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
#include <dwmapi.h>   // DwmGetWindowAttribute(DWMWA_CAPTION_BUTTON_BOUNDS)
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef DWMWA_CAPTION_BUTTON_BOUNDS
#define DWMWA_CAPTION_BUTTON_BOUNDS 5   // DWMWINDOWATTRIBUTE enum value (NOT 30)
#endif

extern HINSTANCE zapp_get_hinstance(void);
extern void windows_webview_create_ext(void* hwnd_ptr, bool inspectable, const char* url_override,
                                       int32_t slot, int32_t identity_id, bool transparent,
                                       int pane_role, bool has_sidebar, bool has_inspector);
extern void windows_webview_resize(int32_t window_id, int w, int h);
extern void windows_webview_notify_position(int32_t window_id);
extern void windows_webview_eval_by_id(int32_t window_id, const char* js);
extern char* zapp_escape_dup(const char* src); // dispatch.zc — JS single-quote escape
extern void windows_window_register_pane_id(int32_t slot, int32_t host_slot); // window.c

// Defined below; called from the inspector collapse/expand ops above them.
void windows_titlebar_relocate_controls(int32_t host_slot);
int32_t windows_pane_controls_slot(int32_t host_slot);

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
    int      sidebar_resizable, inspector_resizable;  // 0 = splitter drag disabled
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
    (void)accessory_slot;   // event reaches ALL panes now (see below), not just the source
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
            // Window events are a "global broadcast, filtered by windowId" — every
            // pane of this window must receive them, not just the host + the pane
            // that triggered the change. Otherwise a section's inspector() (which
            // renders in the INSPECTOR pane) never sees SIDEBAR_* events, and vice
            // versa. Dispatch to content/host + BOTH accessories.
            windows_webview_eval_by_id(host_slot, js);
            ZappPaneWindow* p = panes_for(host_slot);
            if (p) {
                if (p->sidebar_slot >= 0 && p->sidebar_slot != host_slot)
                    windows_webview_eval_by_id(p->sidebar_slot, js);
                if (p->inspector_slot >= 0 && p->inspector_slot != host_slot)
                    windows_webview_eval_by_id(p->inspector_slot, js);
            }
            free(js);
        }
    }
    free(esc);
    free(data_arg);
}

// --- Splitter drag ---

static struct { int active; int32_t host; int which; int start_x; int start_w; } g_drag;
static DWORD g_drag_last_bounds = 0;   // GetTickCount of the last webview put_Bounds during a drag
#define PANE_SETTLE_TIMER_ID 0x5A99    // snaps webviews to final size if the drag pauses
int windows_panes_layout_ex(int32_t host_slot, bool resize_webviews);  // fwd (defined below)

static const wchar_t* PANE_HOST_CLASS       = L"ZappPaneHost";
static const wchar_t* PANE_HOST_CLEAR_CLASS = L"ZappPaneHostClear"; // see-through: no bg brush
static const wchar_t* PANE_SPLIT_CLASS      = L"ZappPaneSplitter";

static int clampi(int v, int lo, int hi) {
    if (lo > 0 && v < lo) v = lo;
    if (hi > 0 && v > hi) v = hi;
    if (v < 0) v = 0;
    return v;
}

static LRESULT CALLBACK splitter_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_SETCURSOR: {
            int32_t host = (int32_t)GetWindowLongPtrW(hwnd, GWLP_USERDATA) - 1;
            ZappPaneWindow* p = panes_for(host);
            if (p) {
                int which = (hwnd == p->inspector_splitter) ? 1 : 0;
                if (!(which ? p->inspector_resizable : p->sidebar_resizable)) break;  // fixed → arrow
            }
            SetCursor(LoadCursorW(NULL, IDC_SIZEWE));
            return TRUE;
        }
        case WM_LBUTTONDOWN: {
            int32_t host = (int32_t)GetWindowLongPtrW(hwnd, GWLP_USERDATA) - 1;
            ZappPaneWindow* p = panes_for(host);
            if (!p) break;
            int which = (hwnd == p->inspector_splitter) ? 1 : 0;
            if (!(which ? p->inspector_resizable : p->sidebar_resizable)) return 0;  // fixed → no drag
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
            if (g_drag.which == 0)              // sidebar grows rightward
                p->sidebar_width = clampi(g_drag.start_w + delta, p->sidebar_min, p->sidebar_max);
            else                                // inspector grows leftward
                p->inspector_width = clampi(g_drag.start_w - delta, p->inspector_min, p->inspector_max);
            // Containers move every tick (atomic DeferWindowPos → smooth). The
            // heavy WebView2 put_Bounds is throttled to ~60fps — cross-process IPC
            // to Chromium's renderer can't keep up per-mousemove. A settle timer
            // snaps the final size if the mouse pauses mid-drag. (The 'resized' JS
            // event fires once on WM_LBUTTONUP.)
            DWORD now = GetTickCount();
            bool do_bounds = (now - g_drag_last_bounds) >= 16;
            windows_panes_layout_ex(g_drag.host, do_bounds);
            if (do_bounds) { g_drag_last_bounds = now; KillTimer(hwnd, PANE_SETTLE_TIMER_ID); }
            else SetTimer(hwnd, PANE_SETTLE_TIMER_ID, 24, NULL);
            return 0;
        }
        case WM_TIMER:
            if (wParam == PANE_SETTLE_TIMER_ID) {
                KillTimer(hwnd, PANE_SETTLE_TIMER_ID);
                if (g_drag.active) {   // mouse paused mid-drag — snap webviews to size
                    windows_panes_layout_ex(g_drag.host, true);
                    g_drag_last_bounds = GetTickCount();
                }
            }
            return 0;
        case WM_LBUTTONUP:
            if (g_drag.active) {
                ReleaseCapture();
                KillTimer(hwnd, PANE_SETTLE_TIMER_ID);
                windows_panes_layout_ex(g_drag.host, true);   // final snap to exact size
                ZappPaneWindow* p = panes_for(g_drag.host);
                if (p) {
                    int32_t slot; const char* evt; int neww;
                    if (g_drag.which == 0) { slot = p->sidebar_slot;   evt = "sidebar-resized";   neww = p->sidebar_width; }
                    else                   { slot = p->inspector_slot; evt = "inspector-resized"; neww = p->inspector_width; }
                    int logical = (int)(neww / panes_scale(p->host_hwnd) + 0.5);
                    char json[40]; snprintf(json, sizeof(json), "{\"width\":%d}", logical);
                    pane_emit(g_drag.host, slot, evt, json);
                }
                g_drag.active = 0;
            }
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static void panes_register_classes(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    extern HBRUSH windows_theme_bg_brush(void); // platform.c — theme surface
    WNDCLASSEXW host = {0};
    host.cbSize = sizeof(host);
    host.lpfnWndProc = DefWindowProcW;
    host.hInstance = zapp_get_hinstance();
    host.hCursor = LoadCursorW(NULL, IDC_ARROW);
    // Theme surface (not NULL/white): fills the strip a pane child exposes while
    // the WebView2 catches up during a divider drag, so it doesn't flash white.
    host.hbrBackground = windows_theme_bg_brush();
    host.lpszClassName = PANE_HOST_CLASS;
    RegisterClassExW(&host);

    // See-through variant: NO background brush. On a Mica/transparent window the
    // pane child must paint NOTHING — an opaque GDI brush in the child blocks the
    // DWM backdrop behind the alpha-0 webview (this, not missing glass, is why
    // Mica looked opaque; Wails/tao have no intermediate children to paint).
    WNDCLASSEXW clear = host;
    clear.hbrBackground = NULL;
    clear.lpszClassName = PANE_HOST_CLEAR_CLASS;
    RegisterClassExW(&clear);

    WNDCLASSEXW split = {0};
    split.cbSize = sizeof(split);
    split.lpfnWndProc = splitter_wndproc;
    split.hInstance = zapp_get_hinstance();
    split.hbrBackground = windows_theme_bg_brush();  // theme surface, not white
    split.lpszClassName = PANE_SPLIT_CLASS;
    RegisterClassExW(&split);
}

// Native (DWM) caption buttons: carve the caption-button rect out of the pane
// container `pane` (positioned at pane_x,0 in host client coords, size pane_w×H)
// so the top-level window owns those pixels — input falls through the hole to the
// host's WM_NCHITTEST → DwmDefWindowProc gets the hover/press/Snap stream
// (WebView2 otherwise swallows it, #446). DWM reports the exact rect (DPI/theme/
// RTL aware) via DWMWA_CAPTION_BUTTON_BOUNDS. NULL region = full rect (no carve).
// strip_w_logical = the caption-button cluster width (logical/96-dpi px), from
// windows_titlebar_metrics (the same value reserved as the content inset).
static void carve_caption_buttons(HWND host, HWND pane, int pane_x, int pane_w,
                                  int pane_h, int strip_w_logical) {
    if (!pane) return;
    RECT btn;
    if (FAILED(DwmGetWindowAttribute(host, DWMWA_CAPTION_BUTTON_BOUNDS, &btn, sizeof(btn)))) {
        SetWindowRgn(pane, NULL, TRUE);
        return;
    }
    // DWM's bounds gives the authoritative RIGHT + top/bottom of the button
    // cluster, but its width can run a bit wider than the drawn buttons. Use our
    // known cluster width (right-aligned to DWM's right edge) so the carve hugs
    // the buttons exactly — no dead Mica gap on the left.
    UINT dpi = GetDpiForWindow(host); if (!dpi) dpi = 96;
    int strip_w = MulDiv(strip_w_logical, (int)dpi, 96);
    if (strip_w > 0 && strip_w < btn.right - btn.left) btn.left = btn.right - strip_w;
    // window-relative → host client → pane-relative.
    RECT wr; GetWindowRect(host, &wr);
    POINT co = { 0, 0 }; ClientToScreen(host, &co);
    OffsetRect(&btn, wr.left - co.x, wr.top - co.y);
    OffsetRect(&btn, -pane_x, 0);
    // Maximized: after the client conversion the cluster top goes NEGATIVE (it
    // extends into the off-screen frame), but DWM DRAWS it clamped to y=0 at full
    // height. Pin the top to 0 while keeping the full height so the whole drawn
    // button is carved (else the bottom is covered and looks too short).
    if (btn.top < 0) { btn.bottom -= btn.top; btn.top = 0; }
    RECT paneRect = { 0, 0, pane_w, pane_h }, overlap;
    if (!IntersectRect(&overlap, &paneRect, &btn)) { SetWindowRgn(pane, NULL, TRUE); return; }
    HRGN rgn = CreateRectRgn(0, 0, pane_w, pane_h);
    HRGN hole = CreateRectRgnIndirect(&overlap);
    CombineRgn(rgn, rgn, hole, RGN_DIFF);
    DeleteObject(hole);
    SetWindowRgn(pane, rgn, TRUE);   // system owns `rgn` after this
}

static HWND make_child(HWND parent, const wchar_t* cls) {
    return CreateWindowExW(0, cls, L"", WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 0, 0,
                           parent, NULL, zapp_get_hinstance(), NULL);
}

// Lay out [sidebar | splitter | content | splitter | inspector]. Returns 1 when
// the window has panes (WM_SIZE then skips the single-webview resize).
//
// resize_webviews=false is the interactive splitter-drag fast path: the child
// container HWNDs move in ONE atomic DeferWindowPos pass (so the drag tracks
// smoothly), but the heavy WebView2 put_Bounds — cross-process IPC to Chromium's
// renderer, which floods + stalls at per-mousemove rates — is skipped. The
// splitter throttles those to ~60fps + a settle. Everything else (window-edge
// WM_SIZE, collapse/expand, setWidth) uses the true wrapper: the OS modal resize
// loop is DWM-paced, so there's no flood to throttle.
int windows_panes_layout_ex(int32_t host_slot, bool resize_webviews) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p) return 0;

    RECT rc;
    GetClientRect(p->host_hwnd, &rc);
    int W = rc.right - rc.left;
    int H = rc.bottom - rc.top;
    int sp = p->splitter_px;

    int content_left = 0;
    int content_right = W;
    const UINT MOVE = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS;

    // Phase 1 — move every child + splitter in ONE atomic DWM pass. Separate
    // SetWindowPos calls each trigger their own reflow/repaint; batching is what
    // lets a splitter drag track like a window-edge resize.
    HDWP hdwp = BeginDeferWindowPos(5);
    int sb_w = p->sidebar_width, insp_w = p->inspector_width;
    bool sb_shown = false, insp_shown = false;

    if (p->sidebar_slot >= 0 && !p->sidebar_collapsed && p->sidebar_child) {
        int w = p->sidebar_width;
        if (w > W - sp) w = (W - sp > 0) ? W - sp : 0;
        sb_w = w; sb_shown = true;
        if (hdwp) hdwp = DeferWindowPos(hdwp, p->sidebar_child, NULL, 0, 0, w, H, MOVE | SWP_SHOWWINDOW);
        if (p->sidebar_splitter && hdwp)
            hdwp = DeferWindowPos(hdwp, p->sidebar_splitter, HWND_TOP, w, 0, sp, H, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        content_left = w + sp;
    } else if (p->sidebar_slot >= 0 && p->sidebar_child) {
        // Collapsed: keep the child SIZED (just hidden) so its WebView2 still
        // navigates/loads — a 0-size controller never loads.
        if (hdwp) hdwp = DeferWindowPos(hdwp, p->sidebar_child, NULL, 0, 0, p->sidebar_width, H, MOVE | SWP_HIDEWINDOW);
        if (p->sidebar_splitter && hdwp)
            hdwp = DeferWindowPos(hdwp, p->sidebar_splitter, NULL, 0, 0, 0, 0,
                                  SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_HIDEWINDOW);
    }

    if (p->inspector_slot >= 0 && !p->inspector_collapsed && p->inspector_child) {
        int w = p->inspector_width;
        if (w > W - content_left - sp) w = (W - content_left - sp > 0) ? W - content_left - sp : 0;
        int x = W - w;
        insp_w = w; insp_shown = true;
        if (hdwp) hdwp = DeferWindowPos(hdwp, p->inspector_child, NULL, x, 0, w, H, MOVE | SWP_SHOWWINDOW);
        if (p->inspector_splitter && hdwp)
            hdwp = DeferWindowPos(hdwp, p->inspector_splitter, HWND_TOP, x - sp, 0, sp, H, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        content_right = x - sp;
    } else if (p->inspector_slot >= 0 && p->inspector_child) {
        if (hdwp) hdwp = DeferWindowPos(hdwp, p->inspector_child, NULL, content_left, 0, p->inspector_width, H, MOVE | SWP_HIDEWINDOW);
        if (p->inspector_splitter && hdwp)
            hdwp = DeferWindowPos(hdwp, p->inspector_splitter, NULL, 0, 0, 0, 0,
                                  SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_HIDEWINDOW);
    }

    int cw = content_right - content_left;
    if (cw < 0) cw = 0;
    if (hdwp) hdwp = DeferWindowPos(hdwp, p->content_child, NULL, content_left, 0, cw, H, MOVE | SWP_SHOWWINDOW);
    if (hdwp) EndDeferWindowPos(hdwp);

    // Phase 2 — resize the WebView2 controllers (the expensive, cross-process
    // part). Skipped on throttled drag ticks; the containers above already moved.
    if (resize_webviews) {
        if (p->sidebar_slot >= 0 && p->sidebar_child) {
            windows_webview_resize(p->sidebar_slot, sb_shown ? sb_w : p->sidebar_width, H);
            if (sb_shown) windows_webview_notify_position(p->sidebar_slot);
        }
        if (p->inspector_slot >= 0 && p->inspector_child) {
            windows_webview_resize(p->inspector_slot, insp_shown ? insp_w : p->inspector_width, H);
            if (insp_shown) windows_webview_notify_position(p->inspector_slot);
        }
        windows_webview_resize(p->host_slot, cw, H);
        windows_webview_notify_position(p->host_slot);

        // Native (DWM) caption buttons: carve their rect out of the RIGHTMOST
        // pane (inspector when expanded, else content) so DWM owns those pixels
        // for hover / Snap / click; clear the region on the others.
        extern bool windows_titlebar_native_controls(void);
        extern bool windows_titlebar_enabled(int32_t);
        extern bool windows_titlebar_metrics(int32_t, int*, int*);
        if (windows_titlebar_native_controls() && windows_titlebar_enabled(p->host_slot)) {
            int th = 0, ir = 0; windows_titlebar_metrics(p->host_slot, &th, &ir);  // ir = cluster width (logical)
            HWND rightmost; int rx, rw;
            if (insp_shown) { rightmost = p->inspector_child; rx = W - insp_w; rw = insp_w; }
            else            { rightmost = p->content_child;   rx = content_left; rw = cw; }
            if (p->content_child   && p->content_child   != rightmost) SetWindowRgn(p->content_child, NULL, TRUE);
            if (p->inspector_child && p->inspector_child != rightmost) SetWindowRgn(p->inspector_child, NULL, TRUE);
            if (p->sidebar_child) SetWindowRgn(p->sidebar_child, NULL, TRUE);
            carve_caption_buttons(p->host_hwnd, rightmost, rx, rw, H, ir);
        }
    }
    return 1;
}

int windows_panes_layout(int32_t host_slot) { return windows_panes_layout_ex(host_slot, true); }

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
    p->sidebar_resizable = 1;      // default draggable (memset zeroed them)
    p->inspector_resizable = 1;

    bool has_sidebar = (sidebar_slot >= 0 && sidebar_url && sidebar_url[0]);
    bool has_inspector = (inspector_slot >= 0 && inspector_url && inspector_url[0]);

    // See-through host (Mica/transparent, set by window.c before panes_init):
    // pane children paint NO background so the DWM backdrop shows through the
    // alpha-0 webviews. Opaque hosts keep the theme brush (drag-gap fill).
    extern bool windows_webview_get_seethrough(int32_t);
    bool host_seethrough = windows_webview_get_seethrough(host_slot);
    const wchar_t* pane_cls = host_seethrough ? PANE_HOST_CLEAR_CLASS : PANE_HOST_CLASS;

    p->content_child = make_child(host_hwnd, pane_cls);

    if (has_sidebar) {
        p->sidebar_slot = sidebar_slot;
        p->sidebar_width = sx(host_hwnd, sb_width);
        p->sidebar_min = sx(host_hwnd, sb_min);
        p->sidebar_max = sx(host_hwnd, sb_max);
        p->sidebar_collapsed = sb_collapsed ? 1 : 0;
        p->sidebar_child = make_child(host_hwnd, pane_cls);
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
        p->inspector_child = make_child(host_hwnd, pane_cls);
        p->inspector_splitter = make_child(host_hwnd, PANE_SPLIT_CLASS);
        SetWindowLongPtrW(p->inspector_splitter, GWLP_USERDATA, host_slot + 1);
        windows_window_register_pane_id(inspector_slot, host_slot); // sender→host remap
    }

    windows_panes_layout(host_slot);

    // Panes inherit the host window's see-through state (DWM backdrop / transparent
    // window), set on host_slot by window.c. Must land BEFORE each pane's
    // controller builds so DefaultBackgroundColor picks alpha-0 (backdrop shows)
    // vs an opaque theme surface (plain window → windowed transparency is white).
    extern void windows_webview_set_seethrough(int32_t, bool);
    // All panes inherit the host's see-through (Mica) state (queried above for
    // the pane-class pick).
    if (has_sidebar)   windows_webview_set_seethrough(sidebar_slot, host_seethrough);
    if (has_inspector) windows_webview_set_seethrough(inspector_slot, host_seethrough);

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
    windows_titlebar_relocate_controls(host_slot);  // buttons → content (now rightmost)
    pane_emit(host_slot, p->inspector_slot, "inspector-collapsed", NULL);
}
void windows_inspector_expand(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p || p->inspector_slot < 0 || !p->inspector_collapsed) return;
    p->inspector_collapsed = 0;
    windows_panes_layout(host_slot);
    windows_titlebar_relocate_controls(host_slot);  // buttons → inspector (now rightmost)
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

// iPhone master-detail column reveal (iOS UISplitViewController). Windows panes
// are always side-by-side (no compact collapse), so there's nothing to reveal:
// no-ops (router parity with ios/sidebar.m + darwin/sidebar.m).
void windows_sidebar_show_content(int32_t host_slot) { (void)host_slot; }
void windows_sidebar_show_sidebar(int32_t host_slot) { (void)host_slot; }

// Collapse/resize gating is a macOS NSSplitViewItem affordance; the Win32 pane
// splitter doesn't expose an equivalent yet, so these are no-ops (router parity).
void windows_sidebar_set_collapsible(int32_t host_slot, bool can_collapse) { (void)host_slot; (void)can_collapse; }
void windows_sidebar_set_resizable(int32_t host_slot, bool resizable) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (p) p->sidebar_resizable = resizable ? 1 : 0;
}
void windows_inspector_set_collapsible(int32_t host_slot, bool can_collapse) { (void)host_slot; (void)can_collapse; }
void windows_inspector_set_resizable(int32_t host_slot, bool resizable) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (p) p->inspector_resizable = resizable ? 1 : 0;
}
// windows:{ paneSeparators:false } — collapse the splitter band to zero width for
// a flush, seamless split. Re-lays out so the panes sit edge-to-edge.
void windows_sidebar_set_pane_separators(int32_t host_slot, bool visible) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p) return;
    p->splitter_px = visible ? sx(p->host_hwnd, ZAPP_SPLITTER_PX) : 0;
    windows_panes_layout(host_slot);
}
// The webview slot that hosts the caption buttons: the RIGHTMOST-VISIBLE pane —
// the inspector when present and expanded, otherwise the content/host webview.
// (Non-paned windows report the host slot itself.) Web caption buttons render
// only in this webview, which is the one reaching the window's right edge.
int32_t windows_pane_controls_slot(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p) return host_slot;
    return (p->inspector_slot >= 0 && !p->inspector_collapsed) ? p->inspector_slot : host_slot;
}

// Move the caption buttons to the current controls slot, clearing the other
// candidate. Called after the inspector collapses/expands (the rightmost-visible
// pane changed, so the buttons must follow it to the window's right edge).
void windows_titlebar_relocate_controls(int32_t host_slot) {
    ZappPaneWindow* p = panes_for(host_slot);
    if (!p) return;
    int32_t controls = windows_pane_controls_slot(host_slot);
    int32_t other = (controls == host_slot) ? p->inspector_slot : host_slot;
    extern void windows_titlebar_push_state(int32_t, int32_t, int);
    windows_titlebar_push_state(host_slot, controls, 1);
    if (other >= 0) windows_titlebar_push_state(host_slot, other, 0);
}
