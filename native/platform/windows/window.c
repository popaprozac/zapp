// Windows window management.
// HWND creation, WndProc, dispatch tables, window operations, event dispatch.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "window.h"

// --- Forward declarations ---

extern HINSTANCE zapp_get_hinstance(void);
extern const wchar_t* zapp_get_window_class(void);
extern void zapp_increment_window_count(void);
extern void zapp_decrement_window_count(void);
extern void windows_webview_create(void* hwnd_ptr, bool inspectable, const char* url_override);
extern int zapp_dispatch_event(int window_id, int event_id, int w, int h, int x, int y);
extern int zapp_app_dispatch(int event_id, const char* data);   // app-level events (app_events.nim)

// App-level event IDs forwarded via zapp_app_dispatch (app_events.nim name map).
#define ZAPP_EVENT_APP_ACTIVE          106
#define ZAPP_EVENT_APP_INACTIVE        107
#define ZAPP_EVENT_APP_SCREEN_LOCKED   111
#define ZAPP_EVENT_APP_SCREEN_UNLOCKED 112
#define ZAPP_EVENT_APP_SCREENS_CHANGED 116

// Session lock/unlock (Win+L) via WTS notifications. These constants live in
// wtsapi32.h (not pulled in under WIN32_LEAN_AND_MEAN) — define locally and load
// the register/unregister entry points dynamically to avoid a wtsapi32 link dep.
#ifndef WM_WTSSESSION_CHANGE
#define WM_WTSSESSION_CHANGE 0x02B1
#endif
#ifndef NOTIFY_FOR_THIS_SESSION
#define NOTIFY_FOR_THIS_SESSION 0
#endif
#ifndef WTS_SESSION_LOCK
#define WTS_SESSION_LOCK   0x7
#define WTS_SESSION_UNLOCK 0x8
#endif

static void zapp_wts_register(HWND hwnd) {
    HMODULE lib = LoadLibraryW(L"wtsapi32.dll");
    if (!lib) return;
    typedef BOOL (WINAPI *RegFn)(HWND, DWORD);
    RegFn fn = (RegFn)GetProcAddress(lib, "WTSRegisterSessionNotification");
    if (fn) fn(hwnd, NOTIFY_FOR_THIS_SESSION);
    // Leave the module loaded — the registration outlives this call.
}
static void zapp_wts_unregister(HWND hwnd) {
    HMODULE lib = GetModuleHandleW(L"wtsapi32.dll");
    if (!lib) return;
    typedef BOOL (WINAPI *UnregFn)(HWND);
    UnregFn fn = (UnregFn)GetProcAddress(lib, "WTSUnRegisterSessionNotification");
    if (fn) fn(hwnd);
}

// --- DPI helper ---

static UINT zapp_get_dpi(void) {
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32) {
        typedef UINT (WINAPI *GetDpiForSystemFn)(void);
        GetDpiForSystemFn fn = (GetDpiForSystemFn)GetProcAddress(user32, "GetDpiForSystem");
        if (fn) return fn();
    }
    return 96;
}

static int zapp_scale(int value, UINT dpi) {
    return MulDiv(value, dpi, 96);
}

// Event IDs (must match events.zc)
#define ZAPP_EVENT_READY        0
#define ZAPP_EVENT_FOCUS        1
#define ZAPP_EVENT_BLUR         2
#define ZAPP_EVENT_RESIZE       3
#define ZAPP_EVENT_MOVE         4
#define ZAPP_EVENT_CLOSE        5
#define ZAPP_EVENT_MINIMIZE     6
#define ZAPP_EVENT_MAXIMIZE     7
#define ZAPP_EVENT_RESTORE      8
#define ZAPP_EVENT_FULLSCREEN   9
#define ZAPP_EVENT_UNFULLSCREEN 10

// EventResult
#define ZAPP_EVENT_ALLOW  0
#define ZAPP_EVENT_CANCEL 1

// --- Dispatch tables (O(1) by numeric window ID) ---

#define ZAPP_MAX_WINDOWS 64

// Forward declare the WebView2 controller type
typedef struct ICoreWebView2Controller ICoreWebView2Controller;

static HWND zapp_hwnds[ZAPP_MAX_WINDOWS] = {0};
static char zapp_window_ids[ZAPP_MAX_WINDOWS][32] = {{0}};
static int zapp_bridge_ready[ZAPP_MAX_WINDOWS] = {0};
static int zapp_was_maximized[ZAPP_MAX_WINDOWS] = {0};
static int zapp_was_minimized[ZAPP_MAX_WINDOWS] = {0};
static int zapp_pending_focus[ZAPP_MAX_WINDOWS] = {0};

// Fullscreen state
static LONG zapp_pre_fullscreen_style[ZAPP_MAX_WINDOWS] = {0};
static RECT zapp_pre_fullscreen_rect[ZAPP_MAX_WINDOWS] = {{0}};
static int zapp_is_fullscreen[ZAPP_MAX_WINDOWS] = {0};

// Map HWND → numeric ID (stored as window user data). Stored as id+1
// so an UNREGISTERED window reads back as -1, not as window 0 —
// CreateWindowExW fires WM_SIZE synchronously before registration, and
// a raw 0 default made the modal's creation-time resize land on the
// main window's webview (the bug where the main webview mirrored a
// new modal's dimensions).
static void zapp_set_window_id(HWND hwnd, int32_t id) {
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)(id + 1));
}

