// Windows tray — Shell_NotifyIcon. Payload-driven API mirroring
// darwin/tray.h: every tray is keyed by a JS-supplied numeric id;
// payloads are the full bridge envelope (flat keys read from "a").
//
// Notes vs macOS:
// - "title" has no menu-bar-text analogue; it feeds the tooltip.
// - attachWindow toggles the window near the taskbar corner (per-icon
//   anchoring via Shell_NotifyIconGetRect is a follow-up), and
//   dismissOnBlur is accepted but not yet enforced.

#ifndef ZAPP_WINDOWS_TRAY_H
#define ZAPP_WINDOWS_TRAY_H

void windows_tray_create_from_payload(const char* payload_json);
void windows_tray_set_icon_from_payload(const char* payload_json);
void windows_tray_set_title_from_payload(const char* payload_json);
void windows_tray_set_tooltip_from_payload(const char* payload_json);
void windows_tray_set_menu_from_payload(const char* payload_json);
void windows_tray_destroy_from_payload(const char* payload_json);
void windows_tray_attach_window_from_payload(const char* payload_json);
void windows_tray_detach_window_from_payload(const char* payload_json);

#endif
