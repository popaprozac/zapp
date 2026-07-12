// Windows platform lifecycle.
// COM initialization, window class registration, Win32 message loop.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <stdio.h>
#include <string.h>
#include "platform.h"

// Forward declarations
extern LRESULT CALLBACK zapp_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
extern int zapp_app_dispatch(int event_id, const char* data);
extern void service_run_shutdown_all(void);
extern void windows_shortcut_handle_wm_hotkey(int hotkey_id);
extern void windows_shortcut_unregister_all(void);

// App event IDs (must match events.zc)
#define ZAPP_EVENT_APP_STARTED        100
#define ZAPP_EVENT_APP_SHUTDOWN       101
#define ZAPP_EVENT_APP_THEME_CHANGED  108
#define ZAPP_EVENT_APP_BEFORE_QUIT    113

// Global state
static const char* zapp_app_name = "Zapp";
static HINSTANCE zapp_hinstance = NULL;
static bool zapp_terminate_after_last_window = true;
static int zapp_window_count = 0;
static const wchar_t* ZAPP_WINDOW_CLASS = L"ZappWindow";

// Accessors for other modules
HINSTANCE zapp_get_hinstance(void) { return zapp_hinstance; }
const wchar_t* zapp_get_window_class(void) { return ZAPP_WINDOW_CLASS; }
const char* zapp_get_app_name(void) { return zapp_app_name; }

void zapp_increment_window_count(void) { zapp_window_count++; }
void zapp_decrement_window_count(void) {
    zapp_window_count--;
    if (zapp_window_count <= 0 && zapp_terminate_after_last_window) {
        PostQuitMessage(0);
    }
}

// --- App lifecycle (quit guard / quit / activate) ---
//
// Mirrors darwin/platform.m: an armed guard turns a plain quit into an
// app:before-quit event so JS can run its (possibly async) confirm and
// re-issue App.quit({force:true}). The force latch is consumed on use.

static bool zapp_quit_guard_enabled = false;

void windows_set_quit_guard(bool enabled) {
    zapp_quit_guard_enabled = enabled;
}

void windows_app_quit(bool force) {
    if (!force && zapp_quit_guard_enabled) {
        zapp_app_dispatch(ZAPP_EVENT_APP_BEFORE_QUIT, "{}");
        return;
    }
    PostQuitMessage(0);
}

// Bring the app's windows to the foreground — the Windows analogue of
// [NSApp activateIgnoringOtherApps:]. window.c owns the HWND table.
extern void windows_window_activate_app(void);
void windows_app_activate(void) {
    windows_window_activate_app();
}

// --- Theme (light/dark) ---
//
// Windows apps-theme preference lives in the registry; there's no
// per-process effectiveAppearance. WM_SETTINGCHANGE("ImmersiveColorSet")
// lands on top-level windows when it flips — zapp_wndproc calls
// windows_theme_setting_changed below.

const char* windows_get_theme(void) {
    DWORD value = 1; // default: light
    DWORD size = sizeof(value);
    RegGetValueW(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &value, &size);
    return value == 0 ? "dark" : "light";
}

// App-theme window background brush. The transparent sidebar webview (and the
// resize gap + pre-load) show this through; the old COLOR_WINDOW (white) was
// jarring against the dark content + titlebar. Matches the titlebar base
// (RGB 32 dark / 243 light) so the surface reads as one coherent chrome. Solid
// (not translucent) for now — Acrylic sidebar parity is a follow-up. Painted via
// the standard class brush (not a custom WM_ERASEBKGND), so no resize tearing.
static HBRUSH zapp_bg_brush = NULL;
static void zapp_refresh_bg_brush(void) {
    // Note: the previous brush is intentionally NOT deleted — the pane class
    // (sidebar.c PANE_HOST_CLASS) also holds it as its class background, and we
    // don't re-point that on theme flips. A stale brush handle would dangle.
    // Theme flips are rare; leaking one small GDI brush per flip is negligible.
    int dark = strcmp(windows_get_theme(), "dark") == 0;
    zapp_bg_brush = CreateSolidBrush(dark ? RGB(32, 32, 32) : RGB(243, 243, 243));
}

// The shared theme surface brush (dark 32 / light 243), for any window/pane class
// that should read as the app chrome instead of COLOR_WINDOW white.
HBRUSH windows_theme_bg_brush(void) {
    if (!zapp_bg_brush) zapp_refresh_bg_brush();
    return zapp_bg_brush;
}

void windows_theme_setting_changed(void) {
    // WM_SETTINGCHANGE fires several times per flip (and for unrelated
    // settings whose lParam also reads "ImmersiveColorSet") — dedupe on
    // the resolved value so JS sees one event per actual change.
    static const char* last_theme = NULL;
    const char* theme = windows_get_theme();
    if (last_theme && strcmp(last_theme, theme) == 0) return;
    last_theme = theme;
    char payload[64];
    snprintf(payload, sizeof(payload), "{\"theme\":\"%s\"}", theme);
    zapp_app_dispatch(ZAPP_EVENT_APP_THEME_CHANGED, payload);

    // Re-sync every window's immersive dark/light caption to the new theme
    // (material.c reads windows_get_theme()).
    extern HWND zapp_get_hwnd(int32_t window_id);
    extern void windows_material_apply_theme(HWND hwnd);
    zapp_refresh_bg_brush();  // recolor the shared surface brush for the new theme
    for (int i = 0; i < 64; i++) {
        HWND h = zapp_get_hwnd(i);
        if (h) {
            windows_material_apply_theme(h);
            SetClassLongPtrW(h, GCLP_HBRBACKGROUND, (LONG_PTR)zapp_bg_brush);
            InvalidateRect(h, NULL, TRUE);
        }
    }
}

