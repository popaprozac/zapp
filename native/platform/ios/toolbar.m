// iOS stubs — NSToolbar is AppKit-only; the iOS analogue (UINavigationBar)
// is a future cycle. ios/window.m never calls these, but the stubs keep the
// symbol surface identical across platforms so shared Zen-C code (and the
// ios-platform-parity gate) can reference them safely if it ever does.
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json, int32_t window_numeric_id) {
    (void)window_ptr; (void)toolbar_json; (void)window_numeric_id;
}

void zapp_toolbar_unregister(void* window_ptr) {
    (void)window_ptr;
}

void zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script) {
    (void)window_ptr; (void)host_slot; (void)add_user_script;
}

void darwin_toolbar_set_items(void* window_ptr, const char* toolbar_json, int32_t host_slot) {
    (void)window_ptr; (void)toolbar_json; (void)host_slot;
}

void darwin_toolbar_update_item(void* window_ptr, const char* item_json) {
    (void)window_ptr; (void)item_json;
}

void darwin_toolbar_remove(void* window_ptr) {
    (void)window_ptr;
}

