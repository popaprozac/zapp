// iOS stubs — NSToolbar is AppKit-only; the iOS analogue (UINavigationBar)
// is a future cycle. ios/window.m never calls these, but the stubs keep the
// symbol surface identical across platforms so shared Zen-C code (and the
// ios-platform-parity gate) can reference them safely if it ever does.
#include <stdint.h>

void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json, int32_t window_numeric_id) {
    (void)window_ptr; (void)toolbar_json; (void)window_numeric_id;
}

void zapp_toolbar_unregister(void* window_ptr) {
    (void)window_ptr;
}
