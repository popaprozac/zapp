// iOS tray stub — there's no menu bar / status item on iOS. Apps
// using `Tray.create(...)` from cross-platform code get silent no-ops
// rather than crashes, matching the "desktop-only APIs no-op on iOS"
// strategy from project_ios_path memory.

#include <stddef.h>

void darwin_tray_create_from_payload(const char* payload_json) { (void)payload_json; }
void darwin_tray_set_icon_from_payload(const char* payload_json) { (void)payload_json; }
void darwin_tray_set_title_from_payload(const char* payload_json) { (void)payload_json; }
void darwin_tray_set_tooltip_from_payload(const char* payload_json) { (void)payload_json; }
void darwin_tray_set_menu_from_payload(const char* payload_json) { (void)payload_json; }
void darwin_tray_destroy_from_payload(const char* payload_json) { (void)payload_json; }
void darwin_tray_attach_window_from_payload(const char* payload_json) { (void)payload_json; }
void darwin_tray_detach_window_from_payload(const char* payload_json) { (void)payload_json; }
