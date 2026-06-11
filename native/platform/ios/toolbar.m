// iOS stubs — NSToolbar is AppKit-only; the iOS analogue (UINavigationBar)
// is a future cycle. These keep the shared window code linking on iOS
// (window.m's attach call compiles into the iOS build; see the
// ios-platform-parity gate in cli/src/ios-platform-parity.test.ts).
#include <stdint.h>

void darwin_toolbar_attach(void* window_ptr, const char* toolbar_json, int32_t window_numeric_id) {
    (void)window_ptr; (void)toolbar_json; (void)window_numeric_id;
}

void zapp_toolbar_unregister(void* window_ptr) {
    (void)window_ptr;
}
