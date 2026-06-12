// Windows global shortcuts — system-wide hotkeys via RegisterHotKey.
// Works regardless of app focus. Accelerator strings reuse the
// menu-style "CmdOrCtrl+Shift+Space" notation (CmdOrCtrl → Ctrl here;
// Cmd/Meta/Super → the Windows key).
//
// THREADING: RegisterHotKey binds to the calling thread's message
// queue. These functions must be called from the main/UI thread (the
// bridge router path is). The WM_HOTKEY messages are picked up by the
// hook in platform.c's message loop.

#ifndef ZAPP_WINDOWS_SHORTCUTS_H
#define ZAPP_WINDOWS_SHORTCUTS_H

#include <stdbool.h>

bool windows_shortcut_register(const char* accelerator);
bool windows_shortcut_unregister(const char* accelerator);
bool windows_shortcut_is_registered(const char* accelerator);
void windows_shortcut_unregister_all(void);

// Called by platform.c's GetMessage loop for WM_HOTKEY (thread-queue
// messages have no HWND, so DispatchMessage can't route them).
void windows_shortcut_handle_wm_hotkey(int hotkey_id);

#endif
