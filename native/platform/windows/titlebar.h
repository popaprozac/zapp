// titlebar.h — custom title bar for titleBarStyle: "hidden" / "hiddenInset".
//
// macOS-parity model: the window keeps its standard frame (DWM drop shadow,
// rounded corners, side/bottom/corner resize); only the top caption is removed
// so web content full-bleeds to the top edge. The native min/max/close buttons
// are KEPT — floated over the content top-right — matching macOS, which keeps
// the traffic lights for hidden/hiddenInset (hiding them is a separate control).
//
// Pass 1 (this file): caption removal (WM_NCCALCSIZE), floated native caption
// buttons (Segoe MDL2 glyphs, light/dark theme, hover/press, clicks ->
// WM_SYSCOMMAND), inactive-frame-line suppression (WM_NCACTIVATE), layout.
// Pass 2 (follow-up): web-driven drag regions (app-region: drag -> beginDrag)
// and the --zapp-window-controls-inset-right / --zapp-titlebar-height CSS vars.

#ifndef ZAPP_WINDOWS_TITLEBAR_H
#define ZAPP_WINDOWS_TITLEBAR_H

#include <windows.h>
#include <stdbool.h>
#include <stdint.h>

// Enable the custom title bar for a window. style_tag: 1 = hidden, 2 =
// hiddenInset (0/other = default, no custom chrome). Creates the caption-button
// child, drops the native menu bar, and forces a frame recalc. Idempotent.
void windows_titlebar_enable(HWND hwnd, int32_t window_id, int32_t style_tag);

// True if this window has the custom title bar (gates the wndproc hooks below).
bool windows_titlebar_enabled(int32_t window_id);

// WM_NCCALCSIZE handler — removes the top caption while keeping the resize
// borders. Returns true if it handled the message (caller returns 0).
bool windows_titlebar_nccalcsize(HWND hwnd, int32_t window_id, WPARAM wParam, LPARAM lParam);

// WM_NCACTIVATE handler — suppresses the inactive (light) frame line DWM paints
// under the caption on deactivation. Returns true if handled (caller returns the
// value written to *result).
bool windows_titlebar_ncactivate(HWND hwnd, int32_t window_id, WPARAM wParam, LRESULT* result);

// (Re)position + raise the caption-button cluster above the WebView2 surface.
// Call on WM_SIZE and after the webview controller mounts.
void windows_titlebar_layout(int32_t window_id);

// Re-theme the caption buttons (app light/dark changed). Safe to call anytime.
void windows_titlebar_theme_changed(int32_t window_id);

// Per-button window-control visibility (from windowControls/trafficLights):
// 0=enabled, 1=disabled (greyed, inert), 2=hidden (dropped, cluster contracts).
// Windows caption order is minimize, maximize, close.
void windows_titlebar_set_controls(int32_t window_id, int close_state, int min_state, int max_state);

// Tear down the button child for a window (WM_DESTROY).
void windows_titlebar_destroy(int32_t window_id);

// Logical (CSS px) caption metrics for a window slot, for the web chrome's CSS
// vars: *height_logical = control cluster height (--zapp-titlebar-height, so
// content can pad the top under the buttons), *inset_right_logical = cluster
// width (--zapp-window-controls-inset-right, so headers pad around the buttons).
// Returns true if the window has a custom title bar; false (out-params
// untouched) otherwise. Keyed by the HOST window slot (titlebar is enabled on
// the host; panes must resolve their host slot before calling).
bool windows_titlebar_metrics(int32_t window_id, int* height_logical, int* inset_right_logical);

#endif // ZAPP_WINDOWS_TITLEBAR_H
