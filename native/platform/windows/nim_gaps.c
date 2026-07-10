// nim_gaps.c — TEMPORARY stubs for the darwin_* C-ABI symbols the Nim layer
// imports (via native/nim/nativeabi.nim `abiPrefix`) that have no windows_*
// implementation yet. Named windows_* so the seam binds them on Windows.
//
// Purpose: unblock the FIRST Windows-Nim link + a rendering window, proving the
// native-UI seam end-to-end. Each stub returns a safe default (no-op / false /
// NULL / "[]"). Phase C of docs/superpowers/2026-07-09-nim-windows-port-plan.md
// replaces these with real implementations (fs → Win32/CRT, window shims →
// delegate to the existing windows_window_* registry, open_external →
// ShellExecute, devtools → WebView2 OpenDevToolsWindow, etc.) and deletes the
// corresponding stub. When a real impl lands in its own .c, remove it here.
//
// The 3 dialog_*_async symbols are intentionally absent: they are iOS-only
// (native/nim/dialog.nim gates them behind `when defined(zappIos)`), so Windows
// never references them.

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// fs (11) is now a real implementation in native/platform/windows/fs.c.

// --- window shims (3) — Windows has near-twins (activate/registry) ----------
void*       windows_window_get_by_numeric_id(int32_t id)     { (void)id; return NULL; }
void        windows_window_focus(void* handle)               { (void)handle; }
void        windows_window_zoom(void* handle)                { (void)handle; }
const char* windows_windows_list_json(void)                  { return "[]"; }

// --- devtools (2) — Phase C: WebView2 OpenDevToolsWindow ---------------------
void        windows_devtools_open(int32_t window_id)         { (void)window_id; }
void        windows_devtools_close(int32_t window_id)        { (void)window_id; }

// --- notification delivered-management (3) ----------------------------------
void        windows_notification_remove_all_delivered(void)  { }
void        windows_notification_remove_delivered_json(const char* json) { (void)json; }
void        windows_notification_update_json(const char* json){ (void)json; }

// --- native chrome: sidebar (2) / inspector (1) -----------------------------
void        windows_sidebar_set_presentation(int32_t wid, const char* mode) { (void)wid; (void)mode; }
void        windows_sidebar_set_title(int32_t wid, const char* title)       { (void)wid; (void)title; }
void        windows_inspector_set_title(int32_t wid, const char* title)     { (void)wid; (void)title; }

// --- toolbar (3) — no windows_toolbar_* exists yet --------------------------
void        windows_toolbar_set_items(void* w, const char* json, int32_t host_slot) { (void)w; (void)json; (void)host_slot; }
void        windows_toolbar_update_item(void* w, const char* item_json)     { (void)w; (void)item_json; }
void        windows_toolbar_remove(void* w)                                 { (void)w; }

// --- unprefixed shared C-ABI symbols the platform must provide --------------
// zapp_form_factor: per-platform (darwin/ios .m define it). Windows is desktop.
const char* zapp_form_factor(void)                           { return "desktop"; }
// These two are build-config getters the zc path emits (build-config.ts:144)
// but the Nim renderBuildConfigNim does not. Referenced only by windows/
// deeplink.c. TODO(phase-c): emit from renderBuildConfigNim with the app's real
// config (config.singleInstance + deep-link schemes) and delete these stubs.
const char* zapp_build_deep_link_schemes_json(void)          { return "[]"; }
int         zapp_build_single_instance(void)                 { return 0; }
