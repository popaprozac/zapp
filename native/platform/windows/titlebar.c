// titlebar.c — custom title bar (titleBarStyle hidden/hiddenInset). See
// titlebar.h for the macOS-parity model. Pass 1: caption removal + floated
// native caption buttons + theming. Pass 2 (follow-up): web-driven drag +
// CSS metric vars.

#include "titlebar.h"
#include <windowsx.h>   // GET_X_LPARAM
#include <string.h>

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

typedef struct {
    bool    enabled;
    int32_t style_tag;   // 1 hidden, 2 hiddenInset
    HWND    host;
    HWND    btn;         // caption-button child window
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

    tb_ensure_class();
    if (!tb->btn) {
        tb->btn = CreateWindowExW(0, TB_BTN_CLASS, L"",
            WS_CHILD | WS_CLIPSIBLINGS | WS_VISIBLE, 0, 0, 0, 0,
            hwnd, NULL, GetModuleHandleW(NULL), NULL);
        if (tb->btn) SetWindowLongPtrW(tb->btn, GWLP_USERDATA, window_id);
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
    // When maximized, Windows pushes the frame off-screen by the frame size;
    // re-inset the top so content isn't clipped by the monitor edge.
    if (IsZoomed(hwnd)) {
        UINT dpi = GetDpiForWindow(hwnd); if (!dpi) dpi = 96;
        p->rgrc[0].top += MulDiv(GetSystemMetrics(SM_CYFRAME), dpi, 96)
                        + MulDiv(GetSystemMetrics(SM_CXPADDEDBORDER), dpi, 96);
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
    if (!tb->btn || !tb->host) return;
    RECT rc; GetClientRect(tb->host, &rc);
    int vis[TB_COUNT]; int n = tb_visible(tb, vis);   // only visible buttons
    int bw  = tb_scale(tb->host, TB_BTN_W) * n;
    int bh  = tb_scale(tb->host, TB_BTN_H);
    // hiddenInset degrades to hidden on Windows — the macOS unified-toolbar inset
    // has no sensible Win analogue and reads as awkward. Buttons sit flush top.
    // Raise above the WebView2 surface (sibling child); re-raised on each resize.
    // n==0 (all controls hidden) → zero-width cluster, effectively no buttons.
    SetWindowPos(tb->btn, HWND_TOP, rc.right - bw, 0, bw, bh,
        SWP_NOACTIVATE | (n > 0 ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
    InvalidateRect(tb->btn, NULL, FALSE);
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
    // the VISIBLE cluster width so web content reserves exactly the shown buttons.
    int vis[TB_COUNT]; int n = tb_visible(&g_tb[window_id], vis);
    if (height_logical)      *height_logical = TB_BTN_H;
    if (inset_right_logical) *inset_right_logical = TB_BTN_W * n;
    return true;
}

// Apply per-button window-control visibility/state (from the app's
// windowControls/trafficLights: 0=enabled, 1=disabled, 2=hidden). Re-lays out +
// repaints. Windows caption order is minimize, maximize, close.
void windows_titlebar_set_controls(int32_t window_id, int close_state, int min_state, int max_state) {
    if (!windows_titlebar_enabled(window_id)) return;
    TitleBar* tb = &g_tb[window_id];
    tb->state[TB_MIN]   = min_state;
    tb->state[TB_MAX]   = max_state;
    tb->state[TB_CLOSE] = close_state;
    windows_titlebar_layout(window_id);
}
