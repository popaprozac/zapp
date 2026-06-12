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

// _WIN32 body guard: zc emits @cfg(windows) imports' #includes into EVERY
// platform's generated TU (@cfg gates functions, not import emission —
// vendor-ledger item). Without this, type definitions here collide with
// the darwin headers in macOS/iOS builds (ZappMenuItem broke the macOS
// build). On Windows _WIN32 is always defined, so this is inert there.
#ifdef _WIN32

#include <stdbool.h>

bool windows_shortcut_register(const char* accelerator);
bool windows_shortcut_unregister(const char* accelerator);
bool windows_shortcut_is_registered(const char* accelerator);
void windows_shortcut_unregister_all(void);

// Called by platform.c's GetMessage loop for WM_HOTKEY (thread-queue
// messages have no HWND, so DispatchMessage can't route them).
void windows_shortcut_handle_wm_hotkey(int hotkey_id);

#endif // _WIN32
#endif