static int32_t zapp_get_window_id(HWND hwnd) {
    return (int32_t)GetWindowLongPtrW(hwnd, GWLP_USERDATA) - 1;
}

// --- UTF conversion helpers ---

static wchar_t* utf8_to_wchar(const char* s) {
    if (!s) return NULL;
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (len <= 0) return NULL;
    wchar_t* ws = (wchar_t*)malloc(len * sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, s, -1, ws, len);
    return ws;
}

static char* wchar_to_utf8(const wchar_t* ws) {
    if (!ws) return NULL;
    int len = WideCharToMultiByte(CP_UTF8, 0, ws, -1, NULL, 0, NULL, NULL);
    if (len <= 0) return NULL;
    char* s = (char*)malloc(len);
    WideCharToMultiByte(CP_UTF8, 0, ws, -1, s, len, NULL, NULL);
    return s;
}

// --- JS event dispatch ---

// Forward declare: eval JS on window's WebView (in webview.c)
extern void windows_webview_eval_by_id(int32_t window_id, const char* js);

void zapp_dispatch_event_to_js(int32_t window_id, int32_t event_id, int32_t w, int32_t h, int32_t x, int32_t y) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return;
    if (!zapp_bridge_ready[window_id]) {
        // Queue focus event if bridge not ready yet
        if (event_id == ZAPP_EVENT_FOCUS) {
            zapp_pending_focus[window_id] = 1;
        }
        return;
    }

    // Map event_id to event name
    const char* name = NULL;
    switch (event_id) {
        case ZAPP_EVENT_READY:       name = "ready"; break;
        case ZAPP_EVENT_FOCUS:       name = "focus"; break;
        case ZAPP_EVENT_BLUR:        name = "blur"; break;
        case ZAPP_EVENT_RESIZE:      name = "resize"; break;
        case ZAPP_EVENT_MOVE:        name = "move"; break;
        case ZAPP_EVENT_CLOSE:       name = "close"; break;
        case ZAPP_EVENT_MINIMIZE:    name = "minimize"; break;
        case ZAPP_EVENT_MAXIMIZE:    name = "maximize"; break;
        case ZAPP_EVENT_RESTORE:     name = "restore"; break;
        case ZAPP_EVENT_FULLSCREEN:  name = "fullscreen"; break;
        case ZAPP_EVENT_UNFULLSCREEN:name = "unfullscreen"; break;
        default: return;
    }

    // Build the JS call on the heap — no fixed-size buffers for
    // outgoing JS (repo lesson; 512B/4KB truncation bug class), and a
    // static buffer here would also race across threads.
    const char* wid = zapp_window_ids[window_id];
    const char* fmt;
    if (event_id == ZAPP_EVENT_RESIZE || event_id == ZAPP_EVENT_MAXIMIZE || event_id == ZAPP_EVENT_RESTORE) {
        fmt = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
              "if(b&&b.dispatchWindowEvent)b.dispatchWindowEvent('%s','%s','{\"width\":%d,\"height\":%d}');})();";
    } else if (event_id == ZAPP_EVENT_MOVE) {
        fmt = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
              "if(b&&b.dispatchWindowEvent)b.dispatchWindowEvent('%s','%s','{\"x\":%d,\"y\":%d}');})();";
    } else {
        fmt = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
              "if(b&&b.dispatchWindowEvent)b.dispatchWindowEvent('%s','%s','{}');})();";
    }
    int arg1 = (event_id == ZAPP_EVENT_MOVE) ? x : w;
    int arg2 = (event_id == ZAPP_EVENT_MOVE) ? y : h;
    int needed = snprintf(NULL, 0, fmt, wid, name, arg1, arg2);
    if (needed < 0) return;
    char* js_buf = (char*)malloc((size_t)needed + 1);
    if (!js_buf) return;
    snprintf(js_buf, (size_t)needed + 1, fmt, wid, name, arg1, arg2);

    windows_webview_eval_by_id(window_id, js_buf);
    free(js_buf);
}

// --- WndProc ---

