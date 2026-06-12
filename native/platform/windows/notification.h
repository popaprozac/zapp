// C API for Windows notifications (Toast Notifications).
// Implementation in notification.c (Win32 COM/WinRT).

#ifndef ZAPP_WINDOWS_NOTIFICATION_H
#define ZAPP_WINDOWS_NOTIFICATION_H

// _WIN32 body guard: zc emits @cfg(windows) imports' #includes into EVERY
// platform's generated TU (@cfg gates functions, not import emission —
// vendor-ledger item). Without this, type definitions here collide with
// the darwin headers in macOS/iOS builds (ZappMenuItem broke the macOS
// build). On Windows _WIN32 is always defined, so this is inert there.
#ifdef _WIN32

#include <stdbool.h>
#include <stdint.h>

// Callback for async notification results.
typedef void (*notif_callback_fn)(int32_t window_id, int32_t request_id, bool ok, const char* json);

void windows_notification_request_permission(int32_t window_id, int32_t request_id, notif_callback_fn cb);
const char* windows_notification_get_permission(void);
void windows_notification_show(const char* options_json, int32_t window_id, int32_t request_id, notif_callback_fn cb);
void windows_notification_schedule(const char* options_json, int32_t window_id, int32_t request_id, notif_callback_fn cb);
void windows_notification_cancel(const char* notification_id);
void windows_notification_cancel_all(void);
void windows_notification_set_bridge_ready(void);

// --- Native typed API ---
void windows_notification_show_typed(const char* title, const char* subtitle, const char* body, const char* sound);

// --- Category registration ---
void windows_notification_register_category(const char* cat_id, const char* args_json);
void windows_notification_remove_category(const char* cat_id);

#endif // _WIN32
#endif
