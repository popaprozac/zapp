// nim_gaps.c — the shrinking set of darwin_* C-ABI symbols the Nim layer imports
// (via native/nim/nativeabi.nim `abiPrefix`, bound as windows_* on Windows) that
// don't have a full native home yet. As real implementations land in their own
// .c (fs.c, window.c, webview.c, notification.c, …) the corresponding entries
// here are deleted. What remains is either an INTENTIONAL parity no-op (matching
// darwin) or a HELD item awaiting a design decision — see notes per group.
//
// The 3 dialog_*_async symbols are intentionally absent: they are iOS-only
// (native/nim/dialog.nim gates them behind `when defined(zappIos)`), so Windows
// never references them.
//
// Done elsewhere: fs (fs.c) · window get_by_numeric_id/focus/zoom + list_json
// (window.c) · devtools open/close (webview.c) · notification
// remove_all_delivered/remove_delivered_json/update_json (notification.c).

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// --- native chrome: sidebar / inspector titles + presentation ---------------
// INTENTIONAL NO-OPS — parity with darwin. darwin/sidebar.m makes these no-ops
// too: runtime pane titles / presentation modes are an iOS-only concept (iOS
// panes are UINavigationController columns). On macOS AND Windows the split
// panes host WebView2/WKWebView content and the app owns the sidebar/inspector
// header in web content, so there is no native title/presentation surface.
void        windows_sidebar_set_presentation(int32_t wid, const char* mode) { (void)wid; (void)mode; }
void        windows_sidebar_set_title(int32_t wid, const char* title)       { (void)wid; (void)title; }
void        windows_inspector_set_title(int32_t wid, const char* title)     { (void)wid; (void)title; }

// --- toolbar (3) — HELD pending the titlebar/toolbar design pass ------------
// macOS NSToolbar has no native Windows equivalent (no windows_toolbar_* exists).
// The likely direction is web-rendered toolbars (as the custom titlebar already
// integrates chrome into web content), which would make these permanent no-ops —
// but that's tied to the titleBarStyle mapping decision (hidden / hiddenInset /
// …). No-ops for now so the surface links; revisit with that follow-up.
void        windows_toolbar_set_items(void* w, const char* json, int32_t host_slot) { (void)w; (void)json; (void)host_slot; }
void        windows_toolbar_update_item(void* w, const char* item_json)     { (void)w; (void)item_json; }
void        windows_toolbar_remove(void* w)                                 { (void)w; }

// --- unprefixed shared C-ABI symbol the platform must provide ---------------
// zapp_form_factor: per-platform (darwin/ios .m define it). Windows is desktop.
// (The zapp_build_deep_link_schemes_json / zapp_build_single_instance getters
// are now emitted by renderBuildConfigNim as Nim {.exportc.} from real config —
// no longer stubbed here.)
const char* zapp_form_factor(void)                           { return "desktop"; }