LRESULT CALLBACK zapp_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    int32_t wid = zapp_get_window_id(hwnd);

    // Messages arriving before registration (inside CreateWindowExW)
    // have no window identity yet — every per-window handler below
    // indexes dispatch tables by wid, so let DefWindowProc have them.
    if (wid < 0 || wid >= ZAPP_MAX_WINDOWS) {
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    switch (msg) {
        case WM_SETTINGCHANGE: {
            // Apps light/dark preference flipped. The lParam string is
            // "ImmersiveColorSet" for theme flips; the handler re-reads
            // the registry and dedupes, so over-matching here is cheap.
            if (lParam && lstrcmpW((LPCWSTR)lParam, L"ImmersiveColorSet") == 0) {
                extern void windows_theme_setting_changed(void);
                windows_theme_setting_changed();
                extern void windows_titlebar_theme_changed(int32_t);
                windows_titlebar_theme_changed(wid);
            }
            break;
        }

        // Custom title bar: remove the caption in NCCALCSIZE and suppress the
        // inactive frame line in NCACTIVATE. Both no-op for non-custom windows.
        case WM_NCCALCSIZE: {
            extern bool windows_titlebar_nccalcsize(HWND, int32_t, WPARAM, LPARAM);
            if (windows_titlebar_nccalcsize(hwnd, wid, wParam, lParam)) return 0;
            break;
        }
        case WM_NCACTIVATE: {
            extern bool windows_titlebar_ncactivate(HWND, int32_t, WPARAM, LRESULT*);
            LRESULT r = 0;
            if (windows_titlebar_ncactivate(hwnd, wid, wParam, &r)) return r;
            break;
        }

        case WM_SIZE: {
            // Get client rect for accurate content dimensions
            RECT client;
            GetClientRect(hwnd, &client);
            int w = client.right - client.left;
            int h = client.bottom - client.top;

            // Resize WebView2 controller bounds. Windows with native panes
            // reflow the whole split; otherwise the single host webview fills
            // the client area.
            extern int windows_panes_layout(int32_t host_slot);
            extern void windows_webview_resize(int32_t window_id, int w, int h);
            if (!windows_panes_layout(wid)) {
                windows_webview_resize(wid, w, h);
            }

            // Keep the custom caption buttons positioned + raised above the
            // (resized) WebView2 surface. No-op for non-custom-titlebar windows.
            extern void windows_titlebar_layout(int32_t);
            windows_titlebar_layout(wid);

            WORD sizeType = LOWORD(wParam);
            if (sizeType == SIZE_MINIMIZED) {
                zapp_was_minimized[wid] = 1;
                zapp_dispatch_event(wid, ZAPP_EVENT_MINIMIZE, 0, 0, 0, 0);
            } else if (sizeType == SIZE_MAXIMIZED) {
                zapp_was_maximized[wid] = 1;
                zapp_was_minimized[wid] = 0;
                zapp_dispatch_event(wid, ZAPP_EVENT_MAXIMIZE, w, h, 0, 0);
                zapp_dispatch_event(wid, ZAPP_EVENT_RESIZE, w, h, 0, 0);
            } else if (sizeType == SIZE_RESTORED) {
                if (zapp_was_maximized[wid] || zapp_was_minimized[wid]) {
                    zapp_was_maximized[wid] = 0;
                    zapp_was_minimized[wid] = 0;
                    zapp_dispatch_event(wid, ZAPP_EVENT_RESTORE, w, h, 0, 0);
                }
                zapp_dispatch_event(wid, ZAPP_EVENT_RESIZE, w, h, 0, 0);
            }
            return 0;
        }

        case WM_MOVE: {
            // Notify WebView2 controller of position change
            extern void windows_webview_notify_position(int32_t window_id);
            extern void windows_panes_notify_move(int32_t host_slot);
            windows_webview_notify_position(wid);
            windows_panes_notify_move(wid); // no-op when no panes

            RECT rc;
            GetWindowRect(hwnd, &rc);
            zapp_dispatch_event(wid, ZAPP_EVENT_MOVE, 0, 0, rc.left, rc.top);
            return 0;
        }

        // Use WM_ACTIVATE instead of WM_SETFOCUS/WM_KILLFOCUS — WebView2 eats focus events
        case WM_ACTIVATE: {
            WORD activateState = LOWORD(wParam);
            if (activateState == WA_ACTIVE || activateState == WA_CLICKACTIVE) {
                zapp_dispatch_event(wid, ZAPP_EVENT_FOCUS, 0, 0, 0, 0);
            } else if (activateState == WA_INACTIVE) {
                zapp_dispatch_event(wid, ZAPP_EVENT_BLUR, 0, 0, 0, 0);
                // Tray-attached windows with dismissOnBlur hide here.
                extern void windows_tray_notify_window_blur(void* hwnd);
                windows_tray_notify_window_blur((void*)hwnd);
            }
            return 0;
        }

        // App-level activation (whole process moves to/from the foreground) —
        // WM_ACTIVATE above is per-window; this is the app:active/inactive
        // analog of NSApplication did-become/resign-active. WM_ACTIVATEAPP is
        // delivered to every top-level window, so dedupe on a process-global
        // state to emit exactly once per transition.
        case WM_ACTIVATEAPP: {
            static int g_app_active = -1;   // -1 = unknown at startup
            int now_active = (wParam != FALSE) ? 1 : 0;
            if (now_active != g_app_active) {
                g_app_active = now_active;
                zapp_app_dispatch(now_active ? ZAPP_EVENT_APP_ACTIVE
                                             : ZAPP_EVENT_APP_INACTIVE, "{}");
            }
            break;
        }

        // Session lock / unlock (Win+L → app:screen-locked/unlocked). Registered
        // on every window (zapp_wts_register), so dedupe on a process-global
        // state to emit once per transition.
        case WM_WTSSESSION_CHANGE: {
            static int g_locked = -1;   // -1 = unknown
            int now_locked = -1;
            if (wParam == WTS_SESSION_LOCK)        now_locked = 1;
            else if (wParam == WTS_SESSION_UNLOCK) now_locked = 0;
            if (now_locked >= 0 && now_locked != g_locked) {
                g_locked = now_locked;
                zapp_app_dispatch(now_locked ? ZAPP_EVENT_APP_SCREEN_LOCKED
                                             : ZAPP_EVENT_APP_SCREEN_UNLOCKED, "{}");
            }
            break;
        }

        // Monitor topology / resolution changed (app:screens-changed). Also
        // broadcast to every top-level window, so throttle to collapse the
        // per-window storm into a single dispatch.
        case WM_DISPLAYCHANGE: {
            static DWORD last_dc = 0;
            DWORD now = GetTickCount();
            if (now - last_dc > 250) {
                last_dc = now;
                zapp_app_dispatch(ZAPP_EVENT_APP_SCREENS_CHANGED, "{}");
            }
            break;
        }

        case WM_COMMAND: {
            // Menu item or accelerator
            extern void zapp_handle_menu_command(unsigned int cmd_id);
            WORD id = LOWORD(wParam);
            if (HIWORD(wParam) == 0 && id >= 0x1000) {
                // Check for __quit
                zapp_handle_menu_command(id);
            }
            return 0;
        }

        case WM_CLOSE: {
            int result = zapp_dispatch_event(wid, ZAPP_EVENT_CLOSE, 0, 0, 0, 0);
            if (result == ZAPP_EVENT_CANCEL) {
                return 0; // Prevent close (close guard active)
            }
            DestroyWindow(hwnd);
            return 0;
        }

        case WM_DESTROY: {
            zapp_wts_unregister(hwnd);   // stop session lock/unlock notifications
            // Modal safety net: if this window owned a disabled parent
            // (attach_modal) and is going away without a detach (user
            // hit the X), re-enable the parent or it's stuck dead.
            {
                HWND owner = (HWND)GetWindowLongPtrW(hwnd, GWLP_HWNDPARENT);
                if (owner && !IsWindowEnabled(owner)) {
                    EnableWindow(owner, TRUE);
                    SetForegroundWindow(owner);
                }
            }
            // Tear down native panes (child windows) if any.
            extern void windows_panes_destroy(int32_t host_slot);
            windows_panes_destroy(wid);
            // Tear down the custom caption-button child if any.
            extern void windows_titlebar_destroy(int32_t);
            windows_titlebar_destroy(wid);
            // Clear dispatch table entry
            if (wid >= 0 && wid < ZAPP_MAX_WINDOWS) {
                zapp_hwnds[wid] = NULL;
                zapp_bridge_ready[wid] = 0;
                zapp_window_ids[wid][0] = '\0';
                zapp_was_maximized[wid] = 0;
                zapp_was_minimized[wid] = 0;
                zapp_is_fullscreen[wid] = 0;
            }
            zapp_decrement_window_count();
            return 0;
        }

        default:
            break;
    }

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// --- Window creation ---

void* windows_window_create(WindowOptions* opts) {
    const char* title = wopts_title(opts);
    int32_t w = wopts_width(opts);
    int32_t h = wopts_height(opts);
    int32_t x = wopts_x(opts);
    int32_t y = wopts_y(opts);
    bool visible = wopts_visible(opts);
    bool resizable = wopts_resizable(opts);
    bool maximizable = wopts_maximizable(opts);
    bool minimizable = wopts_minimizable(opts);
    bool borderless = wopts_borderless(opts);
    bool always_on_top = wopts_always_on_top(opts);
    int32_t inspectable = wopts_inspectable(opts);

    // DPI-aware scaling
    UINT dpi = zapp_get_dpi();
    int scaled_w = zapp_scale(w, dpi);
    int scaled_h = zapp_scale(h, dpi);
    int scaled_x = (x != 0) ? zapp_scale(x, dpi) : 0;
    int scaled_y = (y != 0) ? zapp_scale(y, dpi) : 0;

    // Build window style
    DWORD style = WS_CLIPCHILDREN;
    DWORD ex_style = 0;
    if (borderless) {
        style |= WS_POPUP;
    } else {
        style |= WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
        if (resizable)    style |= WS_THICKFRAME;
        if (minimizable)  style |= WS_MINIMIZEBOX;
        if (maximizable)  style |= WS_MAXIMIZEBOX;
    }
    if (always_on_top) ex_style |= WS_EX_TOPMOST;

    // Adjust rect for non-client area (title bar, borders)
    RECT rc = { 0, 0, scaled_w, scaled_h };
    AdjustWindowRectEx(&rc, style, FALSE, ex_style);
    int adj_w = rc.right - rc.left;
    int adj_h = rc.bottom - rc.top;

    // Center on screen if position not specified
    int screen_w = GetSystemMetrics(SM_CXSCREEN);
    int screen_h = GetSystemMetrics(SM_CYSCREEN);
    int pos_x = (scaled_x == 0) ? (screen_w - adj_w) / 2 : scaled_x;
    int pos_y = (scaled_y == 0) ? (screen_h - adj_h) / 2 : scaled_y;

    wchar_t* wtitle = utf8_to_wchar(title);

    HWND hwnd = CreateWindowExW(
        ex_style,
        zapp_get_window_class(),
        wtitle ? wtitle : L"Zapp",
        style,
        pos_x, pos_y, adj_w, adj_h,
        NULL, NULL,
        zapp_get_hinstance(),
        NULL
    );

    if (wtitle) free(wtitle);
    if (!hwnd) return NULL;

    zapp_increment_window_count();
    zapp_wts_register(hwnd);   // session lock/unlock notifications (Win+L)

    // Content protection (windows:{contentProtection}) — exclude from screen
    // capture / screenshots. WDA_EXCLUDEFROMCAPTURE: Windows 10 2004+.
    extern bool wopts_windows_content_protection(void*);
    if (wopts_windows_content_protection(opts))
        SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);

    // Register the hwnd ↔ numeric-id mapping NOW, from the id the
    // WindowManager pre-allocated, before anything that depends on
    // window identity runs (ShowWindow re-enters the wndproc; the
    // webview-create slot lookup needs zapp_hwnds populated —
    // previously it guessed "next free slot", which is a race).
    // window.zc's later windows_window_register_numeric_id call is
    // idempotent over this.
    int32_t pre_id = wopts_numeric_id_pre_alloc(opts);
    if (pre_id >= 0 && pre_id < ZAPP_MAX_WINDOWS) {
        windows_window_register_numeric_id((void*)hwnd, pre_id);
    }

    // Win11 material + theme-synced caption (Mica/Acrylic via the vibrancy
    // option; immersive dark/light title bar from the app theme). When a
    // backdrop is requested the web surface must be transparent for it to show
    // through — flag the webview before its controller is built. Both no-op
    // gracefully on Win10 / pre-22H2.
    const char* vibrancy = wopts_vibrancy(opts);
    bool transparent = wopts_transparent(opts);
    extern void windows_material_apply(HWND hwnd, const char* vibrancy);
    extern int windows_material_wants_transparent(const char* vibrancy);
    extern void windows_webview_set_transparent(int32_t window_id, bool transparent);
    windows_material_apply(hwnd, vibrancy);
    if (pre_id >= 0 && pre_id < ZAPP_MAX_WINDOWS) {
        windows_webview_set_transparent(pre_id,
            transparent || windows_material_wants_transparent(vibrancy));
        // App-set webview background ("#rrggbb"): seeds the load/resize gap so
        // it isn't a white flash. The page's CSS background still wins.
        const char* bg = wopts_background_color(opts);
        if (bg && bg[0] == '#' && strlen(bg) >= 7) {
            int r = 0, g = 0, b = 0;
            if (sscanf(bg + 1, "%2x%2x%2x", &r, &g, &b) == 3) {
                extern void windows_webview_set_bgcolor(int32_t window_id, int r, int g, int b);
                windows_webview_set_bgcolor(pre_id, r, g, b);
            }
        }
    }

    // Custom title bar (titleBarStyle: hidden/hiddenInset) — remove the caption
    // so content full-bleeds to the top and float native caption buttons over it
    // (macOS parity). tbs 1 = hidden, 2 = hiddenInset. Must run before ShowWindow
    // so the first WM_NCCALCSIZE sees the window as custom.
    // Window controls visibility (windowControls/trafficLights: 0=enabled,
    // 1=disabled, 2=hidden). The Nim layer folds closable/minimizable/maximizable
    // into these tags. minimize=zoom(maximize)=index; order min,max,close.
    extern int32_t wopts_traffic_light_close_tag(WindowOptions* opts);
    extern int32_t wopts_traffic_light_minimize_tag(WindowOptions* opts);
    extern int32_t wopts_traffic_light_zoom_tag(WindowOptions* opts);
    int close_tag = (int)wopts_traffic_light_close_tag(opts);
    int min_tag   = (int)wopts_traffic_light_minimize_tag(opts);
    int max_tag   = (int)wopts_traffic_light_zoom_tag(opts);

    int32_t tbs = wopts_title_bar_style_tag(opts);
    if ((tbs == 1 || tbs == 2) && pre_id >= 0 && pre_id < ZAPP_MAX_WINDOWS) {
        extern void windows_titlebar_enable(HWND, int32_t, int32_t);
        extern void windows_titlebar_set_controls(int32_t, int, int, int);
        windows_titlebar_enable(hwnd, pre_id, tbs);
        windows_titlebar_set_controls(pre_id, close_tag, min_tag, max_tag);
    } else if (close_tag >= 1) {
        // Default (native-caption) window: min/max hiding is handled by the
        // WS_MINIMIZEBOX/WS_MAXIMIZEBOX styles above (minimizable/maximizable).
        // Win32 can't hide the close button, but a disabled/hidden close maps to
        // greying it via the system menu (SC_CLOSE) — the closest native effect.
        HMENU sysmenu = GetSystemMenu(hwnd, FALSE);
        if (sysmenu) EnableMenuItem(sysmenu, SC_CLOSE, MF_BYCOMMAND | MF_GRAYED);
    }

    // Don't show yet — let the app call window_show after on_ready
    // But if visible is true, show immediately
    if (visible) {
        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);
    }

    // Get URL override from options
    const char* url = wopts_url(opts);
    const char* url_override = (url && url[0]) ? url : NULL;

    // Native sidebar / inspector split panes (macOS parity). When either is
    // configured, the host webview is mounted into a content child window and
    // the panes get their own host-twin webviews; otherwise the plain
    // single-webview path. The pane transport slots are pre-allocated by the
    // runtime (window.zc), in the same id-space as pre_id.
    const char* sidebar_url = wopts_sidebar_url(opts);
    const char* inspector_url = wopts_inspector_url(opts);
    bool has_sidebar = sidebar_url && sidebar_url[0];
    bool has_inspector = inspector_url && inspector_url[0];

    if (has_sidebar || has_inspector) {
        extern void windows_panes_init(HWND host_hwnd, int32_t host_slot, int inspectable,
                                       const char* host_url,
                                       int32_t sidebar_slot, const char* sidebar_url,
                                       int sb_width, int sb_min, int sb_max, int sb_collapsed,
                                       int32_t inspector_slot, const char* inspector_url,
                                       int insp_width, int insp_min, int insp_max, int insp_collapsed);
        windows_panes_init(hwnd, pre_id, inspectable > 0, url_override,
            has_sidebar ? wopts_sidebar_numeric_id(opts) : -1,
            has_sidebar ? sidebar_url : NULL,
            wopts_sidebar_width(opts), wopts_sidebar_min_width(opts),
            wopts_sidebar_max_width(opts), wopts_sidebar_collapsed(opts) ? 1 : 0,
            has_inspector ? wopts_inspector_numeric_id(opts) : -1,
            has_inspector ? inspector_url : NULL,
            wopts_inspector_width(opts), wopts_inspector_min_width(opts),
            wopts_inspector_max_width(opts), wopts_inspector_collapsed(opts) ? 1 : 0);
    } else {
        // Plain single-webview path.
        windows_webview_create((void*)hwnd, inspectable > 0, url_override);
    }

    return (void*)hwnd;
}

