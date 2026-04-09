// C API for macOS WebView (WKWebView) creation and management.
// Implementation in webview.m (Objective-C).

#ifndef ZAPP_DARWIN_WEBVIEW_H
#define ZAPP_DARWIN_WEBVIEW_H

#include <stdbool.h>
#include <stdint.h>

// Create a WKWebView inside the given NSWindow.
// Sets up: custom scheme handler (zapp://), message handler, bootstrap injection.
// url_override: if non-NULL and non-empty, load this URL instead of the default.
void darwin_webview_create(void* window_ptr, bool inspectable, const char* url_override);

// Evaluate JavaScript on a specific window's WebView.
void darwin_webview_eval(void* window_ptr, const char* js);

// Evaluate JavaScript on all windows' WebViews.
void darwin_webview_eval_all(const char* js);

// Escape a string for safe embedding in JS string literals.
const char* darwin_escape_js_string(const char* raw);

// Open a URL in the system browser.
void darwin_open_external(const char* url);

// Set drag region flag on a window's WebView.
void darwin_webview_set_drag_region(int32_t window_id, bool drag);

// Load a URL in a window's WebView.
void darwin_window_load_url(int32_t window_id, const char* url);

#endif
