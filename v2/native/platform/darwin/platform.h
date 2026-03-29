// C API for macOS platform lifecycle.
// Implementation in platform.m (Objective-C).

#ifndef ZAPP_DARWIN_PLATFORM_H
#define ZAPP_DARWIN_PLATFORM_H

#include <stdbool.h>
#include <stdint.h>

// Initialize NSApplication, delegate, default menus.
void darwin_platform_init(const char* app_name);

// Run the Cocoa event loop (blocks until app terminates).
int darwin_platform_run(bool terminate_after_last_window);

#endif
