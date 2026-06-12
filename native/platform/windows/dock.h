// Windows taskbar analogues for the macOS dock API.
// badge → ITaskbarList3 overlay icon; bounce → FlashWindowEx;
// set/reset_icon → WM_SETICON; show/hide_icon → no-op.

#ifndef ZAPP_WINDOWS_DOCK_H
#define ZAPP_WINDOWS_DOCK_H

void windows_dock_show_icon(void);
void windows_dock_hide_icon(void);
void windows_dock_set_badge(const char* label);
void windows_dock_remove_badge(void);
const char* windows_dock_get_badge(void);
void windows_dock_bounce(int bounce_type);
void windows_dock_set_icon(const char* path);
void windows_dock_reset_icon(void);

#endif
