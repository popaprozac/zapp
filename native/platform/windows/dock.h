// Windows taskbar analogues for the macOS dock API.
// badge → ITaskbarList3 overlay icon; bounce → FlashWindowEx;
// set/reset_icon → WM_SETICON; show/hide_icon → no-op.

#ifndef ZAPP_WINDOWS_DOCK_H
#define ZAPP_WINDOWS_DOCK_H

// _WIN32 body guard: zc emits @cfg(windows) imports' #includes into EVERY
// platform's generated TU (@cfg gates functions, not import emission —
// vendor-ledger item). Without this, type definitions here collide with
// the darwin headers in macOS/iOS builds (ZappMenuItem broke the macOS
// build). On Windows _WIN32 is always defined, so this is inert there.
#ifdef _WIN32

void windows_dock_show_icon(void);
void windows_dock_hide_icon(void);
void windows_dock_set_badge(const char* label);
void windows_dock_remove_badge(void);
const char* windows_dock_get_badge(void);
void windows_dock_bounce(int bounce_type);
void windows_dock_set_icon(const char* path);
void windows_dock_reset_icon(void);

#endif // _WIN32
#endif
