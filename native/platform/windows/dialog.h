// C API for Windows native dialogs.
// Implementation in dialog.c (Win32 COM IFileDialog + TaskDialog).

#ifndef ZAPP_WINDOWS_DIALOG_H
#define ZAPP_WINDOWS_DIALOG_H

#include <stdbool.h>
#include <stdint.h>

// Extract "a" (args) from a full bridge message JSON. Returns JSON string.
const char* windows_dialog_extract_args(const char* full_json);

// All functions take JSON options and return JSON result strings.
// Caller must NOT free the returned string (static buffer).

// Open file dialog. Returns: {"paths":["..."],"cancelled":false}
const char* windows_dialog_open_file(const char* options_json);

// Save file dialog. Returns: {"path":"...","cancelled":false}
const char* windows_dialog_save_file(const char* options_json);

// Message dialog. Returns: {"button":0}
const char* windows_dialog_message(const char* options_json);

// --- Native API (typed params, zero JSON overhead) ---

const char* windows_dialog_open_file_typed(const char* title, bool multiple, bool directory);
const char* windows_dialog_save_file_typed(const char* title, const char* default_name);
int windows_dialog_message_typed(const char* message, const char* title, int style);
int windows_dialog_message_buttons_typed(const char* message, const char* title, int style,
                                         const char* btn1, const char* btn2, const char* btn3);

#endif
