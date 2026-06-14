// C API for Windows WebView2 creation and management.
// Implementation in webview.c (Win32 COM).

#ifndef ZAPP_WINDOWS_WEBVIEW_H
#define ZAPP_WINDOWS_WEBVIEW_H

// _WIN32 body guard: zc emits @cfg(windows) imports' #includes into EVERY
// platform's generated TU (@cfg gates functions, not import emission —
// vendor-ledger item). Without this, type definitions here collide with
// the darwin headers in macOS/iOS builds (ZappMenuItem broke the macOS
// build). On Windows _WIN32 is always defined, so this is inert there.
#ifdef _WIN32

#include <stdbool.h>
#include <stdint.h>

// Create a WebView2 inside the given HWND.
// Sets up: virtual host mapping, message handler, bootstrap injection.
// url_override: if non-NULL and non-empty, load this URL instead of the default.
void windows_webview_create(void* hwnd_ptr, bool inspectable, const char* url_override);

// Generalized create for sidebar/inspector panes: mount into an arbitrary HWND
// (a pane's child window) at transport slot `slot` with JS identity
// `identity_id` (<0 → slot), optional transparent background, and pane role
// (0 content, 1 sidebar, 3 inspector) + has_sidebar/has_inspector flags.
void windows_webview_create_ext(void* hwnd_ptr, bool inspectable, const char* url_override,
                                int32_t slot, int32_t identity_id, bool transparent,
                                int pane_role, bool has_sidebar, bool has_inspector);

// Evaluate JavaScript on a specific window's WebView.
void windows_webview_eval(void* hwnd_ptr, const char* js);

// Evaluate JavaScript on all windows' WebViews.
void windows_webview_eval_all(const char* js);

// Escape a string for safe embedding in JS string literals.
const char* windows_escape_js_string(const char* raw);

// Open a URL in the system browser.
void windows_open_external(const char* url);

// Set drag region flag on a window's WebView.
void windows_webview_set_drag_region(int32_t window_id, bool drag);

#endif // _WIN32
#endif
