// iOS menu shim — iOS has no app menu bar, so all menu_set / context
// menu calls are no-ops. UIMenuController could host context menus
// later (Phase 4); for the Phase 1 spike everything stubs out cleanly.
//
// We don't include menu.h because the macOS header pulls in macOS-only
// types (NSMenu via objc.h indirection); we just declare the symbols
// matching the same names so the framework's calls link.

#include <stdint.h>

void darwin_menu_set(const char* items_json) { (void)items_json; }
void darwin_menu_set_from_payload(const char* payload_json) { (void)payload_json; }
void darwin_menu_show_context(const char* items_json, int32_t x, int32_t y, int32_t window_id) {
    (void)items_json; (void)x; (void)y; (void)window_id;
}
void darwin_menu_show_context_from_payload(const char* payload_json, int32_t window_id) {
    (void)payload_json; (void)window_id;
}

// Typed API — same signatures the macOS menu.m exports. Stub returns
// nothing meaningful; the framework's Zen-C menu manager just sees
// "no menus available."
void darwin_menu_set_typed(void* items, int32_t count) {
    (void)items; (void)count;
}
void darwin_menu_show_context_typed(void* items, int32_t count, int32_t x, int32_t y, int32_t window_id) {
    (void)items; (void)count; (void)x; (void)y; (void)window_id;
}
