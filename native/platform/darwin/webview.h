// C API for macOS WebView (WKWebView) creation and management.
// Implementation in webview.m (Objective-C).

#ifndef ZAPP_DARWIN_WEBVIEW_H
#define ZAPP_DARWIN_WEBVIEW_H

#include <stdbool.h>
#include <stdint.h>

// Create a WKWebView inside the given NSWindow.
// Sets up: custom scheme handler (zapp://), message handler, bootstrap injection.
// url_override: if non-NULL and non-empty, load this URL instead of the default.
// numeric_id_pre_alloc: pre-assigned numeric window id used to bake the
// canonical "win-<N>" Symbol.for('zapp.windowId') into the bootstrap user
// script. Pass -1 if no id is available yet (the caller will set the id
// later via JS eval; some early Window.current() calls may then race).
// transparent_background: when true, configure the WKWebView for
// transparent rendering (drawsBackground=NO + clear layer) before the
// initial loadRequest so the first paint preserves transparency. Used
// by windows with `vibrancy: ...` set so the NSVisualEffectView blur
// shows through. Reloading post-load would interrupt the initial
// bridge bootstrap and break in-flight invoke responses.
void darwin_webview_create(void* window_ptr, bool inspectable, bool accept_first_mouse,
                           const char* url_override, int32_t numeric_id_pre_alloc,
                           bool transparent_background);

// Extended creation path (native-sidebar feature). The three trailing params
// widen the legacy signature; at their defaults (NULL / -1 / false) behavior is
// byte-for-byte equivalent to darwin_webview_create.
//   - container_view: NSView* to mount the WKWebView into (the .sidebar split
//     item's view, or the main pane's vibrancy host). NULL = legacy mount
//     (replace the window's contentView / vibrancy-subview detection).
//   - identity_window_id: numeric id baked into Symbol.for('zapp.windowId').
//     A sidebar webview passes the HOST window's id so its runtime identifies
//     as the host while TRANSPORT stays on numeric_id_pre_alloc. -1 = self.
//   - pane_role: 0 = main pane, 1 = sidebar pane (sets zapp.isSidebar),
//     2 = popover pane (sets zapp.isPopover),
//     3 = inspector pane (sets zapp.isInspector). Document-start markers.
//   - host_has_sidebar: inject zapp.hasSidebar into this pane when true.
//   - host_has_inspector: inject zapp.hasInspector into this pane when true.
void darwin_webview_create_ext(void* window_ptr, bool inspectable, bool accept_first_mouse,
                               const char* url_override, int32_t numeric_id_pre_alloc,
                               bool transparent_background,
                               void* container_view, int32_t identity_window_id,
                               int32_t pane_role, bool host_has_sidebar,
                               bool host_has_inspector);

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
