// macOS global shortcuts — system-wide hotkeys via Carbon's
// RegisterEventHotKey API. Works regardless of app focus and does not
// require accessibility entitlement (unlike NSEvent global monitor).
//
// Accelerator strings reuse the menu-style "CmdOrCtrl+Shift+Space"
// notation so users have one syntax to remember.

#ifndef ZAPP_DARWIN_SHORTCUTS_H
#define ZAPP_DARWIN_SHORTCUTS_H

#include <stdbool.h>

// Register a global hotkey. Returns true on success, false on:
//   - unknown accelerator (modifier or key not recognised)
//   - already registered (use unregister + register to replace)
//   - the system already binds it (Carbon refuses; usually returns
//     `eventHotKeyExistsErr`)
bool darwin_shortcut_register(const char* accelerator);

// Unregister a previously-registered shortcut. Returns true if found
// and removed, false if not registered. Idempotent — safe to call on
// strings that were never registered.
bool darwin_shortcut_unregister(const char* accelerator);

// Test whether an accelerator is currently registered by this app.
bool darwin_shortcut_is_registered(const char* accelerator);

// Tear down every registered shortcut. Called automatically at app
// shutdown; also exposed for explicit cleanup (e.g. user "Reset
// shortcuts" UI).
void darwin_shortcut_unregister_all(void);

#endif
