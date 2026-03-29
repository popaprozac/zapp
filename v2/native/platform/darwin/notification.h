// C API for macOS notifications (UNUserNotificationCenter).
// Requires: app bundle + code signing + macOS 10.14+.
// Async APIs use a callback to dispatch results (avoids blocking the main thread).

#ifndef ZAPP_DARWIN_NOTIFICATION_H
#define ZAPP_DARWIN_NOTIFICATION_H

#include <stdbool.h>
#include <stdint.h>

// Callback for async notification results.
typedef void (*notif_callback_fn)(int32_t window_id, int32_t request_id, bool ok, const char* json);

// Request permission (async — shows system dialog, calls back when user responds).
void darwin_notification_request_permission(int32_t window_id, int32_t request_id, notif_callback_fn cb);

// Get current status (sync — no dialog, fast).
const char* darwin_notification_get_permission(void);

// Show notification (async — calls back with notification ID).
void darwin_notification_show(const char* options_json, int32_t window_id, int32_t request_id, notif_callback_fn cb);

// Schedule notification (async).
void darwin_notification_schedule(const char* options_json, int32_t window_id, int32_t request_id, notif_callback_fn cb);

// Cancel (sync).
void darwin_notification_cancel(const char* notification_id);
void darwin_notification_cancel_all(void);

// Delegate setup (auto-called).
void darwin_notification_setup_delegate(void);

// --- Native API (typed, fire-and-forget, zero JSON) ---
void darwin_notification_show_typed(const char* title, const char* subtitle, const char* body, const char* sound);
void darwin_notification_schedule_typed(const char* title, const char* body, double delay_seconds);

// --- Category registration (typed, for action buttons) ---
typedef struct {
    char* id;
    char* title;
    int destructive;
} ZappNotifAction;

void darwin_notification_register_category_typed(
    const char* cat_id,
    ZappNotifAction* actions, int action_count,
    int has_reply, const char* reply_placeholder, const char* reply_button);
void darwin_notification_remove_category(const char* cat_id);
void darwin_notification_show_with_category(const char* title, const char* body, const char* category_id);

#endif
