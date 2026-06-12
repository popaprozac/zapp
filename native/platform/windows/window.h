// C API for Windows window operations.
// Types are Zen-C structs (opaque here) — accessed via accessor functions.
// Implementation in window.c (Win32 + WebView2).

#ifndef ZAPP_WINDOWS_WINDOW_H
#define ZAPP_WINDOWS_WINDOW_H

// _WIN32 body guard: zc emits @cfg(windows) imports' #includes into EVERY
// platform's generated TU (@cfg gates functions, not import emission —
// vendor-ledger item). Without this, type definitions here collide with
// the darwin headers in macOS/iOS builds (ZappMenuItem broke the macOS
// build). On Windows _WIN32 is always defined, so this is inert there.
#ifdef _WIN32

#include <stdbool.h>
#include <stdint.h>

// Opaque Zen-C types (defined in window/window.zc)
typedef struct WindowOptions WindowOptions;
typedef struct WindowSize WindowSize;
typedef struct WindowPosition WindowPosition;

// --- WindowOptions accessors (implemented in .zc) ---
char* wopts_title(WindowOptions* opts);
char* wopts_url(WindowOptions* opts);
int32_t wopts_width(WindowOptions* opts);
int32_t wopts_height(WindowOptions* opts);
int32_t wopts_x(WindowOptions* opts);
int32_t wopts_y(WindowOptions* opts);
bool wopts_visible(WindowOptions* opts);
bool wopts_resizable(WindowOptions* opts);
bool wopts_closable(WindowOptions* opts);
bool wopts_minimizable(WindowOptions* opts);
bool wopts_maximizable(WindowOptions* opts);
bool wopts_fullscreen(WindowOptions* opts);
bool wopts_borderless(WindowOptions* opts);
bool wopts_transparent(WindowOptions* opts);
bool wopts_hidden(WindowOptions* opts);
bool wopts_always_on_top(WindowOptions* opts);
int32_t wopts_title_bar_style_tag(WindowOptions* opts);
int32_t wopts_inspectable(WindowOptions* opts);
bool wopts_accept_first_mouse(WindowOptions* opts);
int32_t wopts_numeric_id_pre_alloc(WindowOptions* opts);

// --- Window lifecycle ---
void* windows_window_create(WindowOptions* opts);
void windows_window_destroy(void* handle);
void windows_window_show(void* handle);
void windows_window_hide(void* handle);
void windows_window_force_close(void* handle);

// --- Window setters ---
void windows_window_set_title(void* handle, const char* title);
void windows_window_set_size(void* handle, int32_t width, int32_t height);
void windows_window_set_position(void* handle, int32_t x, int32_t y);
void windows_window_minimize(void* handle);
void windows_window_maximize(void* handle);
void windows_window_set_fullscreen(void* handle, bool on);
void windows_window_set_always_on_top(void* handle, bool on);

// --- Window getters ---
void windows_window_get_size(void* handle, int32_t* out_w, int32_t* out_h);
void windows_window_get_position(void* handle, int32_t* out_x, int32_t* out_y);

// --- Window ID mapping ---
void windows_window_register_numeric_id(void* handle, int32_t numeric_id);

// --- Event dispatch (called by unified dispatcher in callbacks.zc) ---
void zapp_dispatch_event_to_js(int32_t window_id, int32_t event_id, int32_t w, int32_t h, int32_t x, int32_t y);

// --- JS eval on specific window by numeric ID ---
void windows_window_eval_js(int32_t window_id, const char* js);

// --- Lookup numeric window ID from a WebView pointer ---
int32_t windows_window_id_for_webview(void* webview);

// --- Get string window ID for a numeric ID ---
const char* windows_window_id_string(int32_t numeric_id);

// --- Get WebView pointer for a numeric ID (O(1)) ---
void* windows_window_get_webview(int32_t numeric_id);

// --- Bridge readiness ---
void windows_window_set_bridge_ready(const char* window_id);

// --- Load URL in a window's WebView ---
void windows_window_load_url(int32_t window_id, const char* url);

// --- Modal sheets ---
// Stub on Windows for now — Win32 doesn't have a direct sheet equivalent.
// Closest pattern is owned dialog with EnableWindow(parent, FALSE) or a
// modal message loop. Defer until macOS modal API stabilizes.
void windows_window_attach_modal(void* parent_handle, void* modal_handle);
void windows_window_detach_modal(void* parent_handle, void* modal_handle);

#endif // _WIN32
#endif
