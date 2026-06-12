// Windows platform lifecycle.
// COM initialization, window class registration, Win32 message loop.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include "platform.h"

// Forward declarations
extern LRESULT CALLBACK zapp_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
extern int zapp_app_dispatch(int event_id, const char* data);
extern void service_run_shutdown_all(void);
extern void windows_shortcut_handle_wm_hotkey(int hotkey_id);
extern void windows_shortcut_unregister_all(void);

// App event IDs (must match events.zc)
#define ZAPP_EVENT_APP_STARTED  100
#define ZAPP_EVENT_APP_SHUTDOWN 101

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

void windows_platform_init(const char* app_name) {
    zapp_app_name = app_name;
    zapp_hinstance = GetModuleHandleW(NULL);

    // Initialize COM (apartment-threaded for WebView2)
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

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
