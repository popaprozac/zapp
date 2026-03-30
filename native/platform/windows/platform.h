// C API for Windows platform lifecycle.
// Implementation in platform.c (Win32).

#ifndef ZAPP_WINDOWS_PLATFORM_H
#define ZAPP_WINDOWS_PLATFORM_H

#include <stdbool.h>
#include <stdint.h>

// Initialize COM, register window class, store app name.
void windows_platform_init(const char* app_name);

// Run the Win32 message loop (blocks until app terminates).
int windows_platform_run(bool terminate_after_last_window);

#endif
