// titlebar.c — custom title bar (titleBarStyle hidden/hiddenInset). See
// titlebar.h for the macOS-parity model. Pass 1: caption removal + floated
// native caption buttons + theming. Pass 2 (follow-up): web-driven drag +
// CSS metric vars.

#include "titlebar.h"
#include <windowsx.h>   // GET_X_LPARAM
#include <dwmapi.h>     // DwmGetWindowAttribute(DWMWA_CAPTION_BUTTON_BOUNDS)
#include <string.h>
#include <stdio.h>      // snprintf

#ifndef DWMWA_CAPTION_BUTTON_BOUNDS
#define DWMWA_CAPTION_BUTTON_BOUNDS 5
#endif

// Number of caption buttons DWM actually DRAWS, from the WS_*BOX styles (Win32's
// own rule — deterministic + immediate, unlike DWMWA_CAPTION_BUTTON_BOUNDS which
// lags a style change): no WS_SYSMENU → 0; both min/max boxes absent → 1 (close
// only); otherwise 3 (a single absent box greys, not hides). Drives the pane
// carve width (sidebar.c) + the content inset (metrics), so both track hidden
// controls exactly.
int windows_titlebar_drawn_button_count(HWND hwnd) {
    LONG_PTR s = GetWindowLongPtrW(hwnd, GWL_STYLE);
    if (!(s & WS_SYSMENU)) return 0;
    return ((s & WS_MINIMIZEBOX) || (s & WS_MAXIMIZEBOX)) ? 3 : 1;
}

#define ZAPP_MAX_WINDOWS 64   // matches window.c

// Caption button indices.
#define TB_MIN   0
#define TB_MAX   1
#define TB_CLOSE 2
#define TB_COUNT 3
#define TB_NONE  (-1)

// Logical (96-dpi) caption button metrics; scaled per-window.
#define TB_BTN_W 46
#define TB_BTN_H 32

extern const char* windows_get_theme(void); // platform.c → "dark" | "light"

// Forward decls (defined below; also called cross-TU from webview.c/window.c).
void windows_titlebar_sync_web(int32_t window_id);
void windows_titlebar_controls_desc(int32_t window_id, char* buf);

// NATIVE (DWM) vs WEB caption buttons.
//   true  → keep WS_SYSMENU + a "sheet of glass" frame ({-1}) so DWM DRAWS the
//           min/max/close buttons itself (they composite above the webview);
//           WM_NCHITTEST (windows_titlebar_nchittest) feeds DwmDefWindowProc the
//           button hit-tests so hover + Snap Layouts + press work, and the system
//           menu / Alt+Space come free from DefWindowProc. The one path to fully
//           native caption chrome over Mica (GDI can't composite on glass; web
//           buttons work but lack Snap Layouts + a clean system menu).
//   false → web-rendered buttons (bootstrap/webview.ts).
// The DWM path needs the windowed WebView2 to NOT cover the caption-button
// corner (else it swallows the WM_NCMOUSEMOVE/WM_NCLBUTTONDOWN stream
// DwmDefWindowProc needs — WebView2Feedback #446). We carve that rect out of the
// rightmost pane container via SetWindowRgn (sidebar.c), so input falls through
// to the host → native hover / Snap / click. See DWMWA_CAPTION_BUTTON_BOUNDS.
//
// PER-WINDOW: native is the default, BUT modern DWM caption buttons are
// all-or-nothing — removing a WS_*BOX to hide/disable a single min/max button
// drops DWM to legacy rendering + a dead phantom slot (confirmed; no modern
// "subset" layout). So a window whose windowControls hides/disables min/max (or
// hides close) falls back to WEB buttons, which do per-button hide/disable
// cleanly. window.c sets the flag at create via windows_titlebar_set_web_buttons.
static int g_web_buttons[ZAPP_MAX_WINDOWS] = {0};   // 1 = web, 0 = native (default)
void windows_titlebar_set_web_buttons(int32_t window_id, int web) {
    if (window_id >= 0 && window_id < ZAPP_MAX_WINDOWS) g_web_buttons[window_id] = web ? 1 : 0;
}
bool windows_titlebar_native_controls(int32_t window_id) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return true;
    return !g_web_buttons[window_id];
}

typedef struct {
    bool    enabled;
    int32_t style_tag;   // 1 hidden, 2 hiddenInset
    HWND    host;
    HWND    btn;         // caption-button child window (native-controls mode only)
    int     hover;       // TB_* or TB_NONE
    int     pressed;     // TB_* or TB_NONE
    bool    tracking;    // WM_MOUSELEAVE armed
    int     state[TB_COUNT]; // per-button [TB_MIN/TB_MAX/TB_CLOSE]: 0=enabled 1=disabled 2=hidden
} TitleBar;