void windows_window_destroy(void* handle) {
    if (handle) DestroyWindow((HWND)handle);
}

void windows_window_show(void* handle) {
    if (handle) {
        ShowWindow((HWND)handle, SW_SHOW);
        SetForegroundWindow((HWND)handle);
    }
}

void windows_window_hide(void* handle) {
    if (handle) ShowWindow((HWND)handle, SW_HIDE);
}

void windows_window_force_close(void* handle) {
    if (handle) DestroyWindow((HWND)handle);
}

// darwin_window_get_by_numeric_id twin: map a WindowManager numeric id back to
// its native handle (HWND-as-void*) via the zapp_hwnds registry. The router
// resolves an id to a handle here, then calls the window ops below with it.
void* windows_window_get_by_numeric_id(int32_t numeric_id) {
    if (numeric_id < 0 || numeric_id >= ZAPP_MAX_WINDOWS) return NULL;
    return (void*)zapp_hwnds[numeric_id];
}

// darwin_window_focus twin: bring the window to the foreground + key focus.
void windows_window_focus(void* handle) {
    if (handle) SetForegroundWindow((HWND)handle);
}

// darwin_window_zoom twin: macOS "zoom" toggles the standard/zoomed frame; the
// closest Windows analogue is toggling maximize/restore.
void windows_window_zoom(void* handle) {
    if (!handle) return;
    HWND hwnd = (HWND)handle;
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
}

