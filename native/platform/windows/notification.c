// Windows notification — stubs for Phase 0.
// Will be implemented in Phase 6 with Toast Notifications.

#include "notification.h"
#include <stddef.h>

void windows_notification_request_permission(int32_t window_id, int32_t request_id, notif_callback_fn cb) {
    // Windows doesn't need permission — auto-grant
    if (cb) cb(window_id, request_id, true, "\"granted\"");
}
const char* windows_notification_get_permission(void) { return "\"granted\""; }
void windows_notification_show(const char* options_json, int32_t window_id, int32_t request_id, notif_callback_fn cb) {
    (void)options_json; if (cb) cb(window_id, request_id, true, "{}");
}
void windows_notification_schedule(const char* options_json, int32_t window_id, int32_t request_id, notif_callback_fn cb) {
    (void)options_json; if (cb) cb(window_id, request_id, true, "{}");
}
void windows_notification_cancel(const char* notification_id) { (void)notification_id; }
void windows_notification_cancel_all(void) {}
void windows_notification_set_bridge_ready(void) {}
void windows_notification_show_typed(const char* title, const char* subtitle, const char* body, const char* sound) {
    (void)title; (void)subtitle; (void)body; (void)sound;
}
void windows_notification_register_category(const char* cat_id, const char* args_json) { (void)cat_id; (void)args_json; }
void windows_notification_remove_category(const char* cat_id) { (void)cat_id; }