static TitleBar g_tb[ZAPP_MAX_WINDOWS];

static const wchar_t* TB_BTN_CLASS = L"ZappTitlebarButtons";

static bool tb_is_dark(void) {
    const char* t = windows_get_theme();
    return t && strcmp(t, "dark") == 0;
}

static int tb_scale(HWND h, int v) {
    UINT dpi = GetDpiForWindow(h);
    if (!dpi) dpi = 96;
    return MulDiv(v, (int)dpi, 96);
}

// Native (DWM) mode: which caption-button HT* code covers the screen point in
// lParam, or HTNOWHERE. Fed to WM_NCHITTEST so DwmDefWindowProc renders hover /
// Snap Layouts / press. Buttons are right-aligned, order (l→r) min,max,close, so
// from the right edge slot 0=close, 1=maximize, 2=minimize.
LRESULT windows_titlebar_nchittest(HWND hwnd, int32_t window_id, LPARAM lParam) {
    if (!windows_titlebar_enabled(window_id) || !windows_titlebar_native_controls(window_id))
        return HTNOWHERE;
    TitleBar* tb = &g_tb[window_id];
    POINT pt = { GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam) };
    ScreenToClient(hwnd, &pt);                 // caption is reclaimed into client
    int bw = tb_scale(hwnd, TB_BTN_W);
    int bh = tb_scale(hwnd, TB_BTN_H);
    if (bw <= 0 || pt.y < 0 || pt.y >= bh) return HTNOWHERE;
    RECT rc; GetClientRect(hwnd, &rc);
    int fromRight = rc.right - pt.x;
    if (fromRight < 0 || fromRight >= 3 * bw) return HTNOWHERE;
    int slot = fromRight / bw;                  // 0=close,1=max,2=min
    if (slot == 0 && tb->state[TB_CLOSE] == 0) return HTCLOSE;
    if (slot == 1 && tb->state[TB_MAX]   == 0) return HTMAXBUTTON;
    if (slot == 2 && tb->state[TB_MIN]   == 0) return HTMINBUTTON;
    return HTNOWHERE;
}

// Non-hidden buttons in min,max,close order → vis[]; returns the count. Hidden
// (state==2) buttons are dropped so the cluster is laid out contiguously.
static int tb_visible(TitleBar* tb, int vis[TB_COUNT]) {
    int n = 0;
    for (int i = 0; i < TB_COUNT; i++) if (tb->state[i] != 2) vis[n++] = i;
    return n;
}

// Logical button index under an x within the button child, or TB_NONE. Maps the
// x-slot through the visible list and rejects disabled (state==1) buttons so
// they neither hover nor click.
static int tb_hit(HWND btn, int x) {
    int32_t wid = (int32_t)GetWindowLongPtrW(btn, GWLP_USERDATA);
    if (wid < 0 || wid >= ZAPP_MAX_WINDOWS) return TB_NONE;
    TitleBar* tb = &g_tb[wid];
    int bw = tb_scale(btn, TB_BTN_W);
    if (bw <= 0) return TB_NONE;
    int vis[TB_COUNT]; int n = tb_visible(tb, vis);
    int slot = x / bw;
    if (slot < 0 || slot >= n) return TB_NONE;
    int logical = vis[slot];
    return (tb->state[logical] == 0) ? logical : TB_NONE;  // disabled → inert
}