// Web-driven window drag for custom title bars. The bootstrap JS posts
// "beginDrag" once the pointer moves inside an app-region:drag element (Windows
// has no mouseDownCanMoveWindow). 0xF012 == SC_MOVE | HTCAPTION — it starts the
// modal window-move loop that follows the mouse, as if the caption were grabbed.
void windows_window_begin_drag(int32_t window_id) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return;
    HWND hwnd = zapp_hwnds[window_id];
    if (!hwnd) return;
    ReleaseCapture();
    PostMessageW(hwnd, WM_SYSCOMMAND, 0xF012, 0);
}

// Double-click on a drag region toggles maximize/restore — the framework
// behavior that matches macOS (its WKWebView subclass zooms on a dblclick over a
// drag region). The bootstrap posts "toggleMaximize" for custom-titlebar windows.
void windows_window_toggle_maximize(int32_t window_id) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return;
    HWND hwnd = zapp_hwnds[window_id];
    if (!hwnd) return;
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
}

void windows_window_set_title(void* handle, const char* title) {
    if (!handle) return;
    wchar_t* wtitle = utf8_to_wchar(title);
    if (wtitle) {
        SetWindowTextW((HWND)handle, wtitle);
        free(wtitle);
    }
}

void windows_window_set_size(void* handle, int32_t width, int32_t height) {
    if (!handle) return;
    HWND hwnd = (HWND)handle;
    UINT dpi = zapp_get_dpi();
    int scaled_w = zapp_scale(width, dpi);
    int scaled_h = zapp_scale(height, dpi);
    DWORD style = (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE);
    DWORD ex_style = (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    RECT rc = { 0, 0, scaled_w, scaled_h };
    AdjustWindowRectEx(&rc, style, FALSE, ex_style);
    SetWindowPos(hwnd, NULL, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void windows_window_set_position(void* handle, int32_t x, int32_t y) {
    if (!handle) return;
    UINT dpi = zapp_get_dpi();
    SetWindowPos((HWND)handle, NULL, zapp_scale(x, dpi), zapp_scale(y, dpi), 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void windows_window_minimize(void* handle) {
    if (handle) ShowWindow((HWND)handle, SW_MINIMIZE);
}

void windows_window_maximize(void* handle) {
    if (handle) ShowWindow((HWND)handle, SW_MAXIMIZE);
}

void windows_window_set_fullscreen(void* handle, bool on) {
    if (!handle) return;
    HWND hwnd = (HWND)handle;
    int32_t wid = zapp_get_window_id(hwnd);
    if (wid < 0 || wid >= ZAPP_MAX_WINDOWS) return;

    if (on && !zapp_is_fullscreen[wid]) {
        // Save current style and position
        zapp_pre_fullscreen_style[wid] = GetWindowLongW(hwnd, GWL_STYLE);
        GetWindowRect(hwnd, &zapp_pre_fullscreen_rect[wid]);

        // Go borderless fullscreen
        MONITORINFO mi = { sizeof(mi) };
        GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi);
        SetWindowLongW(hwnd, GWL_STYLE, zapp_pre_fullscreen_style[wid] & ~WS_OVERLAPPEDWINDOW);
        SetWindowPos(hwnd, HWND_TOP,
            mi.rcMonitor.left, mi.rcMonitor.top,
            mi.rcMonitor.right - mi.rcMonitor.left,
            mi.rcMonitor.bottom - mi.rcMonitor.top,
            SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        zapp_is_fullscreen[wid] = 1;
        zapp_dispatch_event(wid, ZAPP_EVENT_FULLSCREEN, 0, 0, 0, 0);
    } else if (!on && zapp_is_fullscreen[wid]) {
        // Restore
        SetWindowLongW(hwnd, GWL_STYLE, zapp_pre_fullscreen_style[wid]);
        RECT* r = &zapp_pre_fullscreen_rect[wid];
        SetWindowPos(hwnd, NULL,
            r->left, r->top, r->right - r->left, r->bottom - r->top,
            SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        zapp_is_fullscreen[wid] = 0;
        zapp_dispatch_event(wid, ZAPP_EVENT_UNFULLSCREEN, 0, 0, 0, 0);
    }
}

void windows_window_set_always_on_top(void* handle, bool on) {
    if (!handle) return;
    SetWindowPos((HWND)handle,
        on ? HWND_TOPMOST : HWND_NOTOPMOST,
        0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void windows_window_get_size(void* handle, int32_t* out_w, int32_t* out_h) {
    if (!handle) return;
    RECT rc;
    GetClientRect((HWND)handle, &rc);
    if (out_w) *out_w = rc.right - rc.left;
    if (out_h) *out_h = rc.bottom - rc.top;
}

void windows_window_get_position(void* handle, int32_t* out_x, int32_t* out_y) {
    if (!handle) return;
    RECT rc;
    GetWindowRect((HWND)handle, &rc);
    if (out_x) *out_x = rc.left;
    if (out_y) *out_y = rc.top;
}

// --- ID registration and lookup ---

void windows_window_register_numeric_id(void* handle, int32_t numeric_id) {
    if (!handle || numeric_id < 0 || numeric_id >= ZAPP_MAX_WINDOWS) return;
    HWND hwnd = (HWND)handle;
    zapp_hwnds[numeric_id] = hwnd;
    zapp_set_window_id(hwnd, numeric_id);
    snprintf(zapp_window_ids[numeric_id], 32, "win-%d", numeric_id);
}

// Register a sidebar/inspector pane's transport slot under the HOST window's
// id string ("win-<host>"). A pane slot is NOT a WindowManager window, so a
// window action posted from inside a pane (Window.current().inspector.toggle())
// arrives with the pane slot and would be dropped by the router's is_valid()
// guard. The router remaps an invalid sender to its host via
// windows_window_id_string(slot) → "win-<host>" → numeric; this populates that
// mapping. (Parity with darwin's zapp_register_webview(slot, …, hostWindowId).)
void windows_window_register_pane_id(int32_t slot, int32_t host_slot) {
    if (slot < 0 || slot >= ZAPP_MAX_WINDOWS) return;
    if (host_slot < 0 || host_slot >= ZAPP_MAX_WINDOWS) return;
    snprintf(zapp_window_ids[slot], 32, "win-%d", host_slot);
}

void windows_window_eval_js(int32_t window_id, const char* js) {
    windows_webview_eval_by_id(window_id, js);
}

int32_t windows_window_id_for_webview(void* webview) {
    // Not commonly needed on Windows — WebView2 callbacks carry window context
    (void)webview;
    return -1;
}

const char* windows_window_id_string(int32_t numeric_id) {
    if (numeric_id < 0 || numeric_id >= ZAPP_MAX_WINDOWS) return NULL;
    if (zapp_window_ids[numeric_id][0] == '\0') return NULL;
    return zapp_window_ids[numeric_id];
}

// darwin_windows_list_json twin: a JSON array of the live window id strings
// (e.g. ["win-1","win-3"]). Malloc'd (caller frees), matching darwin's strdup
// contract. Iterates the zapp_hwnds registry.
const char* windows_windows_list_json(void) {
    // Bound: each id is short ("win-<n>"); allocate generously per slot.
    size_t cap = (size_t)ZAPP_MAX_WINDOWS * (sizeof(zapp_window_ids[0]) + 4) + 4;
    char* out = (char*)malloc(cap);
    if (!out) return NULL;
    size_t len = 0;
    out[len++] = '[';
    int first = 1;
    for (int i = 0; i < ZAPP_MAX_WINDOWS; i++) {
        if (!zapp_hwnds[i]) continue;
        const char* id = zapp_window_ids[i];
        if (!id || !id[0]) continue;
        if (!first) out[len++] = ',';
        out[len++] = '"';
        size_t n = strlen(id);
        memcpy(out + len, id, n); len += n;
        out[len++] = '"';
        first = 0;
    }
    out[len++] = ']';
    out[len] = '\0';
    return out;
}

void* windows_window_get_webview(int32_t numeric_id) {
    // Returns the HWND — WebView2 lookup is done in webview.c
    if (numeric_id < 0 || numeric_id >= ZAPP_MAX_WINDOWS) return NULL;
    return (void*)zapp_hwnds[numeric_id];
}

void windows_window_set_bridge_ready(const char* window_id) {
    // Parse "win-N" to get numeric ID
    if (!window_id || strncmp(window_id, "win-", 4) != 0) return;
    int id = atoi(window_id + 4);
    if (id < 0 || id >= ZAPP_MAX_WINDOWS) return;
    zapp_bridge_ready[id] = 1;

    // Fire pending focus event
    if (zapp_pending_focus[id]) {
        zapp_pending_focus[id] = 0;
        zapp_dispatch_event_to_js(id, ZAPP_EVENT_FOCUS, 0, 0, 0, 0);
    }
}

void windows_window_load_url(int32_t window_id, const char* url) {
    extern void windows_webview_navigate(int32_t window_id, const char* url);
    windows_webview_navigate(window_id, url);
}

// Bring every app window to the foreground (App.activate). Restores
// minimized windows first — SetForegroundWindow on an iconic window
// flashes the taskbar instead of raising it.
void windows_window_activate_app(void) {
    HWND last = NULL;
    for (int i = 0; i < ZAPP_MAX_WINDOWS; i++) {
        if (!zapp_hwnds[i] || !IsWindow(zapp_hwnds[i])) continue;
        if (IsIconic(zapp_hwnds[i])) ShowWindow(zapp_hwnds[i], SW_RESTORE);
        last = zapp_hwnds[i];
    }
    if (last) SetForegroundWindow(last);
}

// --- Modal sheets ---
// macOS sheets don't have a literal Win32 equivalent, but Windows DOES
// have the owned-modal idiom: set the parent as the modal's OWNER (the
// modal then always stays above it, minimizes with it) and disable the
// parent so interaction is blocked until the modal closes — the same
// contract as beginSheet. The modal is centered over the parent.
void windows_window_attach_modal(void* parent_handle, void* modal_handle) {
    HWND parent = (HWND)parent_handle;
    HWND modal = (HWND)modal_handle;
    if (!parent || !modal) return;

    // Owner, not WS_CHILD parent — GWLP_HWNDPARENT on a top-level
    // window sets ownership (z-order glue) without re-parenting.
    SetWindowLongPtrW(modal, GWLP_HWNDPARENT, (LONG_PTR)parent);
    EnableWindow(parent, FALSE);

    // Center over the parent.
    RECT pr, mr;
    if (GetWindowRect(parent, &pr) && GetWindowRect(modal, &mr)) {
        int mw = mr.right - mr.left;
        int mh = mr.bottom - mr.top;
        int x = pr.left + ((pr.right - pr.left) - mw) / 2;
        int y = pr.top + ((pr.bottom - pr.top) - mh) / 2;
        SetWindowPos(modal, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
    }
}
void windows_window_detach_modal(void* parent_handle, void* modal_handle) {
    HWND parent = (HWND)parent_handle;
    HWND modal = (HWND)modal_handle;
    // Re-enable BEFORE clearing ownership — destroying/hiding an owned
    // window while its owner is disabled makes Windows activate some
    // OTHER app's window (classic modal-teardown flicker).
    if (parent) {
        EnableWindow(parent, TRUE);
        SetForegroundWindow(parent);
    }
    if (modal) SetWindowLongPtrW(modal, GWLP_HWNDPARENT, (LONG_PTR)NULL);
}

// --- Drag region ---

static int zapp_in_drag_region[ZAPP_MAX_WINDOWS] = {0};

void windows_webview_set_drag_region(int32_t window_id, bool drag) {
    if (window_id >= 0 && window_id < ZAPP_MAX_WINDOWS) {
        zapp_in_drag_region[window_id] = drag ? 1 : 0;
    }
}

// Accessor for webview.c to check drag state
int zapp_is_in_drag_region(int32_t window_id) {
    if (window_id >= 0 && window_id < ZAPP_MAX_WINDOWS) {
        return zapp_in_drag_region[window_id];
    }
    return 0;
}

// Get HWND by numeric ID (for webview.c)
HWND zapp_get_hwnd(int32_t window_id) {
    if (window_id >= 0 && window_id < ZAPP_MAX_WINDOWS) {
        return zapp_hwnds[window_id];
    }
    return NULL;
}

// Resolve a JS window-id string ("win-<n>") to its numeric slot. The Windows
// id is numeric (see webview.c config injection), so this is a simple parse —
// parity with darwin_window_numeric_id_for_string. -1 when unparseable.
int32_t windows_window_numeric_id_for_string(const char* wid) {
    if (!wid) return -1;
    if (strncmp(wid, "win-", 4) == 0) return (int32_t)atoi(wid + 4);
    return -1;
}
