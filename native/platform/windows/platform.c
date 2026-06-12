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
}

void windows_platform_init(const char* app_name) {
    zapp_app_name = app_name;
    zapp_hinstance = GetModuleHandleW(NULL);

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
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = ZAPP_WINDOW_CLASS;
    RegisterClassExW(&wc);
}

int windows_platform_run(bool terminate_after_last_window) {
    zapp_terminate_after_last_window = terminate_after_last_window;

    // Fire APP_STARTED event
    zapp_app_dispatch(ZAPP_EVENT_APP_STARTED, NULL);

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
    service_run_shutdown_all();
    zapp_app_dispatch(ZAPP_EVENT_APP_SHUTDOWN, NULL);

    CoUninitialize();
    return (int)msg.wParam;
}