static void tb_paint(HWND btn) {
    int32_t wid = (int32_t)GetWindowLongPtrW(btn, GWLP_USERDATA);
    if (wid < 0 || wid >= ZAPP_MAX_WINDOWS) return;
    TitleBar* tb = &g_tb[wid];

    RECT rc; GetClientRect(btn, &rc);
    PAINTSTRUCT ps; HDC hdc = BeginPaint(btn, &ps);

    bool dark = tb_is_dark();
    COLORREF base    = dark ? RGB(32, 32, 32)   : RGB(243, 243, 243);
    COLORREF glyph   = dark ? RGB(255, 255, 255): RGB(0, 0, 0);
    COLORREF hoverbg = dark ? RGB(45, 45, 45)   : RGB(229, 229, 229);
    COLORREF closebg = RGB(232, 17, 35);  // Windows close-hover red

    HBRUSH bg = CreateSolidBrush(base);
    FillRect(hdc, &rc, bg);
    DeleteObject(bg);

    int bw = tb_scale(btn, TB_BTN_W);
    int fh = tb_scale(btn, 10);
    HFONT font = CreateFontW(-fh, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe MDL2 Assets");
    HFONT oldFont = (HFONT)SelectObject(hdc, font);
    SetBkMode(hdc, TRANSPARENT);

    // Segoe MDL2 Assets: minimize E921, maximize E922, restore E923, close E8BB.
    static const wchar_t glyphs[TB_COUNT] = { 0xE921, 0xE922, 0xE8BB };
    COLORREF greyed = dark ? RGB(110, 110, 110) : RGB(150, 150, 150);
    int vis[TB_COUNT]; int n = tb_visible(tb, vis);
    for (int s = 0; s < n; s++) {           // draw visible buttons contiguously
        int i = vis[s];                     // logical index (TB_MIN/TB_MAX/TB_CLOSE)
        bool disabled = (tb->state[i] == 1);
        RECT b = { s * bw, rc.top, (s + 1) * bw, rc.bottom };
        bool active = !disabled && (i == tb->hover || i == tb->pressed);
        if (active) {
            HBRUSH hb = CreateSolidBrush(i == TB_CLOSE ? closebg : hoverbg);
            FillRect(hdc, &b, hb);
            DeleteObject(hb);
        }
        SetTextColor(hdc, disabled ? greyed
                        : (i == TB_CLOSE && active) ? RGB(255, 255, 255) : glyph);
        wchar_t g = glyphs[i];
        if (i == TB_MAX && tb->host && IsZoomed(tb->host)) g = 0xE923; // restore
        DrawTextW(hdc, &g, 1, &b, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOCLIP);
    }

    SelectObject(hdc, oldFont);
    DeleteObject(font);
    EndPaint(btn, &ps);
}

static LRESULT CALLBACK tb_btn_proc(HWND btn, UINT msg, WPARAM wp, LPARAM lp) {
    int32_t wid = (int32_t)GetWindowLongPtrW(btn, GWLP_USERDATA);
    TitleBar* tb = (wid >= 0 && wid < ZAPP_MAX_WINDOWS) ? &g_tb[wid] : NULL;
    switch (msg) {
        case WM_PAINT:      tb_paint(btn); return 0;
        case WM_ERASEBKGND: return 1;
        case WM_MOUSEMOVE: {
            if (!tb) break;
            if (!tb->tracking) {
                TRACKMOUSEEVENT tme = { sizeof(tme), TME_LEAVE, btn, 0 };
                TrackMouseEvent(&tme);
                tb->tracking = true;
            }
            int h = tb_hit(btn, GET_X_LPARAM(lp));
            if (h != tb->hover) { tb->hover = h; InvalidateRect(btn, NULL, FALSE); }
            return 0;
        }
        case WM_MOUSELEAVE: {
            if (!tb) break;
            tb->tracking = false;
            if (tb->hover != TB_NONE) { tb->hover = TB_NONE; InvalidateRect(btn, NULL, FALSE); }
            return 0;
        }
        case WM_LBUTTONDOWN: {
            if (!tb) break;
            tb->pressed = tb_hit(btn, GET_X_LPARAM(lp));
            SetCapture(btn);
            InvalidateRect(btn, NULL, FALSE);
            return 0;
        }
        case WM_LBUTTONUP: {
            if (!tb) break;
            int up = tb_hit(btn, GET_X_LPARAM(lp));
            int pressed = tb->pressed;
            tb->pressed = TB_NONE;
            ReleaseCapture();
            InvalidateRect(btn, NULL, FALSE);
            if (up == pressed && pressed != TB_NONE && tb->host) {
                WPARAM sc = 0;
                if (pressed == TB_MIN)        sc = SC_MINIMIZE;
                else if (pressed == TB_MAX)   sc = IsZoomed(tb->host) ? SC_RESTORE : SC_MAXIMIZE;
                else if (pressed == TB_CLOSE) sc = SC_CLOSE;
                if (sc) PostMessageW(tb->host, WM_SYSCOMMAND, sc, 0);
            }
            return 0;
        }
    }
    return DefWindowProcW(btn, msg, wp, lp);
}

static void tb_ensure_class(void) {
    static bool done = false;
    if (done) return;
    WNDCLASSEXW wc = { sizeof(wc) };
    wc.lpfnWndProc   = tb_btn_proc;
    wc.hInstance     = GetModuleHandleW(NULL);
    wc.hCursor       = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = NULL;
    wc.lpszClassName = TB_BTN_CLASS;
    RegisterClassExW(&wc);
    done = true;
}

// --- public API -------------------------------------------------------------
void windows_titlebar_enable(HWND hwnd, int32_t window_id, int32_t style_tag) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return;
    if (style_tag != 1 && style_tag != 2) return;  // default = no custom chrome

    TitleBar* tb = &g_tb[window_id];
    tb->enabled   = true;
    tb->style_tag = style_tag;
    tb->host      = hwnd;
    tb->hover     = TB_NONE;
    tb->pressed   = TB_NONE;
    tb->state[TB_MIN] = tb->state[TB_MAX] = tb->state[TB_CLOSE] = 0;  // all enabled

    SetMenu(hwnd, NULL);  // custom titlebar windows drop the native menu bar

    if (windows_titlebar_native_controls(window_id)) {
        // NATIVE (DWM) caption buttons: DWM draws them (WS_SYSMENU + sheet-of-glass
        // frame, both in window.c/material.c); we only feed hit-tests via
        // windows_titlebar_nchittest. No child window to create.
        tb->btn = NULL;
    } else {
        // WEB-rendered caption buttons (bootstrap/webview.ts): the webview draws
        // them from --zapp-window-controls-inset-right + the data-zapp-window-*
        // attributes and routes clicks to WM_SYSCOMMAND.
        tb->btn = NULL;
    }

    // Mark the frame changed so WM_NCCALCSIZE runs with the window now custom.
    SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
        SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    windows_titlebar_layout(window_id);
}

