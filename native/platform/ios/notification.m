// iOS notification shim — Phase 1 stubs. UNUserNotificationCenter is
// iOS-native; phase 2 ports the macOS notification.m wholesale (most
// of the API is identical — same UNNotificationRequest /
// UNMutableNotificationContent / UNNotificationCategory shapes). For
// the spike, every entry point is a no-op returning the "denied" or
// "no-op" path so the framework links cleanly.

#include <stdbool.h>
#include <stdint.h>

typedef void (*notif_callback_fn)(int32_t, int32_t, bool, const char*);

const char* darwin_notification_get_permission(void) { return "notDetermined"; }
void darwin_notification_request_permission(int32_t wid, int32_t rid, notif_callback_fn cb) {
    if (cb) cb(wid, rid, true, "{\"status\":\"notDetermined\"}");
}
void darwin_notification_show(const char* opts, int32_t wid, int32_t rid, notif_callback_fn cb) {
    (void)opts;
    if (cb) cb(wid, rid, true, "{\"id\":\"\"}");
}
void darwin_notification_schedule(const char* opts, int32_t wid, int32_t rid, notif_callback_fn cb) {
    (void)opts;
    if (cb) cb(wid, rid, true, "{\"id\":\"\"}");
}
void darwin_notification_cancel(const char* id) { (void)id; }
void darwin_notification_cancel_all(void) {}
void darwin_notification_remove_delivered(const char* id) { (void)id; }
void darwin_notification_remove_delivered_json(const char* id_json) { (void)id_json; }
void darwin_notification_remove_all_delivered(void) {}
void darwin_notification_register_category(const char* opts) { (void)opts; }
void darwin_notification_remove_category(const char* id) { (void)id; }
void darwin_notification_update(const char* id, const char* title, const char* body, const char* sound) {
    (void)id; (void)title; (void)body; (void)sound;
}
void darwin_notification_update_json(const char* opts) { (void)opts; }
void darwin_notification_show_typed(const char* title, const char* subtitle, const char* body, const char* sound) {
    (void)title; (void)subtitle; (void)body; (void)sound;
}
void darwin_notification_show_with_attachment(const char* title, const char* body, const char* attachment) {
    (void)title; (void)body; (void)attachment;
}
void darwin_notification_show_with_category(const char* title, const char* body, const char* category) {
    (void)title; (void)body; (void)category;
}
void darwin_notification_schedule_typed(const char* title, const char* body, double delay_seconds) {
    (void)title; (void)body; (void)delay_seconds;
}
void darwin_notification_register_category_typed(const char* id, void* actions, int count) {
    (void)id; (void)actions; (void)count;
}
void darwin_notification_setup_delegate(void) {}
void darwin_notification_set_bridge_ready(void) {}
