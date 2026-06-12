// C API for Windows platform lifecycle.
// Implementation in platform.c (Win32).

#ifndef ZAPP_WINDOWS_PLATFORM_H
#define ZAPP_WINDOWS_PLATFORM_H

// _WIN32 body guard: zc emits @cfg(windows) imports' #includes into EVERY
// platform's generated TU (@cfg gates functions, not import emission —
// vendor-ledger item). Without this, type definitions here collide with
// the darwin headers in macOS/iOS builds (ZappMenuItem broke the macOS
// build). On Windows _WIN32 is always defined, so this is inert there.
#ifdef _WIN32

#include <stdbool.h>
#include <stdint.h>

// Initialize COM, register window class, store app name.
void windows_platform_init(const char* app_name);

// Run the Win32 message loop (blocks until app terminates).
int windows_platform_run(bool terminate_after_last_window);

#endif // _WIN32
#endif