bool windows_titlebar_enabled(int32_t window_id) {
    return window_id >= 0 && window_id < ZAPP_MAX_WINDOWS && g_tb[window_id].enabled;
}

bool windows_titlebar_nccalcsize(HWND hwnd, int32_t window_id, WPARAM wParam, LPARAM lParam) {
    if (!windows_titlebar_enabled(window_id) || !wParam) return false;
    NCCALCSIZE_PARAMS* p = (NCCALCSIZE_PARAMS*)lParam;
    RECT before = p->rgrc[0];
    DefWindowProcW(hwnd, WM_NCCALCSIZE, wParam, lParam);  // standard client insets
    // Reclaim the caption band so web content reaches the top edge; keep the
    // side/bottom resize-border insets DefWindowProc computed.
    p->rgrc[0].top = before.top;
    // When maximized, Windows pushes the frame off-screen by the frame size, so
    // the client top must move down to the monitor WORK-AREA top. Use the EXACT
    // overhang (work-area top − proposed window top), not an SM_CYFRAME estimate:
    // a pixel of slop at the top edge breaks DWM's Y=0 hover tracking when
    // maximized (WM_NCMOUSEMOVE stops firing → caption buttons don't highlight).
    if (IsZoomed(hwnd)) {
        HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        MONITORINFO mi = { sizeof(mi) };
        int overhang = 0;
        if (GetMonitorInfoW(mon, &mi)) overhang = mi.rcWork.top - before.top;
        if (overhang <= 0) {   // fallback
            UINT dpi = GetDpiForWindow(hwnd); if (!dpi) dpi = 96;
            overhang = MulDiv(GetSystemMetrics(SM_CYFRAME), dpi, 96)
                     + MulDiv(GetSystemMetrics(SM_CXPADDEDBORDER), dpi, 96);
        }
        p->rgrc[0].top += overhang;
    }
    return true;
}

bool windows_titlebar_ncactivate(HWND hwnd, int32_t window_id, WPARAM wParam, LRESULT* result) {
    if (!windows_titlebar_enabled(window_id)) return false;
    // lParam = -1 tells DWM not to redraw the (light) inactive frame line.
    *result = DefWindowProcW(hwnd, WM_NCACTIVATE, wParam, (LPARAM)-1);
    return true;
}