// --- Login item (launch at login) ---
//
// Backs App.setLoginItem / getLoginItemEnabled. The standard Windows
// mechanism is a value under HKCU\...\Run holding the quoted exe path;
// Windows auto-runs it at sign-in. Keyed by the app identifier so apps
// don't clobber each other's entries. (macOS uses SMAppService.)

extern const char* zapp_build_identifier(void);

static const wchar_t* LOGIN_RUN_KEY =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

static void login_value_name(wchar_t* out, int out_size) {
    const char* ident = zapp_build_identifier();
    if (!ident || !ident[0]) ident = "com.zapp.app";
    MultiByteToWideChar(CP_UTF8, 0, ident, -1, out, out_size);
}

bool windows_set_login_item(bool enabled) {
    wchar_t name[160];
    login_value_name(name, 160);
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, LOGIN_RUN_KEY, 0, KEY_SET_VALUE, &key)
        != ERROR_SUCCESS) {
        return false;
    }
    bool ok = false;
    if (enabled) {
        wchar_t exe[MAX_PATH];
        if (GetModuleFileNameW(NULL, exe, MAX_PATH)) {
            // Quote the path so spaces in the install dir survive.
            wchar_t quoted[MAX_PATH + 4];
            _snwprintf(quoted, MAX_PATH + 3, L"\"%s\"", exe);
            quoted[MAX_PATH + 3] = L'\0';
            ok = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE*) quoted,
                                (DWORD) ((wcslen(quoted) + 1) * sizeof(wchar_t)))
                 == ERROR_SUCCESS;
        }
    } else {
        LONG r = RegDeleteValueW(key, name);
        // Absent == already disabled — report success either way.
        ok = (r == ERROR_SUCCESS || r == ERROR_FILE_NOT_FOUND);
    }
    RegCloseKey(key);
    return ok;
}

bool windows_get_login_item(void) {
    wchar_t name[160];
    login_value_name(name, 160);
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, LOGIN_RUN_KEY, 0, KEY_QUERY_VALUE, &key)
        != ERROR_SUCCESS) {
        return false;
    }
    LONG r = RegQueryValueExW(key, name, NULL, NULL, NULL, NULL);
    RegCloseKey(key);
    return r == ERROR_SUCCESS;
}

void windows_platform_init(const char* app_name) {
    zapp_app_name = app_name;
    zapp_hinstance = GetModuleHandleW(NULL);

    // Single-instance gate FIRST: a secondary launch forwards its
    // command line (deep-link URL) to the primary and exits before
    // standing up any window or COM apartment.
    extern int windows_single_instance_check(void);
    extern void windows_register_url_schemes(void);
    if (!windows_single_instance_check()) {
        ExitProcess(0);
    }
    // Register myapp:// handlers so the OS routes deep links to us.
    windows_register_url_schemes();

    // Power-state change notifications (sleep/wake, AC/battery, %).
    extern void windows_power_init(void);
    windows_power_init();

    // Initialize COM (apartment-threaded for WebView2)
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

    // Main-thread eval funnel — must exist before any worker thread can
    // post webview evals (WebView2 is STA-bound; see webview.c).
    extern void zapp_webview_init_eval_funnel(void);
    zapp_webview_init_eval_funnel();

    // DPI awareness
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // Register window class
    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = zapp_wndproc;
    wc.hInstance = zapp_hinstance;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    if (!zapp_bg_brush) zapp_refresh_bg_brush();
    wc.hbrBackground = zapp_bg_brush;   // theme surface, not COLOR_WINDOW white
    wc.lpszClassName = ZAPP_WINDOW_CLASS;
    RegisterClassExW(&wc);
}

int windows_platform_run(bool terminate_after_last_window) {
    zapp_terminate_after_last_window = terminate_after_last_window;

    // Fire APP_STARTED event
    zapp_app_dispatch(ZAPP_EVENT_APP_STARTED, NULL);

    // Cold deep-link launch: if we were started with a myapp:// URL
    // (registry handler → argv[1]), surface it now. Native App.on
    // handlers are already registered (run() registers them before
    // platform_run); the JS layer no-ops until a webview is ready,
    // same as a cold launch on macOS.
    extern void windows_dispatch_deep_link_from_argv(void);
    windows_dispatch_deep_link_from_argv();

    // Win32 message loop
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        // Global hotkeys registered with a NULL hwnd arrive as
        // thread-queue messages — DispatchMessage can't route those
        // (no window), so handle them here.
        if (msg.message == WM_HOTKEY) {
            windows_shortcut_handle_wm_hotkey((int)msg.wParam);
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    // Fire APP_SHUTDOWN event
    windows_shortcut_unregister_all();
    extern void windows_power_shutdown(void);
    windows_power_shutdown();
    service_run_shutdown_all();
    zapp_app_dispatch(ZAPP_EVENT_APP_SHUTDOWN, NULL);

    CoUninitialize();
    return (int)msg.wParam;
}
