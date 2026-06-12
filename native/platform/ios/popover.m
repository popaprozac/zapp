// iOS stubs — NSPopover is AppKit-only; the iOS analogue
// (UIPopoverPresentationController) is a future cycle. router.zc references
// darwin_popover_* under #ifdef __APPLE__, which is true on iOS too, so
// these stubs are REQUIRED for the iOS link (the #281 parity-gate class).
#include <stdint.h>

void darwin_popover_create(void* window_ptr, const char* popover_id,
                           const char* url, int32_t width, int32_t height,
                           const char* behavior, int32_t host_slot, int32_t popover_slot) {
    (void)window_ptr; (void)popover_id; (void)url; (void)width; (void)height;
    (void)behavior; (void)host_slot; (void)popover_slot;
}

void darwin_popover_show(const char* popover_id, const char* args_json) {
    (void)popover_id; (void)args_json;
}

void darwin_popover_hide(const char* popover_id) { (void)popover_id; }
void darwin_popover_destroy(const char* popover_id) { (void)popover_id; }
void zapp_popover_unregister_window(void* window_ptr) { (void)window_ptr; }