void windows_titlebar_layout(int32_t window_id) {
    if (!windows_titlebar_enabled(window_id)) return;
    TitleBar* tb = &g_tb[window_id];
    if (!tb->host) return;
    RECT rc; GetClientRect(tb->host, &rc);
    int vis[TB_COUNT]; int n = tb_visible(tb, vis);   // only visible buttons
    int bw1 = tb_scale(tb->host, TB_BTN_W);
    int bh  = tb_scale(tb->host, TB_BTN_H);
    if (tb->btn) {
        int bw = bw1 * n;
        // hiddenInset degrades to hidden on Windows — the macOS unified-toolbar
        // inset has no sensible Win analogue and reads as awkward. Buttons sit
        // flush top. Raise above the WebView2 surface (sibling child); re-raised
        // on each resize. n==0 (all hidden) → zero-width, effectively no buttons.
        SetWindowPos(tb->btn, HWND_TOP, rc.right - bw, 0, bw, bh,
            SWP_NOACTIVATE | (n > 0 ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
        InvalidateRect(tb->btn, NULL, FALSE);
    }
    (void)bw1;
}

void windows_titlebar_theme_changed(int32_t window_id) {
    if (!windows_titlebar_enabled(window_id)) return;
    if (g_tb[window_id].btn) InvalidateRect(g_tb[window_id].btn, NULL, FALSE);
}

void windows_titlebar_destroy(int32_t window_id) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return;
    TitleBar* tb = &g_tb[window_id];
    if (tb->btn) { DestroyWindow(tb->btn); tb->btn = NULL; }
    tb->enabled = false;
    tb->host = NULL;
}

bool windows_titlebar_metrics(int32_t window_id, int* height_logical, int* inset_right_logical) {
    if (!windows_titlebar_enabled(window_id)) return false;
    // Logical (96-dpi) values — CSS px in the DPI-aware webview. inset_right is
    // the cluster width so web content reserves exactly the shown buttons.
    TitleBar* tb = &g_tb[window_id];
    if (height_logical) *height_logical = TB_BTN_H;
    if (inset_right_logical) {
        // NATIVE (DWM) mode: reserve the DRAWN-button count × button width (from
        // the WS_*BOX styles) so content padding tracks hidden controls exactly.
        // Web mode: our tb_visible count (it hides individual buttons itself).
        int n;
        if (windows_titlebar_native_controls(window_id) && tb->host) {
            n = windows_titlebar_drawn_button_count(tb->host);
        } else {
            int vis[TB_COUNT]; n = tb_visible(tb, vis);
        }
        *inset_right_logical = TB_BTN_W * n;
    }
    return true;
}

// Apply per-button window-control visibility/state (from the app's
// windowControls: 0=enabled, 1=disabled, 2=hidden). Re-lays out +
// repaints. Windows caption order is minimize, maximize, close.
void windows_titlebar_set_controls(int32_t window_id, int close_state, int min_state, int max_state) {
    if (!windows_titlebar_enabled(window_id)) return;
    TitleBar* tb = &g_tb[window_id];
    tb->state[TB_MIN]   = min_state;
    tb->state[TB_MAX]   = max_state;
    tb->state[TB_CLOSE] = close_state;
    if (windows_titlebar_native_controls(window_id)) {
        // NATIVE (DWM) mode: DWM draws min/max from the WS_*BOX styles, so drive
        // them from windowControls (present=enabled; removed=greyed, or hidden if
        // BOTH min+max are removed — a Win32 rule we can't split per-button).
        // Close can't be removed without losing the system menu / Alt+Space, so
        // it's greyed via the system menu instead of hidden. DWM's
        // CAPTION_BUTTON_BOUNDS then reflects the drawn set → the carve follows.
        HWND h = tb->host;
        LONG_PTR style = GetWindowLongPtrW(h, GWL_STYLE);
        if (min_state == 0) style |= WS_MINIMIZEBOX; else style &= ~WS_MINIMIZEBOX;
        if (max_state == 0) style |= WS_MAXIMIZEBOX; else style &= ~WS_MAXIMIZEBOX;
        SetWindowLongPtrW(h, GWL_STYLE, style);
        HMENU sys = GetSystemMenu(h, FALSE);
        if (sys) EnableMenuItem(sys, SC_CLOSE,
                     MF_BYCOMMAND | (close_state == 0 ? MF_ENABLED : MF_GRAYED));
        SetWindowPos(h, NULL, 0, 0, 0, 0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        // Force DWM to REPAINT the caption — the frame-change alone leaves a dead
        // "ghost" of a button whose WS_*BOX we just removed (DWM drew it at create
        // and doesn't re-render the caption on a bare style change).
        RedrawWindow(h, NULL, NULL, RDW_FRAME | RDW_INVALIDATE | RDW_UPDATENOW);
        // Re-run the PANE layout so the caption-button carve recomputes against
        // the new drawn-button count (windows_titlebar_layout only repositions
        // the native GDI child, which DWM mode doesn't use).
        extern int windows_panes_layout(int32_t);
        windows_panes_layout(window_id);
    }
    windows_titlebar_layout(window_id);   // reposition (GDI native-button mode)
    if (!windows_titlebar_native_controls(window_id)) windows_titlebar_sync_web(window_id);
}

// Per-button state descriptor for the web buttons: 3 chars (min, max, close),
// 'e'=enabled 'd'=disabled 'h'=hidden. buf must hold >= 4 bytes.
void windows_titlebar_controls_desc(int32_t window_id, char* buf) {
    static const char code[3] = { 'e', 'd', 'h' };  // state 0/1/2
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) { buf[0] = '\0'; return; }
    // Native mode: empty desc → the bootstrap renders NO web cluster (it still
    // gets the inset var so app chrome pads around the native buttons).
    if (windows_titlebar_native_controls(window_id)) { buf[0] = '\0'; return; }
    TitleBar* tb = &g_tb[window_id];
    for (int i = 0; i < TB_COUNT; i++) {
        int s = tb->state[i]; if (s < 0 || s > 2) s = 0;
        buf[i] = code[s];
    }
    buf[TB_COUNT] = '\0';
}

// Push the current caption-button state (per-button visibility + maximized glyph)
// to the host webview so the web buttons re-render. Called on maximize/restore
// (WM_SIZE) and windowControls changes. The initial state is injected inline by
// webview.c's metrics script at document load.
// Push caption-button state to `webview_slot`. visible=0 hides (inset 0, no
// buttons); visible=1 shows the reserved inset + per-button state + maximized
// glyph. Used to (re)project the buttons onto the rightmost-visible pane
// (windows_titlebar_relocate_controls) and to refresh state in place.
void windows_titlebar_push_state(int32_t host_slot, int32_t webview_slot, int visible) {
    if (!windows_titlebar_enabled(host_slot)) return;
    if (windows_titlebar_native_controls(host_slot)) return;   // native mode: no web cluster
    extern void windows_webview_eval_by_id(int32_t, const char*);
    char js[512];
    if (visible) {
        int th = 0, ir = 0; windows_titlebar_metrics(host_slot, &th, &ir);
        char desc[TB_COUNT + 1]; windows_titlebar_controls_desc(host_slot, desc);
        int maxed = (g_tb[host_slot].host && IsZoomed(g_tb[host_slot].host)) ? 1 : 0;
        snprintf(js, sizeof(js),
            "(function(){var r=document.documentElement;if(r){"
            "r.style.setProperty('--zapp-window-controls-inset-right','%dpx');"
            "r.setAttribute('data-zapp-window-controls','%s');"
            "r.setAttribute('data-zapp-window-maximized','%d');}})();",
            ir, desc, maxed);
    } else {
        // Directly remove the cluster (don't rely on the MutationObserver — the
        // hide must be certain so a pane that no longer hosts the buttons can't
        // keep a stale cluster).
        snprintf(js, sizeof(js),
            "(function(){var r=document.documentElement;if(r){"
            "r.style.setProperty('--zapp-window-controls-inset-right','0px');"
            "r.setAttribute('data-zapp-window-controls','');}"
            "var cs=document.querySelectorAll('[data-zapp-winctl]');"
            "for(var i=0;i<cs.length;i++)cs[i].remove();})();");
    }
    windows_webview_eval_by_id(webview_slot, js);
}

// Refresh state (maximized glyph / per-button visibility) on the CURRENT
// controls webview (the rightmost-visible pane) without moving the buttons.
void windows_titlebar_sync_web(int32_t window_id) {
    if (!windows_titlebar_enabled(window_id)) return;
    extern int32_t windows_pane_controls_slot(int32_t);
    windows_titlebar_push_state(window_id, windows_pane_controls_slot(window_id), 1);
}

// Native parity: dim the web caption buttons when the window loses focus.
// Pushed from WM_ACTIVATE (window.c); CSS keys off data-zapp-window-focused.
void windows_titlebar_set_focused(int32_t window_id, bool focused) {
    if (!windows_titlebar_enabled(window_id)) return;
    if (windows_titlebar_native_controls(window_id)) {
        if (g_tb[window_id].btn) InvalidateRect(g_tb[window_id].btn, NULL, FALSE);
        return;
    }
    extern int32_t windows_pane_controls_slot(int32_t);
    extern void windows_webview_eval_by_id(int32_t, const char*);
    char js[160];
    snprintf(js, sizeof(js),
        "(function(){var r=document.documentElement;"
        "if(r)r.setAttribute('data-zapp-window-focused','%d');})();", focused ? 1 : 0);
    windows_webview_eval_by_id(windows_pane_controls_slot(window_id), js);
}

